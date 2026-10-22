import MoorboxCore
import SwiftUI

@main
struct MoorboxApp: App {
    @State private var model = AppModel()
    @NSApplicationDelegateAdaptor private var appDelegate: AppDelegate

    var body: some Scene {
        Window("Moorbox", id: "main") {
            ContentView()
                .environment(model)
                .frame(minWidth: 900, minHeight: 560)
                .modifier(WindowOpenerRegistration(model: model, delegate: appDelegate))
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

        // One window per running device (embedded display).
        WindowGroup("Device", id: "player", for: String.self) { $deviceID in
            if let deviceID {
                PlayerView(deviceID: deviceID)
                    .environment(model)
            }
        }
        .defaultSize(width: 440, height: 900)
        .windowResizability(.contentMinSize)

        Settings {
            SettingsView().environment(model)
        }
    }
}

/// Gives the model SwiftUI's window opener so any start path can show the player window.
private struct WindowOpenerRegistration: ViewModifier {
    let model: AppModel
    let delegate: AppDelegate
    @Environment(\.openWindow) private var openWindow

    func body(content: Content) -> some View {
        content.onAppear {
            model.openPlayerWindow = { openWindow(id: "player", value: $0) }
            delegate.model = model
        }
    }
}

/// Devices shown in Moorbox's own window have no emulator window, so they are stopped
/// gracefully (snapshot saved) when Moorbox quits instead of running on unseen.
final class AppDelegate: NSObject, NSApplicationDelegate {
    weak var model: AppModel?

    func applicationShouldTerminate(_: NSApplication) -> NSApplication.TerminateReply {
        guard let model = MainActor.assumeIsolated({ model }),
              MainActor.assumeIsolated({ model.hasEmbeddedLaunchesRunning }) else { return .terminateNow }
        Task { @MainActor in
            await model.stopEmbeddedDevicesForQuit()
            NSApp.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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

/// Sheet heights that fit the current display (sheets with scrolling content shrink on
/// small screens instead of putting their buttons off-screen).
@MainActor
func fittingSheetHeight(_ ideal: CGFloat, minimum: CGFloat = 360) -> CGFloat {
    let available = (NSScreen.main?.visibleFrame.height ?? ideal + 120) - 120
    return max(minimum, min(ideal, available))
}

extension Int64 {
    var bytes: String {
        ByteCountFormatter.string(fromByteCount: self, countStyle: .file)
    }
}
