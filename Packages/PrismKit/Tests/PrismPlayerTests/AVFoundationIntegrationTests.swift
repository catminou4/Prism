import AVFoundation
import AppKit
import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import PrismPlayer

/// Plays a generated 2 s silent H.264 file through `AVFoundationEngine` and the controller
/// (local file, no audio track, offscreen view).
@Suite(.serialized) struct AVFoundationIntegrationTests {
    static func makeMovie(seconds: Int = 2) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "prism-player-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(
            mediaType: .video,
            outputSettings: [AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 320, AVVideoHeightKey: 180])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input,
            sourcePixelBufferAttributes: [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
                kCVPixelBufferWidthKey as String: 320, kCVPixelBufferHeightKey as String: 180,
            ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        let fps = 10
        for frame in 0..<(seconds * fps) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            var buffer: CVPixelBuffer?
            CVPixelBufferCreate(nil, 320, 180, kCVPixelFormatType_32BGRA, nil, &buffer)
            guard let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 10 % 255), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: CMTimeScale(fps)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    @Test func engineReportsReadyTimeAndEnd() async throws {
        let url = try await Self.makeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AVFoundationEngine(configuration: EngineConfiguration())
        var events: [EngineEvent] = []
        engine.eventHandler = { events.append($0) }
        engine.isMuted = true
        engine.load(url: url, headers: [:], startPosition: nil, isLive: false)
        engine.play()
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while clock.now < deadline, !events.contains(.ended) {
            try await Task.sleep(for: .milliseconds(20))
        }
        let ready: [TimeInterval] = events.compactMap { event in
            if case .ready(let duration) = event { return duration ?? -1 }
            return nil
        }
        #expect(ready.count == 1)
        #expect(abs((ready.first ?? 0) - 2) < 0.2)
        #expect(events.contains(.state(.playing)))
        #expect(events.contains { if case .time = $0 { true } else { false } })
        #expect(events.contains(.videoSize(CGSize(width: 320, height: 180))))
        #expect(events.contains(.ended))
        #expect(engine.techInfo.videoCodec == "H.264")
        engine.stop()
    }

    @Test func controllerPlaysToTheEndAndReportsProgress() async throws {
        let url = try await Self.makeMovie()
        defer { try? FileManager.default.removeItem(at: url) }
        let suite = "prism.player.integration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let preferences = PlayerPreferences(defaults: defaults)
        preferences.volume = 0
        let controller = PlayerController(
            item: PlaybackItem(id: "local", url: url, title: "Local"), preferences: preferences)
        var ended = false
        var progress: [TimeInterval] = []
        controller.onEnded = { ended = true }
        controller.onProgress = { position, _ in progress.append(position) }
        controller.start()
        #expect(controller.engineKind == .avFoundation)
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(8))
        while clock.now < deadline, !ended {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(ended)
        #expect(controller.phase == .ended)
        #expect(abs((controller.duration ?? 0) - 2) < 0.2)
        #expect(!progress.isEmpty)
        controller.stop()
        #expect(controller.phase == .idle)
    }
}
