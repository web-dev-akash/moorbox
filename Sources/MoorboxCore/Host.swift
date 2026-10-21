import Foundation

public enum CPUArchitecture: String, Sendable {
    // swiftlint:disable:next identifier_name
    case arm64, x86_64 // matches the platform's own spelling (uname, Mach-O, Android ABIs)

    /// The Android ABI that runs natively (hardware-accelerated) on this host.
    public var nativeAndroidABI: String {
        self == .arm64 ? "arm64-v8a" : "x86_64"
    }

    /// `host-arch` value used in the SDK repository metadata.
    public var repositoryName: String {
        self == .arm64 ? "aarch64" : "x64"
    }
}

public struct HostInfo: Sendable {
    public var macOSVersion: String
    public var architecture: CPUArchitecture
    /// True when this process runs under Rosetta on Apple Silicon.
    public var isTranslated: Bool
    public var physicalMemory: UInt64
    public var cpuCount: Int
    /// `kern.hv_support`: whether Hypervisor.framework acceleration is available.
    public var hypervisorSupported: Bool

    public init(
        macOSVersion: String,
        architecture: CPUArchitecture,
        isTranslated: Bool = false,
        physicalMemory: UInt64,
        cpuCount: Int,
        hypervisorSupported: Bool
    ) {
        self.macOSVersion = macOSVersion
        self.architecture = architecture
        self.isTranslated = isTranslated
        self.physicalMemory = physicalMemory
        self.cpuCount = cpuCount
        self.hypervisorSupported = hypervisorSupported
    }

    public static func current() -> HostInfo {
        let info = ProcessInfo.processInfo
        let v = info.operatingSystemVersion
        // hw.optional.arm64 reports the real hardware even for a Rosetta-translated process.
        let arm = sysctlInt("hw.optional.arm64") == 1
        return HostInfo(
            macOSVersion: "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)",
            architecture: arm ? .arm64 : .x86_64,
            isTranslated: sysctlInt("sysctl.proc_translated") == 1,
            physicalMemory: info.physicalMemory,
            cpuCount: info.processorCount,
            hypervisorSupported: sysctlInt("kern.hv_support") == 1
        )
    }

    public var physicalMemoryMB: Int {
        Int(physicalMemory / 1_048_576)
    }

    /// Bytes available for new files on the volume containing `url` (or its nearest existing parent).
    public static func availableDiskSpace(at url: URL) -> Int64? {
        var probe = url
        while !FileManager.default.fileExists(atPath: probe.path), probe.pathComponents.count > 1 {
            probe.deleteLastPathComponent()
        }
        let values = try? probe.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }

    private static func sysctlInt(_ name: String) -> Int32? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname(name, &value, &size, nil, 0) == 0 ? value : nil
    }
}

/// Reads the CPU architectures from a Mach-O (thin or universal) executable header.
public func machOArchitectures(of url: URL) -> Set<CPUArchitecture> {
    guard let handle = try? FileHandle(forReadingFrom: url),
          let header = try? handle.read(upToCount: 4096) else { return [] }
    try? handle.close()
    return machOArchitectures(header: header)
}

func machOArchitectures(header: Data) -> Set<CPUArchitecture> {
    let bytes = [UInt8](header)
    func u32(_ at: Int, bigEndian: Bool) -> UInt32? {
        guard at + 4 <= bytes.count else { return nil }
        let slice = bytes[at ..< at + 4]
        return bigEndian ? slice.reduce(0) { $0 << 8 | UInt32($1) } : slice.reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
    func arch(_ cpuType: UInt32) -> CPUArchitecture? {
        switch cpuType {
        case 0x0100_000C: .arm64
        case 0x0100_0007: .x86_64
        default: nil
        }
    }
    guard let magicBE = u32(0, bigEndian: true) else { return [] }
    switch magicBE {
    case 0xCFFA_EDFE: // MH_MAGIC_64, little-endian on disk
        return Set([u32(4, bigEndian: false).flatMap(arch)].compactMap(\.self))
    case 0xCAFE_BABE, 0xCAFE_BABF: // FAT_MAGIC / FAT_MAGIC_64 (big-endian)
        let stride = magicBE == 0xCAFE_BABE ? 20 : 32
        let count = Int(u32(4, bigEndian: true) ?? 0)
        return Set((0 ..< min(count, 16)).compactMap { u32(8 + $0 * stride, bigEndian: true).flatMap(arch) })
    default:
        return []
    }
}

/// `key=value` files: SDK `source.properties`, AVD `config.ini` and `<name>.ini`.
public enum Properties {
    public static func parse(_ text: String) -> [String: String] {
        var result: [String: String] = [:]
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), let eq = trimmed.firstIndex(of: "=") else { continue }
            let key = trimmed[..<eq].trimmingCharacters(in: .whitespaces)
            let value = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            result[key] = value.replacingOccurrences(of: "\\:", with: ":")
        }
        return result
    }

    public static func read(_ url: URL) -> [String: String]? {
        (try? String(contentsOf: url, encoding: .utf8)).map(parse)
    }

    public static func serialize(_ values: [String: String]) -> String {
        values.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)\n" }.joined()
    }

    /// Writes via a temporary file and atomic rename so a crash never leaves a half-written config.
    public static func write(_ values: [String: String], to url: URL) throws {
        try serialize(values).write(to: url, atomically: true, encoding: .utf8)
    }
}

public extension URL {
    /// A URL from a compile-time constant. Constants are covered by unit tests, so a typo is a
    /// programmer error, not a runtime condition.
    init(constant: StaticString) {
        guard let url = URL(string: "\(constant)") else { preconditionFailure("invalid URL constant \(constant)") }
        self = url
    }
}
