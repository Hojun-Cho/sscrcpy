import SwiftUI

struct AddDeviceView: View {
    @Bindable var model: AppModel

    var body: some View {
        Form {
            // Prompts are hints, not sample values: a grouped Form draws them where values go.
            Section {
                TextField("Address", text: $model.pairAddress, prompt: Text("IP address:port"))
                TextField("Code", text: $model.pairCode, prompt: Text("6 digits"))
                    .onSubmit(pair)
                actionRow("Pair", action: pair)
                    .disabled(model.pairAddress.isEmpty || model.pairCode.isEmpty)
            } header: {
                Text("Pair (Android 11+)")
            } footer: {
                Text("On the phone: Developer options › Wireless debugging › Pair device with pairing code. Enter the code while it is shown. Once paired, the phone connects on its own.")
            }

            Section {
                TextField("Address", text: $model.connectAddress, prompt: Text("IP address:port"))
                    .onSubmit(connect)
                actionRow("Connect", action: connect)
                    .disabled(model.connectAddress.isEmpty)
            } header: {
                Text("Connect")
            } footer: {
                Text("If a paired phone doesn't appear, use the IP address & port shown under Wireless debugging.")
            }

            if model.isAddingDevice {
                Section {
                    ProgressView().controlSize(.small).frame(maxWidth: .infinity)
                }
            } else if let error = model.addDeviceError {
                Section {
                    Label(error, systemImage: "xmark.octagon.fill")
                        .foregroundStyle(.red)
                        .font(.callout)
                    if error.contains(ADB.reachabilityHint) {
                        HStack {
                            Spacer()
                            Button("Restart adb") { Task { await model.restartADB() } }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
        .disabled(model.isAddingDevice)
    }

    private func actionRow(_ title: String, action: @escaping () -> Void) -> some View {
        HStack {
            Spacer()
            Button(title, action: action)
                .buttonStyle(.borderedProminent)
        }
    }

    private func pair() {
        Task {
            if await model.pair() { model.show(.devices) }
        }
    }

    private func connect() {
        Task {
            if await model.connect() { model.show(.devices) }
        }
    }
}
