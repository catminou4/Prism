import CoreGraphics
import Foundation

/// Pure formatting helpers for the player UI (French conventions).
nonisolated public enum PlayerFormat {
    /// "00:27", "12:05", "1:02:03". Negative / non-finite values render as "00:00".
    /// - Parameter forceHours: renders "0:00:27" so elapsed/remaining labels keep the same width
    ///   on content longer than an hour.
    public static func timecode(_ seconds: TimeInterval, forceHours: Bool = false) -> String {
        let total = seconds.isFinite ? max(0, Int(seconds.rounded(.down))) : 0
        let h = total / 3600
        let m = (total % 3600) / 60
        let s = total % 60
        if h > 0 || forceHours {
            return "\(h):" + twoDigits(m) + ":" + twoDigits(s)
        }
        return twoDigits(m) + ":" + twoDigits(s)
    }

    /// Remaining time label: "-02:09".
    public static func remaining(current: TimeInterval, duration: TimeInterval) -> String {
        let left = max(0, (duration.isFinite ? duration : 0) - (current.isFinite ? current : 0))
        return "-" + timecode(left.rounded(.up), forceHours: duration >= 3600)
    }

    /// Duration label: "57 min", "1 h 35 min", "2 h".
    public static func durationLabel(seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds > 0 else { return "0 min" }
        let minutes = max(1, Int((seconds / 60).rounded()))
        let h = minutes / 60
        let m = minutes % 60
        switch (h, m) {
        case (0, _): return "\(m) min"
        case (_, 0): return "\(h) h"
        default: return "\(h) h \(m) min"
        }
    }

    /// "1920 × 1080".
    public static func resolution(_ size: CGSize) -> String {
        "\(Int(size.width.rounded())) × \(Int(size.height.rounded()))"
    }

    /// "25", "29,97".
    public static func frameRate(_ fps: Double) -> String {
        guard fps.isFinite, fps > 0 else { return "—" }
        if abs(fps - fps.rounded()) < 0.01 { return "\(Int(fps.rounded()))" }
        return String(format: "%.2f", fps).replacingOccurrences(of: ".", with: ",")
    }

    /// "4,2 Mb/s", "850 kb/s".
    public static func bitrate(_ bitsPerSecond: Double) -> String {
        guard bitsPerSecond.isFinite, bitsPerSecond > 0 else { return "—" }
        if bitsPerSecond >= 1_000_000 {
            return String(format: "%.1f Mb/s", bitsPerSecond / 1_000_000)
                .replacingOccurrences(of: ".", with: ",")
        }
        return "\(Int((bitsPerSecond / 1000).rounded())) kb/s"
    }

    /// "+10 s" / "−10 s" (typographic minus).
    public static func skipLabel(_ seconds: Int) -> String {
        seconds >= 0 ? "+\(seconds) s" : "−\(abs(seconds)) s"
    }

    /// "1×", "1,5×", "0,75×".
    public static func rateLabel(_ rate: Float) -> String {
        let value = Double(rate)
        if abs(value - value.rounded()) < 0.001 { return "\(Int(value.rounded()))×" }
        var text = String(format: "%.2f", value)
        while text.hasSuffix("0") { text.removeLast() }
        return text.replacingOccurrences(of: ".", with: ",") + "×"
    }

    /// "20:45" wall-clock time for live programmes.
    public static func clockTime(_ date: Date) -> String {
        let c = Calendar.current.dateComponents([.hour, .minute], from: date)
        return twoDigits(c.hour ?? 0) + ":" + twoDigits(c.minute ?? 0)
    }

    private static func twoDigits(_ value: Int) -> String {
        value < 10 ? "0\(value)" : "\(value)"
    }
}
