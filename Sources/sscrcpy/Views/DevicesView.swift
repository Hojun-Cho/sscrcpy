import SwiftUI

struct DevicesView: View {
    let model: AppModel

    var body: some View {
        if !model.devices.isEmpty {
            ScrollView {
                VStack(spacing: 8) {
                    if let error = model.listError {
                        Label(error, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    ForEach(model.devices) { device in
                        DeviceRow(model: model, device: device)
                    }
                }
                .padding(12)
            }
        } else if let error = model.listError {
            ContentUnavailableView {
                Label("Can't List Devices", systemImage: "exclamationmark.triangle")
            } description: {
                Text(error)
            }
        } else if !model.hasListed {
            ProgressView("Starting adb…")
                .controlSize(.small)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            ContentUnavailableView {
                Label("No Devices", systemImage: "smartphone")
            } description: {
                Text("Connect a phone with a USB cable and allow USB debugging, or add one over Wi-Fi.")
            } actions: {
                Button("Add Wi-Fi Device") { model.show(.addDevice) }
            }
        }
    }
}

private struct DeviceRow: View {
    let model: AppModel
    let device: Device

    private var isMirroring: Bool { model.sessions[device.serial] != nil }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: device.isWireless ? "wifi" : "cable.connector")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 30, height: 30)
                .background(device.isWireless ? Color.green : Color.blue, in: RoundedRectangle(cornerRadius: 7))
            VStack(alignment: .leading, spacing: 2) {
                Text(model.name(of: device))
                    .fontWeight(.medium)
                    .lineLimit(1)
                status
                    .font(.caption)
                    .lineLimit(3)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 4)
            if device.isWireless && !isMirroring {
                // Offline Wi-Fi devices too: adb keeps retrying them until disconnected.
                IconButton("wifi.slash", help: "Disconnect") {
                    Task { await model.disconnect(device) }
                }
            }
            Button(isMirroring ? "Stop" : "Mirror") { model.toggleMirroring(device) }
                .buttonStyle(.borderedProminent)
                .tint(isMirroring ? .red : .accentColor)
                .disabled(!(device.isReady || isMirroring))
        }
        .padding(10)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }

    @ViewBuilder private var status: some View {
        if let error = model.deviceErrors[device.serial] {
            Text(error).foregroundStyle(.red)
        } else if isMirroring {
            Text("Mirroring").foregroundStyle(.green)
        } else {
            switch device.state {
            case "device":
                Text("\(device.isWireless ? "Wi-Fi" : "USB") · \(device.address)").foregroundStyle(.secondary)
            case "unauthorized":
                Text("Allow USB debugging on the phone").foregroundStyle(.orange)
            case "authorizing", "connecting":
                Text("Connecting…").foregroundStyle(.secondary)
            default:
                Text(device.state.capitalized).foregroundStyle(.secondary)
            }
        }
    }
}
