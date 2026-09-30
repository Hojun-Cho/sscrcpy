import Testing
@testable import sscrcpy

@Suite struct DeviceListTests {
    @Test func parsesUSBWirelessAndUnauthorizedDevices() throws {
        let output = """
        * daemon not running; starting now at tcp:5037
        * daemon started successfully
        List of devices attached
        R5CT31ABCDE            device usb:1-1 product:dm3qksx model:SM_S918N device:dm3q transport_id:1
        192.168.0.23:5555      device product:husky model:Pixel_8_Pro device:husky transport_id:2
        ZY22H7KQ9P             unauthorized usb:2-1 transport_id:3
        adb-3A241FDJH000GR-vWgJpq._adb-tls-connect._tcp device product:shiba model:Pixel_8 device:shiba transport_id:4

        """
        let devices = try parseDevices(output)
        #expect(devices.map(\.serial) == [
            "R5CT31ABCDE", "192.168.0.23:5555", "ZY22H7KQ9P",
            "adb-3A241FDJH000GR-vWgJpq._adb-tls-connect._tcp",
        ])
        #expect(devices.map(\.state) == ["device", "device", "unauthorized", "device"])
        #expect(devices.map(\.model) == ["SM_S918N", "Pixel_8_Pro", nil, "Pixel_8"])
        #expect(devices.map(\.isWireless) == [false, true, false, true])
        #expect(devices.map(\.isReady) == [true, true, false, true])
    }

    @Test func serialsMayContainSpaces() throws {
        let output = """
        List of devices attached
        adb-0123456789AB-CDdefg (2)._adb-tls-connect._tcp device product:PongEEA model:A065 device:Pong transport_id:74
        12345678               device 3-1 product:x model:y device:z transport_id:5
        """
        let devices = try parseDevices(output)
        #expect(devices.map(\.serial) == ["adb-0123456789AB-CDdefg (2)._adb-tls-connect._tcp", "12345678"])
        #expect(devices.map(\.model) == ["A065", "y"])
        #expect(devices[0].isWireless)
    }

    @Test func emptyListHasNoDevices() throws {
        #expect(try parseDevices("List of devices attached\n\n").isEmpty)
    }

    @Test func outputWithoutHeaderIsAnError() {
        #expect(throws: ADBError.self) {
            try parseDevices("adb: failed to check server version: cannot connect to daemon")
        }
    }

    @Test func addressShowsSerialForMDNSConnections() {
        let mdns = Device(serial: "adb-3A241FDJH000GR-vWgJpq._adb-tls-connect._tcp", state: "device")
        #expect(mdns.address == "3A241FDJH000GR")
        let tcp = Device(serial: "192.168.0.23:5555", state: "device")
        #expect(tcp.address == "192.168.0.23:5555")
    }
}

@Suite struct MirrorExitTests {
    private func exit(_ status: Int32, _ output: String = "", signal: Bool = false, stopped: Bool = false) -> MirrorExit {
        MirrorExit(status: status, killedBySignal: signal, stopRequested: stopped, output: output)
    }

    @Test func normalEndsHaveNoMessage() {
        #expect(exit(0).message == nil)
        #expect(exit(15, signal: true, stopped: true).message == nil)
        #expect(exit(0, stopped: true).message == nil)
        // A disconnect shows in the device list; a message would outlive the reconnect.
        #expect(exit(2, "WARN: Device disconnected").message == nil)
    }

    @Test func failureWhileStoppingIsShown() {
        // The client could not leave the phone in order.
        #expect(exit(1, "ERROR: the phone did not go to sleep within 15 seconds", stopped: true).message
            == "the phone did not go to sleep within 15 seconds")
    }

    @Test func firstErrorLineIsShown() {
        let output = """
        scrcpy 4.1 <https://github.com/Genymobile/scrcpy>
        INFO: ADB device found:
        [server] ERROR: Could not open camera
        ERROR: Server connection failed
        """
        #expect(exit(1, output).message == "Could not open camera")
        #expect(exit(1, "ERROR: Could not find any ADB device\n").message == "Could not find any ADB device")
    }

    @Test func fallsBackToSignalOrStatus() {
        #expect(exit(1, "[server] INFO: Device: [samsung] SM-G525F (Android 13)\n").message == "sscrcpy-mirror exited with status 1.")
        #expect(exit(9, signal: true).message == "sscrcpy-mirror stopped unexpectedly (signal 9).")
    }
}
