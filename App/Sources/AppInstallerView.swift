import MoorboxCore
import SwiftUI
import UniformTypeIdentifiers

struct AppInstallerView: View {
    @Environment(AppModel.self) private var model
    @State private var serial: String?
    @State private var busy: String?
    @State private var results: [(id: UUID, ok: Bool, text: String)] = []
    @State private var packages: [String] = []
    @State private var dropTargeted = false
    @State private var showImporter = false
    @State private var logcat: String?
    @State private var uninstallTarget: String?

    var body: some View {
        let running = model.runningDevices
        VStack(spacing: 0) {
            if running.isEmpty {
                ContentUnavailableView(
                    "No running device",
                    systemImage: "iphone.slash",
                    description: Text("Start a device in Devices. APKs install onto a running device.")
                )
            } else {
                Form {
                    Picker("Device", selection: $serial) {
                        ForEach(running, id: \.serial) { item in
                            Text(verbatim: item.device.displayName + " (" + item.serial + ")").tag(String?.some(item.serial))
                        }
                    }
                    Section("Install an APK") {
                        dropZone
                        ForEach(results, id: \.id) { r in
                            Label(r.text, systemImage: r.ok ? "checkmark.circle.fill" : "xmark.octagon.fill")
                                .foregroundStyle(r.ok ? .green : .red)
                                .textSelection(.enabled)
                        }
                    }
                    Section {
                        if packages.isEmpty {
                            Text("No user-installed apps.").foregroundStyle(.secondary)
                        }
                        ForEach(packages, id: \.self) { pkg in
                            HStack {
                                Text(pkg).textSelection(.enabled)
                                Spacer()
                                Button("Open") { run("Opening \(pkg)") { try await $0.launch(pkg, serial: $1); return "Opened \(pkg)." } }
                                Button("Uninstall…") { uninstallTarget = pkg }
                            }
                            .disabled(busy != nil)
                        }
                    } header: {
                        HStack {
                            Text("Installed apps")
                            Spacer()
                            Button("Refresh") { reloadPackages() }.buttonStyle(.link)
                        }
                    }
                }
                .formStyle(.grouped)
            }
        }
        .navigationTitle("App Installer")
        .toolbar {
            Button { showImporter = true } label: { Label("Choose APK…", systemImage: "doc.badge.plus") }
                .disabled(serial == nil || busy != nil)
            Button { loadLogcat() } label: { Label("Logcat", systemImage: "text.alignleft") }
                .disabled(serial == nil)
                .help("Show the last 500 lines of the device log")
        }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data]) { result in
            if case let .success(url) = result {
                install(url)
            }
        }
        .onAppear { serial = serial ?? running.first?.serial; reloadPackages() }
        .onChange(of: running.map(\.serial)) { _, serials in
            if !serials.contains(where: { $0 == serial }) {
                serial = serials.first
            }
        }
        .onChange(of: serial) { reloadPackages() }
        .sheet(item: Binding(get: { logcat.map(LogText.init) }, set: { logcat = $0?.text })) { log in
            LogSheet(title: "Logcat (last 500 lines)", text: log.text)
        }
        .confirmationDialog("Uninstall \(uninstallTarget ?? "")?", isPresented: Binding(
            get: { uninstallTarget != nil }, set: {
                if !$0 {
                    uninstallTarget = nil
                }
            }
        ), presenting: uninstallTarget) { pkg in
            Button("Uninstall", role: .destructive) {
                run("Uninstalling \(pkg)") { try await $0.uninstall(pkg, serial: $1); return "Uninstalled \(pkg)." }
            }
        } message: { _ in Text("The app and its data will be removed from the device.") }
    }

    var dropZone: some View {
        VStack(spacing: 6) {
            if let busy {
                ProgressView(busy)
            } else {
                Image(systemName: "arrow.down.app").font(.largeTitle).foregroundStyle(.secondary)
                Text("Drop an .apk here, or ")
                    + Text("choose a file…").foregroundStyle(Color.accentColor)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 110)
        .background(RoundedRectangle(cornerRadius: 10).strokeBorder(
            dropTargeted ? Color.accentColor : .secondary.opacity(0.4),
            style: StrokeStyle(lineWidth: 2, dash: [6])
        ))
        .contentShape(Rectangle())
        .onTapGesture {
            if busy == nil {
                showImporter = true
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first, busy == nil else { return false }
            install(url)
            return true
        } isTargeted: { dropTargeted = $0 }
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Drop an APK file here or choose a file")
    }

    func install(_ url: URL) {
        do { try ADB.validateAPK(url) } catch {
            results.insert((UUID(), false, error.localizedDescription), at: 0)
            return
        }
        let access = url.startAccessingSecurityScopedResource()
        run("Installing \(url.lastPathComponent)…") { adb, serial in
            defer {
                if access {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            _ = try await adb.install(url, serial: serial)
            return "Installed \(url.lastPathComponent)."
        }
    }

    func run(_ label: String, _ body: @escaping @Sendable (ADB, String) async throws -> String) {
        guard let adb = model.adb, let serial else { return }
        busy = label
        Task {
            do {
                let message = try await body(adb, serial)
                results.insert((UUID(), true, message), at: 0)
                model.log(.info, message)
            } catch {
                results.insert((UUID(), false, error.localizedDescription), at: 0)
                model.log(.error, error.localizedDescription)
            }
            if results.count > 20 {
                results.removeLast(results.count - 20)
            }
            busy = nil
            reloadPackages()
        }
    }

    func reloadPackages() {
        guard let adb = model.adb, let serial else { packages = []; return }
        Task { packages = await (try? adb.userPackages(serial: serial)) ?? [] }
    }

    func loadLogcat() {
        guard let adb = model.adb, let serial else { return }
        Task {
            do { logcat = try await adb.logcat(serial: serial) } catch { model.alertMessage = error.localizedDescription }
        }
    }
}

struct LogText: Identifiable {
    let id = UUID()
    let text: String
}

struct LogSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading) {
            Text(title).font(.headline)
            ScrollView {
                Text(text.isEmpty ? "(empty)" : text)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .defaultScrollAnchor(.bottom)
            HStack {
                Button("Copy") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding()
        .frame(width: 760, height: fittingSheetHeight(520))
    }
}
