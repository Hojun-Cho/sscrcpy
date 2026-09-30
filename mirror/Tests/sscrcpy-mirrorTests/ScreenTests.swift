import Foundation
import Testing
@testable import sscrcpy_mirror

@Test func keyMessages() {
    // test_serialize_inject_keycode: ENTER up, repeat 5, both Shift meta bits.
    let enter = ControlMessage.injectKeycode(action: .up, keycode: 66, repeatCount: 5, metaState: 0x41)
    #expect(enter.bytes == [0, 0x01, 0x00, 0x00, 0x00, 0x42, 0x00, 0x00, 0x00, 0x05, 0x00, 0x00, 0x00, 0x41])
    #expect(ControlMessage.press(ControlMessage.sleepKey).map(\.bytes) == [
        [0, 0, 0, 0, 0, 0xdf, 0, 0, 0, 0, 0, 0, 0, 0], [0, 1, 0, 0, 0, 0xdf, 0, 0, 0, 0, 0, 0, 0, 0],
    ])
    #expect(ControlMessage.press(ControlMessage.wakeUpKey).map(\.bytes) == [
        [0, 0, 0, 0, 0, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0], [0, 1, 0, 0, 0, 0xe0, 0, 0, 0, 0, 0, 0, 0, 0],
    ])
}

@Test func phoneLogLines() throws {
    // As `logcat -v tag` prints them (tags padded to 8 characters), with phone B's values.
    let lines: [(String, PhoneEvent?)] = [
        ("I/power_sleep_requested: 0", .sleepStarted),
        ("I/power_screen_state: [0,2,0,0,749]", .sleepFinished),
        ("I/screen_toggled: 1", .wakeStarted),
        ("I/power_screen_state: [1,0,0,0,340]", .wakeFinished),
        ("I/screen_toggled: 0", nil),
        // Phone A's lock screen, on a PIN unlock.
        ("I/screen_toggled: 310405", nil),
        ("I/scrcpy  : Device display turned off", .displayOff),
        ("I/scrcpy  : Device display turned on", .displayOn),
        ("I/scrcpy  : Forcing display off", .forcedOff),
        ("I/scrcpy  : Device: [samsung] samsung SM-G525N (Android 13)", nil),
        ("E/scrcpy  : \tat com.genymobile.scrcpy.Server.main(Server.java:258)", nil),
        ("I/sscrcpy : 0badc0de", nil),
        ("--------- beginning of events", nil),
    ]
    for (line, event) in lines {
        #expect(try phoneEvent(line) == event, "\(line)")
    }
    // What the filter keeps out, and a power state this client does not know.
    for line in ["logcat: bad time format", "D/SysinputHAL: setTspEnable(1),2,false(0)", "I/power_screen_state: [2,0,0,0,1]"] {
        #expect(throws: Failure.self, "\(line)") { try phoneEvent(line) }
    }
}

@Test func phoneLogStream() throws {
    // Lines of the second before the marker, then the marker and what follows, one line in CR LF.
    let text = "--------- beginning of main\nI/scrcpy  : Device display turned off\nI/sscrcpy : 0badc0de\n"
        + "I/sscrcpy : 1a2b3c4d\nI/screen_toggled: 1\r\nI/power_screen_state: [1,0,0,0,300]\nI/power_sleep"
    let fd = try socket(sending: Array(text.utf8))
    defer { close(fd) }
    var reads: [[PhoneEvent]] = []
    try receivePhoneEvents(fd, marker: "1a2b3c4d") { reads.append($0) }
    // One read: the events come together; the line cut short at the end is dropped.
    #expect(reads == [[.logStarted, .wakeStarted, .wakeFinished]])
    // The log ends before the marker: adb said why on standard error.
    let offline = try socket(sending: Array("I/sscrcpy : 0badc0de\n".utf8))
    defer { close(offline) }
    #expect(throws: Failure.self) { try receivePhoneEvents(offline, marker: "1a2b3c4d") { _ in } }
}

let off = [ControlMessage.setDisplayPower(on: false)]
let on = [ControlMessage.setDisplayPower(on: true)]
let sleep = ControlMessage.press(ControlMessage.sleepKey)
let wakeUp = ControlMessage.press(ControlMessage.wakeUpKey)

/// Lines of the phone's log, read together.
func log(_ events: PhoneEvent...) -> ScreenPower.Input { .log(events) }

/// Feeds each input at its time, expecting the action.
func run(_ power: inout ScreenPower, _ steps: [(Double, ScreenPower.Input, ScreenPower.Action?)],
         sourceLocation: SourceLocation = #_sourceLocation) {
    for (time, input, action) in steps {
        #expect(power.handle(input, at: time) == action, "\(input) at \(time)", sourceLocation: sourceLocation)
    }
}

/// Mirroring with the screen turned off at the start: the panel off since 0.3 s.
func screenOff() -> ScreenPower {
    var power = ScreenPower()
    run(&power, [
        (0, .start(turnScreenOff: true), nil), // not before the log is read
        (0.1, log(.logStarted), .send(off)),
        (0.3, log(.displayOff), nil),
    ])
    #expect(power.canTurnOn && power.canTurnOff)
    return power
}

/// screenOff(), then the power button at 10 s, repaired up to the panel's initialization.
func repairedUpToInit() -> ScreenPower {
    var power = screenOff()
    run(&power, [
        (10, log(.sleepStarted), nil),
        // The touch driver may have taken the rails without the panel's initialization. [10, 1]
        // first: the server would force the panel off 200 ms after WAKEUP.
        (10.8, log(.sleepFinished), .send(on)),
        (11.0, log(.displayOn), .send(wakeUp)),
        (11.1, log(.wakeStarted), nil),
        (11.4, log(.wakeFinished), .send(off)),
        (11.6, log(.displayOff), nil),
        (14.6, .tick, .send(on)),
    ])
    #expect(!power.canTurnOn)
    return power
}

@Test func startWaitsForTheLogAndAnAwakePhone() {
    // The server's wake-up (power_on) shows before the window: [10, 0] once it is done.
    var power = ScreenPower()
    run(&power, [
        (0, .start(turnScreenOff: true), nil),
        (0.1, log(.logStarted, .wakeStarted), nil),
        (0.4, log(.wakeFinished), .send(off)),
        (0.6, log(.displayOff), nil),
    ])
    #expect(power.canTurnOff)
    // It shows only after [10, 0] was sent: that off cannot be trusted as a cut, but a wake alone
    // cannot arm the black state, so the client cuts again instead of repairing.
    var late = ScreenPower()
    run(&late, [
        (0, .start(turnScreenOff: true), nil),
        (0.1, log(.logStarted), .send(off)),
        (0.12, log(.wakeStarted), nil),
        (0.4, log(.wakeFinished), nil),
        (0.7, log(.displayOff), .send(off)),
        (0.9, log(.displayOff), nil),
    ])
    #expect(late.canTurnOff)
    run(&late, [
        // Stop: the cut's margin, then the panel on and Android to sleep.
        (1, .end, nil),
        (3.9, .tick, .send(on)),
        (4.1, log(.displayOn), .send(sleep)),
        (4.2, log(.sleepStarted), nil),
        (4.9, log(.sleepFinished), .quit),
    ])
    // The log never starts.
    var silent = ScreenPower()
    run(&silent, [(0, .start(turnScreenOff: true), nil), (14.9, .tick, nil)])
    #expect(silent.handle(.tick, at: 15) == .fail("the phone did not start its log within 15 seconds"))
    // Stop before the log starts: nothing was sent.
    var early = ScreenPower()
    run(&early, [(0, .start(turnScreenOff: true), nil), (1, .end, .quit)])
    // Stop while the server's power_on wake is under way, before the first [10, 0]: nothing to
    // undo once Android is done.
    var waking = ScreenPower()
    run(&waking, [
        (0, .start(turnScreenOff: true), nil),
        (0.1, log(.logStarted, .wakeStarted), nil),
        (0.2, .end, nil),
        (0.4, log(.wakeFinished), .quit),
    ])
}

@Test func endAfterScreenOff() {
    var power = screenOff()
    run(&power, [
        (10, .end, .send(on)),
        (10.2, log(.displayOn), .send(sleep)),
        (10.3, log(.sleepStarted), nil),
        (11, log(.sleepFinished), .quit),
    ])
    // Soon after the panel went off: [10, 1] waits for the margin.
    var soon = screenOff()
    run(&soon, [(1, .end, nil), (2, .tick, nil)])
    #expect(soon.deadline == 3.3)
    run(&soon, [
        (3.3, .tick, .send(on)),
        (3.5, log(.displayOn), .send(sleep)),
        (3.6, log(.sleepStarted), nil),
        (4.3, log(.sleepFinished), .quit),
    ])
}

@Test func endWithNothingToUndo() {
    var mirroring = ScreenPower()
    run(&mirroring, [(0, .start(turnScreenOff: false), nil), (0.1, log(.logStarted), nil), (5, .end, .quit)])
    // Android going to sleep by itself: the client waits for it to finish.
    var sleeping = ScreenPower()
    run(&sleeping, [
        (0, .start(turnScreenOff: false), nil),
        (0.1, log(.logStarted), nil),
        (5, log(.sleepStarted), nil),
        (5.2, .end, nil),
        (5.8, log(.sleepFinished), .quit),
    ])
}

@Test func offMeetingASleepIsRepairedEvenAtTheEnd() {
    // [10, 0] and a sleep at once, then Stop before the sleep ends: the rails may have been down
    // when the touch driver took them. The phone must be woken and repaired before the exit.
    var power = ScreenPower()
    run(&power, [
        (0, .start(turnScreenOff: false), nil),
        (0.1, log(.logStarted), nil),
        (5, .turnOff, .send(off)),
        (5.1, log(.sleepStarted), nil),
        (5.3, log(.displayOff), nil),
        (5.4, .end, nil),
        (5.9, log(.sleepFinished), nil), // the margin after the off
        (8.3, .tick, .send(on)),
        (8.5, log(.displayOn), .send(wakeUp)),
        (8.6, log(.wakeStarted), nil),
        (8.9, log(.wakeFinished), .send(off)),
        (9.1, log(.displayOff), nil),
        (12.1, .tick, .send(on)),
        (12.3, log(.displayOn), .send(sleep)),
        (12.4, log(.sleepStarted), nil),
        (13.1, log(.sleepFinished), .quit),
    ])
    // The off's line after the sleep's end: the same.
    var late = ScreenPower()
    run(&late, [
        (0, .start(turnScreenOff: false), nil),
        (0.1, log(.logStarted), nil),
        (5, .turnOff, .send(off)),
        (5.1, log(.sleepStarted), nil),
        (5.8, log(.sleepFinished), nil),
        (6.0, log(.displayOff), nil),
        (9.0, .tick, .send(on)),
    ])
}

@Test func sleepWhileScreenOffIsRepaired() {
    var power = repairedUpToInit()
    run(&power, [
        // Initialized; a sleep and a wake reload the touch firmware.
        (14.8, log(.displayOn), .send(sleep)),
        (14.9, log(.sleepStarted), nil),
        (15.6, log(.sleepFinished), .send(wakeUp)),
        (15.7, log(.wakeStarted), nil),
    ])
    #expect(!power.canTurnOn)
    run(&power, [(16.0, log(.wakeFinished), nil)])
    #expect(power.canTurnOn && power.canTurnOff)
    // Later sleeps and wakes are the phone's own.
    run(&power, [(30, log(.sleepStarted), nil), (30.8, log(.sleepFinished), nil), (40, log(.wakeStarted, .wakeFinished), nil)])
    #expect(power.canTurnOn)
}

@Test func lockScreenSleepDuringTheMarginStartsAgain() {
    var power = screenOff()
    run(&power, [
        (10, log(.sleepStarted), nil),
        (10.8, log(.sleepFinished), .send(on)),
        (11.0, log(.displayOn), .send(wakeUp)),
        (11.1, log(.wakeStarted), nil),
        (11.4, log(.wakeFinished), .send(off)),
        (11.6, log(.displayOff), nil),
        // The lock screen's timeout while the rails are down.
        (13.0, log(.sleepStarted), nil),
        (13.8, log(.sleepFinished), nil), // [10, 1] no sooner than the margin after the off
        (14.6, .tick, .send(on)),
        (14.8, log(.displayOn), .send(wakeUp)),
        (14.9, log(.wakeStarted), nil),
        (15.2, log(.wakeFinished), .send(off)),
    ])
}

@Test func sleepBetweenOnAndItsLineStartsAgain() {
    var power = repairedUpToInit()
    run(&power, [
        // The lock screen's timeout lands before [10, 1]'s line: the initialization is not sure.
        (14.7, log(.sleepStarted), nil),
        (14.8, log(.displayOn), nil),
        (15.4, log(.sleepFinished), .send(wakeUp)),
        (15.5, log(.wakeStarted), nil),
        (15.8, log(.wakeFinished), .send(off)),
    ])
}

@Test func lockScreenSleepAfterTheInitEndsTheTouchCycle() {
    var power = repairedUpToInit()
    run(&power, [
        (14.8, log(.displayOn), .send(sleep)),
        // The timeout's sleep comes first; SLEEP then finds the phone asleep.
        (14.85, log(.sleepStarted), nil),
        (15.5, log(.sleepFinished), .send(wakeUp)),
        (15.6, log(.wakeStarted, .wakeFinished), nil),
    ])
    #expect(power.canTurnOn)
}

@Test func powerPressedTwiceDuringScreenOff() {
    // Asleep and awake again before the client acts (Android 13's order): the panel may be black
    // with Android awake.
    var power = screenOff()
    run(&power, [
        (10, log(.sleepStarted), nil),
        (10.3, log(.sleepFinished, .wakeStarted), nil),
        (10.6, log(.wakeFinished), .send(off)),
        (10.8, log(.displayOff), nil),
        (13.8, .tick, .send(on)),
        (14.0, log(.displayOn), .send(sleep)),
    ])
}

@Test func stopDuringARepairEndsAsleep() {
    var power = screenOff()
    run(&power, [
        (10, log(.sleepStarted), nil),
        (10.8, log(.sleepFinished), .send(on)),
        (11.0, log(.displayOn), .send(wakeUp)),
        (11.4, log(.wakeStarted, .wakeFinished), .send(off)),
        (11.6, log(.displayOff), nil),
        (12, .end, nil),
        (14.6, .tick, .send(on)),
        (14.8, log(.displayOn), .send(sleep)),
        (14.9, log(.sleepStarted), nil),
        (15.6, log(.sleepFinished), .quit),
    ])
}

@Test func turnScreenOn() {
    // After the panel was off long enough: [10, 1], then a sleep and a wake for touch.
    var power = screenOff()
    run(&power, [
        (20, .turnOn, .send(on)),
        (20.2, log(.displayOn), .send(sleep)),
    ])
    // Once under way, the menu waits.
    #expect(!power.canTurnOn && !power.canTurnOff)
    #expect(power.handle(.turnOn, at: 20.25) == nil)
    run(&power, [
        (20.3, log(.sleepStarted), nil),
        (21, log(.sleepFinished), .send(wakeUp)),
        (21.3, log(.wakeStarted, .wakeFinished), nil),
    ])
    #expect(power.canTurnOn)
    // Again, with the panel on: it may be black from before, so off, margin, on, then touch.
    run(&power, [
        (30, .turnOn, .send(off)),
        (30.2, log(.displayOff), nil),
        (33.2, .tick, .send(on)),
        (33.4, log(.displayOn), .send(sleep)),
        (33.5, log(.sleepStarted), nil),
        (34.2, log(.sleepFinished), .send(wakeUp)),
        (34.5, log(.wakeStarted, .wakeFinished), nil),
    ])
    #expect(power.canTurnOn)
    // Asleep: woken first.
    run(&power, [
        (40, log(.sleepStarted), nil),
        (40.8, log(.sleepFinished), nil),
        (50, .turnOn, .send(wakeUp)),
        (50.3, log(.wakeStarted, .wakeFinished), .send(off)),
    ])
}

@Test func turnScreenOffOnlyWhileAwake() {
    var power = ScreenPower()
    run(&power, [
        (0, .start(turnScreenOff: false), nil),
        (0.1, log(.logStarted), nil),
        (1, log(.sleepStarted, .sleepFinished), nil),
    ])
    #expect(!power.canTurnOff && power.canTurnOn)
    run(&power, [(2, .turnOff, nil), (5, log(.wakeStarted, .wakeFinished), nil), (6, .turnOff, .send(off))])
    // --turn-screen-off, and the lock screen's timeout sleeps the phone just before the server's
    // power_on wakes it: the screen goes off once Android is awake, in one read or several.
    var start = ScreenPower()
    run(&start, [
        (0, .start(turnScreenOff: true), nil),
        (0.1, log(.logStarted, .sleepStarted), nil),
        (0.8, log(.sleepFinished), nil),
        (2, log(.wakeStarted), nil),
        (2.3, log(.wakeFinished), .send(off)),
    ])
    var woken = ScreenPower()
    run(&woken, [
        (0, .start(turnScreenOff: true), nil),
        (1, log(.logStarted, .sleepStarted, .sleepFinished, .wakeStarted, .wakeFinished), .send(off)),
        (1.2, log(.displayOff), nil),
    ])
    #expect(woken.canTurnOn && woken.canTurnOff)
    // Asleep with the request pending, Turn Screen On drops it and brings the phone up.
    var asleep = ScreenPower()
    run(&asleep, [
        (0, .start(turnScreenOff: true), nil),
        (0.1, log(.logStarted, .sleepStarted, .sleepFinished), nil),
        (5, .turnOn, .send(wakeUp)),
    ])
}

@Test func changesThatBeganBeforeTheLog() {
    // A wake whose start the marker missed: the screen goes off once it ends.
    var woke = ScreenPower()
    run(&woke, [(0, .start(turnScreenOff: true), nil), (0.1, log(.logStarted, .wakeFinished), .send(off))])
    // A sleep whose start the marker missed: Android is settled again after the next wake.
    var slept = ScreenPower()
    run(&slept, [
        (0, .start(turnScreenOff: false), nil),
        (0.1, log(.logStarted, .sleepFinished), nil),
        (3, log(.wakeStarted, .wakeFinished), nil),
    ])
    #expect(slept.canTurnOff)
}

@Test func mirroringAloneDoesNotWaitForTheLog() {
    // Logging off on the phone: plain mirroring goes on, and the Phone menu stays off.
    var power = ScreenPower()
    run(&power, [(0, .start(turnScreenOff: false), nil), (60, .tick, nil)])
    #expect(!power.canTurnOn && !power.canTurnOff)
    run(&power, [(61, .end, .quit)])
}

@Test func wakeCuttingTheTouchCycleShort() {
    // Android 14 ends a sleep cut short after the wake's start: touch may not have suspended, so
    // the client cycles again, then wakes the phone as the user wanted.
    var power = repairedUpToInit()
    run(&power, [
        (14.8, log(.displayOn), .send(sleep)),
        (14.9, log(.sleepStarted), nil),
        (15.1, log(.wakeStarted, .sleepFinished), nil),
        (15.4, log(.wakeFinished), .send(sleep)),
        (15.5, log(.sleepStarted), nil),
        (16.2, log(.sleepFinished), .send(wakeUp)),
        (16.5, log(.wakeStarted, .wakeFinished), nil),
    ])
    #expect(power.canTurnOn)
}

@Test func unaskedOffIsRepaired() {
    // The server forced the panel off, which this client never asks for: where it fell among
    // Android's changes is unknown, so the panel is cut again and repaired.
    var power = ScreenPower()
    run(&power, [
        (0, .start(turnScreenOff: false), nil),
        (0.1, log(.logStarted), nil),
        (5, log(.forcedOff), .send(off)),
        (5.2, log(.displayOff), nil),
        (8.2, .tick, .send(on)),
        (8.4, log(.displayOn), .send(sleep)),
    ])
}

@Test func noAnswerFails() {
    var power = ScreenPower()
    run(&power, [(0, .start(turnScreenOff: true), nil), (0.1, log(.logStarted), .send(off)), (15, .tick, nil)])
    #expect(power.handle(.tick, at: 15.1) == .fail("the phone did not turn its screen off within 15 seconds"))
    var changing = screenOff()
    run(&changing, [(10, log(.sleepStarted), nil), (24.9, .tick, nil)])
    #expect(changing.handle(.tick, at: 25) == .fail("Android did not finish going to sleep or waking up within 15 seconds"))
}
