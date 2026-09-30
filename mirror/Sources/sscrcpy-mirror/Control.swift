import AppKit
import Carbon.HIToolbox

/// A point of the video, in pixels of the video size it was computed for: the server drops
/// events computed for another size, since the device has rotated in between.
nonisolated struct Position: Equatable {
    var x: Int32
    var y: Int32
    var width: UInt16
    var height: UInt16
}

/// Android's MotionEvent actions for the mouse.
nonisolated enum MotionAction: UInt8 {
    case down = 0, up = 1, move = 2, hoverMove = 7
}

/// Android's key event actions (KeyEvent.java).
nonisolated enum KeyAction: UInt8 {
    case down = 0, up = 1
}

/// The key the device presses when asked for its clipboard (control_msg.h). The clipboard
/// change it makes comes back like any other.
nonisolated enum CopyKey: UInt8 {
    case copy = 1, cut = 2
}

/// The messages this client sends to the server (control_msg.c).
nonisolated enum ControlMessage: Equatable {
    /// scrcpy's pointer id for the mouse.
    static let mouse = UInt64.max
    /// KEYCODE_SLEEP and KEYCODE_WAKEUP (KeyEvent.java). Unlike POWER, which toggles after
    /// waiting for a second press, each acts at once and only one way: SLEEP on an awake
    /// phone, WAKEUP on a sleeping one.
    static let sleepKey: UInt32 = 223, wakeUpKey: UInt32 = 224

    /// A key pressed and released.
    static func press(_ keycode: UInt32) -> [ControlMessage] {
        [KeyAction.down, .up].map { .injectKeycode(action: $0, keycode: keycode, repeatCount: 0, metaState: 0) }
    }

    case injectKeycode(action: KeyAction, keycode: UInt32, repeatCount: UInt32, metaState: UInt32)

    case touch(action: MotionAction, pointer: UInt64, position: Position, pressure: Float, actionButton: UInt32, buttons: UInt32)
    case scroll(position: Position, horizontal: Float, vertical: Float, buttons: UInt32)
    case getClipboard(copyKey: CopyKey)
    /// With `paste`, the device presses Paste once its clipboard has the text. A `sequence`
    /// other than 0 asks for an acknowledgment.
    case setClipboard(sequence: UInt64, paste: Bool, text: String)
    /// Turns the device's screen off or on; mirroring goes on.
    case setDisplayPower(on: Bool)
    case uhidCreate(id: UInt16, vendor: UInt16, product: UInt16, name: String, descriptor: [UInt8])
    case uhidInput(id: UInt16, report: [UInt8])

    /// The message as the server reads it: a type byte, then big-endian fields.
    var bytes: [UInt8] {
        var b: [UInt8] = []
        func u16(_ v: UInt16) { b += [UInt8(v >> 8), UInt8(truncatingIfNeeded: v)] }
        func u32(_ v: UInt32) { u16(UInt16(v >> 16)); u16(UInt16(truncatingIfNeeded: v)) }
        func u64(_ v: UInt64) { u32(UInt32(v >> 32)); u32(UInt32(truncatingIfNeeded: v)) }
        func position(_ p: Position) {
            u32(UInt32(bitPattern: p.x))
            u32(UInt32(bitPattern: p.y))
            u16(p.width)
            u16(p.height)
        }
        switch self {
        case let .injectKeycode(action, keycode, repeatCount, metaState):
            b = [0, action.rawValue]
            u32(keycode)
            u32(repeatCount)
            u32(metaState)
        case let .touch(action, pointer, p, pressure, actionButton, buttons):
            b = [2, action.rawValue]
            u64(pointer)
            position(p)
            // 16-bit fixed point, where 1 would overflow and becomes 0xffff.
            u16(UInt16(min(UInt32(pressure * 0x1p16), 0xffff)))
            u32(actionButton)
            u32(buttons)
        case let .scroll(p, horizontal, vertical, buttons):
            b = [3]
            position(p)
            // -16 to 16 as signed 16-bit fixed point of -1 to 1, where 1 becomes 0x7fff.
            for amount in [horizontal, vertical] {
                let fixed = min(Int32(min(max(amount / 16, -1), 1) * 0x1p15), 0x7fff)
                u16(UInt16(bitPattern: Int16(fixed)))
            }
            u32(buttons)
        case let .getClipboard(copyKey):
            b = [8, copyKey.rawValue]
        case let .setClipboard(sequence, paste, text):
            b = [9]
            u64(sequence)
            b.append(paste ? 1 : 0)
            let utf8 = Self.clipboardBytes(text)
            u32(UInt32(utf8.count))
            b += utf8
        case let .setDisplayPower(on):
            b = [10, on ? 1 : 0]
        case let .uhidCreate(id, vendor, product, name, descriptor):
            b = [12]
            u16(id)
            u16(vendor)
            u16(product)
            b.append(UInt8(name.utf8.count))
            b += name.utf8
            u16(UInt16(descriptor.count))
            b += descriptor
        case let .uhidInput(id, report):
            b = [13]
            u16(id)
            u16(UInt16(report.count))
            b += report
        }
        return b
    }

    /// The UTF-8 of a clipboard text as the device gets it: what fills a 256 KiB message after
    /// its 14-byte header at most, cut before a character that does not fit whole, as scrcpy
    /// cuts it (control_msg.h, str.c).
    static func clipboardBytes(_ text: String) -> ArraySlice<UInt8> {
        let utf8 = Array(text.utf8)
        var end = min(utf8.count, (1 << 18) - 14)
        while end < utf8.count, utf8[end] & 0xc0 == 0x80 { end -= 1 }
        return utf8[..<end]
    }
}

/// Reads what the server sends on the control socket until the connection ends: the device's
/// clipboard text each time it changes (`onClipboard`), and the keyboard's LED reports
/// (`onLEDs`).
nonisolated func receiveDeviceMessages(_ fd: Int32, onClipboard: (String) -> Void, onLEDs: (UInt8) -> Void) throws {
    func read(_ count: Int) -> [UInt8]? {
        var bytes = [UInt8](repeating: 0, count: count)
        return bytes.withUnsafeMutableBytes { receive(fd, $0) } ? bytes : nil
    }
    func number(_ bytes: [UInt8]) -> Int { bytes.reduce(0) { $0 << 8 | Int($1) } }
    // The server never cuts a message short: the device disconnected, as between messages.
    while let type = read(1) {
        switch type[0] {
        case 0: // clipboard: text length, text
            guard let length = read(4).map(number) else { return }
            // The server cuts texts to fit 256 KiB with the header (DeviceMessageWriter.java).
            guard length <= (1 << 18) - 5 else { throw Failure("clipboard text from the device too long (\(length) bytes)") }
            guard let text = read(length) else { return }
            onClipboard(String(decoding: text, as: UTF8.self))
        case 1: // clipboard change acknowledged: sequence number
            guard read(8) != nil else { return }
        case 2: // UHID output report: device id, report size, report
            guard let id = read(2), let size = read(2), let report = read(number(size)) else { return }
            if number(id) == Int(HIDKeyboard.id), let leds = report.first { onLEDs(leds) }
        default:
            throw Failure("unknown message from the device (type \(type[0]))")
        }
    }
}

/// Keeps a Mac pasteboard in step with the device's clipboard, reading the pasteboard only to
/// paste: macOS may ask the user before an app reads it at other times (NSPasteboard's
/// AccessBehavior). Its change count tells instead whether it still has the device's text.
struct ClipboardSync {
    /// The text the pasteboard and the device last shared, and the pasteboard's change count then.
    private var shared: (text: String, changeCount: Int)?

    /// The pasteboard's text for the device to paste, or nil if it has none.
    mutating func textToPaste(from pasteboard: NSPasteboard) -> String? {
        guard let text = pasteboard.string(forType: .string) else { return nil }
        // As the device gets it, so that its echo matches.
        shared = (String(decoding: ControlMessage.clipboardBytes(text), as: UTF8.self), pasteboard.changeCount)
        return text
    }

    /// Puts the device's new clipboard text on the pasteboard, unless the pasteboard still has
    /// it, e.g. when the device echoes a paste: the Mac's copy may be richer, such as styled
    /// text. An emptied device clipboard leaves the Mac's alone.
    mutating func copyDeviceText(_ text: String, to pasteboard: NSPasteboard) {
        guard !text.isEmpty else { return }
        if let shared, shared.text == text, shared.changeCount == pasteboard.changeCount { return }
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        shared = (text, pasteboard.changeCount)
    }
}

/// The keyboard scrcpy creates on the device through UHID (hid_keyboard.c): the keys held,
/// and the reports that bring the device to the Mac's state.
nonisolated struct HIDKeyboard {
    static let id: UInt16 = 1
    /// Modifier bits, a reserved byte and six keys of usages up to 0x65; five LEDs back.
    static let descriptor: [UInt8] = [
        0x05, 0x01, 0x09, 0x06, 0xA1, 0x01,
        0x05, 0x07, 0x19, 0xE0, 0x29, 0xE7, 0x15, 0x00, 0x25, 0x01, 0x75, 0x01, 0x95, 0x08, 0x81, 0x02,
        0x75, 0x08, 0x95, 0x01, 0x81, 0x01,
        0x05, 0x08, 0x19, 0x01, 0x29, 0x05, 0x75, 0x01, 0x95, 0x05, 0x91, 0x02,
        0x75, 0x03, 0x95, 0x01, 0x91, 0x01,
        0x05, 0x07, 0x19, 0x00, 0x29, 0x65, 0x15, 0x00, 0x25, 0x65, 0x75, 0x08, 0x95, 0x06, 0x81, 0x00,
        0xC0,
    ]
    /// No vendor, product or name, as scrcpy creates it.
    static let create = ControlMessage.uhidCreate(id: id, vendor: 0, product: 0, name: "", descriptor: descriptor)

    /// HID usages of the keys held down.
    var keys: Set<UInt8> = []
    /// Left Control, Shift, Option and Command, then the right ones.
    var modifiers: UInt8 = 0
    /// The device's Caps Lock: what the last sync press set, or what its LED reports tell since.
    var capsLock = false
    /// The last report sent: what the device has.
    private var sent = [UInt8](repeating: 0, count: 8)

    /// The reports to send for a key event; `keyCode` is nil when only modifiers changed. Like
    /// scrcpy, the device first gets a Caps Lock press whenever its Caps Lock differs from the
    /// Mac's. Command is the Mac's: while it is held the device gets only releases, so neither
    /// Command nor a key pressed with it reaches the device, and a key held from before is not
    /// left held there. The caller drops auto-repeats: the device repeats held keys itself, and
    /// a repeat of a key pressed with Command would press it once Command is up.
    mutating func reports(keyCode: UInt16?, down: Bool, flags: NSEvent.ModifierFlags) -> [[UInt8]] {
        let command = flags.contains(.command)
        var reports: [[UInt8]] = []
        if !command, flags.contains(.capsLock) != capsLock {
            capsLock.toggle()
            keys.insert(0x39)
            reports += changed(to: report)
            keys.remove(0x39)
        }
        if let keyCode, !(down && command) { set(hidUsage(keyCode: keyCode), down: down) }
        modifiers = command ? modifiers & hidModifiers(flags) : hidModifiers(flags)
        return reports + changed(to: report)
    }

    /// The report releasing every key, unless the device holds none.
    mutating func release() -> [[UInt8]] {
        keys = []
        modifiers = 0
        return changed(to: report)
    }

    private mutating func changed(to report: [UInt8]) -> [[UInt8]] {
        guard report != sent else { return [] }
        sent = report
        return [report]
    }

    /// Records a key press or release. Keys the descriptor has no usage for are ignored.
    mutating func set(_ usage: UInt8, down: Bool) {
        guard usage != 0, usage < 0x66 else { return }
        if down { keys.insert(usage) } else { keys.remove(usage) }
    }

    /// The input report: modifiers, a reserved byte, then the keys in usage order. More than
    /// six keys report ErrorRollOver in every slot.
    var report: [UInt8] {
        let slots = keys.count > 6 ? [UInt8](repeating: 1, count: 6)
            : keys.sorted() + [UInt8](repeating: 0, count: 6 - keys.count)
        return [modifiers, 0] + slots
    }
}

/// The HID usage of a Mac virtual key code, 0 for none, as SDL maps it for scrcpy.
nonisolated func hidUsage(keyCode: UInt16) -> UInt8 {
    var code = Int(keyCode)
    // ISO keyboards swap the codes of the keys left of 1 and right of the left Shift.
    if code == 10 || code == 50, KBGetLayoutType(Int16(LMGetKbdType())) == kKeyboardISO {
        code = 60 - code
    }
    return code < hidUsages.count ? hidUsages[code] : 0
}

/// SDL's table (scancodes_darwin.h): SDL scancodes are HID usages.
nonisolated let hidUsages: [UInt8] = [
    0x04, 0x16, 0x07, 0x09, 0x0B, 0x0A, 0x1D, 0x1B, 0x06, 0x19, 0x64, 0x05, 0x14, 0x1A, 0x08, 0x15,
    0x1C, 0x17, 0x1E, 0x1F, 0x20, 0x21, 0x23, 0x22, 0x2E, 0x26, 0x24, 0x2D, 0x25, 0x27, 0x30, 0x12,
    0x18, 0x2F, 0x0C, 0x13, 0x28, 0x0F, 0x0D, 0x34, 0x0E, 0x33, 0x31, 0x36, 0x38, 0x11, 0x10, 0x37,
    0x2B, 0x2C, 0x35, 0x2A, 0x58, 0x29, 0xE7, 0xE3, 0xE1, 0x39, 0xE2, 0xE0, 0xE5, 0xE6, 0xE4, 0xE7,
    0x6C, 0x63, 0x00, 0x55, 0x00, 0x57, 0x00, 0x53, 0x80, 0x81, 0x7F, 0x54, 0x58, 0x00, 0x56, 0x6D,
    0x6E, 0x67, 0x62, 0x59, 0x5A, 0x5B, 0x5C, 0x5D, 0x5E, 0x5F, 0x00, 0x60, 0x61, 0x89, 0x87, 0x85,
    0x3E, 0x3F, 0x40, 0x3C, 0x41, 0x42, 0x91, 0x44, 0x90, 0x46, 0x6B, 0x47, 0x00, 0x43, 0x65, 0x45,
    0x00, 0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x3D, 0x4D, 0x3B, 0x4E, 0x3A, 0x50, 0x4F, 0x51, 0x52, 0x66,
]

/// The HID modifier bits of a key event, read from its device-dependent flags as SDL reads
/// them for scrcpy.
nonisolated func hidModifiers(_ flags: NSEvent.ModifierFlags) -> UInt8 {
    // For bits 0 to 3: the left and right keys' device-dependent masks.
    let masks: [(left: UInt, right: UInt, either: NSEvent.ModifierFlags)] = [
        (0x0001, 0x2000, .control), (0x0002, 0x0004, .shift), (0x0020, 0x0040, .option), (0x0008, 0x0010, .command),
    ]
    var bits: UInt8 = 0
    for (i, m) in masks.enumerated() {
        var left = flags.rawValue & m.left != 0
        var right = flags.rawValue & m.right != 0
        // Events whose device-dependent flags disagree with the plain one, such as synthetic
        // ones, follow the plain one for both sides.
        let either = flags.contains(m.either)
        if either != (left || right) {
            left = either
            right = either
        }
        if left { bits |= 1 << i }
        if right { bits |= 1 << (i + 4) }
    }
    return bits
}

/// The video pixel under a point of a view showing the video letterboxed, computed exactly as
/// scrcpy computes it (screen.c): `x` and `y` are in points from the view's top-left corner.
nonisolated func videoPoint(_ x: Int32, _ y: Int32, view: (w: Int, h: Int), video: (w: Int, h: Int)) -> (x: Int32, y: Int32) {
    let (w, h, vw, vh) = (UInt32(view.w), UInt32(view.h), UInt32(video.w), UInt32(video.h))
    // The video fills the view if integer arithmetic finds the view's aspect ratio already
    // right; otherwise it is centered.
    var rect = (x: Float(0), y: Float(0), w: Float(w), h: Float(h))
    if h != w * vh / vw && w != h * vw / vh {
        if vw * h > vh * w {
            rect.h = Float(w) * Float(vh) / Float(vw)
            rect.y = (Float(h) - rect.h) / 2
        } else {
            rect.w = Float(h) * Float(vw) / Float(vh)
            rect.x = (Float(w) - rect.w) / 2
        }
    }
    return (
        Int32(Float(Int64(Float(x) - rect.x) * Int64(vw)) / rect.w),
        Int32(Float(Int64(Float(y) - rect.y) * Int64(vh)) / rect.h)
    )
}

/// The scroll amounts SDL gives scrcpy for a scroll event: a tenth of a trackpad's points, or
/// whole steps of a mouse wheel.
func scrollAmounts(_ event: NSEvent) -> (horizontal: Float, vertical: Float) {
    if event.hasPreciseScrollingDeltas {
        // SDL's factor is the float 0.1, applied in double.
        let tenth = Double(Float(0.1))
        return (Float(-event.scrollingDeltaX * tenth), Float(event.scrollingDeltaY * tenth))
    }
    return (Float((-event.deltaX).rounded(.awayFromZero)), Float(event.deltaY.rounded(.awayFromZero)))
}
