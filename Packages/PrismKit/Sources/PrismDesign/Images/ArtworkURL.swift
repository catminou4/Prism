import CoreGraphics
import Foundation

/// Requests artwork at the size it is displayed instead of the size a provider happened to list.
///
/// TMDB serves every image at a set of standard widths from one master. Providers often list
/// `original` (several megabytes) or `w600_and_h900_bestv2` for a 300-pixel card; asking for the
/// smallest standard width that still covers the slot cuts the transfer and decode time severalfold.
nonisolated enum ArtworkURL {
    /// Standard TMDB widths the pipeline picks from. Anything smaller would be a second download
    /// next to the card-sized copy that is almost always on disk already.
    static let tmdbWidths = [342, 500, 780, 1280]

    /// A TMDB size token from an image path.
    struct SizeToken: Equatable {
        /// `nil` for `original`.
        let width: Int?
        /// Width / height when the token is a fixed crop (`w600_and_h900_bestv2`).
        let aspect: CGFloat?

        init?(_ token: Substring) {
            if token == "original" {
                width = nil
                aspect = nil
                return
            }
            guard token.first == "w" else { return nil }
            let body = token.dropFirst()
            if let value = Int(body), value > 0 {
                width = value
                aspect = nil
                return
            }
            // `w600_and_h900_bestv2`: a poster-shaped crop, identical in framing to the native 2:3 image.
            let pieces = body.split(separator: "_")
            guard pieces.count == 4, pieces[1] == "and", pieces[3] == "bestv2", pieces[2].first == "h",
                  let w = Int(pieces[0]), let h = Int(pieces[2].dropFirst()), w > 0, h > 0 else { return nil }
            width = w
            aspect = CGFloat(w) / CGFloat(h)
        }

        /// Pixels of width this token can deliver (`original` is unbounded).
        var capacity: Int { width ?? .max }
    }

    struct Resolved: Equatable {
        /// What to download first.
        let primary: URL
        /// The provider's own URL, when it differs from `primary` (tried if `primary` fails).
        let fallback: URL?
        /// The fallback's bytes already on disk are at least as large as `primary`'s.
        let fallbackIsLarger: Bool
        /// `primary` is a TMDB `original`: a 1280-wide copy can be shown while it downloads.
        let isOriginal: Bool
    }

    /// The URL to download for a decode target.
    static func resolve(_ url: URL, target: CGSize, fitting: ImagePipeline.Fitting, fillsForBlur: Bool) -> Resolved {
        guard let parsed = parse(url) else {
            return Resolved(primary: url, fallback: nil, fallbackIsLarger: false, isOriginal: false)
        }
        let needed = neededWidth(target: target, fitting: fitting, fillsForBlur: fillsForBlur, aspect: parsed.token.aspect)
        let chosen = tmdbWidths.first { $0 >= needed }
        let token = chosen.map { "w\($0)" } ?? "original"
        guard let primary = URL(string: "https://image.tmdb.org/t/p/\(token)/\(parsed.file)") else {
            return Resolved(primary: url, fallback: nil, fallbackIsLarger: false, isOriginal: false)
        }
        if primary == url {
            return Resolved(primary: url, fallback: nil, fallbackIsLarger: false, isOriginal: chosen == nil)
        }
        return Resolved(
            primary: primary, fallback: url,
            fallbackIsLarger: parsed.token.capacity >= (chosen ?? .max),
            isOriginal: chosen == nil
        )
    }

    /// Width in source pixels that covers (`fill`) or fits (`fit`) `target`.
    static func neededWidth(target: CGSize, fitting: ImagePipeline.Fitting, fillsForBlur: Bool, aspect: CGFloat?) -> Int {
        let roleAspect: CGFloat? = switch fitting {
        case .landscapeFill: 16.0 / 9.0
        case .portraitFit: 2.0 / 3.0
        case .fill, .fit: nil
        }
        let hint = aspect ?? roleAspect
        let width: CGFloat
        if let hint {
            let fromHeight = target.height * hint
            width = fitting.fillsTarget || fillsForBlur ? max(target.width, fromHeight) : min(target.width, fromHeight)
        } else {
            width = target.width
        }
        return Int(width.rounded(.up))
    }

    /// TMDB's image CDN. Its masters are always JPEG/PNG — WebP only exists as a
    /// content-negotiated re-encode — so downloads from these hosts can safely refuse
    /// WebP/AVIF in their `Accept` header (see `ImagePipeline.download`).
    static func isTMDBHost(_ url: URL) -> Bool {
        guard let host = url.host()?.lowercased() else { return false }
        return host == "image.tmdb.org" || host == "themoviedb.org" || host.hasSuffix(".themoviedb.org")
    }

    private static func parse(_ url: URL) -> (token: SizeToken, file: Substring)? {
        guard isTMDBHost(url), url.query() == nil else { return nil }
        let path = url.path(percentEncoded: true)
        let parts = path.split(separator: "/", maxSplits: 3, omittingEmptySubsequences: true)
        guard parts.count == 4, parts[0] == "t", parts[1] == "p", !parts[3].isEmpty, !parts[3].contains("/"),
              let token = SizeToken(parts[2]) else { return nil }
        return (token, parts[3])
    }
}
