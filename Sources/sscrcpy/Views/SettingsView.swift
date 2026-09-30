import SwiftUI

struct SettingsView: View {
    @Bindable var settings: Settings

    var body: some View {
        Form {
            Section {
                Picker("Resolution", selection: $settings.maxSize) {
                    Text("Device").tag(0)
                    ForEach([2560, 1920, 1600, 1280, 1024, 800], id: \.self) { Text("\($0) px").tag($0) }
                }
                Picker("Bit rate", selection: $settings.videoBitRateMbps) {
                    ForEach([2, 4, 8, 16, 32], id: \.self) { Text("\($0) Mbps").tag($0) }
                }
                Picker("Frame rate", selection: $settings.maxFps) {
                    Text("Device").tag(0)
                    ForEach([30, 60, 90, 120], id: \.self) { Text("\($0) fps").tag($0) }
                }
                Toggle("Play phone audio on this Mac", isOn: $settings.audio)
            } header: {
                Text("Mirroring")
            } footer: {
                Text("Changes apply the next time you start mirroring.")
            }

            Section("Phone") {
                Toggle("Keep awake while plugged in", isOn: $settings.stayAwake)
                Toggle("Turn screen off", isOn: $settings.turnScreenOff)
                Toggle("Show touches", isOn: $settings.showTouches)
            }

            Section {
                Toggle("Physical keyboard", isOn: $settings.physicalKeyboard)
            } header: {
                Text("Keyboard")
            } footer: {
                Text("Needed to type from this Mac, in any language. Switch the input language on the phone's keyboard.")
            }

            Section("Window") {
                Toggle("Always on top", isOn: $settings.alwaysOnTop)
            }

            Section {
                HStack {
                    Spacer()
                    Button("Quit sscrcpy") { NSApp.terminate(nil) }
                }
            }
        }
        .formStyle(.grouped)
        .scrollContentBackground(.hidden)
    }
}
