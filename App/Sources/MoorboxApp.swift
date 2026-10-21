import MoorboxCore
import SwiftUI

@main
struct MoorboxApp: App {
    @State private var model = AppModel()

    var body: some Scene {
        Window("Moorbox", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Device…") { model.showCreate = true }
                    .keyboardShortcut("n")
            }
            CommandGroup(after: .appInfo) {
                Button("Setup Assistant…") { model.showSetup = true }
            }
            DeviceCommands(model: model)
        }

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// The Device menu acts on the device selected in the Devices list.
struct DeviceCommands: Commands {
    let model: AppModel

    var body: some Commands {
        CommandMenu("Device") {
            let device = model.selectedDevice
            let state = device.map(model.state(of:))
            let running = state?.serial != nil
            Button(state == .starting ? "Cancel Start" : state?.isActive == true ? "Stop" : "Start") {
                guard let device else { return }
                if state == .starting {
                    model.cancelStart(device)
                } else if state?.isActive == true {
                    model.stop(device)
                } else {
                    model.start(device)
                }
            }
            .keyboardShortcut("r")
            .disabled(device == nil || state == .stopping)
            Button("Cold Boot") { device.map { model.start($0, coldBoot: true) } }
                .keyboardShortcut("r", modifiers: [.command, .shift])
                .disabled(device == nil || state?.isActive == true)
            Button("Restart") { device.map(model.restart) }
                .disabled(!running)
            Divider()
            Button("Rotate") { device.map(model.rotate) }
                .keyboardShortcut(.rightArrow, modifiers: [.command])
                .disabled(!running)
            Button("Take Screenshot") { device.map(model.screenshot) }
                .keyboardShortcut("s", modifiers: [.command, .shift])
                .disabled(!running)
            Divider()
            Button("Home") { device.map { model.press(.home, on: $0) } }
                .keyboardShortcut("h", modifiers: [.command, .shift])
                .disabled(!running)
            Button("Back") { device.map { model.press(.back, on: $0) } }
                .keyboardShortcut("[", modifiers: [.command])
                .disabled(!running)
            Button("Recent Apps") { device.map { model.press(.recents, on: $0) } }
                .disabled(!running)
        }
    }
}

enum SidebarItem: String, CaseIterable, Identifiable {
    case devices = "Devices", versions = "Android Versions", apps = "App Installer", diagnostics = "Diagnostics"
    var id: String {
        rawValue
    }

    var icon: String {
        switch self {
        case .devices: "iphone.gen3"
        case .versions: "square.stack.3d.down.right"
        case .apps: "shippingbox"
        case .diagnostics: "stethoscope"
        }
    }
}

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            List(SidebarItem.allCases, selection: $model.section) { s in
                Label(s.rawValue, systemImage: s.icon).tag(s)
                    .accessibilityIdentifier("sidebar.\(String(describing: s))")
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
        } detail: {
            switch model.section ?? .devices {
            case .devices: DevicesView()
            case .versions: VersionsView()
            case .apps: AppInstallerView()
            case .diagnostics: DiagnosticsView()
            }
        }
        .sheet(isPresented: $model.showSetup) { SetupView().environment(model) }
        .sheet(isPresented: $model.showCreate) { CreateDeviceView().environment(model) }
        .alert("Moorbox", isPresented: Binding(get: { model.alertMessage != nil }, set: {
            if !$0 {
                model.alertMessage = nil
            }
        })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
    }
}

extension Int64 {
    var bytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
