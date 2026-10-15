import Foundation
import CoreAudio
import AudioToolbox
@preconcurrency import AVFoundation

/// Records what the Mac plays (the other side of a call) through a Core Audio process tap (macOS 14.2+,
/// permission „Nur Systemaudio-Aufnahme“). Unlike a whole-system loopback it leaves out Rekord itself and
/// known media players, so background music does not end up in the meeting; the exclusion list follows
/// players that start during the call. Calls from the iPhone via Continuity play through system services
/// and are therefore included. Written as AAC to an `.m4a` file.
@available(macOS 14.2, *)
final class SystemAudioTap: @unchecked Sendable {
    static let excludedBundleIDs: Set<String> = [
        "com.spotify.client","com.apple.Music","com.apple.podcasts","com.apple.TV","com.apple.QuickTimePlayerX",
        "org.videolan.vlc","com.colliderli.iina","com.tidal.desktop","com.deezer.deezer-desktop","com.amazon.music",
        "com.apple.iBooksX","com.apple.Audible","com.soundcloud.desktop",
    ]
    private let queue = DispatchQueue(label: "dev.sapunov.rekord.systemaudio",qos: .userInitiated)
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private var description: CATapDescription?
    private var file: AVAudioFile?
    private var format: AVAudioFormat?
    private var processListener: AudioObjectPropertyListenerBlock?
    private let lock = NSLock()
    private var firstHostSeconds: Double?
    private var peak: Float = 0
    private var writeError: Error?
    /// Host-clock seconds of the first written buffer (same clock as AVCapture timestamps).
    var startSeconds: Double? { lock.withLock { firstHostSeconds } }
    /// Highest sample magnitude so far; 0 after a while means the permission is missing or nothing played.
    var maximumLevel: Float { lock.withLock { peak } }
    var currentLevel: Float = 0

    func start(url: URL) throws {
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: Self.excludedProcesses())
        description.uuid = UUID(); description.name = "Rekord Meeting"
        description.isPrivate = true; description.muteBehavior = .unmuted
        self.description = description
        try check(AudioHardwareCreateProcessTap(description,&tapID),"Systemton-Abgriff konnte nicht erstellt werden")
        do {
            var asbd = AudioStreamBasicDescription()
            try read(tapID,kAudioTapPropertyFormat,&asbd)
            guard let format = AVAudioFormat(streamDescription: &asbd) else { throw RecorderError.message("Format des Systemtons wird nicht unterstützt.") }
            self.format = format
            let output = try Self.defaultOutputUID()
            let aggregate: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Rekord Meeting",kAudioAggregateDeviceUIDKey: UUID().uuidString,
                kAudioAggregateDeviceMainSubDeviceKey: output,kAudioAggregateDeviceIsPrivateKey: true,kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceTapAutoStartKey: true,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapDriftCompensationKey: true,kAudioSubTapUIDKey: description.uuid.uuidString]],
            ]
            try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary,&aggregateID),"Aufnahmegerät für den Systemton konnte nicht erstellt werden")
            file = try AVAudioFile(forWriting: url,settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,AVSampleRateKey: format.sampleRate,AVNumberOfChannelsKey: format.channelCount,AVEncoderBitRateKey: 128000],
                                   commonFormat: .pcmFormatFloat32,interleaved: format.isInterleaved)
            try check(AudioDeviceCreateIOProcIDWithBlock(&procID,aggregateID,queue) { [weak self] _,input,inputTime,_,_ in
                self?.receive(input,time: inputTime.pointee)
            },"Systemton kann nicht gelesen werden")
            try check(AudioDeviceStart(aggregateID,procID),"Systemton-Aufnahme startet nicht")
            watchProcesses()
        } catch { stop(); throw error }
    }

    private func receive(_ input: UnsafePointer<AudioBufferList>,time: AudioTimeStamp) {
        guard let format,let file,let buffer = AVAudioPCMBuffer(pcmFormat: format,bufferListNoCopy: input,deallocator: nil), buffer.frameLength > 0 else { return }
        var level: Float = 0
        if let channels = buffer.floatChannelData {
            let stride = buffer.stride
            for channel in 0..<(format.isInterleaved ? 1 : Int(format.channelCount)) {
                let samples = channels[channel]
                for index in Swift.stride(from: 0,to: Int(buffer.frameLength)*stride,by: stride) { level = max(level,abs(samples[index])) }
            }
        }
        currentLevel = level
        lock.withLock {
            if firstHostSeconds == nil, time.mFlags.contains(.hostTimeValid) { firstHostSeconds = Double(AudioConvertHostTimeToNanos(time.mHostTime))/1e9 }
            peak = max(peak,level)
        }
        do { try file.write(from: buffer) } catch { lock.withLock { if writeError == nil { writeError = error } } }
    }

    /// Stops capture, removes tap and aggregate device and closes the file (finalizing the AAC stream).
    func stop() {
        if let processListener {
            var address = Self.address(kAudioHardwarePropertyProcessObjectList)
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),&address,queue,processListener)
            self.processListener = nil
        }
        if aggregateID != kAudioObjectUnknown {
            if let procID { AudioDeviceStop(aggregateID,procID); AudioDeviceDestroyIOProcID(aggregateID,procID) }
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        queue.sync { file = nil }
        procID = nil; aggregateID = AudioObjectID(kAudioObjectUnknown); tapID = AudioObjectID(kAudioObjectUnknown)
    }
    var failure: Error? { lock.withLock { writeError } }

    /// Keeps the exclusion list current when a media player starts during the call.
    private func watchProcesses() {
        var address = Self.address(kAudioHardwarePropertyProcessObjectList)
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _,_ in
            guard let self,let description = self.description,self.tapID != kAudioObjectUnknown else { return }
            let excluded = Self.excludedProcesses()
            guard Set(description.processes) != Set(excluded) else { return }
            description.processes = excluded
            var reference = Unmanaged.passUnretained(description).toOpaque()
            var tapAddress = Self.address(kAudioTapPropertyDescription)
            _ = AudioObjectSetPropertyData(self.tapID,&tapAddress,0,nil,UInt32(MemoryLayout<UnsafeMutableRawPointer>.size),&reference)
        }
        if AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject),&address,queue,listener) == noErr { processListener = listener }
    }

    static func excludedProcesses() -> [AudioObjectID] {
        let own = ProcessInfo.processInfo.processIdentifier
        return processObjects().filter { object in
            if let pid: pid_t = try? value(object,kAudioProcessPropertyPID), pid == own { return true }
            guard let bundle = bundleID(object) else { return false }
            return excludedBundleIDs.contains(bundle)
        }
    }
    static func processObjects() -> [AudioObjectID] {
        var address = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size) == noErr, size > 0 else { return [] }
        var objects = [AudioObjectID](repeating: 0,count: Int(size)/MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),&address,0,nil,&size,&objects) == noErr else { return [] }
        return objects
    }
    static func bundleID(_ object: AudioObjectID) -> String? {
        var address = address(kAudioProcessPropertyBundleID)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var value: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(object,&address,0,nil,&size,&value) == noErr, let value else { return nil }
        let bundle = value.takeRetainedValue() as String
        return bundle.isEmpty ? nil : bundle
    }
    static func defaultOutputUID() throws -> String {
        let device: AudioObjectID = try value(AudioObjectID(kAudioObjectSystemObject),kAudioHardwarePropertyDefaultSystemOutputDevice)
        var address = address(kAudioDevicePropertyDeviceUID)
        var size = UInt32(MemoryLayout<CFString?>.size)
        var uid: Unmanaged<CFString>?
        guard AudioObjectGetPropertyData(device,&address,0,nil,&size,&uid) == noErr, let uid else { throw RecorderError.message("Kein Audio-Ausgabegerät gefunden.") }
        return uid.takeRetainedValue() as String
    }
    static func address(_ selector: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,mScope: kAudioObjectPropertyScopeGlobal,mElement: kAudioObjectPropertyElementMain)
    }
    static func value<T>(_ object: AudioObjectID,_ selector: AudioObjectPropertySelector) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1); defer { pointer.deallocate() }
        let status = AudioObjectGetPropertyData(object,&address,0,nil,&size,pointer)
        guard status == noErr else { throw RecorderError.message("Core Audio Fehler \(status)") }
        return pointer.pointee
    }
    private func read<T>(_ object: AudioObjectID,_ selector: AudioObjectPropertySelector,_ value: inout T) throws {
        var address = Self.address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(object,&address,0,nil,&size,pointer)
        }
        try check(status,"Core Audio liefert keine Eigenschaft \(selector)")
    }
    private func check(_ status: OSStatus,_ message: String) throws {
        guard status == noErr else { throw RecorderError.message("\(message) (Core Audio \(status)).") }
    }
}
