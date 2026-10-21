import Foundation

/// An Android Virtual Device on disk (`<home>/<id>.ini` + `<home>/<id>.avd/config.ini`),
/// in the same format Android Studio and avdmanager use, so devices are shared.
public struct VirtualDevice: Identifiable, Hashable, Sendable {
    public var id: String
    public var iniFile: URL
    public var directory: URL
    public var config: [String: String]
    /// `target` from `<id>.ini`, e.g. `android-36`.
    public var target: String?

    public var displayName: String { config["avd.ini.displayname"] ?? id.replacingOccurrences(of: "_", with: " ") }
    public var systemImageDirectory: String? { config["image.sysdir.1"] }
    public var abi: String? { config["abi.type"] }
    public var ramMB: Int? { config["hw.ramSize"].flatMap(Self.megabytes) }
    public var cores: Int? { config["hw.cpu.ncore"].flatMap { Int($0) } }
    public var tagDisplay: String? { config["tag.display"] }
    public var resolution: String? {
        guard let w = config["hw.lcd.width"], let h = config["hw.lcd.height"] else { return nil }
        return "\(w)×\(h)" + (config["hw.lcd.density"].map { " @ \($0) dpi" } ?? "")
    }

    /// API level derived from the system image path (`system-images/android-36/...`).
    public var apiLevel: String? {
        let platform = systemImageDirectory?.split(separator: "/").dropFirst().first.map(String.init) ?? target
        return platform?.replacingOccurrences(of: "android-", with: "")
    }

    public var androidVersionName: String {
        apiLevel.map { AndroidVersion.displayName(apiLevel: $0) } ?? "Unknown Android version"
    }

    public var hasQuickBootSnapshot: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("snapshots/default_boot/snapshot.pb").path)
    }

    /// True once the device has been booted and has user data.
    public var hasUserData: Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent("userdata-qemu.img").path)
    }

    /// Accepts "2048", "2048M", "2G" (all forms appear in real config files).
    static func megabytes(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespaces).uppercased()
        if t.hasSuffix("G"), let n = Int(t.dropLast()) { return n * 1024 }
        if t.hasSuffix("M") || t.hasSuffix("MB") { return Int(t.trimmingCharacters(in: .letters)) }
        return Int(t)
    }
}

public struct ResourcePreset: Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var summary: String
    public var ramMB: Int
    public var cores: Int
    public var storageGB: Int

    public static let lightweight = ResourcePreset(id: "lightweight", name: "Lightweight",
        summary: "Conservative allocation for everyday use", ramMB: 2048, cores: 2, storageGB: 4)
    public static let balanced = ResourcePreset(id: "balanced", name: "Balanced",
        summary: "A reasonable default for app testing", ramMB: 4096, cores: 4, storageGB: 6)
    public static let performance = ResourcePreset(id: "performance", name: "Performance",
        summary: "More resources for demanding apps", ramMB: 6144, cores: 6, storageGB: 8)
    public static let all = [lightweight, balanced, performance]
}

/// What this host + image combination permits.
public struct ResourceLimits: Equatable, Sendable {
    public var ramMB: ClosedRange<Int>
    public var cores: ClosedRange<Int>
    public var storageGB: ClosedRange<Int>

    /// - API 37+ requires at least 4 GB of guest RAM (emulator 36.6.11 release notes).
    /// - The emulator accepts 1536–8192 MB; we keep at least half the host's memory free.
    /// - Leave at least two host cores for macOS and the app.
    public static func compute(host: HostInfo, apiLevel: String) -> ResourceLimits {
        let minRAM = AndroidVersion.parse(apiLevel).major >= 37 ? 4096 : 2048
        let maxRAM = max(minRAM, min(8192, host.physicalMemoryMB / 2 / 512 * 512))
        let maxCores = max(1, min(8, host.cpuCount - 2))
        return ResourceLimits(ramMB: minRAM...maxRAM, cores: 1...maxCores, storageGB: 2...64)
    }

    public func clamp(_ preset: ResourcePreset) -> ResourcePreset {
        var p = preset
        p.ramMB = min(max(p.ramMB, ramMB.lowerBound), ramMB.upperBound)
        p.cores = min(max(p.cores, cores.lowerBound), cores.upperBound)
        p.storageGB = min(max(p.storageGB, storageGB.lowerBound), storageGB.upperBound)
        return p
    }
}

public enum GPUMode: String, CaseIterable, Sendable, Identifiable {
    case auto, host, swiftshader
    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .auto: "Automatic (recommended)"
        case .host: "Hardware (Metal/MoltenVK)"
        case .swiftshader: "Software (SwiftShader, slower)"
        }
    }
}

public struct DeviceSpec: Sendable, Equatable {
    public var displayName: String
    public var image: InstalledSystemImage
    /// An `avdmanager` hardware profile id, e.g. `medium_phone`.
    public var profileID: String
    public var ramMB: Int
    public var cores: Int
    public var storageGB: Int
    public var gpu: GPUMode = .auto

    public init(displayName: String, image: InstalledSystemImage, profileID: String,
                resources: ResourcePreset, gpu: GPUMode = .auto) {
        self.displayName = displayName
        self.image = image
        self.profileID = profileID
        self.ramMB = resources.ramMB
        self.cores = resources.cores
        self.storageGB = resources.storageGB
        self.gpu = gpu
    }
}

public enum AVDError: LocalizedError, Equatable {
    case invalidName(String)
    case nameTaken(String)
    case outOfRange(String)
    case notFound(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidName(why): "Invalid device name: \(why)"
        case let .nameTaken(name): "A device named “\(name)” already exists."
        case let .outOfRange(why): why
        case let .notFound(name): "The device “\(name)” no longer exists on disk."
        }
    }
}

public struct AVDStore: Sendable {
    public let home: URL

    public init(home: URL) { self.home = home }

    /// Same lookup order as the emulator: $ANDROID_AVD_HOME, $ANDROID_USER_HOME/avd, ~/.android/avd.
    public static func defaultHome(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> URL {
        if let v = environment["ANDROID_AVD_HOME"], !v.isEmpty { return URL(fileURLWithPath: v) }
        if let v = environment["ANDROID_USER_HOME"], !v.isEmpty { return URL(fileURLWithPath: v).appendingPathComponent("avd") }
        return home.appendingPathComponent(".android/avd")
    }

    public func list() -> [VirtualDevice] {
        let files = (try? FileManager.default.contentsOfDirectory(at: home, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "ini" }.compactMap(load)
            .sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    func load(iniFile: URL) -> VirtualDevice? {
        guard let ini = Properties.read(iniFile) else { return nil }
        let id = iniFile.deletingPathExtension().lastPathComponent
        let dir = ini["path"].map { URL(fileURLWithPath: $0) }
            .flatMap { FileManager.default.fileExists(atPath: $0.path) ? $0 : nil }
            ?? home.appendingPathComponent("\(id).avd")
        guard let config = Properties.read(dir.appendingPathComponent("config.ini")) else { return nil }
        return VirtualDevice(id: id, iniFile: iniFile, directory: dir, config: config, target: ini["target"])
    }

    /// AVD ids become file names and emulator arguments, so keep them to a safe charset.
    public static func makeID(from displayName: String) -> String {
        let mapped = displayName.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? Character($0) : "_" }
        return String(mapped).trimmingCharacters(in: CharacterSet(charactersIn: "_"))
    }

    public static func validate(_ spec: DeviceSpec, limits: ResourceLimits) throws {
        let name = spec.displayName.trimmingCharacters(in: .whitespaces)
        if name.isEmpty { throw AVDError.invalidName("enter a name") }
        if name.count > 60 { throw AVDError.invalidName("use 60 characters or fewer") }
        if makeID(from: name).isEmpty { throw AVDError.invalidName("include at least one letter or digit") }
        if !limits.ramMB.contains(spec.ramMB) {
            throw AVDError.outOfRange("Memory must be between \(limits.ramMB.lowerBound) and \(limits.ramMB.upperBound) MB for this Android version and Mac.")
        }
        if !limits.cores.contains(spec.cores) {
            throw AVDError.outOfRange("CPU cores must be between \(limits.cores.lowerBound) and \(limits.cores.upperBound).")
        }
        if !limits.storageGB.contains(spec.storageGB) {
            throw AVDError.outOfRange("Storage must be between \(limits.storageGB.lowerBound) and \(limits.storageGB.upperBound) GB.")
        }
    }

    /// Settings Moorbox applies on top of what `avdmanager` writes, the same way Android
    /// Studio's device wizard does. Everything else stays as Google's tool created it.
    public static func overrides(for spec: DeviceSpec) -> [String: String] {
        [
            "avd.ini.displayname": spec.displayName.trimmingCharacters(in: .whitespaces),
            "hw.ramSize": String(spec.ramMB),
            "hw.cpu.ncore": String(spec.cores),
            "disk.dataPartition.size": "\(spec.storageGB)G",
            "hw.gpu.enabled": "yes",
            "hw.gpu.mode": spec.gpu.rawValue,
            "hw.keyboard": "yes",
            "fastboot.forceColdBoot": "no",
            "fastboot.forceFastBoot": "yes",
        ]
    }

    /// Creates the device with Google's `avdmanager`, then applies the chosen resources.
    @discardableResult
    public func create(_ spec: DeviceSpec, limits: ResourceLimits, using manager: AVDManager) async throws -> VirtualDevice {
        try Self.validate(spec, limits: limits)
        let id = Self.makeID(from: spec.displayName.trimmingCharacters(in: .whitespaces))
        let fm = FileManager.default
        let taken = list().contains { $0.id.lowercased() == id.lowercased() || $0.displayName == spec.displayName }
        if taken || fm.fileExists(atPath: home.appendingPathComponent("\(id).ini").path)
            || fm.fileExists(atPath: home.appendingPathComponent("\(id).avd").path) {
            throw AVDError.nameTaken(spec.displayName)
        }
        try await manager.create(id: id, systemImagePackage: spec.image.packagePath, deviceID: spec.profileID)
        guard let created = load(iniFile: home.appendingPathComponent("\(id).ini")) else { throw AVDError.notFound(spec.displayName) }
        try update(created, changes: Self.overrides(for: spec))
        guard let device = load(iniFile: created.iniFile) else { throw AVDError.notFound(spec.displayName) }
        return device
    }

    /// Changes selected `config.ini` keys, leaving every other key untouched.
    public func update(_ device: VirtualDevice, changes: [String: String]) throws {
        let file = device.directory.appendingPathComponent("config.ini")
        guard var config = Properties.read(file) else { throw AVDError.notFound(device.displayName) }
        config.merge(changes) { _, new in new }
        try Properties.write(config, to: file)
    }

    public func rename(_ device: VirtualDevice, to name: String) throws {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, trimmed.count <= 60 else { throw AVDError.invalidName("use 1–60 characters") }
        try update(device, changes: ["avd.ini.displayname": trimmed])
    }

    /// Moves the device to the Trash (recoverable) rather than deleting it outright.
    public func moveToTrash(_ device: VirtualDevice) throws {
        let fm = FileManager.default
        try fm.trashItem(at: device.directory, resultingItemURL: nil)
        try fm.trashItem(at: device.iniFile, resultingItemURL: nil)
    }

    /// Removes the quick-boot snapshot only; installed apps and user data are kept.
    public func deleteQuickBootSnapshot(_ device: VirtualDevice) throws {
        let snapshot = device.directory.appendingPathComponent("snapshots/default_boot")
        if FileManager.default.fileExists(atPath: snapshot.path) { try FileManager.default.removeItem(at: snapshot) }
    }

    /// Allocated (not logical) size, since the emulator's disk images are sparse.
    public static func diskUsage(of directory: URL) -> Int64 {
        let keys: [URLResourceKey] = [.totalFileAllocatedSizeKey]
        guard let walker = FileManager.default.enumerator(at: directory, includingPropertiesForKeys: keys) else { return 0 }
        var total: Int64 = 0
        for case let url as URL in walker {
            total += Int64((try? url.resourceValues(forKeys: Set(keys)))?.totalFileAllocatedSize ?? 0)
        }
        return total
    }
}
