import CoreAudio
import Foundation

/// Enumeration helpers for CoreAudio output devices used by Settings and
/// `AudioReceiver`'s explicit device pinning.
enum AudioOutputDevices {
    struct Device: Identifiable, Hashable, Sendable {
        /// Stable CoreAudio UID — persisted in AppSettings.
        var id: String { uid }
        let uid: String
        let name: String
        let deviceID: AudioDeviceID
    }

    /// Empty UID means “follow the system default output”.
    static let systemDefaultUID = ""

    static func listOutputs() -> [Device] {
        deviceIDs().compactMap { deviceID in
            guard outputChannelCount(deviceID) > 0,
                  let uid = stringProperty(
                    deviceID, kAudioDevicePropertyDeviceUID),
                  let name = stringProperty(
                    deviceID, kAudioObjectPropertyName)
            else { return nil }
            return Device(uid: uid, name: name, deviceID: deviceID)
        }
        .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return listOutputs().first { $0.uid == uid }?.deviceID
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &size, &deviceID)
        return status == noErr ? deviceID : nil
    }

    // MARK: - Private

    private static func deviceIDs() -> [AudioDeviceID] {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return [] }

        let count = Int(dataSize) / MemoryLayout<AudioDeviceID>.size
        var devices = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address, 0, nil, &dataSize, &devices) == noErr
        else { return [] }
        return devices
    }

    private static func outputChannelCount(_ deviceID: AudioDeviceID) -> Int {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamConfiguration,
            mScope: kAudioDevicePropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(dataSize), alignment: MemoryLayout<AudioBufferList>.alignment)
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(
            deviceID, &address, 0, nil, &dataSize, raw) == noErr
        else { return 0 }

        let bufferList = raw.bindMemory(to: AudioBufferList.self, capacity: 1)
        let buffers = UnsafeMutableAudioBufferListPointer(bufferList)
        return buffers.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private static func stringProperty(
        _ deviceID: AudioDeviceID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var dataSize: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            deviceID, &address, 0, nil, &dataSize) == noErr,
              dataSize > 0
        else { return nil }

        var cfString: CFString?
        var size = UInt32(MemoryLayout<CFString?>.size)
        let status = withUnsafeMutablePointer(to: &cfString) { pointer in
            AudioObjectGetPropertyData(
                deviceID, &address, 0, nil, &size, pointer)
        }
        guard status == noErr, let cfString else { return nil }
        return cfString as String
    }
}
