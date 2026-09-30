import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let model = AppModel()
    private let popover = NSPopover()
    private var statusItem: NSStatusItem?
    private var monitors: [Any] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        if let button = item.button {
            button.image = NSImage(systemSymbolName: "smartphone", accessibilityDescription: "sscrcpy")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(togglePopover)
        }
        statusItem = item

        // A menu bar app never shows its main menu, but text fields take Cmd-C/V/X/A/Z from it.
        NSApp.mainMenu = editMenu()

        // Same content size as the Mullvad VPN window.
        popover.contentSize = NSSize(width: 320, height: 568)
        // .transient would close on mouse-down over the status item and then reopen on
        // mouse-up, so closing is handled here instead.
        popover.behavior = .applicationDefined
        popover.delegate = self
        let host = NSHostingController(rootView: RootView(model: model))
        host.sizingOptions = []
        popover.contentViewController = host

        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        Task {
            await model.quit()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }

    @objc private func togglePopover() {
        if popover.isShown {
            dismissPopover()
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem?.button else { return }
        // Activation lets text fields in the popover take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        popover.contentViewController?.view.window?.makeKey()

        monitors = [
            // Clicks in other apps close the popover, like the system's own menu bar panels.
            NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                self?.popover.performClose(nil)
            },
            NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard event.keyCode == 53 else { return event } // Esc
                self?.dismissPopover()
                return nil
            },
        ].compactMap { $0 }
        model.popoverDidOpen()
    }

    /// Closes the popover and gives keyboard focus back to the app that had it before.
    private func dismissPopover() {
        popover.performClose(nil)
        NSApp.hide(nil)
    }

    @objc private func appDidResignActive() {
        popover.performClose(nil)
    }

    // Every close ends here, including the ones AppKit starts on its own.
    func popoverDidClose(_ notification: Notification) {
        monitors.forEach(NSEvent.removeMonitor)
        monitors = []
        model.popoverDidClose()
    }

    private func editMenu() -> NSMenu {
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let item = NSMenuItem()
        item.submenu = edit
        let menu = NSMenu()
        menu.addItem(item)
        return menu
    }
}
