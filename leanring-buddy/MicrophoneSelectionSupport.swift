import Foundation
import CoreAudio

struct AudioInputDevice: Hashable, Identifiable {
    var id: String { uid }
    let name: String
    let uid: String
    let deviceID: AudioDeviceID

    static func fetchAvailableDevices() -> [AudioInputDevice] {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        
        var dataSize: UInt32 = 0
        var status = AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize)
        guard status == noErr, dataSize > 0 else { return [] }
        
        let deviceCount = Int(dataSize / UInt32(MemoryLayout<AudioObjectID>.size))
        var deviceIDs = [AudioObjectID](repeating: 0, count: deviceCount)
        
        status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceIDs)
        guard status == noErr else { return [] }
        
        var devices: [AudioInputDevice] = []
        for deviceID in deviceIDs {
            // Check for input channels
            var streamAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyStreamConfiguration,
                mScope: kAudioDevicePropertyScopeInput,
                mElement: kAudioObjectPropertyElementMain
            )
            var streamDataSize: UInt32 = 0
            status = AudioObjectGetPropertyDataSize(deviceID, &streamAddress, 0, nil, &streamDataSize)
            guard status == noErr, streamDataSize > 0 else { continue }
            
            let bufferList = UnsafeMutablePointer<UInt8>.allocate(capacity: Int(streamDataSize))
            defer { bufferList.deallocate() }
            
            status = AudioObjectGetPropertyData(deviceID, &streamAddress, 0, nil, &streamDataSize, bufferList)
            guard status == noErr else { continue }
            
            let audioBufferList = bufferList.withMemoryRebound(to: AudioBufferList.self, capacity: 1) { $0.pointee }
            let bufferCount = Int(audioBufferList.mNumberBuffers)
            
            var totalChannels: UInt32 = 0
            let buffers = UnsafeBufferPointer<AudioBuffer>(start: withUnsafePointer(to: audioBufferList.mBuffers) {
                $0.withMemoryRebound(to: AudioBuffer.self, capacity: bufferCount) { $0 }
            }, count: bufferCount)
            
            for buffer in buffers {
                totalChannels += buffer.mNumberChannels
            }
            guard totalChannels > 0 else { continue }
            
            // Get Name
            var nameAddress = AudioObjectPropertyAddress(
                mSelector: kAudioObjectPropertyName,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var name: CFString = "" as CFString
            var nameSize = UInt32(MemoryLayout<CFString>.size)
            status = withUnsafeMutablePointer(to: &name) {
                AudioObjectGetPropertyData(deviceID, &nameAddress, 0, nil, &nameSize, $0)
            }
            let deviceName = (status == noErr) ? (name as String) : "Unknown Device"
            
            // Get UID
            var uidAddress = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain
            )
            var uid: CFString = "" as CFString
            var uidSize = UInt32(MemoryLayout<CFString>.size)
            status = withUnsafeMutablePointer(to: &uid) {
                AudioObjectGetPropertyData(deviceID, &uidAddress, 0, nil, &uidSize, $0)
            }
            let deviceUID = (status == noErr) ? (uid as String) : ""
            guard !deviceUID.isEmpty else { continue }
            
            devices.append(AudioInputDevice(name: deviceName, uid: deviceUID, deviceID: deviceID))
        }
        return devices
    }
    
    static func deviceID(forUID uid: String) -> AudioDeviceID? {
        guard !uid.isEmpty else { return nil }
        return fetchAvailableDevices().first { $0.uid == uid }?.deviceID
    }
    static func defaultInputDeviceID() -> AudioDeviceID? {
        var propertyAddress = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var deviceID: AudioDeviceID = kAudioObjectUnknown
        var dataSize = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &propertyAddress, 0, nil, &dataSize, &deviceID)
        return (status == noErr && deviceID != kAudioObjectUnknown) ? deviceID : nil
    }
}
