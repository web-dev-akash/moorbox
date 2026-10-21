import MoorboxCore
import SwiftUI

struct CreateDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var imageID: String?
    @State private var profileID = "medium_phone"
    @State private var preset = ResourcePreset.balanced
    @State private var ram = 4096
    @State private var cores = 4
    @State private var storage = 6
    @State private var gpu = GPUMode.auto
    @State private var error: String?
    @State private var creating = false

    var image: InstalledSystemImage? {
        model.installedImages.first { $0.id == imageID }
    }

    var limits: ResourceLimits {
        ResourceLimits.compute(host: model.host, apiLevel: image?.apiLevel ?? "0")
    }

    /// Generic profiles first, then the rest alphabetically.
    var profiles: [HardwareProfile] {
        model.hardwareProfiles.sorted { a, b in
            if (a.oem == "Generic") != (b.oem == "Generic") {
                return a.oem == "Generic"
            }
            return a.name.localizedStandardCompare(b.name) == .orderedAscending
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if let missing = missingRequirement {
                ContentUnavailableView {
                    Label("Can’t create devices yet", systemImage: "wrench.and.screwdriver")
                } description: {
                    Text(missing)
                } actions: {
                    Button("Open Setup Assistant") { dismiss(); model.showSetup = true }
                        .buttonStyle(.borderedProminent)
                }
            } else {
                form
            }
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                if creating {
                    ProgressView().controlSize(.small); Text("Creating with avdmanager…").font(.callout)
                }
                Button("Create") { create(start: false) }.disabled(!canCreate)
                Button("Create & Start") { create(start: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canCreate)
            }
            .padding()
        }
        .frame(width: 540, height: 580)
        .onAppear {
            model.loadHardwareProfiles()
            imageID = imageID ?? model.installedImages.first?.id
            name = name.isEmpty ? suggestedName() : name
            apply(preset)
        }
        .onChange(of: preset) { apply(preset) }
        .onChange(of: imageID) { apply(preset) }
    }

    var missingRequirement: String? {
        if !model
            .hasCommandLineTools {
            return "Moorbox creates devices with Google’s avdmanager, part of the Android SDK command-line tools, which aren’t installed yet."
        }
        if model
            .java ==
            nil {
            return "Google’s avdmanager needs a Java runtime (JDK 17 or newer). Setup can find one on this Mac or install Eclipse Temurin for you."
        }
        if model.installedImages.isEmpty {
            return "Install an Android version first."
        }
        return nil
    }

    var canCreate: Bool {
        missingRequirement == nil && image != nil && !creating && model.hardwareProfiles.contains { $0.id == profileID }
    }

    var form: some View {
        Form {
            TextField("Name", text: $name, prompt: Text("My Phone"))
            Picker("Android version", selection: $imageID) {
                ForEach(model.installedImages) { img in
                    Text("\(img.displayName) — \(img.tagDisplay)").tag(Optional(img.id))
                }
            }
            if model.isLoadingProfiles {
                LabeledContent("Device type") { ProgressView().controlSize(.small) }
            } else if let profilesError = model.profilesError {
                LabeledContent("Device type") { Text(profilesError).foregroundStyle(.red) }
            } else {
                Picker("Device type", selection: $profileID) {
                    ForEach(profiles) { Text($0.oem == "Generic" ? $0.name : "\($0.name) (\($0.oem))").tag($0.id) }
                }
            }
            Section {
                Picker("Resources", selection: $preset) {
                    ForEach(ResourcePreset.all) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                Text(preset.summary).font(.caption).foregroundStyle(.secondary)
                Picker("Memory", selection: $ram) {
                    ForEach(Array(stride(from: limits.ramMB.lowerBound, through: limits.ramMB.upperBound, by: 1024)), id: \.self) {
                        Text("\($0 / 1024) GB").tag($0)
                    }
                }
                Stepper("CPU cores: \(cores)", value: $cores, in: limits.cores)
                Stepper("Storage: \(storage) GB", value: $storage, in: limits.storageGB)
                Picker("Graphics", selection: $gpu) {
                    ForEach(GPUMode.allCases) { Text($0.label).tag($0) }
                }
            } footer: {
                Text(
                    """
                    Hardware profiles come from Google’s avdmanager. Limits come from the Android version and this \
                    Mac (\(model.host.physicalMemoryMB / 1024) GB RAM, \(model.host.cpuCount) cores); Android 17 \
                    (API 37) and newer need at least 4 GB.
                    """
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
        }
        .formStyle(.grouped)
    }

    func apply(_ p: ResourcePreset) {
        let clamped = limits.clamp(p)
        (ram, cores, storage) = (clamped.ramMB, clamped.cores, clamped.storageGB)
    }

    func suggestedName() -> String {
        let base = image.map { "\(AndroidVersion.shortName(apiLevel: $0.apiLevel)) Phone" } ?? "Phone"
        var name = base, n = 2
        while model.devices.contains(where: { $0.displayName == name }) {
            name = "\(base) \(n)"; n += 1
        }
        return name
    }

    func create(start: Bool) {
        guard let image else { return }
        var spec = DeviceSpec(displayName: name, image: image, profileID: profileID, resources: preset, gpu: gpu)
        (spec.ramMB, spec.cores, spec.storageGB) = (ram, cores, storage)
        creating = true
        error = nil
        Task {
            do {
                let device = try await model.create(spec)
                if start {
                    model.start(device)
                }
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
            creating = false
        }
    }
}
