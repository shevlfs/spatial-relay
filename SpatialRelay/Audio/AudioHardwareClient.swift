import AppKit
import CoreAudio
import Foundation

struct AudioProcessInfo: Equatable, Identifiable, Sendable {
    let id: AudioObjectID
    let pid: pid_t
    let bundleIdentifier: String
    let applicationName: String
    let isRunningOutput: Bool
}

struct OutputDeviceInfo: Equatable, Sendable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let sampleRate: Double

    var isLikelySpatialAudioHeadphones: Bool {
        let normalized = name.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return normalized.contains("airpods") ||
            normalized.contains("beats fit pro") ||
            normalized.contains("beats studio pro")
    }
}

enum SpotifyProcessMatcher {
    static func matches(bundleIdentifier: String, applicationName: String) -> Bool {
        let bundle = bundleIdentifier
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        if !bundle.isEmpty {
            return bundle == "com.spotify.client" || bundle.hasPrefix("com.spotify.client.")
        }

        // Older Core Audio process objects may not expose a bundle identifier.
        // Only then fall back to the application name.
        let name = applicationName.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return name == "spotify" || name.hasPrefix("spotify helper")
    }
}

final class AudioHardwareClient {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    func spotifyProcesses() throws -> [AudioProcessInfo] {
        let objectIDs = try processObjectIDs()
        return objectIDs.compactMap { objectID in
            guard objectID != kAudioObjectUnknown else { return nil }

            let coreAudioBundleID = (try? readString(objectID, selector: kAudioProcessPropertyBundleID)) ?? ""
            // Most objects belong to other apps. Avoid resolving their process
            // and AppKit metadata during every relay health check.
            if !coreAudioBundleID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
               !SpotifyProcessMatcher.matches(bundleIdentifier: coreAudioBundleID, applicationName: "") {
                return nil
            }
            let pid = (try? readPID(objectID)) ?? 0
            let application = NSRunningApplication(processIdentifier: pid)
            let bundleID = coreAudioBundleID.isEmpty ? (application?.bundleIdentifier ?? "") : coreAudioBundleID
            let applicationName = application?.localizedName ?? ""

            guard SpotifyProcessMatcher.matches(
                bundleIdentifier: bundleID,
                applicationName: applicationName
            ) else {
                return nil
            }

            return AudioProcessInfo(
                id: objectID,
                pid: pid,
                bundleIdentifier: bundleID,
                applicationName: applicationName.isEmpty ? "Spotify" : applicationName,
                isRunningOutput: (try? readBool(objectID, selector: kAudioProcessPropertyIsRunningOutput)) ?? false
            )
        }
        .sorted {
            if $0.isRunningOutput != $1.isRunningOutput {
                return $0.isRunningOutput && !$1.isRunningOutput
            }
            return $0.pid < $1.pid
        }
    }

    private func processObjectIDs() throws -> [AudioObjectID] {
        var address = propertyAddress(kAudioHardwarePropertyProcessObjectList)
        let stride = MemoryLayout<AudioObjectID>.stride

        // Processes can start between the size query and read. Retry a growing
        // list instead of failing a healthy relay when another app opens audio.
        for attempt in 0..<3 {
            var byteCount: UInt32 = 0
            try CoreAudioFailure.check(
                AudioObjectGetPropertyDataSize(systemObject, &address, 0, nil, &byteCount),
                operation: "Reading the audio process list size"
            )
            guard byteCount > 0 else { return [] }
            guard Int(byteCount) % stride == 0 else {
                throw CoreAudioFailure(
                    operation: "Reading the audio process list",
                    status: kAudioHardwareBadPropertySizeError
                )
            }

            let allocatedByteCount = byteCount
            var objectIDs = [AudioObjectID](repeating: kAudioObjectUnknown, count: Int(byteCount) / stride)
            let status = objectIDs.withUnsafeMutableBytes { bytes in
                AudioObjectGetPropertyData(systemObject, &address, 0, nil, &byteCount, bytes.baseAddress!)
            }
            if status == kAudioHardwareBadPropertySizeError, attempt < 2 { continue }
            try CoreAudioFailure.check(status, operation: "Reading the audio process list")
            guard byteCount <= allocatedByteCount, Int(byteCount) % stride == 0 else {
                throw CoreAudioFailure(
                    operation: "Reading the audio process list",
                    status: kAudioHardwareBadPropertySizeError
                )
            }
            // A shrinking list may successfully return fewer objects.
            return Array(objectIDs.prefix(Int(byteCount) / stride))
        }
        throw CoreAudioFailure(
            operation: "Reading the audio process list",
            status: kAudioHardwareBadPropertySizeError
        )
    }

    func defaultOutputDevice() throws -> OutputDeviceInfo {
        var address = propertyAddress(kAudioHardwarePropertyDefaultOutputDevice)
        var deviceID = AudioDeviceID(kAudioObjectUnknown)
        var byteCount = UInt32(MemoryLayout<AudioDeviceID>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(systemObject, &address, 0, nil, &byteCount, &deviceID),
            operation: "Finding the default output device"
        )

        guard deviceID != kAudioObjectUnknown else {
            throw RelayError.noOutputDevice
        }

        let sampleRate = try readDouble(deviceID, selector: kAudioDevicePropertyNominalSampleRate)
        guard sampleRate.isFinite, sampleRate >= 1, sampleRate <= Double(Int32.max) else {
            throw CoreAudioFailure(
                operation: "Reading the output sample rate",
                status: kAudioDeviceUnsupportedFormatError
            )
        }

        return OutputDeviceInfo(
            id: deviceID,
            uid: try readString(deviceID, selector: kAudioDevicePropertyDeviceUID),
            name: try readString(deviceID, selector: kAudioObjectPropertyName),
            sampleRate: sampleRate
        )
    }

    static func spotifyTapDescription(
        processes: [AudioProcessInfo],
        outputDevice: OutputDeviceInfo
    ) -> CATapDescription {
        // Use the selected device stream's format and clock. Enabling mixdown
        // selects a different capture path even when deviceUID is also set;
        // that path produced recurring dropouts and warble on Bluetooth output.
        let description = CATapDescription(
            processes: processes.map(\.id),
            deviceUID: outputDevice.uid,
            stream: 0
        )
        description.name = "Spatial Relay — Spotify"
        description.isPrivate = true
        description.muteBehavior = .mutedWhenTapped
        return description
    }

    func createSpotifyTap(processes: [AudioProcessInfo], outputDevice: OutputDeviceInfo) throws -> AudioObjectID {
        let description = Self.spotifyTapDescription(processes: processes, outputDevice: outputDevice)
        var tapID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioFailure.check(
            AudioHardwareCreateProcessTap(description, &tapID),
            operation: "Creating the Spotify process tap"
        )
        return tapID
    }

    func tapUID(_ tapID: AudioObjectID) throws -> String {
        try readString(tapID, selector: kAudioTapPropertyUID)
    }

    func tapFormat(_ tapID: AudioObjectID) throws -> AudioStreamBasicDescription {
        var address = propertyAddress(kAudioTapPropertyFormat)
        var format = AudioStreamBasicDescription()
        var byteCount = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &byteCount, &format),
            operation: "Reading the process tap format"
        )
        return format
    }

    func createAggregateDevice(tapUID: String) throws -> AudioObjectID {
        let aggregateUID = "com.shevlfs.SpatialRelay.aggregate.\(UUID().uuidString)"
        let tapEntry: [String: Any] = [
            kAudioSubTapUIDKey: tapUID,
            kAudioSubTapDriftCompensationKey: true
        ]
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Spatial Relay Capture",
            kAudioAggregateDeviceUIDKey: aggregateUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceTapListKey: [tapEntry]
        ]

        var aggregateID = AudioObjectID(kAudioObjectUnknown)
        try CoreAudioFailure.check(
            AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregateID),
            operation: "Creating the private tap device"
        )
        return aggregateID
    }

    @discardableResult
    func destroyAggregateDevice(_ deviceID: AudioObjectID) -> OSStatus {
        guard deviceID != kAudioObjectUnknown else { return noErr }
        return AudioHardwareDestroyAggregateDevice(deviceID)
    }

    @discardableResult
    func destroyTap(_ tapID: AudioObjectID) -> OSStatus {
        guard tapID != kAudioObjectUnknown else { return noErr }
        return AudioHardwareDestroyProcessTap(tapID)
    }

    /// Restores direct process audio even if a lower-level callback cannot be
    /// destroyed immediately. This is the teardown path's last-resort safety net.
    @discardableResult
    func unmuteTap(_ tapID: AudioObjectID) -> OSStatus {
        guard tapID != kAudioObjectUnknown else { return noErr }

        var address = propertyAddress(kAudioTapPropertyDescription)
        var description: CATapDescription?
        var byteCount = UInt32(MemoryLayout<CATapDescription?>.size)
        let readStatus = withUnsafeMutablePointer(to: &description) { pointer in
            AudioObjectGetPropertyData(tapID, &address, 0, nil, &byteCount, pointer)
        }
        guard readStatus == noErr else { return readStatus }
        guard let description else { return kAudioHardwareUnspecifiedError }

        description.muteBehavior = .unmuted
        var updatedDescription: CATapDescription? = description
        byteCount = UInt32(MemoryLayout<CATapDescription?>.size)
        return withUnsafePointer(to: &updatedDescription) { pointer in
            AudioObjectSetPropertyData(tapID, &address, 0, nil, byteCount, pointer)
        }
    }

    private func readPID(_ objectID: AudioObjectID) throws -> pid_t {
        var address = propertyAddress(kAudioProcessPropertyPID)
        var value: pid_t = 0
        var byteCount = UInt32(MemoryLayout<pid_t>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
            operation: "Reading an audio process identifier"
        )
        return value
    }

    private func readBool(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Bool {
        var address = propertyAddress(selector)
        var value: UInt32 = 0
        var byteCount = UInt32(MemoryLayout<UInt32>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
            operation: "Reading an audio property"
        )
        return value != 0
    }

    private func readDouble(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> Double {
        var address = propertyAddress(selector)
        var value: Float64 = 0
        var byteCount = UInt32(MemoryLayout<Float64>.size)
        try CoreAudioFailure.check(
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, &value),
            operation: "Reading an audio property"
        )
        return value
    }

    private func readString(_ objectID: AudioObjectID, selector: AudioObjectPropertySelector) throws -> String {
        var address = propertyAddress(selector)
        // These HAL string properties return a retained CFString. Express that
        // ownership explicitly when writing through the untyped C API.
        var value: Unmanaged<CFString>?
        var byteCount = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(objectID, &address, 0, nil, &byteCount, pointer)
        }
        let string = value?.takeRetainedValue()
        try CoreAudioFailure.check(status, operation: "Reading an audio property")
        guard let string else {
            throw CoreAudioFailure(operation: "Reading an audio property", status: kAudioHardwareUnspecifiedError)
        }
        return string as String
    }
}
