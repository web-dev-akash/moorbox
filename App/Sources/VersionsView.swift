import MoorboxCore
import SwiftUI

struct VersionsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirm: RemotePackage?
    @State private var removing: InstalledSystemImage?

    var body: some View {
        @Bindable var model = model
        let arch = model.host.architecture
        let available = model.catalog?.systemImages(for: arch, includePreviews: true) ?? []
        let recommended = model.catalog?.recommendedSystemImage(for: arch)
        List {
            Section("Installed") {
                if model.installedImages.isEmpty {
                    Text("No Android system images installed yet.").foregroundStyle(.secondary)
                }
                ForEach(model.installedImages) { img in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(img.displayName).font(.headline)
                            Text("\(img.tagDisplay) · \(img.abi) · revision \(img.revision ?? "?")")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        let users = model.devices.filter { $0.systemImageDirectory == img.relativeDirectory }.count
                        if users > 0 {
                            Text("\(users) device\(users == 1 ? "" : "s")").foregroundStyle(.secondary)
                        }
                        Button("Remove…") { removing = img }
                    }
                }
            }
            if let error = model.catalogError {
                Section {
                    Label(error, systemImage: "wifi.exclamationmark").foregroundStyle(.red)
                    Button("Try Again") { model.loadCatalog(force: true) }
                }
            } else if model.catalog == nil {
                Section { ProgressView("Loading available versions from Google’s SDK repository…") }
            } else {
                Section {
                    ForEach(available.filter { $0.systemImage?.isPreview == false }) { p in
                        PackageRow(package: p, isRecommended: p == recommended) { confirm = p }
                    }
                } header: {
                    Text("Available for this Mac (\(arch.nativeAndroidABI))")
                } footer: {
                    let chip = arch == .arm64 ? "Apple Silicon" : "Intel"
                    Text("""
                    Only images that run natively on \(chip) are listed. “16 KB page size” images are for \
                    testing apps against 16 KB memory pages. Play Store images include proprietary Google apps \
                    under Google’s license.
                    """)
                    .font(.caption)
                }
                if model.showPreviews {
                    Section("Previews and betas") {
                        ForEach(available.filter { $0.systemImage?.isPreview == true }) { p in
                            PackageRow(package: p, isRecommended: false) { confirm = p }
                        }
                    }
                }
            }
        }
        .navigationTitle("Android Versions")
        .toolbar {
            Toggle("Show Previews", isOn: $model.showPreviews)
            Button { model.loadCatalog(force: true) } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                .disabled(model.isLoadingCatalog)
        }
        .onAppear { model.loadCatalog() }
        .sheet(item: $confirm) { InstallSheet(package: $0).environment(model) }
        .confirmationDialog("Remove \(removing?.displayName ?? "")?", isPresented: Binding(
            get: { removing != nil }, set: {
                if !$0 {
                    removing = nil
                }
            }
        ), presenting: removing) { img in
            Button("Move to Trash", role: .destructive) { model.removeImage(img) }
        } message: { img in
            let users = model.devices.filter { $0.systemImageDirectory == img.relativeDirectory }
            Text(users.isEmpty
                ? "The image will be moved to the Trash. You can download it again at any time."
                : "\(users.map(\.displayName).joined(separator: ", ")) use this image and won’t start until it’s reinstalled. Their data is not affected.")
        }
    }
}

struct PackageRow: View {
    @Environment(AppModel.self) private var model
    let package: RemotePackage
    let isRecommended: Bool
    let install: () -> Void

    var body: some View {
        if let img = package.systemImage {
            row(img)
        }
    }

    func row(_ img: SystemImageDetails) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(AndroidVersion.displayName(apiLevel: img.apiLevel, codename: img.codename)).font(.headline)
                    if isRecommended {
                        Text("Recommended").font(.caption.bold()).padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Color.accentColor.opacity(0.15), in: Capsule())
                    }
                }
                Text("\(img.tagDisplay) · \(img.abi) · rev \(package.revision.major) · \((package.archive(for: model.host.architecture)?.size ?? 0).bytes)")
                    .font(.subheadline).foregroundStyle(.secondary)
                if let req = model.emulatorRequirement(for: package) {
                    Text(req).font(.caption).foregroundStyle(.orange)
                }
            }
            Spacer()
            InstallButton(package: package, install: install)
        }
    }
}

struct InstallButton: View {
    @Environment(AppModel.self) private var model
    let package: RemotePackage
    let install: () -> Void

    var body: some View {
        if let progress = model.installs[package.path] {
            if let error = progress.error {
                VStack(alignment: .trailing) {
                    Text(error).font(.caption).foregroundStyle(.red).frame(maxWidth: 260, alignment: .trailing)
                    HStack {
                        Button("Dismiss") { model.dismissInstallError(package.path) }
                        Button("Retry") { model.dismissInstallError(package.path); install() }
                    }
                }
            } else {
                HStack {
                    switch progress.phase {
                    case let .downloading(received, total):
                        ProgressView(value: Double(received), total: Double(max(total, 1))).frame(width: 120)
                        Text("\(received.bytes) of \(total.bytes)").font(.caption).monospacedDigit()
                    case .verifying: ProgressView().controlSize(.small); Text("Verifying…").font(.caption)
                    case .extracting: ProgressView().controlSize(.small); Text("Installing…").font(.caption)
                    case .finished: EmptyView()
                    }
                    Button("Cancel") { model.cancelInstall(package.path) }
                }
            }
        } else if model.isInstalled(package) {
            Label("Installed", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
        } else {
            Button("Install…", action: install)
        }
    }
}

/// Shows exactly what will happen before any download starts: size, destination,
/// free space, and the license text from Google's metadata.
struct InstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let package: RemotePackage
    var replacing = false

    var body: some View {
        let archive = package.archive(for: model.host.architecture)
        let license = model.license(for: package)
        let destination = model.effectiveSDKLocation
        let alreadyAccepted = license.map { AndroidSDK(root: destination).hasAccepted($0) } ?? true
        let free = HostInfo.availableDiskSpace(at: destination)
        let needed = ArchiveInstaller.requiredSpace(for: archive?.size ?? 0)
        let isTools = package.path == CommandLineToolsInstaller.packagePath
        VStack(alignment: .leading, spacing: 12) {
            Text("Install \(package.displayName)").font(.title2.bold())
            Grid(alignment: .leading, verticalSpacing: 4) {
                GridRow { Text("Download").foregroundStyle(.secondary); Text((archive?.size ?? 0).bytes) }
                GridRow { Text("Disk space needed").foregroundStyle(.secondary); Text("about \(needed.bytes) during install") }
                GridRow { Text("Available").foregroundStyle(.secondary); Text(free.map(\.bytes) ?? "unknown") }
                GridRow { Text("Source").foregroundStyle(.secondary); Text(archive?.url.host ?? "—") }
                GridRow { Text("Destination").foregroundStyle(.secondary); Text(destination.path).textSelection(.enabled) }
                GridRow {
                    Text("Installed by").foregroundStyle(.secondary)
                    Text(isTools ? "Moorbox (download verified against Google’s SHA-1 checksum)" : "Google’s Android CLI, with usage metrics turned off")
                }
            }
            if isTools {
                Label(
                    """
                    These are Google’s official SDK tools: the Android CLI (package installs) and avdmanager (device \
                    creation). On first use, Google’s launcher downloads the full Android CLI (about 90 MB) to \
                    ~/.android/bin.
                    """,
                    systemImage: "info.circle"
                )
                .font(.callout)
            }
            if replacing {
                Label("The installed version will be replaced after the new one is downloaded and verified.", systemImage: "arrow.triangle.2.circlepath")
            }
            if let free, free < needed {
                Label("Not enough free disk space.", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            }
            if let license, !alreadyAccepted {
                Text("To download this component you must accept Google’s license (\(license.id)):").font(.headline)
                ScrollView {
                    Text(license.text).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading).padding(8)
                }
                .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
            } else if let license {
                Text("You have already accepted \(license.id).").font(.callout).foregroundStyle(.secondary)
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button(alreadyAccepted ? "Install" : "Accept License & Install") {
                    model.install(package, replacing: replacing)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(archive == nil || (free.map { $0 < needed } ?? false))
            }
        }
        .padding(20)
        .frame(width: 640, height: license != nil && !alreadyAccepted ? 660 : 360)
    }
}
