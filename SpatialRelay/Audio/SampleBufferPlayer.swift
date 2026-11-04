import AVFoundation
import CoreMedia
import Foundation

enum OutputReconfigurationGrace {
    static let durationMilliseconds: UInt64 = 5_000
    static let durationNanoseconds = durationMilliseconds * 1_000_000

    static func contains(
        startUptimeNanoseconds: UInt64,
        nowUptimeNanoseconds: UInt64
    ) -> Bool {
        guard nowUptimeNanoseconds >= startUptimeNanoseconds else { return true }
        return nowUptimeNanoseconds - startUptimeNanoseconds <= durationNanoseconds
    }
}

enum PlaybackBufferingPolicy {
    static func prebufferFrameCount(sampleRate: Double) -> Int64 {
        max(1_024, Int64((sampleRate * 0.04).rounded(.up)))
    }

    static func recoveryDiscardFrameCount(availableFrames: UInt32, sampleRate: Double) -> UInt32 {
        let retainedFrames = UInt32(prebufferFrameCount(sampleRate: sampleRate))
        return availableFrames > retainedFrames ? availableFrames - retainedFrames : 0
    }

    static func shouldStartPlayback(
        enqueuedFrames: Int64,
        targetFrames: Int64,
        elapsedMilliseconds: UInt64
    ) -> Bool {
        enqueuedFrames > 0 && (enqueuedFrames >= targetFrames || elapsedMilliseconds >= 80)
    }
}

enum RendererRecoveryTimeline {
    static func hasPlaybackProgress(
        currentTime: CMTime,
        rate: Double,
        segmentStartFrame: Int64,
        timescale: CMTimeScale
    ) -> Bool {
        guard timescale > 0, currentTime.isNumeric, abs(rate - 1) < 0.000_1 else { return false }
        return CMTimeCompare(currentTime, CMTime(value: segmentStartFrame, timescale: timescale)) > 0
    }

    static func isPaused(
        currentTime: CMTime,
        rate: Double,
        targetFrame: Int64,
        timescale: CMTimeScale
    ) -> Bool {
        guard timescale > 0, currentTime.isNumeric, abs(rate) < 0.000_1 else { return false }
        return CMTimeCompare(currentTime, CMTime(value: targetFrame, timescale: timescale)) == 0
    }

    static func bufferedFrameCount(
        currentTime: CMTime,
        segmentStartFrame: Int64,
        nextFrame: Int64,
        timescale: CMTimeScale
    ) -> Int64 {
        guard nextFrame > segmentStartFrame else { return 0 }
        guard timescale > 0, currentTime.isNumeric else { return nextFrame - segmentStartFrame }
        let playhead = CMTimeConvertScale(currentTime, timescale: timescale, method: .roundTowardZero)
        guard playhead.isNumeric else { return nextFrame - segmentStartFrame }
        return nextFrame - min(nextFrame, max(segmentStartFrame, playhead.value))
    }

    static func restartFrame(
        currentTime: CMTime,
        suggestedFlushTime: CMTime?,
        timescale: CMTimeScale,
        fallbackFrame: Int64
    ) -> Int64 {
        guard timescale > 0 else { return max(0, fallbackFrame) }

        let candidates = [currentTime, suggestedFlushTime]
            .compactMap { $0 }
            .filter(\.isNumeric)
            .map {
                CMTimeConvertScale(
                    $0,
                    timescale: timescale,
                    method: .roundTowardPositiveInfinity
                )
            }
            .filter(\.isNumeric)
            .map(\.value)

        return max(0, candidates.max() ?? fallbackFrame)
    }
}

final class SampleBufferPlayer: @unchecked Sendable {
    typealias FailureHandler = @Sendable (Error) -> Void

    private let capture: SRAudioCaptureBridge
    private let renderer = AVSampleBufferAudioRenderer()
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    private let serializationQueue = DispatchQueue(
        label: "com.shevlfs.SpatialRelay.sample-buffer-player",
        qos: .userInitiated
    )
    private let queueKey = DispatchSpecificKey<UInt8>()
    private let factory: PCMSampleBufferFactory
    private let sampleRate: Double
    private let timeScale: CMTimeScale
    private let prebufferFrameCount: Int64
    private let onFailure: FailureHandler

    private var timer: DispatchSourceTimer?
    private var notificationTokens: [NSObjectProtocol] = []
    private var nextFrame: Int64 = 0
    private var segmentStartFrame: Int64 = 0
    private var enqueuedFrameCount: Int64 = 0
    private var timelineIsRunning = false
    private var backpressureStartTime: DispatchTime?
    private var pauseTransitionStartTime: DispatchTime?
    private var pauseTransitionTargetFrame: Int64 = 0
    private var segmentFirstEnqueueTime: DispatchTime?
    private var lastRendererConfigurationChangeTime: DispatchTime?
    private var rendererRecoveryIsActive = false
    private var formatRecoveryStartTime: DispatchTime?
    private var capturedFramesAtFormatMismatch: UInt64 = 0
    private var observedFormatMismatchCount: UInt64 = 0
    private var failureWasDelivered = false
    private var isStarted = false

    init(
        capture: SRAudioCaptureBridge,
        sampleRate: Double,
        outputDeviceUID: String,
        onFailure: @escaping FailureHandler
    ) throws {
        let roundedRate = sampleRate.rounded()
        guard roundedRate > 0, roundedRate <= Double(Int32.max) else {
            throw RelayError.unsupportedTapFormat("invalid sample rate \(sampleRate)")
        }
        self.capture = capture
        self.sampleRate = sampleRate
        self.timeScale = CMTimeScale(roundedRate)
        self.onFailure = onFailure
        self.factory = try PCMSampleBufferFactory(sampleRate: sampleRate)
        self.prebufferFrameCount = PlaybackBufferingPolicy.prebufferFrameCount(sampleRate: sampleRate)
        renderer.audioOutputDeviceUniqueID = outputDeviceUID
        // Playback always runs at 1x. No pitch correction is needed for this
        // live PCM stream, so avoid the default speech time-stretch algorithm.
        renderer.audioTimePitchAlgorithm = .varispeed
        serializationQueue.setSpecific(key: queueKey, value: 1)
    }

    deinit {
        stop()
    }

    func start() {
        performSync {
            guard !isStarted else { return }
            isStarted = true
            failureWasDelivered = false
            nextFrame = 0
            segmentStartFrame = 0
            enqueuedFrameCount = 0
            timelineIsRunning = false
            backpressureStartTime = nil
            pauseTransitionStartTime = nil
            pauseTransitionTargetFrame = 0
            segmentFirstEnqueueTime = nil
            lastRendererConfigurationChangeTime = nil
            rendererRecoveryIsActive = false
            formatRecoveryStartTime = nil
            capturedFramesAtFormatMismatch = 0
            observedFormatMismatchCount = 0

            // Audio-only renderers default to multichannel spatialization. This explicit
            // opt-in is what makes ordinary two-channel PCM eligible for Spatialize Stereo.
            renderer.allowedAudioSpatializationFormats = .monoAndStereo
            renderer.volume = 1
            synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
            synchronizer.addRenderer(renderer)
            synchronizer.setRate(0, time: .zero)
            pauseTransitionStartTime = .now()

            installRendererObservers()

            let timer = DispatchSource.makeTimerSource(queue: serializationQueue)
            timer.schedule(deadline: .now(), repeating: .milliseconds(4), leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in
                self?.pump()
            }
            self.timer = timer
            timer.resume()
        }
    }

    func stop() {
        performSync {
            guard isStarted else { return }
            isStarted = false

            timer?.setEventHandler {}
            timer?.cancel()
            timer = nil

            synchronizer.setRate(0, time: .invalid)
            renderer.flush()
            synchronizer.removeRenderer(renderer, at: .invalid, completionHandler: nil)
            removeRendererObservers()

            timelineIsRunning = false
            nextFrame = 0
            segmentStartFrame = 0
            enqueuedFrameCount = 0
            backpressureStartTime = nil
            pauseTransitionStartTime = nil
            pauseTransitionTargetFrame = 0
            segmentFirstEnqueueTime = nil
            lastRendererConfigurationChangeTime = nil
            rendererRecoveryIsActive = false
            formatRecoveryStartTime = nil
            capturedFramesAtFormatMismatch = 0
            observedFormatMismatchCount = 0
        }
    }

    /// The renderer owns output-mode changes, while the coordinator owns route
    /// health. Exposing only this bounded grace prevents a normal Spatial Audio
    /// reconfiguration from being mistaken for a disconnected device.
    func isWithinOutputReconfigurationGracePeriod() -> Bool {
        performSync {
            guard let start = lastRendererConfigurationChangeTime else { return false }
            return OutputReconfigurationGrace.contains(
                startUptimeNanoseconds: start.uptimeNanoseconds,
                nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        }
    }

    /// Software queue occupancy only; Bluetooth and device latency are not
    /// observable here and must not be presented as an end-to-end measurement.
    func bufferedMilliseconds() -> Double {
        performSync {
            guard isStarted else { return 0 }
            let rendererFrames = timelineIsRunning
                ? RendererRecoveryTimeline.bufferedFrameCount(
                    currentTime: synchronizer.currentTime(),
                    segmentStartFrame: segmentStartFrame,
                    nextFrame: nextFrame,
                    timescale: timeScale
                )
                : enqueuedFrameCount
            return (Double(capture.availableFrameCount) + Double(rendererFrames)) / sampleRate * 1_000
        }
    }

    private func pump() {
        guard isStarted && !failureWasDelivered else { return }

        if renderer.status == .failed {
            // AVQueuedSampleBufferRenderingStatus.failed is terminal. Normal
            // spatial-output changes are handled by the notifications below;
            // retaining Spotify's muted tap for five seconds cannot recover a
            // renderer that has actually entered this state.
            deliverFailure(RelayError.rendererFailed(renderer.error?.localizedDescription ?? "unknown renderer error"))
            return
        }

        let mismatchCount = capture.formatMismatchCount
        if mismatchCount > observedFormatMismatchCount {
            observedFormatMismatchCount = mismatchCount
            if formatRecoveryStartTime == nil {
                recoverRendererAfterConfigurationChange()
                formatRecoveryStartTime = .now()
                capturedFramesAtFormatMismatch = capture.capturedFrameCount
            }
        }
        if let formatRecoveryStartTime {
            if capture.capturedFrameCount > capturedFramesAtFormatMismatch {
                self.formatRecoveryStartTime = nil
            } else if elapsedMilliseconds(since: formatRecoveryStartTime) > OutputReconfigurationGrace.durationMilliseconds {
                deliverFailure(RelayError.captureFailed("the tap buffer layout did not recover after the output change"))
                return
            } else {
                return
            }
        }

        if capture.droppedFrameCount > 0 {
            deliverFailure(RelayError.captureFailed("the live audio buffer overflowed"))
            return
        }

        if rendererRecoveryIsActive, timelineIsRunning {
            var currentTime = CMTime.invalid
            var currentRate = Double.nan
            CMTimebaseGetTimeAndRate(synchronizer.timebase, timeOut: &currentTime, rateOut: &currentRate)
            if RendererRecoveryTimeline.hasPlaybackProgress(
                currentTime: currentTime,
                rate: currentRate,
                segmentStartFrame: segmentStartFrame,
                timescale: timeScale
            ) {
                rendererRecoveryIsActive = false
            }
        }

        let isWithinRecoveryWindow = lastRendererConfigurationChangeTime.map {
            OutputReconfigurationGrace.contains(
                startUptimeNanoseconds: $0.uptimeNanoseconds,
                nowUptimeNanoseconds: DispatchTime.now().uptimeNanoseconds
            )
        } ?? false
        if rendererRecoveryIsActive, !isWithinRecoveryWindow {
            if !timelineIsRunning, enqueuedFrameCount == 0,
               capture.availableFrameCount == 0, pauseTransitionStartTime == nil {
                // An idle, successfully paused renderer needs no PCM to recover.
                rendererRecoveryIsActive = false
            } else {
                deliverFailure(RelayError.rendererFailed("the output did not recover after its configuration changed"))
                return
            }
        }

        // The public rate property changes synchronously, before the timebase
        // applies setRate(_:time:). Check both the actual rate and anchor time
        // before enqueueing PCM against the restarted timeline.
        if let pauseTransitionStartTime {
            var currentTime = CMTime.invalid
            var currentRate = Double.nan
            CMTimebaseGetTimeAndRate(synchronizer.timebase, timeOut: &currentTime, rateOut: &currentRate)
            if RendererRecoveryTimeline.isPaused(
                currentTime: currentTime,
                rate: currentRate,
                targetFrame: pauseTransitionTargetFrame,
                timescale: timeScale
            ) {
                self.pauseTransitionStartTime = nil
            } else if elapsedMilliseconds(since: pauseTransitionStartTime) > OutputReconfigurationGrace.durationMilliseconds {
                deliverFailure(RelayError.rendererFailed("the render timeline did not pause"))
                return
            } else {
                return
            }
        }

        // Renderer queue depth includes the device's required playback lead.
        // Flushing it at a fixed software-buffer threshold can repeatedly
        // interrupt AirPods startup before the audio clock starts advancing.
        // Recovery is confirmed by actual progress above, while the separate
        // pause, backpressure, and format checks handle a stalled pipeline.
        // A route reconfiguration can hold up playback for seconds. Keep the
        // most recent PCM when restarting a live relay instead of preserving
        // that entire delay for the rest of the listening session.
        if rendererRecoveryIsActive, !timelineIsRunning {
            let staleFrames = PlaybackBufferingPolicy.recoveryDiscardFrameCount(
                availableFrames: capture.availableFrameCount,
                sampleRate: sampleRate
            )
            if staleFrames > 0 {
                _ = capture.discardFrames(maximumFrameCount: staleFrames)
            }
        }

        // If the control queue was delayed while Spotify was silent, the
        // synchronizer may already be beyond the last queued frame when audio
        // resumes. Rebase before enqueueing so new PCM is never timestamped in
        // the past.
        if timelineIsRunning, capture.availableFrameCount > 0 {
            let playhead = synchronizer.currentTime()
            if playhead.isNumeric,
               CMTimeCompare(playhead, mediaTime(forFrame: nextFrame)) >= 0 {
                resetTimeline(at: playhead)
                return
            }
        }

        var receivedData = false
        while renderer.isReadyForMoreMediaData,
              let chunk = capture.dequeueChunk(withMaximumFrameCount: 1_024) {
            do {
                if enqueuedFrameCount == 0 {
                    segmentStartFrame = nextFrame
                    segmentFirstEnqueueTime = .now()
                }
                let sampleBuffer = try factory.makeSampleBuffer(
                    data: chunk.data,
                    frameCount: chunk.frameCount,
                    startingAtFrame: nextFrame
                )
                renderer.enqueue(sampleBuffer)
                nextFrame += Int64(chunk.frameCount)
                enqueuedFrameCount += Int64(chunk.frameCount)
                receivedData = true
            } catch {
                deliverFailure(error)
                return
            }
        }

        if receivedData {
            backpressureStartTime = nil
        } else if capture.availableFrameCount >= UInt32(prebufferFrameCount),
                  !renderer.isReadyForMoreMediaData {
            if let backpressureStartTime {
                if elapsedMilliseconds(since: backpressureStartTime) > OutputReconfigurationGrace.durationMilliseconds {
                    deliverFailure(RelayError.rendererFailed("the renderer stopped accepting audio"))
                    return
                }
            } else {
                backpressureStartTime = .now()
            }
        } else {
            backpressureStartTime = nil
        }

        // A short burst followed by a pause may never fill the target buffer.
        // Play its tail after a bounded wait rather than leaving it queued forever.
        if !timelineIsRunning, let segmentFirstEnqueueTime {
            if PlaybackBufferingPolicy.shouldStartPlayback(
                enqueuedFrames: enqueuedFrameCount,
                targetFrames: prebufferFrameCount,
                elapsedMilliseconds: elapsedMilliseconds(since: segmentFirstEnqueueTime)
            ) {
                synchronizer.setRate(1, time: mediaTime(forFrame: segmentStartFrame))
                timelineIsRunning = true
            }
        }

        // The ring is normally empty while the renderer stays prebuffered. When
        // its playhead actually reaches the final queued sample, freeze there;
        // this handles even very short Spotify pauses without creating late PTS.
        if timelineIsRunning, capture.availableFrameCount == 0 {
            let playhead = synchronizer.currentTime()
            let queuedEnd = mediaTime(forFrame: nextFrame)
            if playhead.isNumeric, CMTimeCompare(playhead, queuedEnd) >= 0 {
                resetTimeline(at: playhead)
            }
        }
    }

    private func resetTimeline(at playhead: CMTime) {
        let converted = CMTimeConvertScale(
            playhead,
            timescale: timeScale,
            method: .roundTowardPositiveInfinity
        )
        let restartFrame = converted.isNumeric ? max(nextFrame, converted.value) : nextFrame
        let restartTime = mediaTime(forFrame: restartFrame)

        synchronizer.setRate(0, time: restartTime)
        renderer.flush()
        nextFrame = restartFrame
        segmentStartFrame = restartFrame
        enqueuedFrameCount = 0
        segmentFirstEnqueueTime = nil
        timelineIsRunning = false
        backpressureStartTime = nil
        pauseTransitionStartTime = .now()
        pauseTransitionTargetFrame = restartFrame
    }

    /// Spatial Audio mode changes legitimately reconfigure the AirPods output.
    /// AVFoundation asks clients to flush and enqueue again from the current
    /// playhead; treating this notification as fatal caused the first toggle to
    /// stop the relay. Keep captured PCM in the ring, rebase, and prebuffer it.
    private func recoverRendererAfterConfigurationChange(suggestedFlushTime: CMTime? = nil) {
        guard isStarted && !failureWasDelivered else { return }
        if !rendererRecoveryIsActive {
            lastRendererConfigurationChangeTime = .now()
        }

        // OutputConfigurationDidChange and WasFlushedAutomatically commonly
        // arrive as a pair. If the first notification is still waiting for the
        // timebase to pause, its serialized flush already covers the second.
        guard !(rendererRecoveryIsActive && pauseTransitionStartTime != nil) else { return }
        rendererRecoveryIsActive = true

        let playhead = synchronizer.currentTime()
        let restartFrame = RendererRecoveryTimeline.restartFrame(
            currentTime: playhead,
            suggestedFlushTime: suggestedFlushTime,
            timescale: timeScale,
            fallbackFrame: nextFrame
        )
        let restartTime = mediaTime(forFrame: restartFrame)

        synchronizer.setRate(0, time: restartTime)
        renderer.flush()
        nextFrame = restartFrame
        segmentStartFrame = restartFrame
        enqueuedFrameCount = 0
        segmentFirstEnqueueTime = nil
        timelineIsRunning = false
        backpressureStartTime = nil
        pauseTransitionStartTime = .now()
        pauseTransitionTargetFrame = restartFrame
    }

    private func installRendererObservers() {
        let center = NotificationCenter.default
        let outputToken = center.addObserver(
            forName: .AVSampleBufferAudioRendererOutputConfigurationDidChange,
            object: renderer,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.serializationQueue.async { [self] in
                self.recoverRendererAfterConfigurationChange()
            }
        }
        notificationTokens.append(outputToken)

        let flushToken = center.addObserver(
            forName: .AVSampleBufferAudioRendererWasFlushedAutomatically,
            object: renderer,
            queue: nil
        ) { [weak self] notification in
            guard let self else { return }
            let flushTime = (notification.userInfo?[AVSampleBufferAudioRendererFlushTimeKey] as? NSValue)?.timeValue
            self.serializationQueue.async { [self] in
                self.recoverRendererAfterConfigurationChange(suggestedFlushTime: flushTime)
            }
        }
        notificationTokens.append(flushToken)
    }

    private func removeRendererObservers() {
        let center = NotificationCenter.default
        notificationTokens.forEach(center.removeObserver)
        notificationTokens.removeAll()
    }

    private func deliverFailure(_ error: Error) {
        guard !failureWasDelivered else { return }
        failureWasDelivered = true
        // Failures go directly to the coordinator queue, which owns capture
        // start/stop. Calling capture.stop() here raced its health checks and
        // teardown. The coordinator restores direct output without a UI round trip.
        onFailure(error)
    }

    private func mediaTime(forFrame frame: Int64) -> CMTime {
        CMTime(value: frame, timescale: timeScale)
    }

    private func elapsedMilliseconds(since time: DispatchTime) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let then = time.uptimeNanoseconds
        guard now >= then else { return 0 }
        return (now - then) / 1_000_000
    }

    private func performSync<T>(_ work: () -> T) -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return work()
        }
        return serializationQueue.sync(execute: work)
    }
}

private final class PCMSampleBufferFactory {
    private let formatDescription: CMAudioFormatDescription
    private let timescale: CMTimeScale

    init(sampleRate: Double) throws {
        let roundedRate = sampleRate.rounded()
        guard roundedRate > 0, roundedRate <= Double(Int32.max) else {
            throw RelayError.unsupportedTapFormat("invalid sample rate \(sampleRate)")
        }
        timescale = CMTimeScale(roundedRate)

        var format = AudioStreamBasicDescription(
            mSampleRate: sampleRate,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagsNativeEndian,
            mBytesPerPacket: 8,
            mFramesPerPacket: 1,
            mBytesPerFrame: 8,
            mChannelsPerFrame: 2,
            mBitsPerChannel: 32,
            mReserved: 0
        )
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: kCFAllocatorDefault,
            asbd: &format,
            layoutSize: 0,
            layout: nil,
            magicCookieSize: 0,
            magicCookie: nil,
            extensions: nil,
            formatDescriptionOut: &description
        )
        try CoreAudioFailure.check(status, operation: "Creating the stereo PCM description")
        guard let description else {
            throw RelayError.unsupportedTapFormat("Core Media rejected the PCM description")
        }
        formatDescription = description
    }

    func makeSampleBuffer(
        data: Data,
        frameCount: UInt32,
        startingAtFrame: Int64
    ) throws -> CMSampleBuffer {
        guard frameCount > 0, data.count == Int(frameCount) * 8 else {
            throw RelayError.captureFailed("an incomplete PCM chunk was received")
        }

        var blockBuffer: CMBlockBuffer?
        try CoreAudioFailure.check(
            CMBlockBufferCreateWithMemoryBlock(
                allocator: kCFAllocatorDefault,
                memoryBlock: nil,
                blockLength: data.count,
                blockAllocator: kCFAllocatorDefault,
                customBlockSource: nil,
                offsetToData: 0,
                dataLength: data.count,
                flags: 0,
                blockBufferOut: &blockBuffer
            ),
            operation: "Allocating an audio block buffer"
        )
        guard let blockBuffer else {
            throw RelayError.captureFailed("Core Media did not allocate an audio buffer")
        }

        let copyStatus = data.withUnsafeBytes { bytes -> OSStatus in
            guard let baseAddress = bytes.baseAddress else { return kCMBlockBufferBadPointerParameterErr }
            return CMBlockBufferReplaceDataBytes(
                with: baseAddress,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: data.count
            )
        }
        try CoreAudioFailure.check(copyStatus, operation: "Copying a PCM audio chunk")

        var sampleBuffer: CMSampleBuffer?
        let presentationTime = CMTime(value: startingAtFrame, timescale: timescale)
        try CoreAudioFailure.check(
            CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: kCFAllocatorDefault,
                dataBuffer: blockBuffer,
                formatDescription: formatDescription,
                sampleCount: CMItemCount(frameCount),
                presentationTimeStamp: presentationTime,
                packetDescriptions: nil,
                sampleBufferOut: &sampleBuffer
            ),
            operation: "Creating a PCM sample buffer"
        )
        guard let sampleBuffer else {
            throw RelayError.captureFailed("Core Media did not create a sample buffer")
        }
        return sampleBuffer
    }
}
