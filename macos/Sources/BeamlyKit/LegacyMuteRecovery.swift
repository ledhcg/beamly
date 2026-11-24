import CoreAudio
import Foundation

/// Versions before the process-tap implementation silenced the Mac by muting the output device and
/// stored what they changed so it could be undone after a crash. Call `run()` at launch to restore any
/// device an old version left muted.
public enum LegacyMuteRecovery {
    // Suite and key used by those versions; do not rename.
    private static let defaults = UserDefaults(suiteName: "com.mac2tv.shared")
    private static let key = "mutedOutputDevices"

    public static func run() {
        guard let stored = defaults?.dictionary(forKey: key), !stored.isEmpty else { return }
        for (uid, value) in stored {
            guard let device = AudioDevices.device(forUID: uid), let entry = value as? [String: Any] else { continue }
            if entry["method"] as? String == "mute" {
                var address = AudioDevices.address(kAudioDevicePropertyMute, kAudioDevicePropertyScopeOutput)
                var unmuted: UInt32 = 0
                AudioObjectSetPropertyData(device, &address, 0, nil, UInt32(MemoryLayout<UInt32>.size), &unmuted)
            } else if let volume = (entry["volume"] as? NSNumber)?.floatValue {
                _ = AudioDevices.setFloat(
                    device, AudioDevices.address(kAudioDevicePropertyVolumeScalar, kAudioDevicePropertyScopeOutput),
                    volume)
            }
        }
        defaults?.removeObject(forKey: key)
    }
}
