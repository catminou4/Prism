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
    private var didReportTerminalEvent = false
    private var lastState: EnginePlaybackState?
    private var lastTimeMs: Int32 = -1
    private var lastTimeChange = Date.distantPast
    private var lastVideoSize: CGSize = .zero
    private var nextTimeUpdate: ContinuousClock.Instant?
    private var nextMetadataPoll: ContinuousClock.Instant?
    private var nextTrackPoll: ContinuousClock.Instant?
    private var bufferingCheck: Task<Void, Never>?
    /// Cheap "audio/subtitle/video track counts" probe, refreshed on a slow poll.
    private var trackCountsSignature = ""
    /// Names+counts fingerprint, only computed on elementary-stream events to catch
    /// same-count track swaps without paying for it on every poll.
    private var trackNamesSignature = ""
    /// `seekableRange` hits libvlc locks; the controller polls it at 4 Hz for live.
    private var seekableRangeCache: (range: ClosedRange<TimeInterval>?, at: ContinuousClock.Instant)?
    /// Codec/FPS extracted from `tracksInformation` (expensive): computed once per
    /// media, re-probed a bounded number of times while codecs are still missing
    /// (adaptive streams fill it late), bitrates stay live via `statistics`.
    private var codecSnapshot: (video: String?, audio: String?, fps: Double?)?
    private var codecProbeCount = 0
    private var volumeValue: Float = 1
    private var mutedValue = false
    private var isStopped = false
    /// Minimum interval between libvlc geometry applies driven by view resizes.
    private let geometryInterval: Duration
    private var lastGeometryApply: ContinuousClock.Instant?
    private var pendingGeometryApply: Task<Void, Never>?
    /// Test seam: how many times the libvlc geometry was (re)applied.
    private(set) var geometryApplyCount = 0

    init(configuration: EngineConfiguration, geometryInterval: Duration = .milliseconds(100)) {
        self.configuration = configuration
        self.geometryInterval = geometryInterval
        self.subtitleStyle = configuration.subtitleStyle
        self.player = VLCMediaPlayer()
        super.init()
        player.drawable = drawable
        delegateProxy.owner = self
        player.delegate = delegateProxy
        drawable.onResize = { [weak self] _ in self?.scheduleGeometry() }
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
        didReportTerminalEvent = false
        lastState = nil
        lastTimeMs = -1
        lastTimeChange = .distantPast
        lastVideoSize = .zero
        nextTimeUpdate = nil
        nextMetadataPoll = nil
        nextTrackPoll = nil
        trackCountsSignature = ""
        trackNamesSignature = ""
        seekableRangeCache = nil
        codecSnapshot = nil
        codecProbeCount = 0
        bufferingCheck?.cancel()
        bufferingCheck = nil
        pendingGeometryApply?.cancel()
        pendingGeometryApply = nil
        lastGeometryApply = nil
        isStopped = false

        let media = VLCMedia(url: url)
        let caching = configuration.networkCachingMilliseconds + (isLive ? 1000 : 0)
        media.addOption(":network-caching=\(caching)")
        if isLive { media.addOption(":live-caching=\(caching)") }
        media.addOption(":http-reconnect")
        media.addOption(":no-video-title-show")
        media.addOption(":clock-jitter=0")
        // Subtitle rendering is an input option in libvlc (applies to this media only;
        // a runtime style change lands on the next loaded item).
        switch subtitleStyle {
        case .system:
            break
        case .large:
            // Default rel-fontsize is 40; 56 ≈ the 140% "Grand texte" AVFoundation uses.
            media.addOption(":freetype-rel-fontsize=56")
        case .background:
            media.addOption(":freetype-background-color=#000000")
            media.addOption(":freetype-background-opacity=255")
        case .yellow:
            media.addOption(":freetype-color=#FFFF00")
        }
        for (key, value) in headers where !value.isEmpty {
            switch key.lowercased() {
            case "user-agent": media.addOption(":http-user-agent=\(value)")
            case "referer", "referrer": media.addOption(":http-referrer=\(value)")
            case "cookie": media.addOption(":http-cookie=\(value)")
            default: break  // libvlc has no generic header option.
            }
        }
        if let startPosition, !isLive, startPosition > 1 {
            media.addOption(":start-time=\(Int(startPosition))")
        }
        // Keep deinterlacing per input. VLCKit's setDeinterlace writes global config,
        // which can block the main thread while a failed or retiring input holds it.
        let ext = url.pathExtension.lowercased()
        if isLive || ext == "ts" || ext.isEmpty {
            media.addOption(":deinterlace=-1")
            media.addOption(":deinterlace-mode=yadif")
        }
        player.media = media
        applyAudio()
    }

    func play() {
        wantsPlay = true
        guard !isStopped else { return }
        player.play()
    }

    func pause() {
        wantsPlay = false
        // `canPause` is always false on live streams and while opening; libvlc
        // still honours pause() (and the `.playing` re-pause below covers the case
        // where the pause lands before the stream is actually running).
        player.pause()
    }

    func seek(to seconds: TimeInterval) async {
        guard seconds.isFinite, player.isSeekable else { return }
        let target = max(0, seconds)
        player.time = VLCTime(int: Int32(clamping: Int(target * 1000)))
        // libvlc seeks asynchronously: hold this call until the playhead lands near
        // the target so the controller keeps ignoring stale engine times (otherwise
        // the scrubber rubber-bands back for the ~0.5–2 s the seek takes).
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !Task.isCancelled {
            let position = TimeInterval(player.time.intValue) / 1000
            if abs(position - target) <= 1 { return }
            if ContinuousClock.now >= deadline { return }
            try? await Task.sleep(for: .milliseconds(80))
        }
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        wantsPlay = false
        bufferingCheck?.cancel()
        pendingGeometryApply?.cancel()
        pendingGeometryApply = nil
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

    /// Cached ~1 s: every call crosses libvlc locks and the controller polls at 4 Hz.
    var seekableRange: ClosedRange<TimeInterval>? {
        guard isLive else { return nil }
        let now = ContinuousClock.now
        if let cache = seekableRangeCache, now - cache.at < .seconds(1) { return cache.range }
        let range: ClosedRange<TimeInterval>?
        if player.isSeekable, let length = player.media?.length.intValue, length > 0 {
            range = 0...(TimeInterval(length) / 1000)
        } else {
            range = nil
        }
        seekableRangeCache = (range, now)
        return range
    }

    // MARK: - Geometry

    /// Coalesces resize-driven geometry updates: `layout()` fires per frame during a
    /// window drag (up to 120 Hz) and every apply crosses libvlc locks with up to three
    /// `var_Set` calls. Applies land at most every `geometryInterval`, plus one trailing
    /// update carrying the latest bounds once the resize settles into the interval.
    private func scheduleGeometry() {
        let now = ContinuousClock.now
        if let last = lastGeometryApply, now - last < geometryInterval {
            guard pendingGeometryApply == nil else { return }
            let remaining = geometryInterval - (now - last)
            pendingGeometryApply = Task { [weak self] in
                try? await Task.sleep(for: remaining)
                guard !Task.isCancelled, let self else { return }
                self.pendingGeometryApply = nil
                self.applyGeometry()
            }
            return
        }
        applyGeometry()
    }

    /// fit = source/forced aspect; fill = crop to the view ratio; stretch = force the view ratio.
    private func applyGeometry() {
        lastGeometryApply = ContinuousClock.now
        geometryApplyCount += 1
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
        if lastVideoSize.width > 0, lastVideoSize.height > 0 { info.resolution = lastVideoSize }
        guard let media = player.media else { return info }
        // `tracksInformation` is expensive: probe once per media and re-probe only
        // while a codec is still missing (bounded — video-only streams would
        // otherwise pay for it forever), bitrates stay live below.
        let missingCodec = codecSnapshot?.video == nil || codecSnapshot?.audio == nil
        if codecSnapshot == nil || (missingCodec && codecProbeCount < 10) {
            codecProbeCount += 1
            codecSnapshot = Self.codecSnapshot(for: media)
        }
        info.videoCodec = codecSnapshot?.video
        info.audioCodec = codecSnapshot?.audio
        info.framesPerSecond = codecSnapshot?.fps
        let stats = media.statistics
        // libvlc bitrates are in bytes per microsecond… × 8 000 000 → bits per second.
        if stats.demuxBitrate > 0 { info.indicatedBitrate = Double(stats.demuxBitrate) * 8_000_000 }
        if stats.inputBitrate > 0 { info.observedBitrate = Double(stats.inputBitrate) * 8_000_000 }
        info.droppedFrames = Int(stats.lostPictures)
        return info
    }

    private static func codecSnapshot(for media: VLCMedia) -> (video: String?, audio: String?, fps: Double?) {
        var snapshot: (video: String?, audio: String?, fps: Double?) = (nil, nil, nil)
        for case let track as [String: Any] in media.tracksInformation {
            let type = track[VLCMediaTracksInformationType] as? String
            let codec = (track[VLCMediaTracksInformationCodec] as? NSNumber).map { fourCC($0.uint32Value) }
            if type == VLCMediaTracksInformationTypeVideo, snapshot.video == nil {
                snapshot.video = codec
                if let rate = (track[VLCMediaTracksInformationFrameRate] as? NSNumber)?.doubleValue,
                    let base = (track[VLCMediaTracksInformationFrameRateDenominator] as? NSNumber)?.doubleValue,
                    base > 0, rate > 0
                {
                    snapshot.fps = rate / base
                }
            } else if type == VLCMediaTracksInformationTypeAudio, snapshot.audio == nil {
                snapshot.audio = codec
            }
        }
        return snapshot
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
            if wantsPlay {
                report(.playing)
                refreshTracksIfNeeded()
            } else {
                // Paused while the stream was still opening (`canPause` was false):
                // libvlc started anyway — pause it so the controller sees `.paused`
                // instead of a wedged `.loading` with audio playing.
                player.pause()
            }
        case .paused:
            report(.paused)
        case .esAdded:
            refreshTracksIfNeeded(deep: true)
        case .ended:
            reportTerminal(.ended)
        case .error:
            reportTerminal(.failed("VLC n’a pas pu ouvrir ce flux."))
        case .stopped:
            guard wantsPlay, didReportReady else { break }
            // Natural EOF arrives as `.ended`; `.stopped` here means the stream died
            // mid-playback. Only trust it as an ending when the playhead is actually
            // near the end — otherwise fail so the next attempt resumes in place
            // instead of marking the title watched.
            if !isLive, let length = player.media?.length.intValue, length > 0,
                player.time.intValue < length - 3000
            {
                reportTerminal(.failed("Le flux s’est arrêté avant la fin."))
            } else {
                reportTerminal(.ended)
            }
        @unknown default:
            break
        }
    }

    private func reportTerminal(_ event: EngineEvent) {
        guard !didReportTerminalEvent else { return }
        didReportTerminalEvent = true
        // The controller can replace and stop this player in response. Wait for the delegate to return.
        Task { [weak self] in
            guard let self, !self.isStopped else { return }
            self.eventHandler?(event)
        }
    }

    fileprivate func handleTimeChange() {
        guard !isStopped else { return }
        let now = ContinuousClock.now
        let publishesTime = nextTimeUpdate.map { now >= $0 } ?? true
        guard publishesTime || !didReportFirstFrame else { return }
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
        if publishesTime {
            nextTimeUpdate = now.advanced(by: .milliseconds(250))
            // libvlc exposes no buffered-ahead position (VLCKit 3.6 offers only
            // time/position/seekable + VLCMedia.Stats counters): `buffered` stays
            // equal to `current`, the scrubber's buffered bar is cosmetic for VLC.
            eventHandler?(.time(current: seconds, buffered: seconds))
        }

        if nextMetadataPoll.map({ now >= $0 }) ?? true {
            // Resolution changes without a state event; 1 Hz is enough.
            nextMetadataPoll = now.advanced(by: .seconds(1))
            let size = player.videoSize
            if size.width > 0, size.height > 0, size != lastVideoSize {
                lastVideoSize = size
                eventHandler?(.videoSize(size))
                applyGeometry()
            }
        }
        if nextTrackPoll.map({ now >= $0 }) ?? true {
            // Track lists cross libvlc locks: poll slowly, real changes also
            // arrive via `.esAdded` / `.playing` state events.
            nextTrackPoll = now.advanced(by: .seconds(5))
            refreshTracksIfNeeded()
        }
        if !didReportFirstFrame, player.hasVideoOut || (seconds > 0.5 && player.numberOfVideoTracks == 0) {
            didReportFirstFrame = true
            eventHandler?(.firstFrame)
        }
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

    /// `deep` additionally fingerprints track names: same-count swaps (adaptive
    /// renditions) only surface on elementary-stream events, never on the slow poll.
    private func refreshTracksIfNeeded(deep: Bool = false) {
        let counts = "\(player.numberOfAudioTracks)/\(player.numberOfSubtitlesTracks)"
        var changed = counts != trackCountsSignature
        trackCountsSignature = counts
        if deep {
            let names = (player.audioTrackNames + player.videoSubTitlesNames)
                .compactMap { $0 as? String }.joined(separator: "\u{1F}")
            let signature = "\(counts)\u{1F}\(names)"
            if signature != trackNamesSignature { changed = true }
            trackNamesSignature = signature
        }
        guard changed else { return }
        eventHandler?(.tracksChanged)
    }

    /// Decode/display counters: they keep advancing on streams whose libvlc clock
    /// is frozen (live formats without usable timestamps), which is exactly the
    /// stall false positive the buffering check must not report.
    private func playbackActivity() -> Int {
        guard let stats = player.media?.statistics else { return 0 }
        if player.numberOfVideoTracks > 0 {
            return Int(stats.displayedPictures) + Int(stats.decodedVideo)
        }
        return Int(stats.decodedAudio) + Int(stats.playedAudioBuffers)
    }

    private func scheduleBufferingCheck() {
        // Coalesced: an armed check evaluates the latest state when it fires, so
        // repeated `.buffering` events must not keep pushing it back (libvlc can
        // emit them continuously — a cancel-and-restart would starve the check).
        guard bufferingCheck == nil else { return }
        bufferingCheck = Task { [weak self] in
            try? await Task.sleep(for: .seconds(1))
            guard let self, !Task.isCancelled else { return }
            self.bufferingCheck = nil
            guard !self.isStopped,
                Date().timeIntervalSince(self.lastTimeChange) >= 1, self.wantsPlay
            else { return }
            // A frozen playhead is not proof of a stall: confirm nothing is being
            // decoded or displayed before declaring buffering, and recover a
            // previously reported `.buffering` when frames keep flowing (the
            // `ms != lastTimeMs` recovery in handleTimeChange never fires then).
            let before = self.playbackActivity()
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled, !self.isStopped else { return }
            self.report(self.playbackActivity() == before ? .buffering : .playing)
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
