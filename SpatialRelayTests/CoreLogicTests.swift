import CoreAudio
import CoreMedia
import XCTest
@testable import SpatialRelay

final class CoreLogicTests: XCTestCase {
    func testSpotifyProcessMatcherAcceptsMainAppAndHelpers() {
        XCTAssertTrue(
            SpotifyProcessMatcher.matches(
                bundleIdentifier: "com.spotify.client",
                applicationName: "Spotify"
            )
        )
        XCTAssertTrue(
            SpotifyProcessMatcher.matches(
                bundleIdentifier: "com.spotify.client.helper",
                applicationName: "Spotify Helper (Renderer)"
            )
        )
    }

    func testSpotifyProcessMatcherRejectsUnrelatedAudioApps() {
        XCTAssertFalse(
            SpotifyProcessMatcher.matches(
                bundleIdentifier: "com.apple.Safari",
                applicationName: "Safari"
            )
        )
        XCTAssertFalse(
            SpotifyProcessMatcher.matches(
                bundleIdentifier: "com.example.notspotify",
                applicationName: "Not Spotify"
            )
        )
        XCTAssertFalse(
            SpotifyProcessMatcher.matches(
                bundleIdentifier: "com.example.audio",
                applicationName: "Spotify"
            )
        )
    }

    func testSpotifyProcessMatcherUsesNameOnlyWhenBundleIdentifierIsUnavailable() {
        XCTAssertTrue(
            SpotifyProcessMatcher.matches(
                bundleIdentifier: "",
                applicationName: "Spotify Helper (Renderer)"
            )
        )
    }

    func testSpotifyTapUsesSelectedDeviceStreamWithoutMixdown() {
        let processes = [
            AudioProcessInfo(
                id: 101,
                pid: 201,
                bundleIdentifier: "com.spotify.client",
                applicationName: "Spotify",
                isRunningOutput: true
            ),
            AudioProcessInfo(
                id: 102,
                pid: 202,
                bundleIdentifier: "com.spotify.client.helper",
                applicationName: "Spotify Helper (Renderer)",
                isRunningOutput: false
            )
        ]
        let output = OutputDeviceInfo(
            id: 301,
            uid: "selected-airpods-output",
            name: "AirPods Max",
            sampleRate: 48_000
        )

        // Inspect the description without creating a HAL tap or starting capture.
        let description = AudioHardwareClient.spotifyTapDescription(
            processes: processes,
            outputDevice: output
        )

        XCTAssertEqual(description.deviceUID, output.uid)
        XCTAssertEqual(description.stream, 0)
        XCTAssertFalse(
            description.isMixdown,
            "Mixdown selects a different capture path that can glitch on Bluetooth output"
        )
        XCTAssertFalse(description.isMono)
        XCTAssertEqual(description.processes, processes.map(\.id))
        XCTAssertFalse(description.isExclusive, "Only the supplied Spotify processes should be tapped")
        XCTAssertTrue(description.isPrivate)
        XCTAssertEqual(description.muteBehavior, .mutedWhenTapped)
    }

    func testAirPodsOutputDetectionIsCaseInsensitive() {
        let airPods = OutputDeviceInfo(
            id: 1,
            uid: "airpods",
            name: "TEST AIRPODS PRO",
            sampleRate: 48_000
        )
        let speakers = OutputDeviceInfo(
            id: 2,
            uid: "speakers",
            name: "MacBook Pro Speakers",
            sampleRate: 48_000
        )

        XCTAssertTrue(airPods.isLikelySpatialAudioHeadphones)
        XCTAssertFalse(speakers.isLikelySpatialAudioHeadphones)
    }

    func testOSStatusDescriptionShowsFourCharacterCode() {
        let status = OSStatus(bitPattern: 0x666D743F) // 'fmt?'
        XCTAssertEqual(CoreAudioFailure.describe(status), "'fmt?' / 1718449215")
        XCTAssertEqual(CoreAudioFailure.describe(-50), "-50")
    }

    func testRendererRecoveryRebasesAtLatestValidOutputTime() {
        let timescale: CMTimeScale = 48_000
        let currentTime = CMTime(value: 96_000, timescale: timescale)

        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: currentTime,
                suggestedFlushTime: CMTime(value: 72_000, timescale: timescale),
                timescale: timescale,
                fallbackFrame: 150_000
            ),
            96_000,
            "Flushed renderer timestamps must not force the live timeline backwards"
        )
        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: currentTime,
                suggestedFlushTime: CMTime(value: 120_000, timescale: timescale),
                timescale: timescale,
                fallbackFrame: 150_000
            ),
            120_000,
            "A later automatic-flush timestamp must remain eligible as the restart anchor"
        )
        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: .invalid,
                suggestedFlushTime: nil,
                timescale: timescale,
                fallbackFrame: 150_000
            ),
            150_000
        )
    }

    func testRendererRecoveryRoundsUpToTheNextAudioFrame() {
        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: CMTime(value: 1, timescale: 1_000),
                suggestedFlushTime: nil,
                timescale: 44_100,
                fallbackFrame: 0
            ),
            45
        )
    }

    func testPlaybackBuffersFortyMillisecondsAndBoundsRecoveryBacklog() {
        XCTAssertEqual(PlaybackBufferingPolicy.prebufferFrameCount(sampleRate: 48_000), 1_920)
        XCTAssertEqual(PlaybackBufferingPolicy.prebufferFrameCount(sampleRate: 44_100), 1_764)
        XCTAssertEqual(
            PlaybackBufferingPolicy.recoveryDiscardFrameCount(availableFrames: 10_000, sampleRate: 48_000),
            8_080
        )
        XCTAssertEqual(
            PlaybackBufferingPolicy.recoveryDiscardFrameCount(availableFrames: 1_000, sampleRate: 48_000),
            0
        )
    }

    func testShortAudioBurstStartsAtBoundedWaitWithoutStartingEmptyPlayback() {
        XCTAssertFalse(
            PlaybackBufferingPolicy.shouldStartPlayback(
                enqueuedFrames: 0, targetFrames: 1_920, elapsedMilliseconds: 80
            )
        )
        XCTAssertFalse(
            PlaybackBufferingPolicy.shouldStartPlayback(
                enqueuedFrames: 512, targetFrames: 1_920, elapsedMilliseconds: 79
            )
        )
        XCTAssertTrue(
            PlaybackBufferingPolicy.shouldStartPlayback(
                enqueuedFrames: 512, targetFrames: 1_920, elapsedMilliseconds: 80
            )
        )
        XCTAssertTrue(
            PlaybackBufferingPolicy.shouldStartPlayback(
                enqueuedFrames: 1_920, targetFrames: 1_920, elapsedMilliseconds: 0
            )
        )
    }

    func testRecoveryRecognizesPlaybackWithTwoHundredMillisecondsStillQueued() {
        let playhead = CMTime(value: 1_001, timescale: 48_000)
        XCTAssertEqual(
            RendererRecoveryTimeline.bufferedFrameCount(
                currentTime: playhead,
                segmentStartFrame: 1_000,
                nextFrame: 10_601,
                timescale: 48_000
            ),
            9_600,
            "Renderer queue lead must not be confused with a stopped output clock"
        )
        XCTAssertTrue(
            RendererRecoveryTimeline.hasPlaybackProgress(
                currentTime: playhead,
                rate: 1,
                segmentStartFrame: 1_000,
                timescale: 48_000
            )
        )
    }

    func testRecoveryRecognizesShortBurstBeforeFortyMillisecondsHavePlayed() {
        for playedFrames: Int64 in [1, 128, 512, 1_919] {
            XCTAssertTrue(
                RendererRecoveryTimeline.hasPlaybackProgress(
                    currentTime: CMTime(value: 1_000 + playedFrames, timescale: 48_000),
                    rate: 1,
                    segmentStartFrame: 1_000,
                    timescale: 48_000
                ),
                "Even a short rendered burst confirms that the output has resumed"
            )
        }
    }

    func testRecoveryRequiresAdvancingValidTimeAndRunningClock() {
        func hasProgress(at time: CMTime, rate: Double = 1, timescale: CMTimeScale = 48_000) -> Bool {
            RendererRecoveryTimeline.hasPlaybackProgress(
                currentTime: time,
                rate: rate,
                segmentStartFrame: 1_000,
                timescale: timescale
            )
        }

        XCTAssertFalse(hasProgress(at: CMTime(value: 1_000, timescale: 48_000)))
        XCTAssertFalse(hasProgress(at: CMTime(value: 999, timescale: 48_000)))
        XCTAssertFalse(hasProgress(at: CMTime(value: 1_001, timescale: 48_000), rate: 0))
        XCTAssertFalse(hasProgress(at: CMTime(value: 1_001, timescale: 48_000), rate: .nan))
        XCTAssertFalse(hasProgress(at: CMTime(value: 1_001, timescale: 48_000), timescale: 0))
        for time in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
            XCTAssertFalse(hasProgress(at: time))
        }
    }

    func testPauseConfirmationRequiresBothStoppedRateAndRequestedTime() {
        XCTAssertTrue(
            RendererRecoveryTimeline.isPaused(
                currentTime: CMTime(value: 100, timescale: 48_000),
                rate: 0,
                targetFrame: 100,
                timescale: 48_000
            )
        )
        XCTAssertFalse(
            RendererRecoveryTimeline.isPaused(
                currentTime: CMTime(value: 99, timescale: 48_000),
                rate: 0,
                targetFrame: 100,
                timescale: 48_000
            )
        )
        XCTAssertFalse(
            RendererRecoveryTimeline.isPaused(
                currentTime: CMTime(value: 100, timescale: 48_000),
                rate: 1,
                targetFrame: 100,
                timescale: 48_000
            )
        )
        XCTAssertFalse(
            RendererRecoveryTimeline.isPaused(
                currentTime: .invalid,
                rate: 0,
                targetFrame: 100,
                timescale: 48_000
            )
        )
    }

    func testPlaybackBufferIncludesPendingRendererFramesAndClampsPlayhead() {
        func buffered(at time: CMTime) -> Int64 {
            RendererRecoveryTimeline.bufferedFrameCount(
                currentTime: time,
                segmentStartFrame: 1_000,
                nextFrame: 3_000,
                timescale: 48_000
            )
        }

        XCTAssertEqual(buffered(at: CMTime(value: 1_500, timescale: 48_000)), 1_500)
        XCTAssertEqual(buffered(at: CMTime(value: 4_000, timescale: 48_000)), 0)
        XCTAssertEqual(buffered(at: CMTime(value: 500, timescale: 48_000)), 2_000)
        XCTAssertEqual(buffered(at: .invalid), 2_000)
    }

    func testRendererRecoveryRejectsNonNumericAndNegativeAnchors() {
        for currentTime in [CMTime.invalid, .indefinite, .positiveInfinity, .negativeInfinity] {
            XCTAssertEqual(
                RendererRecoveryTimeline.restartFrame(
                    currentTime: currentTime,
                    suggestedFlushTime: .indefinite,
                    timescale: 48_000,
                    fallbackFrame: 123
                ),
                123
            )
        }
        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: CMTime(value: -100, timescale: 48_000),
                suggestedFlushTime: nil,
                timescale: 48_000,
                fallbackFrame: 123
            ),
            0
        )
        XCTAssertEqual(
            RendererRecoveryTimeline.restartFrame(
                currentTime: .zero,
                suggestedFlushTime: nil,
                timescale: 0,
                fallbackFrame: -100
            ),
            0
        )
    }

    func testOutputReconfigurationGraceIncludesFiveSecondBoundary() {
        let start: UInt64 = 10_000
        XCTAssertTrue(
            OutputReconfigurationGrace.contains(
                startUptimeNanoseconds: start,
                nowUptimeNanoseconds: start + OutputReconfigurationGrace.durationNanoseconds
            )
        )
        XCTAssertFalse(
            OutputReconfigurationGrace.contains(
                startUptimeNanoseconds: start,
                nowUptimeNanoseconds: start + OutputReconfigurationGrace.durationNanoseconds + 1
            )
        )
    }

    func testCaptureRingPreservesStereoFramesAndConsumesPeak() throws {
        let bridge = SRAudioCaptureBridge()
        let input: [Float] = [0.25, -0.5, 0.75, -0.125, -0.2, 0.4]
        let data = input.withUnsafeBytes { Data($0) }

        bridge.debugEnqueueInterleavedFloat(data)

        XCTAssertEqual(bridge.availableFrameCount, 3)
        XCTAssertEqual(bridge.capturedFrameCount, 3)
        XCTAssertEqual(bridge.peakLevel, 0.75, accuracy: 0.0001)
        XCTAssertEqual(bridge.peakLevel, 0, accuracy: 0.0001)

        let firstChunk = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 2))
        XCTAssertEqual(firstChunk.frameCount, 2)
        XCTAssertEqual(floatArray(from: firstChunk.data), Array(input.prefix(4)))

        let secondChunk = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 8))
        XCTAssertEqual(secondChunk.frameCount, 1)
        XCTAssertEqual(floatArray(from: secondChunk.data), Array(input.suffix(2)))
        XCTAssertEqual(bridge.availableFrameCount, 0)
    }

    func testCaptureRingIgnoresPartialStereoFramesAndZeroLengthReads() throws {
        let bridge = SRAudioCaptureBridge()
        bridge.debugEnqueueInterleavedFloat(Data())
        bridge.debugEnqueueInterleavedFloat([Float(0.8)].withUnsafeBytes { Data($0) })
        XCTAssertEqual(bridge.availableFrameCount, 0)
        XCTAssertEqual(bridge.capturedFrameCount, 0)
        XCTAssertNil(bridge.dequeueChunk(withMaximumFrameCount: 1))

        let input: [Float] = [0.25, -0.5, 0.75]
        bridge.debugEnqueueInterleavedFloat(input.withUnsafeBytes { Data($0) })
        XCTAssertEqual(bridge.availableFrameCount, 0)
        bridge.debugEnqueueInterleavedFloat(Array(input.prefix(2)).withUnsafeBytes { Data($0) })
        XCTAssertEqual(bridge.availableFrameCount, 1)
        XCTAssertNil(bridge.dequeueChunk(withMaximumFrameCount: 0))
        XCTAssertEqual(bridge.availableFrameCount, 1)
        let chunk = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 1))
        XCTAssertEqual(floatArray(from: chunk.data), [0.25, -0.5])
    }

    func testCapturePeakRetainsLoudestCallbackUntilRead() {
        let bridge = SRAudioCaptureBridge()
        bridge.debugEnqueueInterleavedFloat([Float(0.9), -0.7].withUnsafeBytes { Data($0) })
        bridge.debugEnqueueInterleavedFloat([Float(0.1), -0.05].withUnsafeBytes { Data($0) })

        XCTAssertEqual(bridge.peakLevel, 0.9, accuracy: 0.0001)
        XCTAssertEqual(bridge.peakLevel, 0, accuracy: 0.0001)
    }

    func testCaptureDiscardKeepsNewestFramesWithoutReportingOverflow() throws {
        let bridge = SRAudioCaptureBridge()
        let input: [Float] = [1, -1, 2, -2, 3, -3, 4, -4]
        bridge.debugEnqueueInterleavedFloat(input.withUnsafeBytes { Data($0) })

        XCTAssertEqual(bridge.discardFrames(maximumFrameCount: 0), 0)
        XCTAssertEqual(bridge.availableFrameCount, 4)
        XCTAssertEqual(bridge.discardFrames(maximumFrameCount: 2), 2)
        XCTAssertEqual(bridge.availableFrameCount, 2)
        let tail = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 1))
        XCTAssertEqual(floatArray(from: tail.data), [3, -3])
        XCTAssertEqual(bridge.discardFrames(maximumFrameCount: UInt32.max), 1)
        XCTAssertEqual(bridge.discardFrames(maximumFrameCount: UInt32.max), 0)
        XCTAssertEqual(bridge.availableFrameCount, 0)
        XCTAssertEqual(bridge.capturedFrameCount, 4)
        XCTAssertEqual(bridge.droppedFrameCount, 0)
    }

    func testCaptureRingBoundsOverflowAndReportsDroppedFrames() {
        let bridge = SRAudioCaptureBridge()
        let capacity = 524_288
        let extraFrames = 17
        let input = [Float](repeating: 0.1, count: (capacity + extraFrames) * 2)

        bridge.debugEnqueueInterleavedFloat(input.withUnsafeBytes { Data($0) })

        XCTAssertEqual(bridge.availableFrameCount, UInt32(capacity))
        XCTAssertEqual(bridge.capturedFrameCount, UInt64(capacity))
        XCTAssertEqual(bridge.droppedFrameCount, UInt64(extraFrames))

        bridge.reset()
        XCTAssertEqual(bridge.availableFrameCount, 0)
        XCTAssertEqual(bridge.capturedFrameCount, 0)
        XCTAssertEqual(bridge.droppedFrameCount, 0)
    }

    func testCaptureRingPreservesOrderAcrossStorageWrap() throws {
        let bridge = SRAudioCaptureBridge()
        let capacity = 524_288
        let initialFrameCount = capacity - 2
        var initial = [Float]()
        initial.reserveCapacity(initialFrameCount * 2)
        for frame in 0..<initialFrameCount {
            initial.append(Float(frame))
            initial.append(-Float(frame))
        }
        bridge.debugEnqueueInterleavedFloat(initial.withUnsafeBytes { Data($0) })

        _ = try XCTUnwrap(
            bridge.dequeueChunk(withMaximumFrameCount: UInt32(initialFrameCount - 2))
        )

        let wrapped: [Float] = [
            1_000_001, -1_000_001,
            1_000_002, -1_000_002,
            1_000_003, -1_000_003,
            1_000_004, -1_000_004,
            1_000_005, -1_000_005,
            1_000_006, -1_000_006
        ]
        bridge.debugEnqueueInterleavedFloat(wrapped.withUnsafeBytes { Data($0) })

        let output = try XCTUnwrap(bridge.dequeueChunk(withMaximumFrameCount: 8))
        let expected = Array(initial.suffix(4)) + wrapped
        XCTAssertEqual(output.frameCount, 8)
        XCTAssertEqual(floatArray(from: output.data), expected)
    }

    func testApplicationBundleContainsStablePrivacyIdentity() {
        XCTAssertEqual(Bundle.main.bundleIdentifier, "com.shevlfs.SpatialRelay")
        XCTAssertNotNil(Bundle.main.object(forInfoDictionaryKey: "NSAudioCaptureUsageDescription"))
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundlePackageType") as? String, "APPL")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "CFBundleIconName") as? String, "AppIcon")
        XCTAssertEqual(Bundle.main.object(forInfoDictionaryKey: "LSUIElement") as? Bool, true)
    }

    private func floatArray(from data: Data) -> [Float] {
        data.withUnsafeBytes { bytes in
            Array(bytes.bindMemory(to: Float.self))
        }
    }
}

final class RelayViewModelTests: XCTestCase {
    @MainActor
    func testDiscoveryKeepsMainActorResponsiveAndCoalescesRefreshes() async throws {
        let controller = FakeRelayController()
        let gate = RelayOperationGate()
        controller.discoveryGate = gate
        defer { gate.release() }
        let viewModel = RelayViewModel(coordinator: controller)

        let refreshStart = DispatchTime.now().uptimeNanoseconds
        viewModel.refresh()
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - refreshStart, 250_000_000)
        try await waitUntil { controller.discoveryCount == 1 }
        viewModel.refresh()
        XCTAssertEqual(controller.discoveryCount, 1)
        XCTAssertFalse(viewModel.canToggleRelay)

        gate.release()
        try await waitUntil { viewModel.canToggleRelay }
        XCTAssertEqual(viewModel.spotifyState, .ready)
    }

    @MainActor
    func testRepeatedTogglesDoNotDuplicateBlockedStartOrStop() async throws {
        let controller = FakeRelayController()
        let viewModel = RelayViewModel(coordinator: controller)
        viewModel.refresh()
        try await waitUntil { viewModel.canToggleRelay }

        let startGate = RelayOperationGate()
        controller.startGate = startGate
        defer { startGate.release() }
        let startTime = DispatchTime.now().uptimeNanoseconds
        viewModel.toggleRelay()
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - startTime, 250_000_000)
        try await waitUntil { controller.startCount == 1 }
        viewModel.toggleRelay()
        XCTAssertTrue(viewModel.isBusy)
        XCTAssertFalse(viewModel.isRelaying)

        startGate.release()
        try await waitUntil { viewModel.isRelaying && !viewModel.isBusy }
        XCTAssertEqual(controller.startCount, 1)

        let stopGate = RelayOperationGate()
        controller.stopGate = stopGate
        defer { stopGate.release() }
        let stopTime = DispatchTime.now().uptimeNanoseconds
        viewModel.toggleRelay()
        XCTAssertLessThan(DispatchTime.now().uptimeNanoseconds - stopTime, 250_000_000)
        try await waitUntil { controller.stopCount == 1 }
        viewModel.toggleRelay()
        XCTAssertTrue(viewModel.isBusy)

        stopGate.release()
        try await waitUntil { !viewModel.isRelaying && !viewModel.isBusy }
        XCTAssertEqual(controller.stopCount, 1)
    }

    @MainActor
    func testFailureFromStoppedSessionCannotStopRestartedRelay() async throws {
        let controller = FakeRelayController()
        let viewModel = RelayViewModel(coordinator: controller)
        viewModel.refresh()
        try await waitUntil { viewModel.canToggleRelay }
        viewModel.toggleRelay()
        try await waitUntil { viewModel.isRelaying }
        let firstFailure = try XCTUnwrap(controller.failureHandler(at: 0))

        viewModel.toggleRelay()
        try await waitUntil { !viewModel.isRelaying && viewModel.canToggleRelay }
        viewModel.toggleRelay()
        try await waitUntil { viewModel.isRelaying && controller.startCount == 2 }

        firstFailure(FakeRelayFailure.pipeline)
        // Let the callback's main-actor task run before inspecting the new session.
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertTrue(viewModel.isRelaying)
        XCTAssertNotEqual(viewModel.message?.kind, .error)

        let currentFailure = try XCTUnwrap(controller.failureHandler(at: 1))
        currentFailure(FakeRelayFailure.pipeline)
        try await waitUntil { !viewModel.isRelaying && viewModel.message?.kind == .error }
        try await waitUntil { !viewModel.isRefreshing }
        let failureMessage = viewModel.message
        viewModel.refresh(preservingError: true)
        try await waitUntil { !viewModel.isRefreshing }
        XCTAssertEqual(viewModel.message, failureMessage)
        viewModel.refresh()
        try await waitUntil { !viewModel.isRefreshing }
        XCTAssertNil(viewModel.message)
    }

    @MainActor
    func testTerminationDuringStartupWaitsForCleanupAndIgnoresLateStart() async throws {
        let controller = FakeRelayController()
        let viewModel = RelayViewModel(coordinator: controller)
        viewModel.refresh()
        try await waitUntil { viewModel.canToggleRelay }

        let gate = RelayOperationGate()
        controller.startGate = gate
        defer { gate.release() }
        viewModel.toggleRelay()
        try await waitUntil { controller.startCount == 1 }
        var completions = 0
        viewModel.prepareForTermination { completions += 1 }
        viewModel.prepareForTermination { completions += 1 }
        XCTAssertFalse(viewModel.isReadyToTerminate)
        XCTAssertEqual(completions, 0)
        XCTAssertEqual(controller.stopCount, 0)

        gate.release()
        try await waitUntil { completions == 2 }
        XCTAssertTrue(viewModel.isReadyToTerminate)
        XCTAssertFalse(viewModel.isRelaying)
        XCTAssertFalse(viewModel.isBusy)
        XCTAssertEqual(controller.stopCount, 1)
        XCTAssertEqual(controller.events, ["start", "started", "stop"])
    }

    @MainActor
    private func waitUntil(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ condition: @MainActor () -> Bool
    ) async throws {
        let deadline = DispatchTime.now().uptimeNanoseconds + 3_000_000_000
        while !condition() {
            guard DispatchTime.now().uptimeNanoseconds < deadline else {
                XCTFail("Timed out waiting for relay state", file: file, line: line)
                throw FakeRelayFailure.timeout
            }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
    }
}

private enum FakeRelayFailure: LocalizedError {
    case pipeline
    case timeout

    var errorDescription: String? { "Test relay failure" }
}

private final class RelayOperationGate: @unchecked Sendable {
    private let condition = NSCondition()
    private var isReleased = false

    func wait() {
        condition.lock()
        let deadline = Date().addingTimeInterval(2)
        while !isReleased, condition.wait(until: deadline) {}
        condition.unlock()
    }

    func release() {
        condition.lock()
        isReleased = true
        condition.broadcast()
        condition.unlock()
    }
}

private final class FakeRelayController: AudioRelayControlling, @unchecked Sendable {
    private let lock = NSLock()
    private var storedDiscoveryCount = 0
    private var storedStartCount = 0
    private var storedStopCount = 0
    private var storedEvents: [String] = []
    private var failureHandlers: [@Sendable (Error) -> Void] = []
    // Gates are set before their operation is submitted to the serial worker queue.
    var discoveryGate: RelayOperationGate?
    var startGate: RelayOperationGate?
    var stopGate: RelayOperationGate?

    var discoveryCount: Int { lock.withLock { storedDiscoveryCount } }
    var startCount: Int { lock.withLock { storedStartCount } }
    var stopCount: Int { lock.withLock { storedStopCount } }
    var events: [String] { lock.withLock { storedEvents } }

    func discover() throws -> RelayDiscovery {
        lock.withLock { storedDiscoveryCount += 1 }
        discoveryGate?.wait()
        return Self.discovery
    }

    func start(onFailure: @escaping @Sendable (Error) -> Void) throws -> RelayDiscovery {
        lock.withLock {
            storedStartCount += 1
            failureHandlers.append(onFailure)
            storedEvents.append("start")
        }
        startGate?.wait()
        lock.withLock { storedEvents.append("started") }
        return Self.discovery
    }

    func stop() -> Error? {
        lock.withLock {
            storedStopCount += 1
            storedEvents.append("stop")
        }
        stopGate?.wait()
        return nil
    }

    func metrics() -> RelayMetrics {
        RelayMetrics(peakLevel: 0, bufferedMilliseconds: 40, droppedFrameCount: 0)
    }

    func healthFailure() -> Error? { nil }

    func failureHandler(at index: Int) -> (@Sendable (Error) -> Void)? {
        lock.withLock { index < failureHandlers.count ? failureHandlers[index] : nil }
    }

    private static let discovery = RelayDiscovery(
        spotifyProcesses: [
            AudioProcessInfo(
                id: 10,
                pid: 42,
                bundleIdentifier: "com.spotify.client",
                applicationName: "Spotify",
                isRunningOutput: true
            )
        ],
        outputDevice: OutputDeviceInfo(id: 20, uid: "test-airpods", name: "AirPods Pro", sampleRate: 48_000)
    )
}
