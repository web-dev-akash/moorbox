import MoorboxCore
import SwiftUI

struct CreateDeviceView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var imageID: String?
    @State private var profile = DeviceProfile.all[0]
    @State private var preset = ResourcePreset.balanced
    @State private var ram = 4096
    @State private var cores = 4
    @State private var storage = 6
    @State private var gpu = GPUMode.auto
    @State private var error: String?

    var image: InstalledSystemImage? { model.installedImages.first { $0.id == imageID } }
    var limits: ResourceLimits { ResourceLimits.compute(host: model.host, apiLevel: image?.apiLevel ?? "0") }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                TextField("Name", text: $name, prompt: Text("My Phone"))
                Picker("Android version", selection: $imageID) {
                    ForEach(model.installedImages) { img in
                        Text("\(img.displayName) — \(img.tagDisplay)").tag(Optional(img.id))
                    }
                }
                Picker("Device type", selection: $profile) {
                    ForEach(DeviceProfile.all) { Text($0.name).tag($0) }
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
                    Text("Limits come from the Android version and this Mac (\(model.host.physicalMemoryMB / 1024) GB RAM, \(model.host.cpuCount) cores). Android 17 (API 37) and newer need at least 4 GB.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if let error { Text(error).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            HStack {
                Button("Cancel", role: .cancel) { dismiss() }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Create") { create(start: false) }.disabled(image == nil)
                Button("Create & Start") { create(start: true) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(image == nil)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
        .onAppear {
            imageID = imageID ?? model.installedImages.first?.id
            name = name.isEmpty ? suggestedName() : name
            apply(preset)
        }
        .onChange(of: preset) { apply(preset) }
        .onChange(of: imageID) { apply(preset) }
    }

    func apply(_ p: ResourcePreset) {
        let clamped = limits.clamp(p)
        (ram, cores, storage) = (clamped.ramMB, clamped.cores, clamped.storageGB)
    }

    func suggestedName() -> String {
        let base = image.map { "\(AndroidVersion.shortName(apiLevel: $0.apiLevel)) Phone" } ?? "Phone"
        var name = base, n = 2
        while model.devices.contains(where: { $0.displayName == name }) { name = "\(base) \(n)"; n += 1 }
        return name
    }

    func create(start: Bool) {
        guard let image else { return }
        var spec = DeviceSpec(displayName: name, image: image, profile: profile, resources: preset, gpu: gpu)
        (spec.ramMB, spec.cores, spec.storageGB) = (ram, cores, storage)
        do {
            let device = try model.create(spec)
            if start { model.start(device) }
            dismiss()
        } catch {
            self.error = error.localizedDescription
        }
    }
}
