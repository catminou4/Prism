import AVFoundation
import AVKit
import AppKit
import CoreMedia
import Foundation
import QuartzCore

/// Black surface hosting an `AVPlayerLayer` that follows the view bounds.
final class AVPlayerSurfaceView: BlackVideoSurfaceView {
    let playerLayer = AVPlayerLayer()

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        playerLayer.backgroundColor = NSColor.black.cgColor
        playerLayer.videoGravity = .resizeAspect
        playerLayer.frame = bounds
        playerLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        playerLayer.actions = ["bounds": NSNull(), "position": NSNull(), "contents": NSNull()]
        layer?.addSublayer(playerLayer)
    }
}

/// `AVPlayer` engine: HLS, MP4/MOV, AAC/MP3. Supports PiP and AirPlay.
final class AVFoundationEngine: NSObject, PlaybackEngine {
    let kind: PlaybackEngineKind = .avFoundation
    var eventHandler: ((EngineEvent) -> Void)?
    var videoView: NSView { surface }
    var routingPlayer: AVPlayer? { player }

    private let player = AVPlayer()
    private let surface = AVPlayerSurfaceView(frame: NSRect(x: 0, y: 0, width: 640, height: 360))
    private let configuration: EngineConfiguration

    private var currentItem: AVPlayerItem?
    private var currentURL: URL?
    private var itemObservations: [NSKeyValueObservation] = []
    private var playerObservations: [NSKeyValueObservation] = []
    private var notificationTokens: [any NSObjectProtocol] = []
    private var timeObserverToken: Any?
    private var prepareTask: Task<Void, Never>?

    private var legibleGroup: AVMediaSelectionGroup?
    private var audibleGroup: AVMediaSelectionGroup?
    private var legibleOptions: [AVMediaSelectionOption] = []
    private var audibleOptions: [AVMediaSelectionOption] = []
    private(set) var audioTracks: [MediaTrack] = []
    private(set) var subtitleTracks: [MediaTrack] = []

    private var isLive = false
    private var startPosition: TimeInterval?
    private var wantsPlay = false
    private var didReportReady = false
    private var didReportFirstFrame = false
    private var lastState: EnginePlaybackState?
    private var lastPresentationSize: CGSize = .zero
    private var videoCodec: String?
    private var audioCodec: String?

    private var pipController: AVPictureInPictureController?
    private var pipObservation: NSKeyValueObservation?
    private let pipDelegate = PictureInPictureDelegate()

    init(configuration: EngineConfiguration) {
        self.configuration = configuration
        self.subtitleStyle = configuration.subtitleStyle
        super.init()
        surface.playerLayer.player = player
        player.allowsExternalPlayback = true
        player.appliesMediaSelectionCriteriaAutomatically = true
        observePlayer()
    }

    isolated deinit {
        teardown()
    }

    // MARK: - Loading

    func load(url: URL, headers: [String: String], startPosition: TimeInterval?, isLive: Bool) {
        teardownItem()
        self.isLive = isLive
        self.startPosition = isLive ? nil : startPosition.flatMap { $0 > 1 ? $0 : nil }
        currentURL = url
        didReportReady = false
        didReportFirstFrame = false
        lastState = nil

        var options: [String: Any] = [:]
        var extraHeaders = headers
        if let uaKey = headers.keys.first(where: { $0.caseInsensitiveCompare("User-Agent") == .orderedSame }),
            let userAgent = headers[uaKey], !userAgent.isEmpty
        {
            options[AVURLAssetHTTPUserAgentKey] = userAgent
            extraHeaders.removeValue(forKey: uaKey)
        }
        if !extraHeaders.isEmpty {
            options["AVURLAssetHTTPHeaderFieldsKey"] = extraHeaders
        }
        let asset = AVURLAsset(url: url, options: options)
        let item = AVPlayerItem(asset: asset)
        // Live HLS segments run 4–10 s: 3 s of buffer underruns at every bitrate
        // spike. ~2 segments of headroom keeps the live edge smooth (+latency).
        item.preferredForwardBufferDuration = isLive ? 15 : 0
        item.textStyleRules = Self.textStyleRules(for: subtitleStyle)
        player.automaticallyWaitsToMinimizeStalling = !isLive
        currentItem = item
        observeItem(item)
        player.replaceCurrentItem(with: item)
        addTimeObserver()
    }

    func play() {
        wantsPlay = true
        player.play()
    }

    func pause() {
        wantsPlay = false
        player.pause()
    }

    func seek(to seconds: TimeInterval) async {
        guard currentItem != nil, seconds.isFinite else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        // Exact seeks decode forward from the previous keyframe (IPTV GOPs run
        // 5–10 s): a small tolerance lets AVPlayer land on a nearby sync sample —
        // imperceptible for skipping/scrubbing, far less decode work.
        let tolerance = CMTime(seconds: isLive ? 2 : 1.5, preferredTimescale: 600)
        _ = await player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
    }

    func stop() {
        wantsPlay = false
        teardown()
    }

    // MARK: - Properties

    var rate: Float {
        get { player.defaultRate }
        set {
            player.defaultRate = newValue
            if player.rate != 0 { player.rate = newValue }
        }
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = min(1, max(0, newValue)) }
    }

    var isMuted: Bool {
        get { player.isMuted }
        set { player.isMuted = newValue }
    }

    var videoGravity: VideoGravity = .fit {
        didSet {
            surface.playerLayer.videoGravity =
                switch videoGravity {
                case .fit: .resizeAspect
                case .fill: .resizeAspectFill
                case .stretch: .resize
                }
        }
    }

    /// AVFoundation honours the stream aspect ratio; no override.
    var aspectRatio: VideoAspectRatio = .automatic
    var supportsAspectRatioOverride: Bool { false }

    var subtitleStyle: SubtitleStyle {
        didSet { currentItem?.textStyleRules = Self.textStyleRules(for: subtitleStyle) }
    }

    var seekableRange: ClosedRange<TimeInterval>? {
        guard let range = currentItem?.seekableTimeRanges.last?.timeRangeValue else { return nil }
        let start = range.start.seconds
        let end = range.end.seconds
        guard start.isFinite, end.isFinite, end > start else { return nil }
        return start...end
    }

    // MARK: - Tracks

    var selectedAudioID: MediaTrack.ID? {
        guard let item = currentItem, let group = audibleGroup,
            let option = item.currentMediaSelection.selectedMediaOption(in: group),
            let index = audibleOptions.firstIndex(of: option)
        else { return nil }
        return "a\(index)"
    }

    var selectedSubtitleID: MediaTrack.ID? {
        guard let item = currentItem, let group = legibleGroup,
            let option = item.currentMediaSelection.selectedMediaOption(in: group),
            let index = legibleOptions.firstIndex(of: option)
        else { return nil }
        return "s\(index)"
    }

    func select(audio id: MediaTrack.ID?) {
        guard let item = currentItem, let group = audibleGroup else { return }
        guard let id, let index = Self.index(of: id, prefix: "a"), audibleOptions.indices.contains(index)
        else { return }
        item.select(audibleOptions[index], in: group)
    }

    func select(subtitle id: MediaTrack.ID?) {
        guard let item = currentItem, let group = legibleGroup else { return }
        guard let id else {
            if group.allowsEmptySelection {
                item.select(nil, in: group)
            } else if let forced = AVMediaSelectionGroup.mediaSelectionOptions(
                from: group.options, withMediaCharacteristics: [.containsOnlyForcedSubtitles]
            ).first {
                item.select(forced, in: group)
            }
            return
        }
        guard let index = Self.index(of: id, prefix: "s"), legibleOptions.indices.contains(index)
        else { return }
        item.select(legibleOptions[index], in: group)
    }

    private static func index(of id: MediaTrack.ID, prefix: Character) -> Int? {
        guard id.first == prefix else { return nil }
        return Int(id.dropFirst())
    }

    // MARK: - Tech info

    var techInfo: StreamTechSnapshot {
        var info = StreamTechSnapshot(engineName: "AVFoundation", url: currentURL)
        info.videoCodec = videoCodec
        info.audioCodec = audioCodec
        if let item = currentItem {
            let size = item.presentationSize
            if size.width > 0, size.height > 0 { info.resolution = size }
            if let event = item.accessLog()?.events.last {
                if event.indicatedBitrate > 0 { info.indicatedBitrate = event.indicatedBitrate }
                if event.observedBitrate > 0 { info.observedBitrate = event.observedBitrate }
                if event.numberOfDroppedVideoFrames >= 0 { info.droppedFrames = event.numberOfDroppedVideoFrames }
            }
            if let fps = item.tracks.first(where: { $0.assetTrack?.mediaType == .video })?.currentVideoFrameRate,
                fps > 0
            {
                info.framesPerSecond = Double(fps)
            }
        }
        return info
    }

    // MARK: - Picture in Picture

    var supportsPictureInPicture: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    var isPictureInPictureActive: Bool { pipController?.isPictureInPictureActive ?? false }

    func togglePictureInPicture() {
        guard supportsPictureInPicture else { return }
        let controller = pipController ?? makePictureInPictureController()
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else if controller.isPictureInPicturePossible {
            controller.startPictureInPicture()
        }
    }

    private func makePictureInPictureController() -> AVPictureInPictureController? {
        guard let controller = AVPictureInPictureController(playerLayer: surface.playerLayer) else {
            return nil
        }
        controller.delegate = pipDelegate
        pipObservation = Self.observe(controller, \.isPictureInPictureActive) { [weak self] in
            guard let self, let pip = self.pipController else { return }
            self.eventHandler?(.pictureInPicture(active: pip.isPictureInPictureActive))
        }
        pipController = controller
        return controller
    }

    // MARK: - Observation

    /// KVO bridge: handlers always run on the main actor.
    nonisolated private static func observe<Object: NSObject, Value>(
        _ object: Object, _ keyPath: KeyPath<Object, Value>,
        _ handler: @escaping @MainActor @Sendable () -> Void
    ) -> NSKeyValueObservation {
        object.observe(keyPath, options: [.new]) { _, _ in onMainActor(handler) }
    }

    private func observePlayer() {
        playerObservations = [
            Self.observe(player, \.timeControlStatus) { [weak self] in self?.handleTimeControlStatus() },
            Self.observe(surface.playerLayer, \.isReadyForDisplay) { [weak self] in self?.handleReadyForDisplay() },
        ]
    }

    private func observeItem(_ item: AVPlayerItem) {
        itemObservations = [
            Self.observe(item, \.status) { [weak self] in self?.handleItemStatus() },
            Self.observe(item, \.presentationSize) { [weak self] in self?.handlePresentationSize() },
            Self.observe(item, \.isPlaybackLikelyToKeepUp) { [weak self] in self?.handleLikelyToKeepUp() },
        ]
        let center = NotificationCenter.default
        notificationTokens = [
            center.addObserver(forName: AVPlayerItem.didPlayToEndTimeNotification, object: item, queue: .main) {
                [weak self] _ in
                onMainActor { self?.eventHandler?(.ended) }
            },
            center.addObserver(forName: AVPlayerItem.failedToPlayToEndTimeNotification, object: item, queue: .main) {
                [weak self] note in
                let message = (note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? NSError)?
                    .localizedDescription
                onMainActor { self?.eventHandler?(.failed(message ?? "La lecture s’est interrompue.")) }
            },
            center.addObserver(forName: AVPlayerItem.playbackStalledNotification, object: item, queue: .main) {
                [weak self] _ in
                onMainActor { self?.report(.buffering) }
            },
        ]
    }

    private func addTimeObserver() {
        guard timeObserverToken == nil else { return }
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserverToken = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) {
            [weak self] time in
            let seconds = time.seconds
            onMainActor { self?.handleTime(seconds) }
        }
    }

    // MARK: - Handlers

    private func handleItemStatus() {
        guard let item = currentItem else { return }
        switch item.status {
        case .readyToPlay:
            guard !didReportReady else { return }
            didReportReady = true
            let duration = item.duration.seconds
            let known: TimeInterval? = (!isLive && duration.isFinite && duration > 0) ? duration : nil
            eventHandler?(.ready(duration: known))
            // Created early: `isPictureInPicturePossible` turns true asynchronously.
            if pipController == nil, supportsPictureInPicture { _ = makePictureInPictureController() }
            prepareTask?.cancel()
            prepareTask = Task { [weak self] in await self?.prepareAfterReady(item) }
        case .failed:
            eventHandler?(.failed(Self.message(for: item.error)))
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    private func prepareAfterReady(_ item: AVPlayerItem) async {
        if let start = startPosition {
            await seek(to: start)
        } else if isLive, let range = seekableRange, range.upperBound - range.lowerBound > 30 {
            // EVENT/DVR playlists start at the beginning of the window: jump to the live edge.
            await seek(to: max(range.lowerBound, range.upperBound - 8))
        }
        guard currentItem === item, !Task.isCancelled else { return }
        if wantsPlay { player.play() }

        guard let asset = item.asset as? AVURLAsset else { return }
        let legible = try? await asset.loadMediaSelectionGroup(for: .legible)
        let audible = try? await asset.loadMediaSelectionGroup(for: .audible)
        guard currentItem === item, !Task.isCancelled else { return }
        legibleGroup = legible
        audibleGroup = audible
        rebuildTracks()
        eventHandler?(.tracksChanged)
        await loadCodecs(asset: asset, item: item)
    }

    private func rebuildTracks() {
        if let group = legibleGroup {
            legibleOptions = group.options.filter {
                !$0.hasMediaCharacteristic(.containsOnlyForcedSubtitles)
            }
            subtitleTracks = legibleOptions.enumerated().map { index, option in
                Self.track(from: option, id: "s\(index)")
            }
        } else {
            legibleOptions = []
            subtitleTracks = []
        }
        if let group = audibleGroup {
            audibleOptions = group.options
            audioTracks = audibleOptions.enumerated().map { index, option in
                Self.track(from: option, id: "a\(index)")
            }
        } else {
            audibleOptions = []
            audioTracks = []
        }
    }

    private static func track(from option: AVMediaSelectionOption, id: String) -> MediaTrack {
        let language = TrackLanguage.normalizedCode(option.extendedLanguageTag ?? option.locale?.identifier)
        let accessibility =
            option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
            || option.hasMediaCharacteristic(.transcribesSpokenDialogForAccessibility)
            || option.hasMediaCharacteristic(.describesVideoForAccessibility)
        var name = option.displayName(with: Locale(identifier: "fr_FR"))
        if name.isEmpty { name = option.displayName }
        if name.isEmpty { name = "Piste \(id.dropFirst())" }
        if accessibility, !name.localizedCaseInsensitiveContains("SDH"),
            option.hasMediaCharacteristic(.describesMusicAndSoundForAccessibility)
        {
            name += " (SDH)"
        }
        return MediaTrack(
            id: id, name: name, language: language,
            isForced: option.hasMediaCharacteristic(.containsOnlyForcedSubtitles),
            isAccessibility: accessibility)
    }

    private func loadCodecs(asset: AVURLAsset, item: AVPlayerItem) async {
        var video = try? await asset.loadTracks(withMediaType: .video).first
        var audio = try? await asset.loadTracks(withMediaType: .audio).first
        guard currentItem === item else { return }
        if video == nil || audio == nil {
            // HLS: tracks only exist on the player item.
            let assetTracks = item.tracks.compactMap(\.assetTrack)
            if video == nil { video = assetTracks.first { $0.mediaType == .video } }
            if audio == nil { audio = assetTracks.first { $0.mediaType == .audio } }
        }
        if let video, let descriptions = try? await video.load(.formatDescriptions),
            let first = descriptions.first
        {
            videoCodec = Self.codecName(CMFormatDescriptionGetMediaSubType(first))
        }
        if let audio, let descriptions = try? await audio.load(.formatDescriptions),
            let first = descriptions.first
        {
            audioCodec = Self.codecName(CMFormatDescriptionGetMediaSubType(first))
        }
    }

    static func codecName(_ fourCC: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((fourCC >> $0) & 0xFF) }
        let raw = String(bytes: bytes, encoding: .ascii)?.trimmingCharacters(in: .whitespaces) ?? "?"
        switch raw {
        case "avc1", "avc3": return "H.264"
        case "hvc1", "hev1": return "HEVC"
        case "dvh1", "dvhe": return "Dolby Vision"
        case "av01": return "AV1"
        case "vp09": return "VP9"
        case "mp4a", "aac ": return "AAC"
        case "ac-3": return "Dolby Digital"
        case "ec-3": return "Dolby Digital Plus"
        case ".mp3": return "MP3"
        case "alac": return "ALAC"
        case "opus": return "Opus"
        default: return raw
        }
    }

    private func handleTimeControlStatus() {
        switch player.timeControlStatus {
        case .playing: report(.playing)
        case .paused: report(wantsPlay ? .buffering : .paused)
        case .waitingToPlayAtSpecifiedRate:
            if player.reasonForWaitingToPlay != .noItemToPlay { report(.buffering) }
        @unknown default: break
        }
    }

    private func handleLikelyToKeepUp() {
        // Live items do not wait automatically: resume once the buffer refilled.
        guard let item = currentItem, item.isPlaybackLikelyToKeepUp, wantsPlay, player.rate == 0 else { return }
        player.play()
    }

    private func handleReadyForDisplay() {
        guard surface.playerLayer.isReadyForDisplay, !didReportFirstFrame, currentItem != nil else { return }
        didReportFirstFrame = true
        eventHandler?(.firstFrame)
    }

    private func handlePresentationSize() {
        guard let size = currentItem?.presentationSize, size.width > 0, size.height > 0,
            size != lastPresentationSize
        else { return }
        lastPresentationSize = size
        eventHandler?(.videoSize(size))
    }

    private func handleTime(_ seconds: TimeInterval) {
        guard let item = currentItem, seconds.isFinite else { return }
        var buffered = seconds
        for value in item.loadedTimeRanges {
            let range = value.timeRangeValue
            let start = range.start.seconds
            let end = range.end.seconds
            if start.isFinite, end.isFinite, start <= seconds + 0.5, end >= seconds {
                buffered = max(buffered, end)
            }
        }
        eventHandler?(.time(current: seconds, buffered: buffered))
        // Audio-only streams never become "ready for display".
        if !didReportFirstFrame, didReportReady, seconds > 0.3, item.presentationSize == .zero,
            player.timeControlStatus == .playing
        {
            didReportFirstFrame = true
            eventHandler?(.firstFrame)
        }
    }

    private func report(_ state: EnginePlaybackState) {
        guard state != lastState else { return }
        lastState = state
        eventHandler?(.state(state))
    }

    // MARK: - Teardown

    private func teardownItem() {
        prepareTask?.cancel()
        prepareTask = nil
        itemObservations.forEach { $0.invalidate() }
        itemObservations = []
        for token in notificationTokens { NotificationCenter.default.removeObserver(token) }
        notificationTokens = []
        legibleGroup = nil
        audibleGroup = nil
        legibleOptions = []
        audibleOptions = []
        audioTracks = []
        subtitleTracks = []
        videoCodec = nil
        audioCodec = nil
        lastPresentationSize = .zero
        currentItem = nil
    }

    private func teardown() {
        if let pip = pipController, pip.isPictureInPictureActive { pip.stopPictureInPicture() }
        pipObservation?.invalidate()
        pipObservation = nil
        pipController = nil
        player.pause()
        if let token = timeObserverToken {
            player.removeTimeObserver(token)
            timeObserverToken = nil
        }
        teardownItem()
        playerObservations.forEach { $0.invalidate() }
        playerObservations = []
        player.replaceCurrentItem(with: nil)
        eventHandler = nil
    }

    // MARK: - Helpers

    static func message(for error: (any Error)?) -> String {
        guard let error = error as NSError? else { return "Ce flux ne peut pas être lu." }
        if let underlying = error.userInfo[NSUnderlyingErrorKey] as? NSError,
            underlying.domain == NSURLErrorDomain
        {
            return underlying.localizedDescription
        }
        return error.localizedDescription
    }

    static func textStyleRules(for style: SubtitleStyle) -> [AVTextStyleRule]? {
        let attributes: [String: Any]
        switch style {
        case .system:
            return nil
        case .large:
            attributes = [kCMTextMarkupAttribute_RelativeFontSize as String: 140]
        case .background:
            attributes = [
                kCMTextMarkupAttribute_CharacterBackgroundColorARGB as String: [0.85, 0, 0, 0],
                kCMTextMarkupAttribute_ForegroundColorARGB as String: [1, 1, 1, 1],
            ]
        case .yellow:
            attributes = [
                kCMTextMarkupAttribute_ForegroundColorARGB as String: [1, 1, 0.86, 0.1],
                kCMTextMarkupAttribute_CharacterEdgeStyle as String:
                    kCMTextMarkupCharacterEdgeStyle_DropShadow as String,
            ]
        }
        return AVTextStyleRule(textMarkupAttributes: attributes).map { [$0] }
    }
}

/// PiP delegate: restores the inline player when the user taps "return" in the PiP window.
final class PictureInPictureDelegate: NSObject, AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureController(
        _ pictureInPictureController: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        completionHandler(true)
    }
}
