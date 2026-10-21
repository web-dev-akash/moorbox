import MoorboxCore
import SwiftUI

/// First-run guide. Every step reflects real detected state and calls the real operation.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirm: (package: RemotePackage, replacing: Bool)?
    @State private var createError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Moorbox").font(.largeTitle.bold())
                Text("Moorbox runs Android virtual devices on your Mac using Google’s official Android Emulator — without installing Android Studio or Java. It downloads only the parts you choose, straight from Google.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    systemStep
                    sdkStep
                    imageStep
                    deviceStep
                }
                .padding(24)
            }
            Divider()
            HStack {
                Text("Nothing is downloaded without your confirmation.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { model.setupCompleted = true; dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 640, height: 680)
        .onAppear { model.loadCatalog() }
        .sheet(isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            if let confirm { InstallSheet(package: confirm.package, replacing: confirm.replacing).environment(model) }
        }
    }

    // MARK: Steps

    var systemStep: some View {
        let h = model.host
        let disk = HostInfo.availableDiskSpace(at: model.effectiveSDKLocation) ?? 0
        return Step(number: 1, title: "Check this Mac", done: h.hypervisorSupported) {
            Check(ok: true, "macOS \(h.macOSVersion)")
            Check(ok: true, h.architecture == .arm64 ? "Apple Silicon — Android arm64 images run natively" : "Intel — x86_64 images (not yet verified on Intel)")
            Check(ok: h.physicalMemoryMB >= 8192, "\(h.physicalMemoryMB / 1024) GB memory" + (h.physicalMemoryMB < 8192 ? " — use the Lightweight preset" : ""))
            Check(ok: disk > 16 * 1_073_741_824, "\(disk.bytes) free" + (disk < 16 * 1_073_741_824 ? " — each Android version needs 2–6 GB" : ""))
            Check(ok: h.hypervisorSupported, h.hypervisorSupported ? "Hardware acceleration available" : "Hardware acceleration unavailable (running inside a VM?). Android will not run.")
            if h.isTranslated { Check(ok: false, "Moorbox is running under Rosetta; use the native build for best results.") }
        }
    }

    @ViewBuilder
    var sdkStep: some View {
        let arch = model.host.architecture
        let emulator = model.catalog?.latestStable("emulator", for: arch)
        let tools = model.catalog?.latestStable("platform-tools", for: arch)
        let health = model.sdkHealth
        Step(number: 2, title: "Android Emulator", done: model.isRuntimeReady) {
            if let sdk = model.sdk {
                Text("Using the Android SDK at \(sdk.root.path)").font(.callout).textSelection(.enabled)
            } else {
                Text("No Android SDK found. Components will be installed to \(model.effectiveSDKLocation.path), the standard location shared with Android Studio.")
                    .font(.callout)
            }
            component("Android Emulator", installed: health?.emulatorRevision, latest: emulator,
                      ok: health.map { !$0.emulatorArchitectures.isEmpty && $0.emulatorArchitectures.contains(arch) } ?? false)
            component("Platform tools (adb)", installed: model.sdk?.platformToolsRevision, latest: tools, ok: health?.adbPresent ?? false)
            if model.catalog == nil {
                if let error = model.catalogError {
                    Text(error).foregroundStyle(.red).font(.callout)
                    Button("Try Again") { model.loadCatalog(force: true) }
                } else {
                    ProgressView("Checking Google’s SDK repository…").controlSize(.small)
                }
            }
            Button("Use Another SDK Folder…") { chooseSDK() }.buttonStyle(.link)
        }
    }

    @ViewBuilder
    func component(_ name: String, installed: Revision?, latest: RemotePackage?, ok: Bool) -> some View {
        HStack {
            Check(ok: ok, installed.map { "\(name) \($0)" } ?? "\(name) — not installed")
            Spacer()
            if let latest {
                if model.installs[latest.path] != nil {
                    InstallButton(package: latest) { confirm = (latest, installed != nil) }
                } else if installed == nil || !ok {
                    Button("Install (\((latest.archive(for: model.host.architecture)?.size ?? 0).bytes))…") { confirm = (latest, installed != nil) }
                } else if let installed, installed < latest.revision {
                    Button("Update to \(latest.revision.description)…") { confirm = (latest, true) }
                }
            }
        }
    }

    @ViewBuilder
    var imageStep: some View {
        let recommended = model.catalog?.recommendedSystemImage(for: model.host.architecture)
        Step(number: 3, title: "Android version", done: !model.installedImages.isEmpty) {
            if model.installedImages.isEmpty {
                if let recommended {
                    PackageRow(package: recommended, isRecommended: true) { confirm = (recommended, false) }
                    Text("Other versions, including Play Store images and previews, are in Android Versions.")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Available versions appear once the repository has loaded.").foregroundStyle(.secondary)
                }
            } else {
                ForEach(model.installedImages) { Check(ok: true, "\($0.displayName) — \($0.tagDisplay)") }
            }
        }
        .disabled(!model.isRuntimeReady)
    }

    @ViewBuilder
    var deviceStep: some View {
        Step(number: 4, title: "Create and start a device", done: !model.devices.isEmpty) {
            if let device = model.devices.first {
                HStack {
                    Check(ok: true, "\(model.devices.count) device\(model.devices.count == 1 ? "" : "s"), e.g. \(device.displayName)")
                    Spacer()
                    let state = model.state(of: device)
                    if state.isActive { StateBadge(state: state) } else {
                        Button("Start \(device.displayName)") { model.start(device) }.buttonStyle(.borderedProminent)
                    }
                }
            } else if let image = model.installedImages.first {
                Text("Creates a phone with the Balanced preset (\(model.host.cpuCount > 6 ? "4 cores" : "2 cores"), \(ResourceLimits.compute(host: model.host, apiLevel: image.apiLevel).clamp(.balanced).ramMB / 1024) GB). You can change this later.")
                    .font(.callout)
                Button("Create Phone with \(image.displayName)") { quickCreate(image) }.buttonStyle(.borderedProminent)
                if let createError { Text(createError).foregroundStyle(.red) }
            }
        }
        .disabled(model.installedImages.isEmpty || !model.isRuntimeReady)
    }

    func quickCreate(_ image: InstalledSystemImage) {
        let limits = ResourceLimits.compute(host: model.host, apiLevel: image.apiLevel)
        let spec = DeviceSpec(displayName: "\(AndroidVersion.shortName(apiLevel: image.apiLevel)) Phone", image: image,
                              profile: DeviceProfile.all[0], resources: limits.clamp(.balanced))
        do { _ = try model.create(spec) } catch { createError = error.localizedDescription }
    }

    func chooseSDK() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Choose an existing Android SDK folder, or an empty folder to install into."
        if panel.runModal() == .OK, let url = panel.url { model.sdkPathOverride = url.path }
    }
}

struct Step<Content: View>: View {
    let number: Int
    let title: String
    let done: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle().fill(done ? Color.green : Color.accentColor.opacity(0.15)).frame(width: 28, height: 28)
                if done { Image(systemName: "checkmark").foregroundStyle(.white).bold() } else { Text("\(number)").bold() }
            }
            .accessibilityLabel(done ? "Step \(number), complete" : "Step \(number)")
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.title3.bold())
                content
            }
            Spacer(minLength: 0)
        }
    }
}

struct Check: View {
    let ok: Bool
    let text: String
    init(ok: Bool, _ text: String) { self.ok = ok; self.text = text }

    var body: some View {
        Label {
            Text(text)
        } icon: {
            Image(systemName: ok ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .foregroundStyle(ok ? .green : .orange)
        }
    }
}
