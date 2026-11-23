import Foundation
import PrismCore
import PrismData

/// `prism-tools refresh [containerDir]` — runs a REAL source refresh (network + decode + cache
/// write) against the installed app's sources, with caches redirected to a temp directory so the
/// user's real catalog/EPG caches are left untouched.
///
/// Password resolution: `PRISM_SOURCE_PASSWORD` env var wins (applies to every Xtream source);
/// otherwise the login keychain is used. Per-stage timings are printed as the import progresses.
enum RefreshCommand {
    static func run(_ arguments: [String]) -> Int32 {
        let container = arguments.first.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Library/Containers/app.prism.Prism/Data/Library", directoryHint: .isDirectory)
        let realRoot = container.appending(path: "Application Support/Prism", directoryHint: .isDirectory)
        // Caches go to a scratch dir: refresh() saves the catalog + playlist EPG URLs there,
        // never into the user's real Caches/Prism.
        let scratch = FileManager.default.temporaryDirectory
            .appending(path: "Prism-refresh-\(UUID().uuidString.prefix(8))", directoryHint: .isDirectory)
        let directories = AppDirectories(root: realRoot, caches: scratch)

        let sources = SourceStore(directories: directories).load().filter(\.isEnabled)
        guard !sources.isEmpty else {
            print("no enabled sources in \(realRoot.path)")
            return 1
        }
        let passwordOverride = ProcessInfo.processInfo.environment["PRISM_SOURCE_PASSWORD"]
        let credentials = BenchmarkCredentials(
            fallback: KeychainCredentialStore(),
            password: passwordOverride
        )
        let repository = CatalogRepository(
            directories: directories,
            credentials: credentials,
            cache: CatalogCache(directories: directories),
            session: PrismURLSession.shared
        )

        var exitCode: Int32 = 0
        var done = false
        Task {
            exitCode = await refreshAll(repository: repository, sources: sources)
            done = true
        }
        while !done { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.05)) }
        return exitCode
    }

    private static func refreshAll(repository: CatalogRepository, sources: [Source]) async -> Int32 {
        var worst: Int32 = 0
        for source in sources {
            print("== \(source.name) (\(source.kind.rawValue)) ==")
            let start = Date()
            var stageStart = start
            var lastStage = ""
            var finishedCatalog: SourceCatalog?
            do {
                for try await progress in repository.refresh(source) {
                    let now = Date()
                    let label = stageLabel(progress.stage)
                    if label != lastStage {
                        if !lastStage.isEmpty {
                            print(String(format: "  %-14@ %8.0f ms  (t+%.0f ms)", lastStage as NSString, now.timeIntervalSince(stageStart) * 1000, now.timeIntervalSince(start) * 1000))
                        }
                        lastStage = label
                        stageStart = now
                    }
                    if progress.stage == .finished { finishedCatalog = progress.catalog }
                }
            } catch {
                print("  FAILED: \(error.localizedDescription)")
                worst = 1
                continue
            }
            let total = Date().timeIntervalSince(start) * 1000
            if let catalog = finishedCatalog {
                print(String(format: "  %-14@ %8.0f ms  (t+%.0f ms)", "finished+save" as NSString, Date().timeIntervalSince(stageStart) * 1000, total))
                print(String(format: "  TOTAL %.0f ms — %d channels, %d movies, %d series — footprint %@, maxRSS %.0f MB",
                             total, catalog.channels.count, catalog.movies.count, catalog.series.count,
                             CatalogCommand.footprint(), rusageMB()))
            }
        }
        return worst
    }

    private static func stageLabel(_ stage: ImportStage) -> String {
        switch stage {
        case .connecting: "connecting"
        case .account: "account"
        case .downloading: "downloading"
        case .parsing: "parsing"
        case .channels: "channels"
        case .movies: "movies"
        case .series: "series"
        case .guide: "guide"
        case .finished: "finished"
        }
    }

    private static func rusageMB() -> Double {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        return Double(usage.ru_maxrss) / 1_048_576
    }
}

/// Credential store that prefers `PRISM_SOURCE_PASSWORD` over the keychain (avoids a keychain
/// prompt from the unsigned CLI binary).
private struct BenchmarkCredentials: CredentialStoring {
    let fallback: KeychainCredentialStore
    let password: String?

    func password(for source: SourceID) -> String? {
        password ?? fallback.password(for: source)
    }

    func setPassword(_ password: String?, for source: SourceID) throws {
        try fallback.setPassword(password, for: source)
    }

    func secret(named name: String) -> String? {
        fallback.secret(named: name)
    }

    func setSecret(_ value: String?, named name: String) throws {
        try fallback.setSecret(value, named: name)
    }
}
