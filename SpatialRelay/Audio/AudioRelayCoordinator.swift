import CoreAudio
import Foundation

struct RelayDiscovery: Sendable {
    let spotifyProcesses: [AudioProcessInfo]
    let outputDevice: OutputDeviceInfo?
}

struct RelayMetrics: Sendable {
    let peakLevel: Float
    let bufferedMilliseconds: Double
    let droppedFrameCount: UInt64
}

final class AudioRelayCoordinator: @unchecked Sendable {
    private let hardware = AudioHardwareClient()
    private let controlQueue = DispatchQueue(label: "com.shevlfs.SpatialRelay.audio-coordinator")
    private let controlQueueKey = DispatchSpecificKey<UInt8>()

    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var capture: SRAudioCaptureBridge?
    private var player: SampleBufferPlayer?
    private var activeOutput: OutputDeviceInfo?
    private var activeProcessIDs = Set<AudioObjectID>()
    private var activeSampleRate: Double = 0
    private var lastCapturedFrameCount: UInt64 = 0
    private var stalledCaptureChecks = 0
    private var sampleRateMismatchStartTime: DispatchTime?
    private var activePipelineID: UUID?

    private var isActive = false

    init() {
        controlQueue.setSpecific(key: controlQueueKey, value: 1)
    }

    deinit {
        _ = stop()
    }

    func discover() throws -> RelayDiscovery {
        try performSync {
            RelayDiscovery(
                spotifyProcesses: try hardware.spotifyProcesses(),
                outputDevice: try? hardware.defaultOutputDevice()
            )
        }
    }

    @discardableResult
    func start(onFailure: @escaping @Sendable (Error) -> Void) throws -> RelayDiscovery {
        try performSync {
            try startPipeline(onFailure: onFailure)
        }
    }

    private func startPipeline(onFailure: @escaping @Sendable (Error) -> Void) throws -> RelayDiscovery {
        if let cleanupFailure = stopPipeline() {
            throw cleanupFailure
        }

        #if !arch(arm64)
        throw RelayError.unsupportedMac
        #endif

        let output = try hardware.defaultOutputDevice()
        let processes = try hardware.spotifyProcesses()
        guard !processes.isEmpty else {
            throw RelayError.spotifyNotRunning
        }

        do {
            tapID = try hardware.createSpotifyTap(processes: processes, outputDevice: output)
            let format = try hardware.tapFormat(tapID)
            guard format.mSampleRate.isFinite,
                  format.mSampleRate >= 1,
                  format.mSampleRate <= Double(Int32.max) else {
                throw RelayError.unsupportedTapFormat("invalid sample rate \(format.mSampleRate)")
            }
            guard abs(format.mSampleRate - output.sampleRate) <= 0.5 else {
                throw RelayError.unsupportedTapFormat(
                    "the tap is \(Int(format.mSampleRate.rounded())) Hz but the output is \(Int(output.sampleRate.rounded())) Hz"
                )
            }
            let uid = try hardware.tapUID(tapID)
            aggregateID = try hardware.createAggregateDevice(tapUID: uid)

            let capture = SRAudioCaptureBridge()
            let pipelineID = UUID()
            let player = try SampleBufferPlayer(
                capture: capture,
                sampleRate: format.mSampleRate,
                outputDeviceUID: output.uid
            ) { [weak self] error in
                guard let self else { return }
                self.controlQueue.async { [weak self] in
                    guard let self, self.isActive, self.activePipelineID == pipelineID else { return }
                    // Flush playback before stopping the tap, then immediately release
                    // mutedWhenTapped so Spotify's direct output is restored.
                    let cleanupFailure = self.stopPipeline()
                    DispatchQueue.main.async {
                        onFailure(cleanupFailure ?? error)
                    }
                }
            }

            self.capture = capture
            self.player = player

            do {
                try capture.startCapturingDevice(aggregateID, format: format)
            } catch {
                throw RelayError.captureFailed(error.localizedDescription)
            }
            player.start()

            activeOutput = output
            activeProcessIDs = Set(processes.map(\.id))
            activeSampleRate = format.mSampleRate
            lastCapturedFrameCount = capture.capturedFrameCount
            stalledCaptureChecks = 0
            sampleRateMismatchStartTime = nil
            activePipelineID = pipelineID
            isActive = true

            return RelayDiscovery(spotifyProcesses: processes, outputDevice: output)
        } catch {
            let startupFailure = error
            if let cleanupFailure = tearDownPipeline() {
                throw cleanupFailure
            }
            throw startupFailure
        }
    }

    @discardableResult
    func stop() -> Error? {
        performSync {
            stopPipeline()
        }
    }

    private func stopPipeline() -> Error? {
        isActive = false
        activePipelineID = nil
        return tearDownPipeline()
    }

    func metrics() -> RelayMetrics {
        performSync {
            guard let capture, activeSampleRate > 0 else {
                return RelayMetrics(peakLevel: 0, bufferedMilliseconds: 0, droppedFrameCount: 0)
            }
            let buffered = player?.bufferedMilliseconds()
                ?? Double(capture.availableFrameCount) / activeSampleRate * 1_000
            return RelayMetrics(
                peakLevel: capture.peakLevel,
                bufferedMilliseconds: buffered,
                droppedFrameCount: capture.droppedFrameCount
            )
        }
    }

    /// The relay safely stops on route/process replacement. Restarting builds
    /// a new device-scoped tap with the new stream format and avoids consuming muted audio
    /// through a stale renderer.
    func healthFailure() -> Error? {
        performSync {
            healthFailureLocked()
        }
    }

    private func healthFailureLocked() -> Error? {
        guard isActive, let activeOutput else { return nil }
        let isWithinOutputGrace = player?.isWithinOutputReconfigurationGracePeriod() == true

        guard capture?.isCapturing == true else {
            return RelayError.captureFailed("the Core Audio callback stopped")
        }

        do {
            let output = try hardware.defaultOutputDevice()
            if output.id != activeOutput.id || output.uid != activeOutput.uid {
                // The renderer is pinned to the original UID. A different
                // default device needs a fresh tap even during spatial-mode
                // recovery; continuing could send audio to the old route.
                return RelayError.rendererFailed("the default output route changed; start the relay again to use \(output.name)")
            }

            if abs(output.sampleRate - activeOutput.sampleRate) > 0.5 {
                if let sampleRateMismatchStartTime {
                    if !isWithinOutputGrace,
                       elapsedMilliseconds(since: sampleRateMismatchStartTime) > OutputReconfigurationGrace.durationMilliseconds {
                        return RelayError.rendererFailed("the output sample rate changed")
                    }
                } else {
                    sampleRateMismatchStartTime = .now()
                }
            } else {
                sampleRateMismatchStartTime = nil
            }

            let processes = try hardware.spotifyProcesses()
            let processIDs = Set(processes.map(\.id))
            if activeProcessIDs.isDisjoint(with: processIDs) {
                return RelayError.captureFailed("Spotify replaced its audio process")
            }

            let runningOutputIDs = Set(processes.filter(\.isRunningOutput).map(\.id))
            if !runningOutputIDs.isEmpty && !runningOutputIDs.isSubset(of: activeProcessIDs) {
                return RelayError.captureFailed("Spotify moved playback to a new audio process")
            }

            if !runningOutputIDs.isEmpty, let capture {
                let capturedFrameCount = capture.capturedFrameCount
                if isWithinOutputGrace {
                    // A spatial-output transition can briefly suspend the HAL
                    // callback. Begin stall detection after the bounded grace,
                    // rather than spending the grace period's entire budget.
                    lastCapturedFrameCount = capturedFrameCount
                    stalledCaptureChecks = 0
                } else if capturedFrameCount == lastCapturedFrameCount {
                    stalledCaptureChecks += 1
                } else {
                    lastCapturedFrameCount = capturedFrameCount
                    stalledCaptureChecks = 0
                }
                if stalledCaptureChecks >= 6 {
                    return RelayError.captureFailed("the Core Audio tap stopped delivering frames")
                }
            } else {
                lastCapturedFrameCount = capture?.capturedFrameCount ?? 0
                stalledCaptureChecks = 0
            }
        } catch {
            if isWithinOutputGrace {
                return nil
            }
            return error
        }
        return nil
    }

    private func tearDownPipeline() -> Error? {
        // Order matters: discard queued relay audio, stop reading (which un-mutes
        // Spotify), then destroy the aggregate device and process tap.
        var cleanupProblems: [String] = []

        player?.stop()
        player = nil

        var callbackWasDestroyed = true
        if let capture {
            do {
                try capture.stop()
            } catch {
                cleanupProblems.append(error.localizedDescription)
                callbackWasDestroyed = !capture.isCapturing
                let unmuteStatus = hardware.unmuteTap(tapID)
                if unmuteStatus != noErr {
                    cleanupProblems.append(
                        "Unmuting the process tap failed (\(CoreAudioFailure.describe(unmuteStatus)))"
                    )
                }
            }
        }

        // Keep the bridge and its HAL objects alive when its IOProc is still
        // registered. A later Stop (or app teardown) can safely retry it.
        if callbackWasDestroyed {
            self.capture = nil

            let aggregateStatus = hardware.destroyAggregateDevice(aggregateID)
            if aggregateStatus == noErr {
                aggregateID = kAudioObjectUnknown
            } else {
                cleanupProblems.append(
                    "Destroying the private tap device failed (\(CoreAudioFailure.describe(aggregateStatus)))"
                )
            }

            // Do not remove a tap while an aggregate device still references it.
            if aggregateID == kAudioObjectUnknown {
                let tapStatus = hardware.destroyTap(tapID)
                if tapStatus == noErr {
                    tapID = kAudioObjectUnknown
                } else {
                    cleanupProblems.append(
                        "Destroying the process tap failed (\(CoreAudioFailure.describe(tapStatus)))"
                    )
                    let unmuteStatus = hardware.unmuteTap(tapID)
                    if unmuteStatus != noErr {
                        cleanupProblems.append(
                            "Unmuting the retained process tap failed (\(CoreAudioFailure.describe(unmuteStatus)))"
                        )
                    }
                }
            } else {
                _ = hardware.unmuteTap(tapID)
            }
        }

        activeOutput = nil
        activeProcessIDs.removeAll()
        activeSampleRate = 0
        lastCapturedFrameCount = 0
        stalledCaptureChecks = 0
        sampleRateMismatchStartTime = nil

        guard !cleanupProblems.isEmpty else { return nil }
        return RelayError.cleanupFailed(cleanupProblems.joined(separator: "; "))
    }

    private func performSync<T>(_ work: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: controlQueueKey) != nil {
            return try work()
        }
        return try controlQueue.sync(execute: work)
    }

    private func elapsedMilliseconds(since time: DispatchTime) -> UInt64 {
        let now = DispatchTime.now().uptimeNanoseconds
        let then = time.uptimeNanoseconds
        guard now >= then else { return 0 }
        return (now - then) / 1_000_000
    }
}
