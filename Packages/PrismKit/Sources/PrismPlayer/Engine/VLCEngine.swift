import AVFoundation
import AppKit
import Foundation
import VLCKitSPM

/// Drawable handed to libvlc; reports size changes so fill/stretch geometry follows the window.
final class VLCDrawableView: BlackVideoSurfaceView {
    var onResize: ((CGSize) -> Void)?
    private var lastSize: CGSize = .zero

    override func layout() {
        super.layout()
        if bounds.size != lastSize {
            lastSize = bounds.size
            onResize?(bounds.size)
        }
    }
}

/// libvlc engine (VLCKit 3.6): MPEG-TS, MKV, AVI, RTMP/RTSP/UDP… No PiP / AirPlay video.
final class VLCEngine: NSObject, PlaybackEngine {
    let kind: PlaybackEngineKind = .vlc
    var eventHandler: ((EngineEvent) -> Void)?
    var videoView: NSView { drawable }
    var routingPlayer: AVPlayer? { nil }

    private let player: VLCMediaPlayer
    private let drawable = VLCDrawableView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    private let delegateProxy = VLCDelegateProxy()
    private let configuration: EngineConfiguration

    private var currentURL: URL?
    private var isLive = false
    private var wantsPlay = false
    private var didReportReady = false
    private var reportedDuration: TimeInterval?
    private var didReportFirstFrame = false
    private var lastState: EnginePlaybackState?
    private var lastTimeMs: Int32 = -1
    private var lastTimeChange = Date.distantPast
    private var lastVideoSize: CGSize = .zero
    private var bufferingCheck: Task<Void, Never>?
    private var trackSignature = ""
    private var volumeValue: Float = 1
    private var mutedValue = false
    private var isStopped = false

    init(configuration: EngineConfiguration) {
        self.configuration = configuration
        self.subtitleStyle = configuration.subtitleStyle
        self.player = VLCMediaPlayer()
        super.init()
        player.drawable = drawable
        delegateProxy.owner = self
        player.delegate = delegateProxy
        drawable.onResize = { [weak self] _ in self?.applyGeometry() }
    }

    isolated deinit {
        stop()
    }

    // MARK: - Loading

    func load(url: URL, headers: [String: String], startPosition: TimeInterval?, isLive: Bool) {
        self.isLive = isLive
        currentURL = url
        didReportReady = false
        reportedDuration = nil
        didReportFirstFrame = false
        lastState = nil
        lastTimeMs = -1
        trackSignature = ""
        isStopped = false

        let media = VLCMedia(url: url)
        let caching = configuration.networkCachingMilliseconds + (isLive ? 1000 : 0)
        media.addOption(":network-caching=\(caching)")
        if isLive { media.addOption(":live-caching=\(caching)") }
        media.addOption(":http-reconnect")
        media.addOption(":no-video-title-show")
        media.addOption(":clock-jitter=0")
        for (key, value) in headers where !value.isEmpty {
            switch key.lowercased() {
            case "user-agent": media.addOption(":http-user-agent=\(value)")
            case "referer", "referrer": media.addOption(":http-referrer=\(value)")
            default: break  // libvlc has no generic header option.
            }
        }
        if let startPosition, !isLive, startPosition > 1 {
            media.addOption(":start-time=\(Int(startPosition))")
        }
        player.media = media
        // MPEG-TS broadcast streams are frequently interlaced.
        let ext = url.pathExtension.lowercased()
        if isLive || ext == "ts" || ext.isEmpty {
            player.setDeinterlace(.auto, withFilter: "yadif")
        }
        applyAudio()
    }

    func play() {
        wantsPlay = true
        guard !isStopped else { return }
        player.play()
    }

    func pause() {
        wantsPlay = false
        if player.canPause { player.pause() }
    }

    func seek(to seconds: TimeInterval) async {
        guard seconds.isFinite, player.isSeekable else { return }
        player.time = VLCTime(int: Int32(clamping: Int(max(0, seconds) * 1000)))
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        wantsPlay = false
        bufferingCheck?.cancel()
        player.delegate = nil
        delegateProxy.owner = nil
        eventHandler = nil
        // libvlc `stop` is synchronous and can block on dead network streams: stop off the main
        // thread, release on the main thread.
        let box = UncheckedSendableBox(player)
        DispatchQueue.global(qos: .userInitiated).async {
            box.value.stop()
            DispatchQueue.main.async { _ = box }
        }
    }

    // MARK: - Properties

    var rate: Float = 1 {
        didSet { player.rate = rate }
    }

    var volume: Float {
        get { volumeValue }
        set {
            volumeValue = min(1, max(0, newValue))
            applyAudio()
        }
    }

    var isMuted: Bool {
        get { mutedValue }
        set {
            mutedValue = newValue
            applyAudio()
        }
    }

    private func applyAudio() {
        guard let audio = player.audio else { return }
        // VLCAudio volume is 0…200 (100 = unity gain): never amplify.
        audio.volume = Int32((volumeValue * 100).rounded())
        audio.isMuted = mutedValue
    }

    var videoGravity: VideoGravity = .fit {
        didSet { applyGeometry() }
    }

    var aspectRatio: VideoAspectRatio = .automatic {
        didSet { applyGeometry() }
    }

    var supportsAspectRatioOverride: Bool { true }

    /// libvlc cannot restyle subtitles at runtime; the style applies on next load only.
    var subtitleStyle: SubtitleStyle

    var seekableRange: ClosedRange<TimeInterval>? {
        guard isLive, player.isSeekable else { return nil }
        let length = TimeInterval(player.media?.length.intValue ?? 0) / 1000
        return length > 0 ? 0...length : nil
    }

    // MARK: - Geometry

    /// fit = source/forced aspect; fill = crop to the view ratio; stretch = force the view ratio.
    private func applyGeometry() {
        let size = drawable.bounds.size
        let viewRatio = Self.ratioString(for: size)
        switch videoGravity {
        case .fit:
            setCString(aspectRatio.vlcValue, \.videoAspectRatio)
            setCString(nil, \.videoCropGeometry)
        case .fill:
            setCString(aspectRatio.vlcValue, \.videoAspectRatio)
            setCString(viewRatio, \.videoCropGeometry)
        case .stretch:
            setCString(nil, \.videoCropGeometry)
            setCString(viewRatio, \.videoAspectRatio)
        }
    }

    /// libvlc copies the string (`var_SetString`), so the temporary buffer is freed right away.
    private func setCString(
        _ value: String?, _ keyPath: ReferenceWritableKeyPath<VLCMediaPlayer, UnsafeMutablePointer<CChar>?>
    ) {
        guard let value else {
            player[keyPath: keyPath] = nil
            return
        }
        guard let buffer = strdup(value) else { return }
        player[keyPath: keyPath] = buffer
        free(buffer)
    }

    static func ratioString(for size: CGSize) -> String? {
        let w = Int(size.width.rounded())
        let h = Int(size.height.rounded())
        guard w > 0, h > 0 else { return nil }
        let divisor = gcd(w, h)
        return "\(w / divisor):\(h / divisor)"
    }

    private static func gcd(_ a: Int, _ b: Int) -> Int {
        b == 0 ? max(1, a) : gcd(b, a % b)
    }

    // MARK: - Tracks

    var audioTracks: [MediaTrack] {
        Self.tracks(names: player.audioTrackNames, indexes: player.audioTrackIndexes, prefix: "Piste audio")
    }

    var subtitleTracks: [MediaTrack] {
        Self.tracks(names: player.videoSubTitlesNames, indexes: player.videoSubTitlesIndexes, prefix: "Sous-titres")
    }

    var selectedAudioID: MediaTrack.ID? {
        let index = player.currentAudioTrackIndex
        return index < 0 ? nil : String(index)
    }

    var selectedSubtitleID: MediaTrack.ID? {
        let index = player.currentVideoSubTitleIndex
        return index < 0 ? nil : String(index)
    }

    func select(audio id: MediaTrack.ID?) {
        guard let id, let index = Int32(id) else { return }
        player.currentAudioTrackIndex = index
    }

    func select(subtitle id: MediaTrack.ID?) {
        guard let id, let index = Int32(id) else {
            player.currentVideoSubTitleIndex = -1
            return
        }
        player.currentVideoSubTitleIndex = index
    }

    static func tracks(names: [Any], indexes: [Any], prefix: String) -> [MediaTrack] {
        var tracks: [MediaTrack] = []
        for (offset, rawIndex) in indexes.enumerated() {
            guard let index = (rawIndex as? NSNumber)?.intValue, index >= 0 else { continue }
            let rawName = offset < names.count ? (names[offset] as? String) ?? "" : ""
            let name = cleanTrackName(rawName, fallback: "\(prefix) \(tracks.count + 1)")
            let words = Set(TrackLanguage.words(in: rawName))
            tracks.append(
                MediaTrack(
                    id: String(index), name: name, language: TrackLanguage.codeFromName(rawName),
                    isForced: !words.isDisjoint(with: ["forced", "force", "forces", "forcee", "forcees"]),
                    isAccessibility: !words.isDisjoint(with: ["sdh", "cc", "malentendants", "malentendant", "ad"])))
        }
        return tracks
    }

    /// "Track 1 - [French]" → "French"; "Piste 2 - [English] - SDH" → "English - SDH".
    static func cleanTrackName(_ raw: String, fallback: String) -> String {
        var name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        for prefix in ["Track ", "Piste "] where name.hasPrefix(prefix) {
            if let dash = name.range(of: " - ") {
                name = String(name[dash.upperBound...])
            }
        }
        name = name.replacingOccurrences(of: "[", with: "").replacingOccurrences(of: "]", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty || name.lowercased() == "disable" || name.lowercased() == "désactiver" {
            return fallback
        }
        if let code = TrackLanguage.normalizedCode(name),
            let localized = Locale(identifier: "fr_FR").localizedString(forLanguageCode: code),
            name.count <= 3
        {
            return localized.prefix(1).uppercased() + localized.dropFirst()
        }
        return name
    }

    // MARK: - Tech info

    var techInfo: StreamTechSnapshot {
        var info = StreamTechSnapshot(engineName: "VLC", url: currentURL)
        let size = player.videoSize
        if size.width > 0, size.height > 0 { info.resolution = size }
        guard let media = player.media else { return info }
        for case let track as [String: Any] in media.tracksInformation {
            let type = track[VLCMediaTracksInformationType] as? String
            let codec = (track[VLCMediaTracksInformationCodec] as? NSNumber).map { Self.fourCC($0.uint32Value) }
            if type == VLCMediaTracksInformationTypeVideo, info.videoCodec == nil {
                info.videoCodec = codec
                if let rate = (track[VLCMediaTracksInformationFrameRate] as? NSNumber)?.doubleValue,
                    let base = (track[VLCMediaTracksInformationFrameRateDenominator] as? NSNumber)?.doubleValue,
                    base > 0, rate > 0
                {
                    info.framesPerSecond = rate / base
                }
            } else if type == VLCMediaTracksInformationTypeAudio, info.audioCodec == nil {
                info.audioCodec = codec
            }
        }
        let stats = media.statistics
        // libvlc bitrates are in bytes per microsecond… × 8 000 000 → bits per second.
        if stats.demuxBitrate > 0 { info.indicatedBitrate = Double(stats.demuxBitrate) * 8_000_000 }
        if stats.inputBitrate > 0 { info.observedBitrate = Double(stats.inputBitrate) * 8_000_000 }
        info.droppedFrames = Int(stats.lostPictures)
        return info
    }

    static func fourCC(_ value: UInt32) -> String {
        let bytes = [0, 8, 16, 24].map { UInt8((value >> $0) & 0xFF) }
        let raw = (String(bytes: bytes, encoding: .ascii) ?? "?").trimmingCharacters(in: .whitespaces)
        switch raw.lowercased() {
        case "h264", "avc1": return "H.264"
        case "hevc", "h265", "hvc1": return "HEVC"
        case "mpgv", "mp2v": return "MPEG-2"
        case "mp4v": return "MPEG-4"
        case "av01": return "AV1"
        case "vp90", "vp09": return "VP9"
        case "mp4a": return "AAC"
        case "a52", "a52 ": return "Dolby Digital"
        case "eac3": return "Dolby Digital Plus"
        case "mpga", "mp3": return "MPEG Audio"
        case "dts": return "DTS"
        case "opus": return "Opus"
        default: return raw
        }
    }

    // MARK: - PiP (unsupported)

    var supportsPictureInPicture: Bool { false }
    var isPictureInPictureActive: Bool { false }
    func togglePictureInPicture() {}

    // MARK: - Delegate callbacks (main actor)

    fileprivate func handleStateChange() {
        guard !isStopped else { return }
        switch player.state {
        case .opening:
            report(.buffering)
        case .buffering:
            // VLC sends "buffering" continuously while playing; only a frozen clock is a stall.
            scheduleBufferingCheck()
        case .playing:
            markReady()
            report(.playing)
            refreshTracksIfNeeded()
        case .paused:
            report(.paused)
        case .esAdded:
            refreshTracksIfNeeded()
        case .ended:
            eventHandler?(.ended)
        case .error:
            eventHandler?(.failed("VLC n’a pas pu ouvrir ce flux."))
        case .stopped:
            if wantsPlay, didReportReady { eventHandler?(.ended) }
        @unknown default:
            break
        }
    }

    fileprivate func handleTimeChange() {
        guard !isStopped else { return }
        let ms = player.time.intValue
        if ms != lastTimeMs {
            lastTimeMs = ms
            lastTimeChange = Date()
            if lastState == .buffering, player.isPlaying { report(.playing) }
        }
        markReady()
        if !isLive, reportedDuration == nil, let length = player.media?.length.intValue, length > 0 {
            // The length of some containers is only known once playback started.
            reportedDuration = TimeInterval(length) / 1000
            eventHandler?(.ready(duration: reportedDuration))
        }
        let seconds = TimeInterval(ms) / 1000
        eventHandler?(.time(current: seconds, buffered: seconds))

        let size = player.videoSize
        if size.width > 0, size.height > 0, size != lastVideoSize {
            lastVideoSize = size
            eventHandler?(.videoSize(size))
            applyGeometry()
        }
        if !didReportFirstFrame, player.hasVideoOut || (seconds > 0.5 && player.numberOfVideoTracks == 0) {
            didReportFirstFrame = true
            eventHandler?(.firstFrame)
        }
        refreshTracksIfNeeded()
    }

    private func markReady() {
        guard !didReportReady else { return }
        didReportReady = true
        let lengthMs = player.media?.length.intValue ?? 0
        let duration: TimeInterval? = (!isLive && lengthMs > 0) ? TimeInterval(lengthMs) / 1000 : nil
        reportedDuration = duration
        eventHandler?(.ready(duration: duration))
        player.rate = rate
        applyAudio()
        applyGeometry()
    }

    private func refreshTracksIfNeeded() {
        let signature = "\(player.audioTrackIndexes.count)/\(player.videoSubTitlesIndexes.count)"
        guard signature != trackSignature else { return }
        trackSignature = signature
        eventHandler?(.tracksChanged)
    }

    private func scheduleBufferingCheck() {
        bufferingCheck?.cancel()
        bufferingCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled, !self.isStopped else { return }
            if Date().timeIntervalSince(self.lastTimeChange) >= 1, self.wantsPlay {
                self.report(.buffering)
            }
        }
    }

    private func report(_ state: EnginePlaybackState) {
        guard state != lastState else { return }
        lastState = state
        eventHandler?(.state(state))
    }
}

/// Objective-C delegate living outside the engine so callbacks hop to the main actor safely
/// (VLCKit 3 posts them on the main thread, but nothing in the API guarantees it).
final class VLCDelegateProxy: NSObject, VLCMediaPlayerDelegate {
    weak var owner: VLCEngine?

    nonisolated func mediaPlayerStateChanged(_ aNotification: Notification) {
        onMainActor { [weak self] in self?.owner?.handleStateChange() }
    }

    nonisolated func mediaPlayerTimeChanged(_ aNotification: Notification) {
        onMainActor { [weak self] in self?.owner?.handleTimeChange() }
    }
}

/// Moves a non-Sendable reference across threads when the API is known to be thread-safe.
nonisolated final class UncheckedSendableBox<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
