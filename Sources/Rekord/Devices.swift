@preconcurrency import AVFoundation

/// Camera and microphone choice shared by setup preview and recording. An empty ID follows the
/// macOS default, which can otherwise silently switch between built-in, virtual and iPhone cameras.
struct CaptureDeviceOption: Identifiable, Hashable {
    let id: String
    let name: String
}

enum CaptureDevices {
    static func cameras() -> [CaptureDeviceOption] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.builtInWideAngleCamera,.external,.continuityCamera],mediaType: .video,position: .unspecified)
            .devices.map { CaptureDeviceOption(id: $0.uniqueID,name: $0.localizedName) }
    }
    static func microphones() -> [CaptureDeviceOption] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone,.external],mediaType: .audio,position: .unspecified)
            .devices.map { CaptureDeviceOption(id: $0.uniqueID,name: $0.localizedName) }
    }
    static func camera(id: String) -> AVCaptureDevice? {
        (id.isEmpty ? nil : AVCaptureDevice(uniqueID: id)) ?? AVCaptureDevice.systemPreferredCamera ?? AVCaptureDevice.default(for: .video)
    }
    static func microphone(id: String) -> AVCaptureDevice? {
        (id.isEmpty ? nil : AVCaptureDevice(uniqueID: id)) ?? AVCaptureDevice.default(for: .audio)
    }
}
