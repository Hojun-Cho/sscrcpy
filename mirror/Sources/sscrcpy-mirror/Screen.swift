import Foundation

/// A line of the phone's log that ScreenPower reads (Server.startLog).
nonisolated enum PhoneEvent: Equatable {
    /// This session's marker: what the phone logs from here on follows, in its order.
    case logStarted
    /// Android began to go to sleep, whatever the cause (power_sleep_requested), or finished,
    /// the panel off (power_screen_state [0,…]).
    case sleepStarted, sleepFinished
    /// Android began to wake up (screen_toggled 1), or finished, the panel on
    /// (power_screen_state [1,…]).
    case wakeStarted, wakeFinished
    /// The server's SET_DISPLAY_POWER returned (Controller.java).
    case displayOff, displayOn
    /// The server turned the panel off by itself, after an injected WAKEUP.
    case forcedOff
}

/// Reads a line as `logcat -v tag` prints it: "I/power_screen_state: [1,0,0,0,328]",
/// "I/scrcpy  : Device display turned off". Nil for lines that say nothing about power; an error
/// for a line the filter should have kept out, or a power line in a form this client does not know.
nonisolated func phoneEvent(_ line: some StringProtocol) throws -> PhoneEvent? {
    if line.hasPrefix("--------- ") { return nil } // logcat's buffer headers
    guard line.dropFirst().first == "/", let colon = line.range(of: ": ") else {
        throw Failure("unexpected line in the phone's log: \(line)")
    }
    let tag = line[line.index(line.startIndex, offsetBy: 2) ..< colon.lowerBound].trimmingCharacters(in: .whitespaces)
    let message = line[colon.upperBound...]
    switch tag {
    case "power_sleep_requested": return .sleepStarted
    case "power_screen_state" where message.hasPrefix("[0,"): return .sleepFinished
    case "power_screen_state" where message.hasPrefix("[1,"): return .wakeFinished
    // Android writes 1 and 0 (power_screen_state [0,…] says 0 too); Samsung's lock screen also
    // writes the tag with other values when it unlocks (310405 on phone A).
    case "screen_toggled": return message == "1" ? .wakeStarted : nil
    case "scrcpy":
        switch message {
        case "Device display turned off": return .displayOff
        case "Device display turned on": return .displayOn
        case "Forcing display off": return .forcedOff
        default: return nil
        }
    case "sscrcpy": return nil // another session's marker
    default: throw Failure("unexpected line in the phone's log: \(line)")
    }
}

/// Reads the phone's log (Server.startLog) until it ends. The lines before `marker` are older
/// than the session and skipped. `onEvents` gets the events of each read together, so that what
/// the phone logged before anyone read is taken in at once.
nonisolated func receivePhoneEvents(_ fd: Int32, marker: String, onEvents: ([PhoneEvent]) -> Void) throws {
    var live = false
    var pending: [UInt8] = []
    var buffer = [UInt8](repeating: 0, count: 1 << 16)
    while true {
        let n = read(fd, &buffer, buffer.count)
        if n < 0, errno == EINTR { continue }
        if n < 0 { throw Failure.system("read") }
        if n == 0 { break }
        pending += buffer[..<n]
        var events: [PhoneEvent] = []
        while let end = pending.firstIndex(of: UInt8(ascii: "\n")) {
            var line = String(decoding: pending[..<end], as: UTF8.self)
            pending.removeSubrange(...end)
            if line.hasSuffix("\r") { line.removeLast() }
            if live {
                if let event = try phoneEvent(line) { events.append(event) }
            } else if line.hasPrefix("I/sscrcpy"), line.hasSuffix(": \(marker)") {
                live = true
                events.append(.logStarted)
            }
        }
        if !events.isEmpty { onEvents(events) }
    }
    if !live { throw Failure("the phone's log ended before it started") }
}

/// Keeps SET_DISPLAY_POWER from leaving the phone's panel black until a reboot.
///
/// On the Galaxy XCover5 one chip drives the panel and the touchscreen, and their two drivers
/// share its power rails. The display driver initializes the panel only when it powers the rails
/// up from zero. [10, 0] lets go of them with Android awake: they drop once the touch driver lets
/// go too, at the end of each wake, and the touch firmware is lost until Android sleeps and wakes.
/// If Android begins to sleep while they are down, the touch driver powers them for double-tap
/// wake without that initialization, and every later wake is black, until the rails drop and come
/// back through the display driver with Android awake.
///
/// So the client follows Android's sleeps and wakes and the server's display-power calls in the
/// phone's log, and at each step sends one thing and waits for the line that shows its outcome:
/// - it turns the panel off only while Android is awake and not changing;
/// - when Android begins to sleep with the panel off, it repairs the panel and ends as Turn
///   Screen On does: awake at the lock screen, the panel initialized, touch reloaded;
/// - it ends a session that left the panel off with the panel initialized and the phone asleep.
nonisolated struct ScreenPower {
    enum Input {
        /// The window is up: the client acts from now on, and turns the screen off with
        /// --turn-screen-off.
        case start(turnScreenOff: Bool)
        /// Lines of the phone's log, in its order.
        case log([PhoneEvent])
        /// The Phone menu.
        case turnOff, turnOn
        /// SIGTERM, the window's close button, Quit.
        case end
        /// `deadline` has passed.
        case tick
    }

    enum Action: Equatable {
        case send([ControlMessage])
        case quit
        case fail(String)
    }

    /// From the log showing the panel off to [10, 1], for what the log cannot show. The rails
    /// must be at zero for a while before the display driver powers them up: the touch driver
    /// lets go of them 0.15 s after the panel comes on at the end of a wake, and its failed
    /// firmware reload after the drop ends about 1.3 s later; the one verified repair had them
    /// down 1.2–1.5 s. The whole repair, from WAKEUP to [10, 1]'s line, must also fit before
    /// the lock screen puts the phone back to sleep, 5 s after a wake on phone B.
    static let margin = 3.0
    /// For each line the client waits for; the longest adb stall seen was 14 s.
    static let answerTime = 15.0

    private enum Step { case off, on, wake, sleep, quit }
    private enum Wait: Equatable {
        /// The line that shows the outcome of what was sent, or the log's marker.
        case line(PhoneEvent)
        /// Android to finish going to sleep or waking up.
        case settle
        /// `margin` after the panel went off.
        case margin
    }
    private enum Mode { case idle, repair, end }

    // What the log shows.
    private var live = false
    /// As of the last change Android finished. The server wakes the phone before it reads the
    /// first message (power_on), so a session starts awake.
    private var awake = true
    /// Changes started and not finished. A sleep's start is written at once and can come before
    /// the end of the change it cuts short.
    private var sleeps = 0, wakes = 0
    /// The server's last display-power call turned the panel off. Until [10, 1] it also turns the
    /// panel off 200 ms after an injected WAKEUP (keepDisplayPowerOff, Controller.java).
    private var panelOff = false
    private var offAt = -Double.infinity
    /// The last [10, 0] reached the panel with Android awake and not changing, from the message
    /// to its line: the rails are down once the touch driver lets go.
    private var cut = false
    /// The panel may be powered without its initialization.
    private var black = false
    /// The touch firmware may be gone.
    private var touchDead = false

    // What the client does.
    private var mode = Mode.idle
    private var started = false
    private var wantOff = false
    /// A repair or Turn Screen On ends with the phone awake.
    private var wantAwake = false
    /// Android changed state since the last display-power message was sent; `slept`: it began
    /// or finished a sleep.
    private var changed = false, slept = false
    private var wait: Wait?
    private(set) var deadline: Double?

    private var settled: Bool { sleeps == 0 && wakes == 0 }
    /// The Phone menu, once nothing else is under way. Turn Screen On works from any state.
    var canTurnOn: Bool { started && live && mode == .idle && wait == nil }
    var canTurnOff: Bool { canTurnOn && awake && settled }

    mutating func handle(_ input: Input, at now: Double) -> Action? {
        switch input {
        case .start(let turnScreenOff):
            started = true
            wantOff = turnScreenOff
            // Mirroring alone does not need the log: the Phone menu waits for it instead.
            if turnScreenOff && !live { waitFor(.line(.logStarted), until: now + Self.answerTime) }
        case .log(let events):
            for event in events { observe(event, at: now) }
        case .turnOff:
            if canTurnOff { wantOff = true }
        case .turnOn:
            guard canTurnOn else { break }
            mode = .repair
            wantAwake = true
            // A panel left black before the session or by a change the log could not place does
            // not show in the log: only a cut with the rails down rules it out.
            if !(panelOff && cut) { black = true }
        case .end:
            // Nothing is sent before the log is read.
            guard live else { return .quit }
            mode = .end
            wantOff = false
            wantAwake = false
        case .tick:
            break
        }
        if let wait, let deadline {
            guard now >= deadline else { return nil }
            switch wait {
            case .line(let event): return .fail("the phone did not \(Self.describe(event)) within \(Int(Self.answerTime)) seconds")
            case .settle: return .fail("Android did not finish going to sleep or waking up within \(Int(Self.answerTime)) seconds")
            case .margin: self.wait = nil; self.deadline = nil
            }
        }
        guard started, wait == nil else { return nil }
        return next(at: now)
    }

    private mutating func observe(_ event: PhoneEvent, at now: Double) {
        let answer = wait == .line(event)
        if answer || wait == .margin { wait = nil; deadline = nil }
        switch event {
        case .logStarted:
            live = true
        case .sleepStarted, .sleepFinished:
            changed = true
            slept = true
            if event == .sleepStarted {
                sleeps += 1
            } else {
                sleeps = max(sleeps - 1, 0) // a change that began before the log did
                awake = false
            }
            if panelOff {
                // The touch driver takes the rails as the sleep begins.
                black = true
                cut = false
            } else if event == .sleepFinished, wakes == 0 {
                // The touch driver suspended with the panel initialized: it reloads its firmware
                // as Android wakes. Unless a wake cut the sleep short, which Android 14 shows by
                // ending the sleep after the wake's start; Android 13 ends it before.
                touchDead = false
            }
        case .wakeStarted:
            changed = true
            wakes += 1
        case .wakeFinished:
            changed = true
            wakes = max(wakes - 1, 0)
            awake = true
        case .displayOff, .forcedOff:
            cut = answer && !changed && awake && settled
            // A sleep around it may have taken the rails while they were down; where a line the
            // client did not ask for falls is unknown. A wake alone (the server's power_on at the
            // start) cannot: the panel is then on or off, and cut again if it must be.
            if !cut && (!answer || slept) { black = true }
            // A screen-off request stands until carried out: at the start, a sleep may come just
            // before the server's power_on wakes the phone again.
            if cut { wantOff = false }
            panelOff = true
            touchDead = true
            offAt = now
        case .displayOn:
            // Up from zero through the display driver: the panel's initialization ran.
            if answer && cut && !changed && awake && settled { black = false }
            panelOff = false
            cut = false
        }
        if wait == .settle && settled { wait = nil; deadline = nil }
    }

    private mutating func next(at now: Double) -> Action? {
        if black && mode == .idle {
            mode = .repair
            wantAwake = true
            wantOff = false
        }
        guard let step = step() else {
            mode = .idle
            wantAwake = false
            return nil
        }
        // Each step's outcome shows in the log only once Android is done changing.
        guard settled else {
            waitFor(.settle, until: now + Self.answerTime)
            return nil
        }
        switch step {
        case .off:
            return send([.setDisplayPower(on: false)], answer: .displayOff, now)
        case .on:
            guard now >= offAt + Self.margin else {
                waitFor(.margin, until: offAt + Self.margin)
                return nil
            }
            return send([.setDisplayPower(on: true)], answer: .displayOn, now)
        case .wake:
            return send(ControlMessage.press(ControlMessage.wakeUpKey), answer: .wakeFinished, now)
        case .sleep:
            return send(ControlMessage.press(ControlMessage.sleepKey), answer: .sleepFinished, now)
        case .quit:
            return .quit
        }
    }

    /// The next step towards what the session wants, in order of need.
    private func step() -> Step? {
        if black {
            // Rails down with Android awake, `margin`, then up through the display driver. Android
            // must be awake first, and WAKEUP must not come while the server would force the panel
            // off after it.
            if awake { return cut ? .on : .off }
            return panelOff ? .on : .wake
        }
        if panelOff && mode != .idle { return .on }
        if touchDead && awake && !panelOff { return .sleep }
        if wantAwake && !awake { return .wake }
        if wantOff && awake && !(panelOff && cut) { return .off }
        return mode == .end ? .quit : nil
    }

    private mutating func send(_ messages: [ControlMessage], answer event: PhoneEvent, _ now: Double) -> Action {
        if event == .displayOff || event == .displayOn {
            changed = false
            slept = false
        }
        waitFor(.line(event), until: now + Self.answerTime)
        return .send(messages)
    }

    private mutating func waitFor(_ wait: Wait, until deadline: Double) {
        self.wait = wait
        self.deadline = deadline
    }

    private static func describe(_ event: PhoneEvent) -> String {
        switch event {
        case .logStarted: "start its log"
        case .displayOff: "turn its screen off"
        case .displayOn: "turn its screen on"
        case .wakeFinished: "wake up"
        case .sleepFinished: "go to sleep"
        default: "answer"
        }
    }
}
