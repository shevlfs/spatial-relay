import AppKit
import Combine
import Foundation

protocol AudioRelayControlling: AnyObject, Sendable {
    func discover() throws -> RelayDiscovery
    /// Deliver failures after tearing down the failed pipeline and restoring direct output.
    func start(onFailure: @escaping @Sendable (Error) -> Void) throws -> RelayDiscovery
    @discardableResult func stop() -> Error?
    func metrics() -> RelayMetrics
    func healthFailure() -> Error?
}

extension AudioRelayCoordinator: AudioRelayControlling {}

@MainActor
final class RelayViewModel: ObservableObject {
    enum CheckState {
        case ready
        case warning
        case unavailable
    }

    struct Message: Equatable {
        enum Kind {
            case info
            case warning
            case error
        }

        let kind: Kind
        let text: String
    }

    @Published private(set) var spotifyDetail = "Looking for Spotify…"
    @Published private(set) var spotifyState: CheckState = .warning
    @Published private(set) var outputDetail = "Looking for the current output…"
    @Published private(set) var outputState: CheckState = .warning
    @Published private(set) var message: Message?
    @Published private(set) var isRelaying = false
    @Published private(set) var isBusy = false
    @Published private(set) var isRefreshing = false
    @Published private(set) var operationLabel = "Starting…"
    @Published private(set) var meterLevel: CGFloat = 0
    @Published private(set) var bufferedMilliseconds: Double = 0
    @Published private(set) var droppedFrameCount: UInt64 = 0

    private let coordinator: any AudioRelayControlling
    private let startupQueue = DispatchQueue(
        label: "com.shevlfs.SpatialRelay.startup",
        qos: .userInitiated
    )
    private var discovery: RelayDiscovery?
    private var meterTimer: Timer?
    private var healthTick = 0
    private var relaySessionID: UUID?
    private var discoveryOperationID: UUID?
    private var pollIsRunning = false
    private var terminationCleanupIsRunning = false
    private var terminationCompletions: [() -> Void] = []
    private(set) var isReadyToTerminate = false

    init(coordinator: any AudioRelayControlling = AudioRelayCoordinator()) {
        self.coordinator = coordinator
    }

    deinit {
        MainActor.assumeIsolated {
            meterTimer?.invalidate()
        }
        let coordinator = coordinator
        startupQueue.async {
            _ = coordinator.stop()
        }
    }

    var canToggleRelay: Bool {
        if isRelaying { return !isBusy }
        return !isBusy && !isRefreshing && !terminationCleanupIsRunning && !isReadyToTerminate &&
            discovery?.outputDevice != nil &&
            !(discovery?.spotifyProcesses.isEmpty ?? true)
    }

    var latencyLabel: String {
        String(format: "%.0f ms buffered", bufferedMilliseconds)
    }

    var outputSymbolName: String {
        discovery?.outputDevice?.isLikelySpatialAudioHeadphones == true
            ? "headphones" : "speaker.wave.2"
    }

    var menuBarSymbolName: String {
        if isBusy { return "ellipsis.circle" }
        if isRelaying { return "waveform.circle.fill" }
        if message?.kind == .error { return "exclamationmark.triangle.fill" }
        return "waveform.circle"
    }

    var menuBarStatusText: String {
        if isBusy { return "Spatial Relay is changing audio state" }
        if isRelaying { return "Spatial Relay is active" }
        if message?.kind == .error { return "Spatial Relay needs attention" }
        return "Spatial Relay is stopped"
    }

    func refresh(preservingError: Bool = false) {
        guard !isRelaying, !isBusy, !isRefreshing, !isReadyToTerminate else { return }
        refreshRoute(preservingError: preservingError)
    }

    func toggleRelay() {
        guard canToggleRelay else { return }
        if isRelaying {
            stopRelay()
        } else {
            startRelay()
        }
    }

    func openSpotify() {
        guard !isBusy, !isRelaying, !isReadyToTerminate else { return }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.spotify.client") else {
            message = Message(kind: .error, text: "Spotify is not installed in a location macOS can find.")
            return
        }

        NSWorkspace.shared.openApplication(at: url, configuration: .init()) { [weak self] _, error in
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.isRelaying, !self.isBusy, !self.isReadyToTerminate else { return }
                    if let error {
                        self.message = Message(kind: .error, text: error.localizedDescription)
                    } else {
                        self.refresh()
                        // Spotify may register its audio process after launch completes.
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                            self?.refresh(preservingError: true)
                        }
                    }
                }
            }
        }
    }

    func prepareForTermination(completion: @escaping () -> Void) {
        if isReadyToTerminate {
            completion()
            return
        }

        terminationCompletions.append(completion)
        guard !terminationCleanupIsRunning else { return }
        terminationCleanupIsRunning = true

        relaySessionID = nil
        discoveryOperationID = nil
        isRefreshing = false
        meterTimer?.invalidate()
        meterTimer = nil
        isRelaying = false
        isBusy = true
        operationLabel = "Quitting…"
        meterLevel = 0

        // The serial startup queue gives cleanup strict ordering after a tap
        // creation that may still be waiting for the privacy prompt. AppKit's
        // terminate-later reply keeps the process alive, while leaving the main
        // actor and menu responsive until Spotify has been safely unmuted.
        let coordinator = coordinator
        startupQueue.async { [weak self] in
            _ = coordinator.stop()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.isBusy = false
                    self.isReadyToTerminate = true
                    self.terminationCleanupIsRunning = false
                    let completions = self.terminationCompletions
                    self.terminationCompletions.removeAll()
                    completions.forEach { $0() }
                }
            }
        }
    }

    func quitApplication() {
        NSApplication.shared.terminate(nil)
    }

    private func startRelay() {
        isBusy = true
        operationLabel = "Starting…"
        message = nil
        let operationID = UUID()
        relaySessionID = operationID
        let coordinator = coordinator

        // Tap creation can wait for Core Audio or a privacy prompt. Keep it off
        // the main actor so the window and progress indicator stay responsive.
        startupQueue.async { [weak self] in
            let result: Result<RelayDiscovery, Error>
            do {
                let discovery = try coordinator.start { [weak self] error in
                    Task { @MainActor in
                        self?.handlePipelineFailure(error, sessionID: operationID)
                    }
                }
                result = .success(discovery)
            } catch {
                result = .failure(coordinator.stop() ?? error)
            }

            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    self?.completeStart(result, operationID: operationID)
                }
            }
        }
    }

    private func completeStart(
        _ result: Result<RelayDiscovery, Error>,
        operationID: UUID
    ) {
        guard relaySessionID == operationID else { return }
        isBusy = false

        switch result {
        case .success(let discovery):
            self.discovery = discovery
            apply(discovery)
            isRelaying = true
            if let output = discovery.outputDevice, !output.isLikelySpatialAudioHeadphones {
                message = Message(
                    kind: .warning,
                    text: "Relaying to \(output.name). For Spatial Audio, select your AirPods in macOS, then restart the relay."
                )
            } else {
                message = nil
            }
            startMetering()
        case .failure(let error):
            relaySessionID = nil
            isRelaying = false
            message = Message(
                kind: .error,
                text: startFailureMessage(error)
            )
        }
    }

    private func stopRelay() {
        relaySessionID = nil
        isBusy = true
        operationLabel = "Stopping…"
        meterTimer?.invalidate()
        meterTimer = nil
        let coordinator = coordinator
        startupQueue.async { [weak self] in
            let cleanupFailure = coordinator.stop()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, !self.terminationCleanupIsRunning, !self.isReadyToTerminate else { return }
                    self.isRelaying = false
                    self.meterLevel = 0
                    self.bufferedMilliseconds = 0
                    self.droppedFrameCount = 0
                    self.isBusy = false
                    self.message = cleanupFailure.map {
                        Message(kind: .error, text: $0.localizedDescription)
                    }
                    self.refreshRoute(preservingError: true)
                }
            }
        }
    }

    private func handlePipelineFailure(_ error: Error, sessionID: UUID) {
        guard relaySessionID == sessionID, !terminationCleanupIsRunning else { return }
        relaySessionID = nil
        meterTimer?.invalidate()
        meterTimer = nil
        isRelaying = false
        isBusy = false
        meterLevel = 0
        bufferedMilliseconds = 0
        droppedFrameCount = 0
        message = Message(kind: .error, text: error.localizedDescription)
        refreshRoute(preservingError: true)
    }

    private func startMetering() {
        meterTimer?.invalidate()
        healthTick = 0
        let timer = Timer(timeInterval: 0.12, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.pollPipeline()
            }
        }
        timer.tolerance = 0.02
        RunLoop.main.add(timer, forMode: .common)
        meterTimer = timer
    }

    private func pollPipeline() {
        guard isRelaying, !isBusy, !pollIsRunning, let sessionID = relaySessionID else { return }
        pollIsRunning = true
        healthTick += 1
        let shouldCheckHealth = healthTick >= 8
        if shouldCheckHealth { healthTick = 0 }
        let coordinator = coordinator
        startupQueue.async { [weak self] in
            let metrics = coordinator.metrics()
            let failure = shouldCheckHealth ? coordinator.healthFailure() : nil
            let reportedFailure = failure.map { coordinator.stop() ?? $0 }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.pollIsRunning = false
                    guard self.relaySessionID == sessionID, !self.isBusy else { return }
                    if let reportedFailure {
                        self.handlePipelineFailure(reportedFailure, sessionID: sessionID)
                        return
                    }
                    let peak = metrics.peakLevel.isFinite ? max(0, min(1, metrics.peakLevel)) : 0
                    self.meterLevel = max(CGFloat(pow(peak, 0.45)), self.meterLevel * 0.72)
                    self.bufferedMilliseconds = metrics.bufferedMilliseconds.isFinite
                        ? max(0, metrics.bufferedMilliseconds) : 0
                    self.droppedFrameCount = metrics.droppedFrameCount
                }
            }
        }
    }

    private func apply(_ discovery: RelayDiscovery) {
        if discovery.spotifyProcesses.isEmpty {
            spotifyDetail = "Open Spotify and start playback"
            spotifyState = .unavailable
        } else {
            let activeCount = discovery.spotifyProcesses.filter(\.isRunningOutput).count
            spotifyDetail = activeCount > 0
                ? "Audio stream detected"
                : "Waiting for playback"
            spotifyState = activeCount > 0 ? .ready : .warning
        }

        if let output = discovery.outputDevice {
            outputDetail = output.name
            outputState = output.isLikelySpatialAudioHeadphones ? .ready : .warning
        } else {
            outputDetail = "No default output device"
            outputState = .unavailable
        }

        guard message == nil || message?.kind != .error else { return }

        #if !arch(arm64)
        message = Message(kind: .error, text: RelayError.unsupportedMac.localizedDescription)
        #else
        if discovery.spotifyProcesses.isEmpty {
            message = Message(kind: .warning, text: "Play a song in Spotify, then refresh to connect.")
        } else if discovery.outputDevice == nil {
            message = Message(kind: .warning, text: "Select an audio output in the macOS Sound menu.")
        } else if let output = discovery.outputDevice, !output.isLikelySpatialAudioHeadphones {
            message = Message(kind: .warning, text: "Select your AirPods in the macOS Sound menu to use Spatial Audio.")
        } else if !isRelaying {
            message = nil
        }
        #endif
    }

    private func refreshRoute(preservingError: Bool) {
        let operationID = UUID()
        discoveryOperationID = operationID
        isRefreshing = true
        let coordinator = coordinator
        startupQueue.async { [weak self] in
            let result = Result { try coordinator.discover() }
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self, self.discoveryOperationID == operationID else { return }
                    self.discoveryOperationID = nil
                    self.isRefreshing = false
                    let savedError = preservingError && self.message?.kind == .error ? self.message : nil
                    switch result {
                    case .success(let discovery):
                        self.discovery = discovery
                        self.message = savedError
                        self.apply(discovery)
                    case .failure(let error):
                        self.discovery = nil
                        self.spotifyDetail = "Could not check Spotify"
                        self.spotifyState = .unavailable
                        self.outputDetail = "Could not check output"
                        self.outputState = .unavailable
                        self.message = Message(kind: .error, text: error.localizedDescription)
                    }
                    if let savedError { self.message = savedError }
                }
            }
        }
    }

    private func startFailureMessage(_ error: Error) -> String {
        let description = error.localizedDescription
        if description.localizedCaseInsensitiveContains("permission") ||
            description.localizedCaseInsensitiveContains("denied") ||
            description.localizedCaseInsensitiveContains("operation not permitted") ||
            description.localizedCaseInsensitiveContains("'perm'") ||
            description.contains("560492391") ||
            description.localizedCaseInsensitiveContains("!hog") {
            return "\(description) Allow Spatial Relay in System Settings → Privacy & Security → Screen & System Audio Recording, then relaunch it."
        }
        return description
    }
}
