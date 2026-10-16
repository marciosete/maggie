import CoreAudio
import Foundation
import OSLog

/// The Mac's audio devices, for choosing which microphone and speaker the voice uses.
/// A device is remembered by its UID, which outlives reconnections; nothing chosen means
/// the system's default.
enum VoiceDevices {
    struct Device: Identifiable, Equatable {
        let id: AudioDeviceID
        let uid: String
        let name: String
        let hasInput: Bool
        let hasOutput: Bool
    }

    private static let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier!,
        category: "VoiceDevices"
    )

    /// Every device, inputs and outputs, in the system's order.
    static func all() -> [Device] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size) == noErr else {
            return []
        }
        var ids = [AudioDeviceID](repeating: 0, count: Int(size) / MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &ids) == noErr else {
            return []
        }
        return ids.compactMap { id in
            guard let uid = string(of: id, selector: kAudioDevicePropertyDeviceUID),
                  let name = string(of: id, selector: kAudioObjectPropertyName) else { return nil }
            // Aggregates the voice itself makes aren't offered back.
            guard !uid.hasPrefix(aggregateUID) else { return nil }
            let input = channels(of: id, scope: kAudioObjectPropertyScopeInput) > 0
            let output = channels(of: id, scope: kAudioObjectPropertyScopeOutput) > 0
            guard input || output else { return nil }
            return Device(id: id, uid: uid, name: name, hasInput: input, hasOutput: output)
        }
    }

    static func inputs() -> [Device] { all().filter(\.hasInput) }
    static func outputs() -> [Device] { all().filter(\.hasOutput) }

    /// The device with `uid`, if it is connected.
    static func device(uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return all().first { $0.uid == uid }?.id
    }

    /// The system's default input or output device.
    static func defaultDevice(input: Bool) -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(
            mSelector: input ? kAudioHardwarePropertyDefaultInputDevice : kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var id: AudioDeviceID = 0
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &id) == noErr,
              id != 0 else { return nil }
        return id
    }

    // MARK: Aggregates

    private static let aggregateUID = "com.marciosete.maggie.voice."

    /// One device for the engine to use: `input` and `output` themselves when they are
    /// the same, or a private aggregate of the two, which the caller destroys after.
    static func combined(input: AudioDeviceID, output: AudioDeviceID) -> (device: AudioDeviceID, aggregate: AudioDeviceID?) {
        guard input != output else { return (input, nil) }
        guard let inputUID = string(of: input, selector: kAudioDevicePropertyDeviceUID),
              let outputUID = string(of: output, selector: kAudioDevicePropertyDeviceUID) else { return (output, nil) }
        let description: [String: Any] = [
            kAudioAggregateDeviceNameKey: "Maggie Voice",
            kAudioAggregateDeviceUIDKey: aggregateUID + UUID().uuidString,
            kAudioAggregateDeviceIsPrivateKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceSubDeviceListKey: [
                [kAudioSubDeviceUIDKey: outputUID],
                [kAudioSubDeviceUIDKey: inputUID, kAudioSubDeviceDriftCompensationKey: 1],
            ],
        ]
        var aggregate: AudioDeviceID = 0
        let status = AudioHardwareCreateAggregateDevice(description as CFDictionary, &aggregate)
        guard status == noErr, aggregate != 0 else {
            logger.warning("couldn't make an aggregate device: \(status)")
            return (output, nil)
        }
        return (aggregate, aggregate)
    }

    static func destroy(aggregate: AudioDeviceID) {
        AudioHardwareDestroyAggregateDevice(aggregate)
    }

    // MARK: Properties

    private static func string(of id: AudioDeviceID, selector: AudioObjectPropertySelector) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(id, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    private static func channels(of id: AudioDeviceID, scope: AudioObjectPropertyScope) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration, mScope: scope, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &address, 0, nil, &size) == noErr, size > 0 else { return 0 }
        let list = UnsafeMutablePointer<AudioBufferList>.allocate(capacity: Int(size))
        defer { list.deallocate() }
        guard AudioObjectGetPropertyData(id, &address, 0, nil, &size, list) == noErr else { return 0 }
        return UnsafeMutableAudioBufferListPointer(list).reduce(0) { $0 + Int($1.mNumberChannels) }
    }
}
