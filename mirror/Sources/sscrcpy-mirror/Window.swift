import AppKit
import AVFoundation

/// The window showing the device screen. It keeps the video's aspect ratio, follows
/// rotation, passes the mouse and the keyboard to the device, shares the clipboard with it,
/// plays its audio, and ends the program when it closes or the device disconnects.
final class MirrorWindow {
    private let server: Server
    private let window: NSWindow
    private let layer = AVSampleBufferDisplayLayer()
    private var videoSize: NSSize
    /// Mouse buttons held, as Android's button bits.
    private var buttons: UInt32 = 0
    /// The device's keyboard, or nil when keys are ignored.
    private var keyboard: HIDKeyboard?
    private var clipboard = ClipboardSync()
    private let turnScreenOff: Bool

    init(server: Server, options: Options, videoSize: NSSize) {
        self.server = server
        self.videoSize = videoSize
        keyboard = options.keyboard ? HIDKeyboard() : nil
        turnScreenOff = options.turnScreenOff
        layer.backgroundColor = .black
        let view = InputView()
        view.layer = layer
        view.wantsLayer = true
        // Hover moves while the window has the keyboard and the pointer is over the video, as
        // in scrcpy.
        view.addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseMoved, .activeInKeyWindow, .inVisibleRect], owner: view))
        let size = optimalSize(videoSize, content: videoSize, screen: NSScreen.main?.visibleFrame)
        window = NSWindow(
            contentRect: NSRect(origin: .zero, size: size),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = options.windowTitle ?? server.deviceName
        // No full screen: the green button zooms the window to the largest size the screen
        // allows at the video's aspect ratio, which leaves nothing beside the video.
        window.collectionBehavior = .fullScreenNone
        // The level SDL gives scrcpy's window on top.
        if options.alwaysOnTop { window.level = .floating }
        window.contentAspectRatio = videoSize
        window.contentView = view
        // The Edit menu's commands go to the first responder.
        window.makeFirstResponder(view)
        window.center()
        view.onMouse = { [unowned self] in mouse($0) }
        view.onCopy = { [unowned self] in send(.getClipboard(copyKey: $0)) }
        view.onPaste = { [unowned self] in
            // Sequence 0 asks for no acknowledgment.
            if let text = clipboard.textToPaste(from: .general) { send(.setClipboard(sequence: 0, paste: true, text: text)) }
        }
        let center = NotificationCenter.default
        center.addObserver(forName: NSWindow.willCloseNotification, object: window, queue: .main) { _ in
            MainActor.assumeIsolated { quit(0) }
        }
        // Key releases go to another window from now on.
        center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [self] _ in
            MainActor.assumeIsolated { releaseKeys() }
        }
    }

    /// Shows the window and the video, plays the audio and starts passing input.
    func start() {
        window.makeKeyAndOrderFront(nil)
        if keyboard != nil {
            send(HIDKeyboard.create)
        }
        // Keys go to the device or nowhere: neither the Mac's input method nor AppKit (key
        // equivalents, beeps) sees them. Key presses with Command are the Mac's instead: they go
        // on to the menus (Copy, Paste, Quit...). Repeats go nowhere: the device repeats the
        // keys it holds, a key pressed with Command is not one of them, and a menu command acts
        // once per press, as in scrcpy.
        NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { [self] event in
            if event.type == .keyDown, event.isARepeat { return nil }
            // The app gets keys even without a key window, e.g. when it is minimized.
            if window.isKeyWindow { key(event) }
            return event.type == .keyDown && event.modifierFlags.contains(.command) ? event : nil
        }
        // The renderer, unlike the layer, accepts frames from any thread.
        nonisolated(unsafe) let renderer = layer.sampleBufferRenderer
        let video = server.video
        startReader { [self] in
            try receiveVideo(video, to: renderer) { width, height in
                DispatchQueue.main.async { self.resize(to: NSSize(width: width, height: height)) }
            }
        }
        if let audio = server.audio {
            startReader { try receiveAudio(audio, play: startOutput) }
        }
        let control = server.control
        startReader { [self] in
            try receiveDeviceMessages(control) { text in
                DispatchQueue.main.async { self.clipboard.copyDeviceText(text, to: .general) }
            } onLEDs: { leds in
                DispatchQueue.main.async { self.keyboard?.capsLock = leds & 0x02 != 0 }
            }
        }
        // Once the video is on its way, as scrcpy does. The server has woken the screen first if
        // it was off, and turns it back on when it ends.
        if turnScreenOff {
            send(.setDisplayPower(on: false))
        }
    }

    /// Runs `receive` on its own thread. The program exits with status 2 when it returns (the
    /// device disconnected), 1 when it fails.
    private func startReader(_ receive: @escaping @Sendable () throws -> Void) {
        let reader = Thread {
            do {
                try receive()
                DispatchQueue.main.async { quit(2) }
            } catch {
                DispatchQueue.main.async { fail(error) }
            }
        }
        reader.qualityOfService = .userInteractive
        reader.start()
    }

    /// Writes a message to the device. A failed write means the device disconnected.
    private func send(_ message: ControlMessage) {
        guard message.bytes.withUnsafeBytes({ sendAll(server.control, $0) }) else { quit(2) }
    }

    /// Passes a mouse event on as scrcpy does with every button bound to itself: buttons and
    /// motion become touch events of the mouse pointer, the wheel scroll events.
    private func mouse(_ event: NSEvent) {
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp:
            // Left, right, middle, back and forward: bits 0 to 4 of Android's buttons too.
            guard event.buttonNumber < 5 else { return }
            let button = UInt32(1) << event.buttonNumber
            let down = [.leftMouseDown, .rightMouseDown, .otherMouseDown].contains(event.type)
            buttons = down ? buttons | button : buttons & ~button
            send(.touch(
                action: down ? .down : .up, pointer: ControlMessage.mouse, position: position(event.locationInWindow),
                pressure: down ? 1 : 0, actionButton: button, buttons: buttons
            ))
        case .scrollWheel:
            // No inertia after the fingers lift: SDL turns momentum events off for scrcpy.
            guard event.momentumPhase.isEmpty else { return }
            let (horizontal, vertical) = scrollAmounts(event)
            guard horizontal != 0 || vertical != 0 else { return }
            send(.scroll(position: position(event.locationInWindow), horizontal: horizontal, vertical: vertical, buttons: buttons))
        default:
            // Moved or dragged. macOS 26 can put wrong positions in motion events; the
            // pointer's current position is right, and SDL reads that one too.
            let point = window.convertPoint(fromScreen: NSEvent.mouseLocation)
            send(.touch(
                action: buttons == 0 ? .hoverMove : .move, pointer: ControlMessage.mouse, position: position(point),
                pressure: 1, actionButton: 0, buttons: buttons
            ))
        }
    }

    /// The position on the video of a point of the window, as scrcpy computes it from SDL's
    /// window coordinates: points from the top-left corner, truncated to integers.
    private func position(_ point: NSPoint) -> Position {
        let view = window.contentView!
        let p = view.convert(point, from: nil)
        let size = (w: Int(view.bounds.width), h: Int(view.bounds.height))
        let video = (w: Int(videoSize.width), h: Int(videoSize.height))
        let (x, y) = videoPoint(Int32(p.x), Int32(Double(size.h) - p.y), view: size, video: video)
        return Position(x: x, y: y, width: UInt16(video.w), height: UInt16(video.h))
    }

    private func key(_ event: NSEvent) {
        let keyCode = event.type == .flagsChanged ? nil : event.keyCode
        for report in keyboard?.reports(keyCode: keyCode, down: event.type == .keyDown, flags: event.modifierFlags) ?? [] {
            send(.uhidInput(id: HIDKeyboard.id, report: report))
        }
    }

    private func releaseKeys() {
        for report in keyboard?.release() ?? [] {
            send(.uhidInput(id: HIDKeyboard.id, report: report))
        }
    }

    private func resize(to new: NSSize) {
        guard new != videoSize else { return }
        let old = videoSize
        videoSize = new
        fit(from: old)
    }

    /// Follows rotation as scrcpy does: scales the window by the change of the video size,
    /// keeping its top-left corner, then keeps it on its screen.
    private func fit(from old: NSSize) {
        let current = window.contentRect(forFrameRect: window.frame).size
        let scaled = NSSize(
            width: Int(current.width) * Int(videoSize.width) / Int(old.width),
            height: Int(current.height) * Int(videoSize.height) / Int(old.height)
        )
        let visible = window.screen?.visibleFrame
        let size = optimalSize(scaled, content: videoSize, screen: visible)
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: size))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        if let visible {
            frame.origin.x = min(frame.origin.x, visible.maxX - frame.width)
            frame.origin.y = max(frame.origin.y, visible.minY)
        }
        window.contentAspectRatio = videoSize
        window.setFrame(frame, display: true)
    }
}

/// The window's content: the video, the mouse events on it, and the Edit menu's commands,
/// which act on the device's clipboard.
final class InputView: NSView {
    var onMouse: (NSEvent) -> Void = { _ in }
    var onCopy: (CopyKey) -> Void = { _ in }
    var onPaste: () -> Void = {}

    override var acceptsFirstResponder: Bool { true }
    @objc func copy(_ sender: Any?) { onCopy(.copy) }
    @objc func cut(_ sender: Any?) { onCopy(.cut) }
    @objc func paste(_ sender: Any?) { onPaste() }

    // The click that brings the window forward reaches the device too, as in scrcpy.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) { onMouse(event) }
    override func mouseUp(with event: NSEvent) { onMouse(event) }
    override func rightMouseDown(with event: NSEvent) { onMouse(event) }
    override func rightMouseUp(with event: NSEvent) { onMouse(event) }
    override func otherMouseDown(with event: NSEvent) { onMouse(event) }
    override func otherMouseUp(with event: NSEvent) { onMouse(event) }
    override func mouseMoved(with event: NSEvent) { onMouse(event) }
    override func mouseDragged(with event: NSEvent) { onMouse(event) }
    override func rightMouseDragged(with event: NSEvent) { onMouse(event) }
    override func otherMouseDragged(with event: NSEvent) { onMouse(event) }
    override func scrollWheel(with event: NSEvent) { onMouse(event) }
}

/// The window content size scrcpy chooses: the largest size up to `size` (in points) that
/// keeps the aspect ratio of `content` and fits `screen` with a 96-point margin.
func optimalSize(_ size: NSSize, content: NSSize, screen: NSRect?) -> NSSize {
    var width = Int(size.width)
    var height = Int(size.height)
    if let screen {
        width = min(width, Int(screen.width) - 96)
        height = min(height, Int(screen.height) - 96)
    }
    let (w, h) = (Int(content.width), Int(content.height))
    if w * height > h * width {
        return NSSize(width: width, height: h * width / w)
    }
    return NSSize(width: w * height / h, height: height)
}
