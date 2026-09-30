import AppKit

nonisolated struct Options {
    var serial = ""
    var windowTitle: String?
    var videoBitRate = 8_000_000
    var maxSize = 0
    var maxFps = 0
    var audio = true
    /// Keys reach the device through a UHID keyboard; without it they are ignored.
    var keyboard = false
    var stayAwake = false
    var turnScreenOff = false
    var showTouches = false
    var alwaysOnTop = false

    /// Reads the flags the app passes, which are all there are: a value always follows "=".
    init(_ arguments: some Sequence<String>) throws {
        for argument in arguments {
            // Split on the byte: as Characters, "=" merges with a combining mark after it.
            let parts = argument.utf8.split(separator: UInt8(ascii: "="), maxSplits: 1, omittingEmptySubsequences: false)
            let value = parts.count == 2 ? String(decoding: parts[1], as: UTF8.self) : nil
            switch (String(decoding: parts[0], as: UTF8.self), value) {
            case ("--serial", let value?): serial = value
            case ("--window-title", let value?): windowTitle = value
            case ("--video-bit-rate", let value?): videoBitRate = try positive(value, argument, suffixes: true)
            case ("--max-size", let value?): maxSize = try positive(value, argument)
            case ("--max-fps", let value?): maxFps = try positive(value, argument)
            case ("--keyboard", "uhid"): keyboard = true
            case ("--no-audio", nil): audio = false
            case ("--stay-awake", nil): stayAwake = true
            case ("--turn-screen-off", nil): turnScreenOff = true
            case ("--show-touches", nil): showTouches = true
            case ("--always-on-top", nil): alwaysOnTop = true
            default: throw Failure("invalid option: \(argument)")
            }
        }
        guard !serial.isEmpty else { throw Failure("--serial is required") }
    }
}

/// Parses a positive integer; with `suffixes`, "8M" and "800k" as in scrcpy.
nonisolated func positive(_ value: String, _ argument: String, suffixes: Bool = false) throws -> Int {
    var digits = Substring(value)
    var multiplier = 1
    if suffixes, let last = digits.last, let m = ["k": 1_000, "K": 1_000, "m": 1_000_000, "M": 1_000_000][last] {
        multiplier = m
        digits = digits.dropLast()
    }
    guard let n = Int(digits), n > 0, n <= Int(Int32.max) / multiplier else {
        throw Failure("invalid value: \(argument)")
    }
    return n * multiplier
}

/// Ends the program, and first its adb processes, which would outlive it: the server's shell
/// and, while connecting, the adb command running. They are the only processes it starts, two
/// at most. The sockets close at exit, which ends the server; its cleanup process then restores
/// the device.
func quit(_ status: Int32) -> Never {
    var children = [pid_t](repeating: 0, count: 8)
    let count = proc_listchildpids(getpid(), &children, Int32(children.count * MemoryLayout<pid_t>.size))
    for child in children.prefix(Int(max(count, 0))) {
        kill(child, SIGTERM)
    }
    exit(status)
}

func fail(_ error: Error) -> Never {
    FileHandle.standardError.write(Data("ERROR: \(error.localizedDescription)\n".utf8))
    quit(1)
}

let options: Options
do { options = try Options(CommandLine.arguments.dropFirst()) } catch { fail(error) }
guard let adbPath = ProcessInfo.processInfo.environment["ADB"], adbPath.hasPrefix("/") else {
    fail(Failure("ADB must be set to the absolute path of adb"))
}
let adb = ADB(executable: URL(fileURLWithPath: adbPath), serial: options.serial)

// The app stops mirroring with SIGTERM. The source watches before the signal is ignored, so
// that none is lost.
let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
terminate.setEventHandler { quit(0) }
terminate.resume()
signal(SIGTERM, SIG_IGN)
// Quit, from the menu, the Dock or at logout, ends here too, even while connecting.
NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { _ in
    MainActor.assumeIsolated { quit(0) }
}

// The app is in the Dock while it connects, as scrcpy is.
NSApplication.shared.setActivationPolicy(.regular)
// The menus SDL gives scrcpy, so that Command's keys act on the Mac as in every Mac app, and
// an Edit menu whose Cut, Copy and Paste go through the device's clipboard.
do {
    let name = ProcessInfo.processInfo.processName
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "Hide \(name)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        .keyEquivalentModifierMask = [.option, .command]
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit \(name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    let editMenu = NSMenu(title: "Edit")
    editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
    editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
    editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    let bar = NSMenu()
    for menu in [appMenu, editMenu, windowMenu] {
        bar.addItem(withTitle: menu.title, action: nil, keyEquivalent: "").submenu = menu
    }
    NSApp.mainMenu = bar
    NSApp.windowsMenu = windowMenu
}
// Connecting takes seconds: it runs on its own thread, so that SIGTERM ends it.
var window: MirrorWindow?
Thread { [adb, options] in
    do {
        let server = try Server.start(adb, options)
        let videoSize = try receiveVideoStart(server.video)
        DispatchQueue.main.async {
            window = MirrorWindow(server: server, options: options, videoSize: NSSize(width: videoSize.width, height: videoSize.height))
            window?.start()
            NSApp.activate()
        }
    } catch {
        DispatchQueue.main.async { fail(error) }
    }
}.start()
NSApplication.shared.run()
