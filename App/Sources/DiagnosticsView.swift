import MoorboxCore
import SwiftUI
import UniformTypeIdentifiers

struct DiagnosticsView: View {
    @Environment(AppModel.self) private var model
    @State private var logDevice: VirtualDevice?
    @State private var adbStatus: String?
    @State private var adbConflicts: [ADB.OtherInstallation] = []

    var body: some View {
        Form {
            Section("This Mac") {
                LabeledContent("macOS", value: model.host.macOSVersion)
                LabeledContent("CPU", value: model.host.architecture == .arm64 ? "Apple Silicon (arm64)" : "Intel (x86_64)")
                LabeledContent("Memory", value: ByteCountFormatter.string(fromByteCount: Int64(model.host.physicalMemory), countStyle: .memory))
                LabeledContent("Free disk", value: HostInfo.availableDiskSpace(at: model.effectiveSDKLocation).map(\.bytes) ?? "unknown")
                LabeledContent("Hardware acceleration", value: model.host.hypervisorSupported ? "Available (Hypervisor.framework)" : "Unavailable")
            }
            Section("Android SDK") {
                LabeledContent("Location", value: model.sdk?.root.path ?? "Not found")
                LabeledContent("Command-line tools", value: model.sdkHealth?.commandLineToolsRevision.map { "\($0)" } ?? "Not installed")
                LabeledContent(
                    "Java (for avdmanager)",
                    value: model.java.map { "\($0.version) — \($0.source.rawValue)" } ?? (model.javaChecked ? "Not found" : "Checking…")
                )
                LabeledContent("Emulator", value: model.sdkHealth?.emulatorRevision.map { "\($0)" } ?? "Not installed")
                LabeledContent("platform-tools", value: model.sdk?.platformToolsRevision.map { "\($0)" } ?? "Not installed")
                LabeledContent("Devices folder", value: model.avdStore.home.path)
                LabeledContent("Emulator logs", value: AppModel.logDirectory.path)
                ForEach(model.sdkHealth?.problems ?? [], id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                }
                ForEach(adbConflicts, id: \.self) { other in
                    VStack(alignment: .leading, spacing: 2) {
                        Label("Another adb (\(other.version)) is installed at \(other.path).", systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text(
                            """
                            If both are used, they restart each other’s adb server and devices disconnect. Moorbox always \
                            uses the SDK’s adb; keep tools you run yourself on the same version (for example, update \
                            platform-tools here, or remove the other copy with `brew uninstall --cask \
                            android-platform-tools`).
                            """
                        )
                        .font(.caption).textSelection(.enabled)
                    }
                }
                HStack {
                    Button("Check adb connection") { checkADB() }
                    if let adbStatus {
                        Text(adbStatus).font(.callout).textSelection(.enabled)
                    }
                }
            }
            Section("Devices") {
                if model.devices.isEmpty {
                    Text("No devices.").foregroundStyle(.secondary)
                }
                ForEach(model.devices) { device in
                    let state = model.state(of: device)
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(device.displayName)
                            Spacer()
                            StateBadge(state: state)
                            Button("Emulator Log") { logDevice = device }
                        }
                        if case let .failed(d) = state {
                            Text(d.summary).foregroundStyle(.red)
                            Text(d.remedy).font(.callout)
                        }
                    }
                }
            }
            Section("Activity") {
                if model.events.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                ForEach(model.events.suffix(100).reversed()) { e in
                    HStack(alignment: .firstTextBaseline) {
                        Text(e.date, style: .time).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        Text(e.message).foregroundStyle(e.level == .error ? .red : e.level == .warning ? .orange : .primary)
                            .textSelection(.enabled)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Diagnostics")
        .toolbar {
            Button { model.refresh() } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            Button { exportReport() } label: { Label("Export Report…", systemImage: "square.and.arrow.up") }
                .help("Save a diagnostics report with personal paths and tokens redacted. Nothing is uploaded.")
        }
        .task {
            if let adb = model.adb {
                adbConflicts = await adb.conflictingInstallations()
            }
        }
        .sheet(item: $logDevice) { device in
            let url = model.runtime?.logFile(for: device)
            LogSheet(title: "Emulator log — \(device.displayName)", text: url.map { LogFiles.tail($0) } ?? "")
        }
    }

    func checkADB() {
        guard let adb = model.adb else { adbStatus = "adb is not installed."; return }
        adbStatus = "Checking…"
        Task {
            await model.ensureADBServer()
            do {
                let devices = try await adb.devices()
                adbStatus = devices.isEmpty ? "adb is running; no devices connected."
                    : devices.map { "\($0.serial): \($0.state)" }.joined(separator: ", ")
            } catch {
                adbStatus = error.localizedDescription
            }
        }
    }

    func exportReport() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Moorbox Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try Redactor.redact(model.diagnosticsReport()).write(to: url, atomically: true, encoding: .utf8)
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } catch {
            model.alertMessage = "Could not save the report: \(error.localizedDescription)"
        }
    }
}

extension AppModel {
    /// Plain-text report. The caller redacts it before saving.
    func diagnosticsReport() -> String {
        var lines = ["Moorbox diagnostics — \(Date())", ""]
        let rosetta = host.isTranslated ? " (Rosetta)" : ""
        lines.append("macOS \(host.macOSVersion), \(host.architecture.rawValue)\(rosetta), \(host.physicalMemoryMB) MB RAM, "
            + "\(host.cpuCount) cores, hypervisor: \(host.hypervisorSupported)")
        lines += [
            "SDK: \(sdk?.root.path ?? "not found")",
            "Command-line tools: \(sdkHealth?.commandLineToolsRevision.map { "\($0)" } ?? "none")",
            "Java: \(java.map { "\($0.version) (\($0.source.rawValue)) \($0.home.path)" } ?? "none")",
            "Emulator: \(sdkHealth?.emulatorRevision.map { "\($0)" } ?? "none") archs: \(sdkHealth?.emulatorArchitectures.map(\.rawValue).sorted() ?? [])",
            "Problems: \(sdkHealth?.problems ?? [])",
            "AVD home: \(avdStore.home.path)",
            "",
        ]
        lines += ["Installed images:"] + installedImages.map { "  \($0.packagePath) rev \($0.revision ?? "?")" }
        lines += ["", "Devices:"]
        for d in devices {
            let image = d.systemImageDirectory ?? "?", gpu = d.config["hw.gpu.mode"] ?? "?"
            lines.append("  \(d.id): \(state(of: d).label), image \(image), RAM \(d.ramMB ?? 0) MB, cores \(d.cores ?? 0), gpu \(gpu)")
        }
        lines += ["", "Running instances:"] + instances.map { "  pid \($0.pid) \($0.avdID) \($0.serial)" }
        lines += ["", "Recent activity:"] + events.suffix(100).map { "  \($0.date) \($0.message)" }
        for d in devices {
            guard let url = runtime?.logFile(for: d), FileManager.default.fileExists(atPath: url.path) else { continue }
            lines += ["", "--- Emulator log: \(d.id) (last 16 KB) ---", LogFiles.tail(url, maxBytes: 16 * 1024)]
        }
        return lines.joined(separator: "\n")
    }
}
