import AppKit
import Testing
@testable import sscrcpy_mirror

// Expected bytes come from scrcpy 4.1's tests where they have a case
// (app/tests/test_control_msg_serialize.c, test_device_msg_deserialize.c and the server's
// ControlMessageReaderTest.java); the others are worked out from scrcpy's code.

@Test func touchEvent() {
    let message = ControlMessage.touch(
        action: .down, pointer: 0x1234567887654321,
        position: Position(x: 100, y: 200, width: 1080, height: 1920),
        pressure: 1, actionButton: 1, buttons: 1
    )
    #expect(message.bytes == [
        2,
        0x00,
        0x12, 0x34, 0x56, 0x78, 0x87, 0x65, 0x43, 0x21,
        0x00, 0x00, 0x00, 0x64, 0x00, 0x00, 0x00, 0xc8,
        0x04, 0x38, 0x07, 0x80,
        0xff, 0xff,
        0x00, 0x00, 0x00, 0x01,
        0x00, 0x00, 0x00, 0x01,
    ])
    // The server's test: pointer id -42, with the same fields otherwise.
    let server = ControlMessage.touch(
        action: .down, pointer: UInt64(bitPattern: -42),
        position: Position(x: 100, y: 200, width: 1080, height: 1920),
        pressure: 1, actionButton: 1, buttons: 1
    )
    #expect(server.bytes == [2, 0] + [0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xff, 0xd6] + Array(message.bytes[10...]))
}

@Test func mouseTouchEvents() {
    let position = Position(x: -1, y: 2, width: 720, height: 1480)
    let up = ControlMessage.touch(action: .up, pointer: ControlMessage.mouse, position: position, pressure: 0, actionButton: 2, buttons: 0)
    #expect(up.bytes == [2, 1] + [UInt8](repeating: 0xff, count: 8)
        + [0xff, 0xff, 0xff, 0xff, 0, 0, 0, 2, 0x02, 0xd0, 0x05, 0xc8] + [0, 0] + [0, 0, 0, 2] + [0, 0, 0, 0])
    let hover = ControlMessage.touch(action: .hoverMove, pointer: ControlMessage.mouse, position: position, pressure: 1, actionButton: 0, buttons: 0)
    #expect(hover.bytes[1] == 7 && hover.bytes[22 ..< 24] == [0xff, 0xff])
}

@Test func scrollEvent() {
    let message = ControlMessage.scroll(
        position: Position(x: 260, y: 1026, width: 1080, height: 1920), horizontal: 16, vertical: -16, buttons: 1
    )
    #expect(message.bytes == [
        3,
        0x00, 0x00, 0x01, 0x04, 0x00, 0x00, 0x04, 0x02,
        0x04, 0x38, 0x07, 0x80,
        0x7F, 0xFF,
        0x80, 0x00,
        0x00, 0x00, 0x00, 0x01,
    ])
    // The server's test: 0 and -16.
    let server = ControlMessage.scroll(
        position: Position(x: 260, y: 1026, width: 1080, height: 1920), horizontal: 0, vertical: -16, buttons: 1
    )
    #expect(server.bytes[13 ..< 17] == [0, 0, 0x80, 0x00])
    // Out of range amounts are clamped.
    let clamped = ControlMessage.scroll(position: Position(x: 0, y: 0, width: 1, height: 1), horizontal: -40, vertical: 40, buttons: 0)
    #expect(clamped.bytes[13 ..< 17] == [0x80, 0x00, 0x7f, 0xff])
    // Fractions are truncated toward zero: -204.8 is FF 34, where rounding or flooring gives FF 33.
    let fraction = ControlMessage.scroll(position: Position(x: 0, y: 0, width: 1, height: 1), horizontal: 0.1, vertical: -0.1, buttons: 0)
    #expect(fraction.bytes[13 ..< 17] == [0x00, 0xcc, 0xff, 0x34])
}

@Test func uhidMessages() {
    let create = ControlMessage.uhidCreate(id: 42, vendor: 0x1234, product: 0x5678, name: "ABC", descriptor: Array(1 ... 11))
    #expect(create.bytes == [12, 0, 42, 0x12, 0x34, 0x56, 0x78, 3, 65, 66, 67, 0, 11, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11])
    #expect(ControlMessage.uhidInput(id: 42, report: [1, 2, 3, 4, 5]).bytes == [13, 0, 42, 0, 5, 1, 2, 3, 4, 5])
    // What this client sends for its keyboard: no vendor, product or name.
    #expect(HIDKeyboard.create.bytes.prefix(10) == [12, 0, 1, 0, 0, 0, 0, 0, 0, 63])
    #expect(HIDKeyboard.create.bytes.count == 10 + 63)
}

@Test func clipboardMessages() {
    // test_serialize_get_clipboard, and the cut key.
    #expect(ControlMessage.getClipboard(copyKey: .copy).bytes == [8, 1])
    #expect(ControlMessage.getClipboard(copyKey: .cut).bytes == [8, 2])
    // test_serialize_set_clipboard.
    let hello = ControlMessage.setClipboard(sequence: 0x0102030405060708, paste: true, text: "hello, world!")
    #expect(hello.bytes == [9, 1, 2, 3, 4, 5, 6, 7, 8, 1, 0, 0, 0, 0x0d] + Array("hello, world!".utf8))
    // The server's testParseSetClipboardEvent: the length counts bytes.
    let accent = ControlMessage.setClipboard(sequence: 0x0102030405060708, paste: true, text: "testé")
    #expect(accent.bytes == [9, 1, 2, 3, 4, 5, 6, 7, 8, 1, 0, 0, 0, 6, 0x74, 0x65, 0x73, 0x74, 0xc3, 0xa9])
    #expect(ControlMessage.setClipboard(sequence: 0, paste: false, text: "").bytes == [9, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
    // test_serialize_set_clipboard_long: the longest text fills 256 KiB.
    let max = (1 << 18) - 14
    let a = { String(repeating: "a", count: $0) }
    let long = ControlMessage.setClipboard(sequence: 0x0102030405060708, paste: true, text: a(max))
    #expect(long.bytes == [9, 1, 2, 3, 4, 5, 6, 7, 8, 1, 0x00, 0x03, 0xff, 0xf2] + [UInt8](repeating: 0x61, count: max))
    // Longer texts are cut before the first character that does not fit whole (é is 2 bytes, 한 3).
    let cases: [(String, Int)] = [(a(max) + "b", max), (a(max - 1) + "é", max - 1), (a(max - 2) + "한", max - 2), (a(max - 3) + "한", max)]
    for (text, kept) in cases {
        let length: [UInt8] = [0, UInt8(kept >> 16), UInt8(kept >> 8 & 0xff), UInt8(kept & 0xff)]
        let message = ControlMessage.setClipboard(sequence: 0, paste: true, text: text)
        #expect(message.bytes == [9, 0, 0, 0, 0, 0, 0, 0, 0, 1] + length + text.utf8.prefix(kept), "\(kept)")
    }
}

@Test func deviceMessages() throws {
    // scrcpy's app/tests/test_device_msg_deserialize.c messages, the server's
    // DeviceMessageWriterTest clipboard, an empty clipboard, then two keyboard LED reports:
    // every message was framed right if all the texts and LEDs come out.
    let stream: [UInt8] = [
        0, 0x00, 0x00, 0x00, 0x03, 0x41, 0x42, 0x43,
        1, 0x01, 0x02, 0x03, 0x04, 0x05, 0x06, 0x07, 0x08,
        2, 0, 42, 0, 5, 0x01, 0x02, 0x03, 0x04, 0x05,
        0, 0x00, 0x00, 0x00, 0x08, 0x61, 0xc3, 0xa9, 0xc3, 0xbb, 0x6f, 0xc3, 0xa7,
        0, 0x00, 0x00, 0x00, 0x00,
        2, 0, 1, 0, 1, 0x02,
        2, 0, 1, 0, 1, 0x00,
    ]
    let fd = try socket(sending: stream)
    defer { close(fd) }
    var texts: [String] = []
    var leds: [UInt8] = []
    try receiveDeviceMessages(fd) { texts.append($0) } onLEDs: { leds.append($0) }
    #expect(texts == ["ABC", "aéûoç", ""])
    #expect(leds == [0x02, 0x00])

    let unknown = try socket(sending: [3, 0, 0])
    defer { close(unknown) }
    #expect(throws: Failure.self) { try receiveDeviceMessages(unknown) { _ in } onLEDs: { _ in } }
    // One byte longer than the server's longest text.
    let long = try socket(sending: [0, 0x00, 0x03, 0xff, 0xfc])
    defer { close(long) }
    #expect(throws: Failure.self) { try receiveDeviceMessages(long) { _ in } onLEDs: { _ in } }

    // Cut inside a message: a disconnect, as for the video.
    for message: [UInt8] in [[2, 0, 1, 0, 8, 0], [0, 0, 0, 0, 9, 0x41]] {
        let cut = try socket(sending: message)
        defer { close(cut) }
        try receiveDeviceMessages(cut) { _ in Issue.record("no complete text was sent") } onLEDs: { _ in
            Issue.record("no complete report was sent")
        }
    }
}

@Test func longDeviceClipboard() throws {
    // test_deserialize_clipboard_big: the longest text the server sends. A socket buffer holds
    // less, so it is written while it is read.
    let max = (1 << 18) - 5
    var fds: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    let (reader, writer) = (fds[0], fds[1])
    defer { close(reader) }
    // A reader that stops early fails the write instead of killing the tests with SIGPIPE.
    var on: Int32 = 1
    try #require(setsockopt(writer, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size)) == 0)
    let message: [UInt8] = [0, 0x00, 0x03, 0xff, 0xfb] + [UInt8](repeating: 0x61, count: max)
    Thread {
        _ = message.withUnsafeBytes { sendAll(writer, $0) }
        close(writer)
    }.start()
    var texts: [String] = []
    try receiveDeviceMessages(reader) { texts.append($0) } onLEDs: { _ in }
    #expect(texts == [String(repeating: "a", count: max)])
}

@MainActor @Test func clipboardSync() {
    // A pasteboard of the test's own: the general one is the user's.
    let pasteboard = NSPasteboard(name: NSPasteboard.Name("sscrcpy-mirror-test-\(UUID().uuidString)"))
    defer { pasteboard.releaseGlobally() }
    var sync = ClipboardSync()
    // Copied on the device: the Mac gets the text.
    pasteboard.clearContents()
    pasteboard.setString("mac", forType: .string)
    sync.copyDeviceText("phone", to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "phone")
    // The same again, or an emptied device clipboard: the pasteboard is left alone.
    let count = pasteboard.changeCount
    sync.copyDeviceText("phone", to: pasteboard)
    sync.copyDeviceText("", to: pasteboard)
    #expect(pasteboard.changeCount == count)
    // Styled text pasted on the device, which echoes it: the Mac keeps its styled copy.
    pasteboard.clearContents()
    pasteboard.setData(Data(#"{\rtf1 hi}"#.utf8), forType: .rtf)
    pasteboard.setString("hi", forType: .string)
    let styled = pasteboard.changeCount
    #expect(sync.textToPaste(from: pasteboard) == "hi")
    sync.copyDeviceText("hi", to: pasteboard)
    #expect(pasteboard.changeCount == styled && pasteboard.data(forType: .rtf) != nil)
    // Copied on the Mac since, then the device copies that text again: the device's wins.
    pasteboard.clearContents()
    pasteboard.setString("new", forType: .string)
    sync.copyDeviceText("hi", to: pasteboard)
    #expect(pasteboard.string(forType: .string) == "hi")
    // Too long for a message: the device echoes it cut, and the Mac keeps it whole.
    let long = String(repeating: "a", count: 1 << 18)
    pasteboard.clearContents()
    pasteboard.setString(long, forType: .string)
    #expect(sync.textToPaste(from: pasteboard) == long)
    sync.copyDeviceText(String(repeating: "a", count: (1 << 18) - 14), to: pasteboard)
    #expect(pasteboard.string(forType: .string) == long)
    // No text, e.g. an image: nothing to paste.
    pasteboard.clearContents()
    pasteboard.setData(Data([0x89, 0x50, 0x4e, 0x47]), forType: .png)
    #expect(sync.textToPaste(from: pasteboard) == nil)
}

@Test func keyboardReports() {
    var keyboard = HIDKeyboard()
    #expect(keyboard.report == [0, 0, 0, 0, 0, 0, 0, 0])
    keyboard.modifiers = 0x02
    // Up to six keys, in usage order whatever the order they were pressed in.
    for usage: UInt8 in [0x65, 0x09, 0x08, 0x07, 0x05, 0x04] { keyboard.set(usage, down: true) }
    #expect(keyboard.report == [0x02, 0, 0x04, 0x05, 0x07, 0x08, 0x09, 0x65])
    // Past the descriptor's usages (Power, LANG1) or unknown: ignored.
    for usage: UInt8 in [0x66, 0x90, 0] { keyboard.set(usage, down: true) }
    #expect(keyboard.report == [0x02, 0, 0x04, 0x05, 0x07, 0x08, 0x09, 0x65])
    // A seventh key: ErrorRollOver in every slot, modifiers kept.
    keyboard.set(0x06, down: true)
    #expect(keyboard.report == [0x02, 0, 1, 1, 1, 1, 1, 1])
    for usage: UInt8 in [0x65, 0x09, 0x08, 0x07, 0x06, 0x05] { keyboard.set(usage, down: false) }
    #expect(keyboard.report == [0x02, 0, 0x04, 0, 0, 0, 0, 0])
}

@Test func keyboardStateReports() {
    var keyboard = HIDKeyboard()
    let leftShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)
    // kVK_ANSI_A down, down again (nothing changed), with Shift, then up.
    #expect(keyboard.reports(keyCode: 0, down: true, flags: []) == [[0, 0, 0x04, 0, 0, 0, 0, 0]])
    #expect(keyboard.reports(keyCode: 0, down: true, flags: []) == [])
    #expect(keyboard.reports(keyCode: nil, down: false, flags: leftShift) == [[0x02, 0, 0x04, 0, 0, 0, 0, 0]])
    #expect(keyboard.reports(keyCode: 0, down: false, flags: leftShift) == [[0x02, 0, 0, 0, 0, 0, 0, 0]])
    #expect(keyboard.reports(keyCode: nil, down: false, flags: []) == [[0, 0, 0, 0, 0, 0, 0, 0]])
    // Caps Lock turned on: a press, then its release with the event's own report.
    #expect(keyboard.reports(keyCode: nil, down: false, flags: .capsLock) == [
        [0, 0, 0x39, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0],
    ])
    #expect(keyboard.reports(keyCode: 0, down: true, flags: .capsLock) == [[0, 0, 0x04, 0, 0, 0, 0, 0]])
    // The device reports Caps Lock off (it missed the press): pressed again before the next key.
    keyboard.capsLock = false
    #expect(keyboard.reports(keyCode: 11, down: true, flags: .capsLock) == [
        [0, 0, 0x04, 0x39, 0, 0, 0, 0], [0, 0, 0x04, 0x05, 0, 0, 0, 0],
    ])
    // Losing the keyboard releases everything once.
    #expect(keyboard.release() == [[0, 0, 0, 0, 0, 0, 0, 0]])
    #expect(keyboard.release() == [])
}

@Test func commandStaysOnTheMac() {
    var keyboard = HIDKeyboard()
    let leftCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)
    let rightCommand = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x10)
    let leftShift = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.shift.rawValue | 0x2)
    // Either Command, alone or with kVK_ANSI_C: nothing.
    for command in [leftCommand, rightCommand] {
        #expect(keyboard.reports(keyCode: nil, down: false, flags: command) == [])
        #expect(keyboard.reports(keyCode: 8, down: true, flags: command) == [])
        #expect(keyboard.reports(keyCode: 8, down: false, flags: command) == [])
        #expect(keyboard.reports(keyCode: nil, down: false, flags: []) == [])
    }
    // C pressed with Command and still held once Command is up: it stays off the device.
    #expect(keyboard.reports(keyCode: nil, down: false, flags: leftCommand) == [])
    #expect(keyboard.reports(keyCode: 8, down: true, flags: leftCommand) == [])
    #expect(keyboard.reports(keyCode: nil, down: false, flags: []) == [])
    #expect(keyboard.reports(keyCode: 8, down: false, flags: []) == [])
    // A key held from before is released on the device while Command is held.
    #expect(keyboard.reports(keyCode: 0, down: true, flags: []) == [[0, 0, 0x04, 0, 0, 0, 0, 0]])
    #expect(keyboard.reports(keyCode: nil, down: false, flags: leftCommand) == [])
    #expect(keyboard.reports(keyCode: 0, down: false, flags: leftCommand) == [[0, 0, 0, 0, 0, 0, 0, 0]])
    #expect(keyboard.reports(keyCode: nil, down: false, flags: []) == [])
    // So is a modifier.
    #expect(keyboard.reports(keyCode: nil, down: false, flags: leftShift) == [[0x02, 0, 0, 0, 0, 0, 0, 0]])
    #expect(keyboard.reports(keyCode: nil, down: false, flags: leftShift.union(leftCommand)) == [])
    #expect(keyboard.reports(keyCode: nil, down: false, flags: leftCommand) == [[0, 0, 0, 0, 0, 0, 0, 0]])
    #expect(keyboard.reports(keyCode: nil, down: false, flags: []) == [])
    // A modifier pressed with Command held reaches the device once Command is up.
    #expect(keyboard.reports(keyCode: nil, down: false, flags: leftShift.union(leftCommand)) == [])
    #expect(keyboard.reports(keyCode: nil, down: false, flags: leftShift) == [[0x02, 0, 0, 0, 0, 0, 0, 0]])
    #expect(keyboard.release() == [[0, 0, 0, 0, 0, 0, 0, 0]])
    // Caps Lock turned on with Command held: synced once Command is up.
    #expect(keyboard.reports(keyCode: nil, down: false, flags: leftCommand.union(.capsLock)) == [])
    #expect(keyboard.reports(keyCode: nil, down: false, flags: .capsLock) == [
        [0, 0, 0x39, 0, 0, 0, 0, 0], [0, 0, 0, 0, 0, 0, 0, 0],
    ])
}

@Test func keyCodes() {
    // kVK_ANSI_A, kVK_Return, kVK_ANSI_KeypadEnter, kVK_F1, kVK_ForwardDelete, kVK_UpArrow,
    // kVK_JIS_Kana, and unknown codes. (Not the two keys ISO keyboards swap: the result
    // depends on the keyboard attached.)
    let codes: [UInt16] = [0x00, 0x24, 0x4c, 0x7a, 0x75, 0x7e, 0x68, 0x42, 200]
    #expect(codes.map { hidUsage(keyCode: $0) } == [0x04, 0x28, 0x58, 0x3a, 0x4c, 0x52, 0x90, 0, 0])
}

@Test func modifiers() {
    // Device-dependent flags tell left from right: left Shift (0x2) and right Command (0x10).
    #expect(hidModifiers(NSEvent.ModifierFlags(rawValue: 0x2 | 0x10 | NSEvent.ModifierFlags([.shift, .command]).rawValue)) == 0x02 | 0x80)
    // Right Control (0x2000) and left Option (0x20).
    #expect(hidModifiers(NSEvent.ModifierFlags(rawValue: 0x2000 | 0x20 | NSEvent.ModifierFlags([.control, .option]).rawValue)) == 0x10 | 0x04)
    // Without device-dependent flags, both sides.
    #expect(hidModifiers([.control]) == 0x01 | 0x10)
    // Caps Lock and fn are not modifiers here.
    #expect(hidModifiers([.capsLock, .function]) == 0)
}

@Test func videoPoints() {
    // (view width, height, video width, height, x, y, expected x, y) from scrcpy 4.1's
    // compute_content_rect and sc_screen_convert_window_to_frame_coords, compiled as they are.
    let cases: [(Int, Int, Int, Int, Int32, Int32, Int32, Int32)] = [
        (360, 740, 720, 1480, 0, 0, 0, 0),
        (360, 740, 720, 1480, 359, 739, 718, 1478),
        (360, 740, 720, 1480, 180, 370, 360, 740),
        (360, 740, 720, 1480, -5, 10, -10, 20),
        (360, 740, 720, 1480, 400, 800, 800, 1600),
        (361, 740, 720, 1480, 0, 0, 0, 0),
        (361, 740, 720, 1480, 1, 1, 0, 2),
        (361, 740, 720, 1480, 360, 739, 718, 1478),
        (1920, 1080, 720, 1480, 100, 540, -818, 740),
        (1920, 1080, 720, 1480, 960, 540, 359, 740),
        (1920, 1080, 720, 1480, 1222, 1079, 718, 1478),
        (1000, 500, 1480, 720, 500, 3, 740, -4),
        (1000, 500, 1480, 720, 999, 499, 1478, 728),
        (1000, 500, 1480, 720, 250, 250, 370, 359),
        (333, 687, 720, 1480, 166, 343, 358, 737),
        (333, 687, 720, 1480, 332, 686, 717, 1478),
        (1344, 654, 1480, 720, 1343, 653, 1478, 718),
        (893, 1836, 1080, 2220, 446, 918, 539, 1110),
    ]
    for (w, h, vw, vh, x, y, ex, ey) in cases {
        let p = videoPoint(x, y, view: (w, h), video: (vw, vh))
        #expect(p.x == ex && p.y == ey, "\(w)x\(h) \(vw)x\(vh) at \(x),\(y)")
    }
}

@MainActor @Test func scrollAmountsAsSDL() throws {
    // A trackpad (pixel deltas): a tenth, horizontal negated.
    let pixels = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 3, wheel2: -2, wheel3: 0))
    let (h, v) = scrollAmounts(try #require(NSEvent(cgEvent: pixels)))
    #expect(abs(h - 0.2) < 1e-6 && abs(v - 0.3) < 1e-6)
    // A wheel: whole steps away from zero.
    let lines = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: 0, wheel3: 0))
    lines.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: 0.4)
    lines.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: -1.5)
    let steps = scrollAmounts(try #require(NSEvent(cgEvent: lines)))
    #expect(steps.horizontal == 2 && steps.vertical == 1)
    lines.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: -0.4)
    lines.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: 1.5)
    let down = scrollAmounts(try #require(NSEvent(cgEvent: lines)))
    #expect(down.horizontal == -2 && down.vertical == -1)
}

@Test func inputOptions() throws {
    let o = try Options(["--serial=abc", "--mouse-bind=++++:++++", "--keyboard=uhid"])
    #expect(o.keyboard)
    #expect(try !Options(["--serial=abc"]).keyboard)
    #expect(throws: Failure.self) { try Options(["--serial=abc", "--mouse-bind=+bhs:++++"]) }
    #expect(throws: Failure.self) { try Options(["--serial=abc", "--keyboard=sdk"]) }
    #expect(throws: Failure.self) { try Options(["--serial=abc", "--keyboard"]) }
}
