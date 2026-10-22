import MoorboxCore
import SwiftUI

struct DevicesView: View {
    @Environment(AppModel.self) private var model
    @State private var pendingDelete: VirtualDevice?
    @State private var renaming: VirtualDevice?

    var body: some View {
        @Bindable var model = model
        Group {
            if !model.isRuntimeReady {
                ContentUnavailableView {
                    Label("Android Emulator not set up", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text(model.sdkHealth?.problems.first ?? "No Android SDK was found on this Mac.")
                } actions: {
                    Button("Open Setup Assistant") { model.showSetup = true }.buttonStyle(.borderedProminent)
                }
            } else if model.devices.isEmpty {
                ContentUnavailableView {
                    Label("No virtual devices", systemImage: "iphone.gen3.slash")
                } description: {
                    Text(model.installedImages.isEmpty
                        ? "Install an Android version first, then create a device."
                        : "Create a device to run Android.")
                } actions: {
                    Button("New Device…") { model.showCreate = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                HStack(spacing: 0) {
                    List(model.devices, selection: $model.selectedDeviceID) { device in
                        DeviceRow(device: device)
                            .tag(device.id)
                            .accessibilityElement(children: .contain)
                            .accessibilityIdentifier("device.\(device.id)")
                            .contextMenu { menu(for: device) }
                    }
                    .frame(width: 330)
                    Divider()
                    Group {
                        if let device = model.selectedDevice {
                            DeviceInspector(device: device)
                        } else {
                            ContentUnavailableView(
                                "Select a device",
                                systemImage: "sidebar.right",
                                description: Text("Its status, controls and hardware settings appear here.")
                            )
                        }
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
                .onAppear {
                    if model.selectedDeviceID == nil {
                        model.selectedDeviceID = model.devices.first?.id
                    }
                }
            }
        }
        .navigationTitle("Devices")
        .toolbar {
            // Always available: the sheet explains anything that's missing.
            Button { model.showCreate = true } label: { Label("New Device", systemImage: "plus") }
                .help("Create a virtual device")
        }
        .confirmationDialog("Delete “\(pendingDelete?.displayName ?? "")”?", isPresented: Binding(
            get: { pendingDelete != nil }, set: {
                if !$0 {
                    pendingDelete = nil
                }
            }
        ), presenting: pendingDelete) { device in
            Button("Move to Trash", role: .destructive) { model.delete(device) }
        } message: { device in
            let size = AVDStore.diskUsage(of: device.directory).bytes
            Text(device.hasUserData
                ? """
                This device has data: installed apps, files and settings (\(size)). It will be moved to the \
                Trash, where you can still recover it.
                """
                : "The device will be moved to the Trash.")
        }
        .sheet(item: $renaming) { device in
            RenameSheet(device: device) { model.rename(device, to: $0) }
        }
    }

    @ViewBuilder
    func menu(for device: VirtualDevice) -> some View {
        let state = model.state(of: device)
        if state == .starting {
            Button("Cancel Start") { model.cancelStart(device) }
        } else if state.isActive {
            Button("Stop") { model.stop(device) }
            Button("Restart") { model.restart(device) }.disabled(state.serial == nil)
            Button("Force Stop") { model.forceStop(device) }
        } else {
            Button("Start") { model.start(device) }
            Button("Cold Boot") { model.start(device, coldBoot: true) }
        }
        Divider()
        Button("Rename…") { renaming = device }
        Button("Reset Quick Boot") { model.resetQuickBoot(device) }
            .disabled(state.isActive || !device.hasQuickBootSnapshot)
        Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([device.directory]) }
        Divider()
        Button("Delete…", role: .destructive) { pendingDelete = device }.disabled(state.isActive)
    }
}

struct RenameSheet: View {
    @Environment(\.dismiss) private var dismiss
    let device: VirtualDevice
    let rename: (String) -> Void
    @State private var name = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Rename Device").font(.headline)
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(commit)
                .accessibilityIdentifier("rename.name")
            Text("Only the display name changes; the device’s files and data stay where they are.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Rename", action: commit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .padding(20)
        .frame(width: 380)
        .onAppear { name = device.displayName }
    }

    func commit() {
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        rename(name)
        dismiss()
    }
}

struct StateBadge: View {
    let state: DeviceState

    var body: some View {
        HStack(spacing: 5) {
            switch state {
            case .starting, .booting, .stopping: ProgressView().controlSize(.mini)
            default: Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(state.label).font(.callout).foregroundStyle(.secondary)
        }
        .accessibilityElement(children: .combine)
    }

    var color: Color {
        switch state {
        case .running: .green
        case .failed: .red
        default: .secondary.opacity(0.5)
        }
    }
}

struct DeviceRow: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice

    var body: some View {
        let state = model.state(of: device)
        HStack(spacing: 12) {
            Image(systemName: device.config["hw.initialOrientation"] == "landscape" ? "ipad.landscape" : "iphone.gen3")
                .font(.title)
                .foregroundStyle(state.serial != nil ? Color.accentColor : .secondary)
                .frame(width: 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.displayName).font(.headline)
                Text([device.androidVersionName, device.tagDisplay].compactMap(\.self).joined(separator: " · "))
                    .font(.subheadline).foregroundStyle(.secondary)
                StateBadge(state: state)
            }
            Spacer()
            switch state {
            case .stopped, .failed:
                Button("Start") { model.start(device) }
                    .help("Start using quick boot when a snapshot is available")
            case let .running(serial), let .booting(serial):
                if model.instances.contains(where: { serial == "emulator-\($0.consolePort)" && $0.grpcToken != nil }) {
                    Button("Show") { model.openPlayerWindow?(device.id) }
                        .help("Show this device’s window")
                }
                Button("Stop") { model.stop(device) }
            case .starting:
                Button("Cancel") { model.cancelStart(device) }
                    .help("Stop an emulator that hasn't finished starting")
            case .stopping:
                Button("Stop") {}.disabled(true)
            }
        }
        .padding(.vertical, 4)
    }
}

struct DeviceInspector: View {
    @Environment(AppModel.self) private var model
    let device: VirtualDevice
    @State private var ram = 2048
    @State private var cores = 2
    @State private var gpu = GPUMode.auto

    var body: some View {
        let state = model.state(of: device)
        let limits = ResourceLimits.compute(host: model.host, apiLevel: device.apiLevel ?? "0")
        Form {
            Section {
                LabeledContent("Status") { StateBadge(state: state) }
                if case let .failed(diagnosis) = state {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(diagnosis.summary).foregroundStyle(.red)
                        if !diagnosis.remedy.isEmpty {
                            Text(diagnosis.remedy).font(.callout)
                        }
                    }
                }
                if let serial = state.serial {
                    LabeledContent("adb serial", value: serial).textSelection(.enabled)
                }
                LabeledContent("Quick boot", value: device.hasQuickBootSnapshot ? "Snapshot saved" : "Cold boot next")
            }
            Section("Controls") {
                HStack {
                    control("rotate.right", "Rotate (⌘→)") { model.rotate(device) }
                    control("camera", "Screenshot to Desktop (⇧⌘S)") { model.screenshot(device) }
                    control("chevron.backward", "Back (⌘[)") { model.press(.back, on: device) }
                    control("circle", "Home (⇧⌘H)") { model.press(.home, on: device) }
                    control("square.on.square", "Recent apps") { model.press(.recents, on: device) }
                }
                .disabled(state.serial == nil)
                Text("Location, battery, sensors and network conditions are in the emulator window's “…” extended controls.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Hardware") {
                LabeledContent("Android", value: device.androidVersionName)
                LabeledContent("System image", value: device.systemImageDirectory ?? "—")
                LabeledContent("Screen", value: device.resolution ?? "—")
                Picker("Memory", selection: $ram) {
                    ForEach(memoryOptions(limits), id: \.self) { Text("\($0 / 1024) GB").tag($0) }
                }
                Stepper("CPU cores: \(cores)", value: $cores, in: limits.cores)
                Picker("Graphics", selection: $gpu) {
                    ForEach(GPUMode.allCases) { Text($0.label).tag($0) }
                }
                Button("Apply") { model.updateResources(device, ramMB: ram, cores: cores, gpu: gpu) }
                    .disabled(state.isActive || (ram == device.ramMB && cores == device.cores && gpu.rawValue == device.config["hw.gpu.mode"]))
                if state.isActive {
                    Text("Stop the device to change its hardware.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear(perform: load)
        .onChange(of: device) { load() }
    }

    func load() {
        ram = device.ramMB ?? 2048
        cores = device.cores ?? 2
        gpu = GPUMode(rawValue: device.config["hw.gpu.mode"] ?? "auto") ?? .auto
    }

    func memoryOptions(_ limits: ResourceLimits) -> [Int] {
        Array(Set(stride(from: limits.ramMB.lowerBound, through: limits.ramMB.upperBound, by: 1024)).union([ram])).sorted()
    }

    func control(_ icon: String, _ help: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: icon).frame(width: 22, height: 18) }
            .help(help)
            .accessibilityLabel(help)
    }
}
