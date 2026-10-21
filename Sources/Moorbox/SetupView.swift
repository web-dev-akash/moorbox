import MoorboxCore
import SwiftUI

/// First-run guide. Every step reflects real detected state and calls the real operation,
/// and nothing is installed without the user confirming what, where and under which license.
struct SetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var confirm: (package: RemotePackage, replacing: Bool)?
    @State private var confirmJDK = false
    @State private var createError: String?
    @State private var creating = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Moorbox").font(.largeTitle.bold())
                Text("Moorbox runs Android virtual devices on your Mac with Google’s official Android Emulator and SDK tools, without Android Studio. It asks before downloading anything, and downloads only from Google and Eclipse Adoptium.")
                    .foregroundStyle(.secondary)
            }
            .padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    systemStep
                    toolsStep
                    javaStep
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
        .frame(width: 660, height: 720)
        .onAppear { model.loadCatalog() }
        .sheet(isPresented: Binding(get: { confirm != nil }, set: { if !$0 { confirm = nil } })) {
            if let confirm { InstallSheet(package: confirm.package, replacing: confirm.replacing).environment(model) }
        }
        .sheet(isPresented: $confirmJDK) { JDKInstallSheet().environment(model) }
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
    var toolsStep: some View {
        let arch = model.host.architecture
        let catalog = model.catalog
        let tools = catalog?.latestStable(CommandLineToolsInstaller.packagePath, for: arch)
        let emulator = catalog?.latestStable("emulator", for: arch)
        let platformTools = catalog?.latestStable("platform-tools", for: arch)
        let health = model.sdkHealth
        Step(number: 2, title: "Android SDK tools", done: model.isRuntimeReady && model.hasCommandLineTools) {
            if let sdk = model.sdk {
                Text("Using the Android SDK at \(sdk.root.path)").font(.callout).textSelection(.enabled)
            } else {
                Text("No Android SDK found. Components will be installed to \(model.effectiveSDKLocation.path), the standard location shared with Android Studio.")
                    .font(.callout)
            }
            component("Command-line tools (Android CLI, avdmanager)", installed: health?.commandLineToolsRevision, latest: tools,
                      ok: model.hasCommandLineTools, enabled: true)
            component("Android Emulator", installed: health?.emulatorRevision, latest: emulator,
                      ok: health.map { $0.emulatorArchitectures.contains(arch) } ?? false, enabled: model.hasCommandLineTools)
            component("Platform tools (adb)", installed: model.sdk?.platformToolsRevision, latest: platformTools,
                      ok: health?.adbPresent ?? false, enabled: model.hasCommandLineTools)
            if !model.hasCommandLineTools {
                Text("Moorbox uses Google’s own tools to install packages and create devices, so install the command-line tools first.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if catalog == nil {
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
    func component(_ name: String, installed: Revision?, latest: RemotePackage?, ok: Bool, enabled: Bool) -> some View {
        HStack {
            Check(ok: ok, installed.map { "\(name) \($0)" } ?? "\(name) — not installed")
            Spacer()
            if let latest {
                if model.installs[latest.path] != nil {
                    InstallButton(package: latest) { confirm = (latest, installed != nil) }
                } else if installed == nil || !ok {
                    Button("Install (\((latest.archive(for: model.host.architecture)?.size ?? 0).bytes))…") { confirm = (latest, installed != nil) }
                        .disabled(!enabled)
                } else if let installed, installed < latest.revision {
                    Button("Update to \(latest.revision.description)…") { confirm = (latest, true) }
                        .disabled(!enabled)
                }
            }
        }
    }

    @ViewBuilder
    var javaStep: some View {
        Step(number: 3, title: "Java runtime (for creating devices)", done: model.java != nil) {
            if let java = model.java {
                Check(ok: true, "Java \(java.version) — \(java.source.rawValue)")
                Text(java.home.path).font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            } else if !model.javaChecked {
                ProgressView("Looking for a Java runtime…").controlSize(.small)
            } else if let progress = model.installs[AppModel.jdkInstallKey] {
                JDKProgressView(progress: progress)
            } else {
                Check(ok: false, "No Java 17 or newer found")
                Text("Google’s avdmanager, which creates devices, needs Java. Moorbox looked in JAVA_HOME, Android Studio, and macOS’s Java registry. Running existing devices doesn’t need Java.")
                    .font(.callout)
                HStack {
                    Button("Install Eclipse Temurin…") { confirmJDK = true }
                    Button("Check Again") { model.locateJava() }
                }
            }
        }
    }

    @ViewBuilder
    var imageStep: some View {
        let recommended = model.catalog?.recommendedSystemImage(for: model.host.architecture)
        Step(number: 4, title: "Android version", done: !model.installedImages.isEmpty) {
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
        .disabled(!model.isRuntimeReady || !model.hasCommandLineTools)
    }

    @ViewBuilder
    var deviceStep: some View {
        Step(number: 5, title: "Create and start a device", done: !model.devices.isEmpty) {
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
                let ram = ResourceLimits.compute(host: model.host, apiLevel: image.apiLevel).clamp(.balanced).ramMB
                Text("Creates a Medium Phone (Google’s generic profile) with the Balanced preset (\(ram / 1024) GB). You can change this later.")
                    .font(.callout)
                HStack {
                    Button("Create Phone with \(image.displayName)") { quickCreate(image) }
                        .buttonStyle(.borderedProminent)
                        .disabled(creating || model.java == nil)
                    if creating { ProgressView().controlSize(.small) }
                }
                if let createError { Text(createError).foregroundStyle(.red).textSelection(.enabled) }
            }
        }
        .disabled(model.installedImages.isEmpty || !model.isRuntimeReady || !model.hasCommandLineTools)
    }

    func quickCreate(_ image: InstalledSystemImage) {
        let limits = ResourceLimits.compute(host: model.host, apiLevel: image.apiLevel)
        let spec = DeviceSpec(displayName: "\(AndroidVersion.shortName(apiLevel: image.apiLevel)) Phone", image: image,
                              profileID: "medium_phone", resources: limits.clamp(.balanced))
        creating = true
        createError = nil
        Task {
            do { _ = try await model.create(spec) } catch { createError = error.localizedDescription }
            creating = false
        }
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

/// Consent for downloading a JDK: what, from where, where to, and under which license.
struct JDKInstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        let destination = JavaLocator.managedRoot(applicationSupport: AppModel.supportDirectory)
        VStack(alignment: .leading, spacing: 12) {
            Text("Install Eclipse Temurin JDK").font(.title2.bold())
            Text("Google’s avdmanager needs Java 17 or newer to create devices. Eclipse Temurin is a free, open-source build of OpenJDK from the Eclipse Adoptium project.")
            if let release = model.jdkRelease {
                Grid(alignment: .leading, verticalSpacing: 4) {
                    GridRow { Text("Version").foregroundStyle(.secondary); Text("Temurin \(release.version)") }
                    GridRow { Text("Download").foregroundStyle(.secondary); Text(release.size.bytes) }
                    GridRow { Text("Source").foregroundStyle(.secondary); Text("github.com/adoptium (SHA-256 verified)") }
                    GridRow { Text("Destination").foregroundStyle(.secondary); Text(destination.path).textSelection(.enabled) }
                    GridRow { Text("License").foregroundStyle(.secondary); Link(Adoptium.licenseName, destination: Adoptium.licenseURL) }
                }
                Text("Installed for your user only: no administrator password, nothing system-wide, and Moorbox uses it only to run avdmanager.")
                    .font(.callout).foregroundStyle(.secondary)
            } else if let error = model.jdkError {
                Text(error).foregroundStyle(.red)
            } else {
                ProgressView("Looking up the latest Temurin release…").controlSize(.small)
            }
            Text("Prefer to manage Java yourself? Install any JDK 17+ (for example from adoptium.net), then click Check Again.")
                .font(.caption).foregroundStyle(.secondary)
            Spacer()
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Download & Install") {
                    if let release = model.jdkRelease { model.installJDK(release) }
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(model.jdkRelease == nil)
            }
        }
        .padding(20)
        .frame(width: 600, height: 380)
        .onAppear { model.loadJDKRelease() }
    }
}

struct JDKProgressView: View {
    @Environment(AppModel.self) private var model
    let progress: InstallProgress

    var body: some View {
        if let error = progress.error {
            VStack(alignment: .leading) {
                Text(error).foregroundStyle(.red).font(.callout)
                Button("Dismiss") { model.dismissInstallError(AppModel.jdkInstallKey) }
            }
        } else {
            HStack {
                switch progress.phase {
                case let .downloading(received, total):
                    ProgressView(value: Double(received), total: Double(max(total, 1))).frame(width: 160)
                    Text("Downloading Temurin… \(received.bytes) of \(total.bytes)").font(.caption).monospacedDigit()
                case .verifying: ProgressView().controlSize(.small); Text("Verifying…").font(.caption)
                case .extracting: ProgressView().controlSize(.small); Text("Installing…").font(.caption)
                case .finished: EmptyView()
                }
                Button("Cancel") { model.cancelInstall(AppModel.jdkInstallKey) }
            }
        }
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
