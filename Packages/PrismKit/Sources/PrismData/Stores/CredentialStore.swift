import Foundation
import OSLog
import PrismCore
import Security
import Synchronization

/// Secure storage for source passwords and app secrets (TMDB API key stored as secret `"tmdb"`).
public protocol CredentialStoring: Sendable {
    func password(for source: SourceID) -> String?
    func setPassword(_ password: String?, for source: SourceID) throws
    func secret(named name: String) -> String?
    func setSecret(_ value: String?, named name: String) throws
}

public extension CredentialStoring {
    /// TMDB API key / read access token.
    var tmdbKey: String? { secret(named: CredentialKeys.tmdb) }
}

public enum CredentialKeys {
    public static let tmdb = "tmdb"
    public static let theSportsDB = "thesportsdb"
}

public struct KeychainError: LocalizedError, Sendable, Equatable {
    public let status: OSStatus

    public init(status: OSStatus) { self.status = status }

    public var errorDescription: String? {
        let message = SecCopyErrorMessageString(status, nil) as String? ?? "code \(status)"
        return "Impossible d’accéder au trousseau (\(message))."
    }
}

/// Keychain-backed store (generic passwords, service `app.prism.credentials`).
public struct KeychainCredentialStore: CredentialStoring {
    public static let defaultService = "app.prism.credentials"

    /// Memoized read outcome per account: `SecItemCopyMatching` is synchronous and callers ask
    /// for the same secrets repeatedly (every detail/metadata/guide request). Writes update it.
    private enum Memo: Sendable {
        case hit(String)
        case miss
    }

    /// `Mutex` is noncopyable: boxed so the store struct stays `Copyable` while all copies
    /// still share the same memo.
    private final class MemoStorage: Sendable {
        let entries = Mutex<[String: Memo]>([:])
    }

    private static let logger = Logger(subsystem: "app.prism", category: "credentials")

    public let service: String
    private let memo = MemoStorage()

    public init(service: String = KeychainCredentialStore.defaultService) {
        self.service = service
    }

    public func password(for source: SourceID) -> String? {
        read(account: Self.passwordAccount(source))
    }

    public func setPassword(_ password: String?, for source: SourceID) throws {
        try write(password, account: Self.passwordAccount(source))
    }

    public func secret(named name: String) -> String? {
        read(account: Self.secretAccount(name))
    }

    public func setSecret(_ value: String?, named name: String) throws {
        try write(value, account: Self.secretAccount(name))
    }

    static func passwordAccount(_ source: SourceID) -> String { "source:\(source.rawValue)" }
    static func secretAccount(_ name: String) -> String { "secret:\(name)" }

    private func baseQuery(account: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    private func read(account: String) -> String? {
        if let memoized = memo.entries.withLock({ $0[account] }) {
            if case .hit(let value) = memoized { return value }
            return nil
        }
        var query = baseQuery(account: account)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        switch status {
        case errSecSuccess:
            guard let data = result as? Data, let value = String(data: data, encoding: .utf8) else {
                memo.entries.withLock { $0[account] = .miss }
                return nil
            }
            memo.entries.withLock { $0[account] = .hit(value) }
            return value
        case errSecItemNotFound:
            memo.entries.withLock { $0[account] = .miss }
            return nil
        default:
            // Not cached: an unexpected status (locked keychain, ACL…) may be transient.
            Self.logger.error("SecItemCopyMatching failed for \(account, privacy: .public): OSStatus \(status)")
            return nil
        }
    }

    private func write(_ value: String?, account: String) throws {
        let query = baseQuery(account: account)
        guard let value, !value.isEmpty else {
            let status = SecItemDelete(query as CFDictionary)
            guard status == errSecSuccess || status == errSecItemNotFound else {
                Self.logger.error("SecItemDelete failed for \(account, privacy: .public): OSStatus \(status)")
                throw KeychainError(status: status)
            }
            memo.entries.withLock { $0[account] = .miss }
            return
        }
        let data = Data(value.utf8)
        // Keep using the macOS login Keychain so existing items stay readable. The
        // accessibility attribute is available only for the data protection Keychain.
        let attributes: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        switch status {
        case errSecSuccess:
            memo.entries.withLock { $0[account] = .hit(value) }
            return
        case errSecItemNotFound:
            var add = query
            add.merge(attributes) { _, new in new }
            add[kSecAttrLabel as String] = "Prism"
            let addStatus = SecItemAdd(add as CFDictionary, nil)
            let writeStatus = addStatus == errSecDuplicateItem ? SecItemUpdate(query as CFDictionary, attributes as CFDictionary) : addStatus
            guard writeStatus == errSecSuccess else {
                Self.logger.error("SecItemAdd/Update failed for \(account, privacy: .public): OSStatus \(writeStatus)")
                throw KeychainError(status: writeStatus)
            }
            memo.entries.withLock { $0[account] = .hit(value) }
        default:
            Self.logger.error("SecItemUpdate failed for \(account, privacy: .public): OSStatus \(status)")
            throw KeychainError(status: status)
        }
    }
}

/// Lock-protected in-memory store for tests and previews.
/// (`Mutex`-protected, so the `Sendable` conformance is compiler-checked.)
public final class InMemoryCredentialStore: CredentialStoring, Sendable {
    private let storage: Mutex<[String: String]>

    public init(passwords: [SourceID: String] = [:], secrets: [String: String] = [:]) {
        var initial: [String: String] = [:]
        for (id, password) in passwords { initial[KeychainCredentialStore.passwordAccount(id)] = password }
        for (name, value) in secrets { initial[KeychainCredentialStore.secretAccount(name)] = value }
        storage = Mutex(initial)
    }

    public func password(for source: SourceID) -> String? {
        storage.withLock { $0[KeychainCredentialStore.passwordAccount(source)] }
    }

    public func setPassword(_ password: String?, for source: SourceID) throws {
        storage.withLock { $0[KeychainCredentialStore.passwordAccount(source)] = password?.isEmpty == false ? password : nil }
    }

    public func secret(named name: String) -> String? {
        storage.withLock { $0[KeychainCredentialStore.secretAccount(name)] }
    }

    public func setSecret(_ value: String?, named name: String) throws {
        storage.withLock { $0[KeychainCredentialStore.secretAccount(name)] = value?.isEmpty == false ? value : nil }
    }
}
