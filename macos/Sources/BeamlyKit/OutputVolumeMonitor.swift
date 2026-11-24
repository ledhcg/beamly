import AudioToolbox
import CoreAudio
import Foundation

/// Watches the default output device's volume and mute state (following default-device changes)
/// so they can be mirrored to the TV.
/// Callback: (slider position 0...1, linear gain 0...1, muted). Delivered on an internal queue.
final class OutputVolumeMonitor {
    var onChange: ((Float, Float, Bool) -> Void)?

    private let q = DispatchQueue(label: "app.beamly.volume")
    private var device = AudioDeviceID(0)
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var defaultListener: AudioObjectPropertyListenerBlock?
    private var defaultAddress = AudioDevices.address(kAudioHardwarePropertyDefaultOutputDevice)
    private var last: (Float, Float, Bool)?

    /// Properties that change when the volume keys are pressed (main element or per channel, depending on the device).
    private static let watched: [AudioObjectPropertyAddress] = {
        let out = kAudioDevicePropertyScopeOutput
        var list = [
            AudioDevices.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, out),
            AudioDevices.address(kAudioDevicePropertyMute, out),
        ]
        for el: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1, 2] {
            list.append(AudioDevices.address(kAudioDevicePropertyVolumeScalar, out, el))
        }
        return list
    }()

    func start() {
        q.async { [self] in
            let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.attachToDefault() }
            if AudioObjectAddPropertyListenerBlock(
                AudioObjectID(kAudioObjectSystemObject), &self.defaultAddress, self.q, block) == noErr
            {
                self.defaultListener = block
            }
            self.attachToDefault()
        }
    }

    func stop() {
        q.sync {
            detach()
            if let block = defaultListener {
                AudioObjectRemovePropertyListenerBlock(
                    AudioObjectID(kAudioObjectSystemObject), &defaultAddress, q, block)
                defaultListener = nil
            }
            onChange = nil
        }
    }

    private func attachToDefault() {
        guard let dev = AudioDevices.defaultOutput() else { return }
        if dev != device {
            detach()
            device = dev
            for var addr in Self.watched {
                guard AudioObjectHasProperty(dev, &addr) else { continue }
                let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in self?.report() }
                if AudioObjectAddPropertyListenerBlock(dev, &addr, q, block) == noErr {
                    deviceListeners.append((addr, block))
                }
            }
        }
        report()
    }

    private func detach() {
        for (addr, block) in deviceListeners {
            var a = addr
            AudioObjectRemovePropertyListenerBlock(device, &a, q, block)
        }
        deviceListeners.removeAll()
        device = 0
    }

    private func report() {
        let out = kAudioDevicePropertyScopeOutput
        let muted = (AudioDevices.getUInt32(device, AudioDevices.address(kAudioDevicePropertyMute, out)) ?? 0) != 0
        var element: AudioObjectPropertyElement = kAudioObjectPropertyElementMain
        var scalar = AudioDevices.getFloat(
            device, AudioDevices.address(kAudioHardwareServiceDeviceProperty_VirtualMainVolume, out))
        if scalar == nil {
            for el: AudioObjectPropertyElement in [kAudioObjectPropertyElementMain, 1] {
                if let v = AudioDevices.getFloat(
                    device, AudioDevices.address(kAudioDevicePropertyVolumeScalar, out, el))
                {
                    scalar = v; element = el; break
                }
            }
        }
        // Devices without volume control (e.g. HDMI) leave the TV at full source level.
        let volume = scalar ?? 1
        var gain: Float = 1
        if volume <= 0 {
            gain = 0
        } else if scalar != nil {
            // Use the device's own dB curve so the TV gets louder and quieter exactly like the Mac.
            var db = volume
            var addr = AudioDevices.address(kAudioDevicePropertyVolumeScalarToDecibels, out, element)
            var size = UInt32(MemoryLayout<Float32>.size)
            if !AudioObjectHasProperty(device, &addr) { addr.mElement = 1 }
            if AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &db) == noErr {
                gain = powf(10, db / 20)
            } else {
                gain = volume * volume
            }
        }
        if muted { gain = 0 }
        let value = (volume, min(max(gain, 0), 1), muted)
        if let last, last == value { return }
        last = value
        onChange?(value.0, value.1, value.2)
    }
}
