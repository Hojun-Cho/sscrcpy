import Foundation
import Observation

// All UI state lives in @Observable models rather than SwiftUI @State: in the macOS 27
// SDK @State is a macro whose plugin ships only with Xcode, and this project builds with
// the Command Line Tools alone.

@Observable final class AppModel {
    enum Screen { case devices, addDevice, settings }

    var screen = Screen.devices
    private(set) var tools: Toolchain?
    private(set) var devices: [Device] = []
    /// False until adb has answered once, so an empty list isn't shown while adb starts.
    private(set) var hasListed = false
    /// adb failure that affects the whole list.
    private(set) var listError: String?
    private(set) var sessions: [String: MirrorSession] = [:]
    /// Last failure per serial, shown in the device's row until the next action.
    private(set) var deviceErrors: [String: String] = [:]
    /// Names shown for devices, by serial (the phone's "Device name" setting).
    private var names: [String: String] = [:]

    let settings = Settings()

    // Add Device screen.
    var pairAddress = ""
    var pairCode = ""
    var connectAddress = UserDefaults.standard.string(forKey: "connectAddress") ?? ""
    private(set) var isAddingDevice = false
    private(set) var addDeviceError: String?

    @ObservationIgnored private var pollTask: Task<Void, Never>?
    /// Whether this app started the adb server; see quit().
    @ObservationIgnored private var startedADBServer = false
    /// Set by quit(). A Pair or Connect still running then ends with refreshDevices(), and
    /// any adb call after kill-server would start a new server.
    @ObservationIgnored private var quitting = false

    init(tools: Toolchain? = Toolchain.locate()) {
        self.tools = tools
    }

    // MARK: Popover lifecycle

    func popoverDidOpen() {
        if tools == nil { tools = Toolchain.locate() }
        pollTask?.cancel()
        pollTask = Task {
            while !Task.isCancelled {
                await refreshDevices()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    func popoverDidClose() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: Devices

    func name(of device: Device) -> String {
        names[device.serial] ?? device.model?.replacingOccurrences(of: "_", with: " ") ?? device.serial
    }

    func refreshDevices() async {
        guard !quitting else { return }
        guard let tools else {
            listError = "adb or sscrcpy-mirror was not found. Reinstall with: brew reinstall --cask sscrcpy"
            return
        }
        let adb = ADB(tools: tools)
        do {
            let list = try await adb.devices()
            devices = list.devices
            if list.startedServer { startedADBServer = true }
            hasListed = true
            listError = nil
        } catch {
            listError = error.localizedDescription
            return
        }
        for device in devices where device.isReady && names[device.serial] == nil {
            // The name is cosmetic: if the lookup fails, keep adb's model name
            // instead of asking again on every poll.
            names[device.serial] = (try? await adb.deviceName(of: device.serial)) ?? name(of: device)
        }
    }

    func toggleMirroring(_ device: Device) {
        let serial = device.serial
        if let session = sessions[serial] {
            session.stop()
            return
        }
        guard let tools else { return }
        deviceErrors[serial] = nil
        do {
            let arguments = ["--serial=\(serial)", "--window-title=\(name(of: device))"]
                + settings.scrcpyArguments()
            sessions[serial] = try MirrorSession(tools: tools, arguments: arguments) { [weak self] exit in
                self?.sessions[serial] = nil
                self?.deviceErrors[serial] = exit.message
            }
        } catch {
            deviceErrors[serial] = error.localizedDescription
        }
    }

    /// Stops mirroring, and the adb server if this app started it: macOS takes Local Network
    /// access away from the server when the app that started it quits, and the server would
    /// then stay unable to reach Wi-Fi devices.
    func quit() async {
        quitting = true
        sessions.values.forEach { $0.stop() }
        // Quit sits in the popover, so a poll is running, and its call in flight may be the one
        // starting the server.
        pollTask?.cancel()
        await pollTask?.value
        guard startedADBServer, let tools else { return }
        do {
            try await ADB(tools: tools).killServer()
        } catch {
            NSLog("adb kill-server failed: %@", error.localizedDescription)
        }
    }

    func disconnect(_ device: Device) async {
        guard let tools else { return }
        deviceErrors[device.serial] = nil
        do {
            try await ADB(tools: tools).disconnect(device.serial)
        } catch {
            deviceErrors[device.serial] = error.localizedDescription
        }
        await refreshDevices()
    }

    // MARK: Add Device

    /// Returns true once the phone is paired; adb then connects to it on its own.
    func pair() async -> Bool {
        let address = pairAddress.trimmingCharacters(in: .whitespaces)
        let code = pairCode.trimmingCharacters(in: .whitespaces)
        guard address.contains(":") else {
            addDeviceError = "Enter the IP address and port shown with the pairing code, e.g. 192.168.0.10:37123."
            return false
        }
        // Full-width digits pass isNumber but fail adb's password check.
        guard !code.isEmpty, code.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            addDeviceError = "The pairing code is the number shown on the phone."
            return false
        }
        let paired = await addDevice { try await $0.pair(address, code: code) }
        if paired { pairCode = "" }
        return paired
    }

    /// Returns true once the device is connected.
    func connect() async -> Bool {
        let address = connectAddress.trimmingCharacters(in: .whitespaces)
        guard !address.isEmpty else { return false }
        return await addDevice {
            try await $0.connect(address)
            UserDefaults.standard.set(address, forKey: "connectAddress")
        }
    }

    func restartADB() async {
        _ = await addDevice { try await $0.killServer() }
    }

    private func addDevice(_ action: (ADB) async throws -> Void) async -> Bool {
        guard let tools else { return false }
        isAddingDevice = true
        addDeviceError = nil
        var succeeded = false
        do {
            try await action(ADB(tools: tools))
            succeeded = true
        } catch {
            addDeviceError = error.localizedDescription
        }
        isAddingDevice = false
        await refreshDevices()
        return succeeded
    }
}
