import Foundation

/// User preferences persisted in `UserDefaults`.
struct Settings {
    private let defaults = UserDefaults.standard

    static let qualities: [(width: Int, label: String)] = [(1280, "720p"), (1920, "1080p"), (2560, "1440p")]
    static let frameRates = [30, 60]

    var width: Int {
        get { defaults.object(forKey: "width") as? Int ?? 1920 }
        nonmutating set { defaults.set(newValue, forKey: "width") }
    }

    var fps: Int {
        get { defaults.object(forKey: "fps") as? Int ?? 60 }
        nonmutating set { defaults.set(newValue, forKey: "fps") }
    }

    var audio: Bool {
        get { defaults.object(forKey: "audio") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "audio") }
    }

    /// Play sound only on the TV and let the Mac's volume keys control it.
    var audioOnTVOnly: Bool {
        get { defaults.object(forKey: "muteMac") as? Bool ?? true }
        nonmutating set { defaults.set(newValue, forKey: "muteMac") }
    }

    var display: Int {
        get { defaults.object(forKey: "display") as? Int ?? 0 }
        nonmutating set { defaults.set(newValue, forKey: "display") }
    }

    /// Bitrate that keeps text sharp at the chosen resolution and frame rate.
    var bitrate: Int {
        let megabits: Double = width <= 1280 ? 6 : (width <= 1920 ? 12 : 20)
        return Int(megabits * (fps <= 30 ? 0.6 : 1.0) * 1_000_000)
    }
}
