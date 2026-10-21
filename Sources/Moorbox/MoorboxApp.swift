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
                    .disabled(model.installedImages.isEmpty)
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
                if state == .starting { model.cancelStart(device) }
                else if state?.isActive == true { model.stop(device) } else { model.start(device) }
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
    var id: String { rawValue }
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
        .alert("Moorbox", isPresented: Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        #if DEBUG
        .task { await UISnapshot.runIfRequested(model: model) }
        #endif
    }
}

#if DEBUG
/// Development aid: `MOORBOX_SNAPSHOT_DIR=/path swift run Moorbox` renders each screen of
/// the app's own windows to PNG and quits. Not compiled into release builds.
@MainActor enum UISnapshot {
    static func runIfRequested(model: AppModel) async {
        guard let dir = ProcessInfo.processInfo.environment["MOORBOX_SNAPSHOT_DIR"] else { return }
        if ProcessInfo.processInfo.environment["MOORBOX_SNAPSHOT_APPEARANCE"] == "light" { NSApp.appearance = NSAppearance(named: .aqua) }
        try? await Task.sleep(for: .seconds(3))
        capture(to: dir, name: "0-setup")
        model.showSetup = false
        try? await Task.sleep(for: .seconds(1))
        model.showCreate = true
        try? await Task.sleep(for: .seconds(2))
        capture(to: dir, name: "0-create")
        model.showCreate = false
        for item in SidebarItem.allCases {
            model.section = item
            try? await Task.sleep(for: .seconds(item == .versions ? 6 : 2))
            capture(to: dir, name: "\(SidebarItem.allCases.firstIndex(of: item)! + 1)-\(item.rawValue)")
        }
        // MOORBOX_SNAPSHOT_LIFECYCLE=1 also drives start → running → stop on the first device
        // through AppModel (use ANDROID_AVD_HOME to point at a scratch device folder).
        if ProcessInfo.processInfo.environment["MOORBOX_SNAPSHOT_LIFECYCLE"] == "1", let device = model.devices.first {
            model.section = .devices
            model.selectedDeviceID = device.id
            let t0 = Date()
            model.start(device)
            try? await Task.sleep(for: .milliseconds(300))
            capture(to: dir, name: "5-starting")
            while model.state(of: device).serial == nil, Date().timeIntervalSince(t0) < 180 { try? await Task.sleep(for: .milliseconds(250)) }
            capture(to: dir, name: "6-booting")
            while !isRunning(model.state(of: device)), Date().timeIntervalSince(t0) < 300 { try? await Task.sleep(for: .milliseconds(250)) }
            print("[snapshot] running after \(Date().timeIntervalSince(t0))s: \(model.state(of: device))")
            try? await Task.sleep(for: .seconds(2))
            capture(to: dir, name: "7-running")
            model.section = .apps
            try? await Task.sleep(for: .seconds(3))
            capture(to: dir, name: "8-apps-running")
            model.section = .devices
            if ProcessInfo.processInfo.environment["MOORBOX_SNAPSHOT_CRASH"] == "1",
               let instance = model.instances.first(where: { $0.avdID == device.id }) {
                // Simulate an emulator crash and check the app reports it without touching data.
                kill(instance.pid, SIGKILL)
                try? await Task.sleep(for: .seconds(3))
                print("[snapshot] after SIGKILL: \(model.state(of: device))")
                capture(to: dir, name: "9-crashed")
                print(model.events.map(\.message).joined(separator: "\n"))
                NSApp.terminate(nil)
                return
            }
            model.stop(device)
            let t1 = Date()
            while model.state(of: device) != .stopped, Date().timeIntervalSince(t1) < 120 { try? await Task.sleep(for: .milliseconds(250)) }
            print("[snapshot] stopped after \(Date().timeIntervalSince(t1))s: \(model.state(of: device))")
            capture(to: dir, name: "9-stopped")
            print(model.events.map(\.message).joined(separator: "\n"))
        }
        NSApp.terminate(nil)
    }

    static func isRunning(_ state: DeviceState) -> Bool {
        if case .running = state { return true }
        return false
    }

    static func capture(to dir: String, name: String) {
        for (i, window) in NSApp.windows.enumerated() where window.isVisible {
            guard let view = window.contentView?.superview ?? window.contentView,
                  let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
            view.cacheDisplay(in: view.bounds, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: URL(fileURLWithPath: "\(dir)/\(name)-\(i).png"))
        }
    }
}
#endif

extension Int64 {
    var bytes: String { ByteCountFormatter.string(fromByteCount: self, countStyle: .file) }
}
