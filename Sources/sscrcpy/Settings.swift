import Foundation
import Observation

/// scrcpy options chosen in Settings. Every change is written to UserDefaults.
@Observable final class Settings {
    /// Longest side of the mirrored video in pixels; 0 keeps the device resolution.
    var maxSize: Int { didSet { defaults.set(maxSize, forKey: Key.maxSize) } }
    var videoBitRateMbps: Int { didSet { defaults.set(videoBitRateMbps, forKey: Key.videoBitRate) } }
    /// 0 lets the device decide.
    var maxFps: Int { didSet { defaults.set(maxFps, forKey: Key.maxFps) } }
    var audio: Bool { didSet { defaults.set(audio, forKey: Key.audio) } }
    var stayAwake: Bool { didSet { defaults.set(stayAwake, forKey: Key.stayAwake) } }
    var turnScreenOff: Bool { didSet { defaults.set(turnScreenOff, forKey: Key.turnScreenOff) } }
    var showTouches: Bool { didSet { defaults.set(showTouches, forKey: Key.showTouches) } }
    var alwaysOnTop: Bool { didSet { defaults.set(alwaysOnTop, forKey: Key.alwaysOnTop) } }
    /// Sends keys as a hardware keyboard, so the phone's own keyboard handles languages
    /// such as Korean; without it the client ignores keys.
    var physicalKeyboard: Bool { didSet { defaults.set(physicalKeyboard, forKey: Key.physicalKeyboard) } }

    private let defaults: UserDefaults

    private enum Key {
        static let maxSize = "maxSize"
        static let videoBitRate = "videoBitRateMbps"
        static let maxFps = "maxFps"
        static let audio = "audio"
        static let stayAwake = "stayAwake"
        static let turnScreenOff = "turnScreenOff"
        static let showTouches = "showTouches"
        static let alwaysOnTop = "alwaysOnTop"
        static let physicalKeyboard = "physicalKeyboard"
    }

    init(defaults: UserDefaults = .standard) {
        // scrcpy's own defaults, so an untouched Settings screen behaves like plain `scrcpy`, and
        // the keyboard, which the client ignores otherwise; unregistered keys read as 0 or off,
        // which matches scrcpy for everything else.
        defaults.register(defaults: [Key.videoBitRate: 8, Key.audio: true, Key.physicalKeyboard: true])
        self.defaults = defaults
        maxSize = defaults.integer(forKey: Key.maxSize)
        videoBitRateMbps = defaults.integer(forKey: Key.videoBitRate)
        maxFps = defaults.integer(forKey: Key.maxFps)
        audio = defaults.bool(forKey: Key.audio)
        stayAwake = defaults.bool(forKey: Key.stayAwake)
        turnScreenOff = defaults.bool(forKey: Key.turnScreenOff)
        showTouches = defaults.bool(forKey: Key.showTouches)
        alwaysOnTop = defaults.bool(forKey: Key.alwaysOnTop)
        physicalKeyboard = defaults.bool(forKey: Key.physicalKeyboard)
    }

    /// scrcpy flags for the current settings, without the device selection.
    func scrcpyArguments() -> [String] {
        // Every mouse button reaches the phone as itself; scrcpy's default turns right-click
        // into BACK and middle-click into HOME.
        var args = ["--video-bit-rate=\(videoBitRateMbps)M", "--mouse-bind=++++:++++"]
        if maxSize > 0 { args.append("--max-size=\(maxSize)") }
        if maxFps > 0 { args.append("--max-fps=\(maxFps)") }
        if !audio { args.append("--no-audio") }
        if stayAwake { args.append("--stay-awake") }
        if turnScreenOff { args.append("--turn-screen-off") }
        if showTouches { args.append("--show-touches") }
        if alwaysOnTop { args.append("--always-on-top") }
        if physicalKeyboard { args.append("--keyboard=uhid") }
        return args
    }
}
