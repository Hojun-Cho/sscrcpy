import SwiftUI

/// The popover content: a header and one of three screens that slide in like Mullvad VPN's.
struct RootView: View {
    @Bindable var model: AppModel

    var body: some View {
        VStack(spacing: 0) {
            HeaderView(model: model)
            Divider()
            ZStack {
                switch model.screen {
                case .devices:
                    DevicesView(model: model)
                        .transition(.move(edge: .leading))
                case .addDevice:
                    AddDeviceView(model: model)
                        .transition(.move(edge: .trailing))
                case .settings:
                    SettingsView(settings: model.settings)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
        }
    }
}

extension AppModel {
    func show(_ screen: Screen) {
        withAnimation(.easeInOut(duration: 0.2)) { self.screen = screen }
    }
}

private struct HeaderView: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 6) {
            if model.screen == .devices {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable()
                    .frame(width: 22, height: 22)
                Text("sscrcpy")
                    .font(.headline)
                Spacer()
                if model.tools != nil {
                    IconButton("plus", help: "Add Wi-Fi Device") { model.show(.addDevice) }
                }
                IconButton("gearshape", help: "Settings") { model.show(.settings) }
            } else {
                IconButton("chevron.left", help: "Back") { model.show(.devices) }
                Text(model.screen == .addDevice ? "Add Wi-Fi Device" : "Settings")
                    .font(.headline)
                Spacer()
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 44)
    }
}

struct IconButton: View {
    let symbol: String
    let help: String
    let action: () -> Void

    init(_ symbol: String, help: String, action: @escaping () -> Void) {
        self.symbol = symbol
        self.help = help
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 14, weight: .medium))
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .buttonStyle(.borderless)
        .help(help)
        .accessibilityLabel(help)
    }
}
