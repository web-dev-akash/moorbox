import Foundation

public enum ToolError: LocalizedError, Equatable {
    case notInstalled(String)
    case failed(tool: String, message: String)

    public var errorDescription: String? {
        switch self {
        case let .notInstalled(what): "\(what) is not installed. Open Setup to install it."
        case let .failed(tool, message): message.isEmpty ? "\(tool) failed." : "\(tool) failed: \(message)"
        }
    }
}

/// Google's Android CLI (`android`), the official SDK manager since cmdline-tools 23
/// (`sdkmanager` is now a thin wrapper around it). Moorbox always passes `--no-metrics`.
///
/// The `android` binary in cmdline-tools is a small launcher. On first use it downloads the
/// full CLI (about 90 MB) to `~/.android/bin/android-cli`; that is Google's behavior, which
/// Moorbox discloses before installing cmdline-tools.
public struct AndroidCLI: Sendable {
    public let sdk: AndroidSDK

    public init(sdk: AndroidSDK) {
        self.sdk = sdk
    }

    public var launcher: URL {
        sdk.root.appendingPathComponent("cmdline-tools/latest/bin/android")
    }

    public var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: launcher.path)
    }

    /// Where Google's launcher keeps the downloaded CLI.
    public static let cacheLocation = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/bin/android-cli")

    /// `--no-metrics` must come before the subcommand to apply.
    func arguments(_ command: [String]) -> [String] {
        ["--no-metrics", "--sdk=\(sdk.root.path)"] + command
    }

    /// The CLI uses `/` where SDK paths use `;` (`system-images/android-36/default/arm64-v8a`).
    public static func cliPath(_ sdkPath: String) -> String {
        sdkPath.replacingOccurrences(of: ";", with: "/")
    }

    /// Packages outside the stable channel need an explicit opt-in flag.
    public static func channelFlags(_ channel: String) -> [String] {
        switch channel {
        case "beta": ["--beta"]
        case "dev", "canary": ["--canary"]
        default: []
        }
    }

    public static func installArguments(for package: RemotePackage) -> [String] {
        ["sdk", "install"] + channelFlags(package.channel) + [cliPath(package.path)]
    }

    @discardableResult
    func run(_ command: [String], timeout: TimeInterval) async throws -> CommandResult {
        guard isInstalled else { throw ToolError.notInstalled("Google's command-line tools") }
        let r = try await Shell.run(launcher, arguments(command), timeout: timeout)
        guard r.succeeded else {
            throw ToolError.failed(tool: "Android CLI", message: Self.errorMessage(from: r.combined))
        }
        return r
    }

    /// Keeps the meaningful lines of CLI output (drops progress noise and the ToS banner).
    static func errorMessage(from output: String) -> String {
        let lines = output.replacingOccurrences(of: "\r", with: "\n").split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { line in
                !line.isEmpty && !line.hasPrefix("https://") && !line.hasPrefix("Unzipping")
                    && !line.localizedCaseInsensitiveContains("metrics") && !line.hasPrefix("Tip:")
            }
        return lines.suffix(6).joined(separator: "\n")
    }

    /// Installs (or updates) a package. Progress comes from the CLI's own partial download
    /// (`<sdk>/.sdk/arch/<sha1>.part`, observed in CLI 1.0); if that file can't be found the
    /// caller still gets the phase changes, just without byte counts.
    public func install(
        _ package: RemotePackage,
        host: CPUArchitecture,
        progress: @escaping @Sendable (InstallPhase) -> Void
    ) async throws {
        let archive = package.archive(for: host)
        let total = archive?.size ?? 0
        progress(.downloading(received: 0, total: total))
        let partial = archive.map { sdk.root.appendingPathComponent(".sdk/arch/\($0.sha1).part") }
        let monitor = Task.detached {
            var finishedDownload = false
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(400))
                guard let partial else { continue }
                if let size = (try? FileManager.default.attributesOfItem(atPath: partial.path))?[.size] as? Int64 {
                    progress(.downloading(received: size, total: total))
                } else if !finishedDownload, FileManager.default.fileExists(atPath: partial.deletingPathExtension().path) {
                    finishedDownload = true
                    progress(.extracting)
                }
            }
        }
        defer { monitor.cancel() }
        try await run(Self.installArguments(for: package), timeout: 4 * 3600)
        // Don't trust the exit status alone: confirm the package is actually on disk.
        guard sdk.isInstalled(package) else {
            throw ToolError.failed(tool: "Android CLI", message: "\(package.displayName) was not installed. Check your network connection and disk space.")
        }
        progress(.finished)
    }

    public func remove(_ packagePath: String) async throws {
        try await run(["sdk", "remove", Self.cliPath(packagePath)], timeout: 600)
    }

    public func version() async throws -> String {
        try await run(["--version"], timeout: 120).stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// A hardware profile from `avdmanager list device`.
public struct HardwareProfile: Identifiable, Hashable, Sendable {
    public var id: String
    public var name: String
    public var oem: String
    public var tag: String?

    /// Phones and tablets only; Wear, TV, Automotive, XR, desktop and glasses need their own images.
    public var isPhoneOrTablet: Bool {
        tag == nil
    }
}

/// Google's `avdmanager` (still Java-based in cmdline-tools 23). Creates AVDs exactly as
/// Android Studio's tooling does; Moorbox then applies the chosen resources to config.ini.
public struct AVDManager: Sendable {
    public let sdk: AndroidSDK
    public let java: JavaRuntime
    public let avdHome: URL

    public init(sdk: AndroidSDK, java: JavaRuntime, avdHome: URL) {
        self.sdk = sdk
        self.java = java
        self.avdHome = avdHome
    }

    public var executable: URL {
        sdk.root.appendingPathComponent("cmdline-tools/latest/bin/avdmanager")
    }

    func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["JAVA_HOME"] = java.home.path
        env["ANDROID_HOME"] = sdk.root.path
        env["ANDROID_SDK_ROOT"] = sdk.root.path
        env["ANDROID_AVD_HOME"] = avdHome.path
        return env
    }

    @discardableResult
    func run(_ arguments: [String], input: Data? = nil, timeout: TimeInterval = 180) async throws -> CommandResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else {
            throw ToolError.notInstalled("Google's command-line tools (avdmanager)")
        }
        let r = try await Shell.run(executable, arguments, environment: environment(), input: input, timeout: timeout)
        let errorLine = r.combined.replacingOccurrences(of: "\r", with: "\n").split(whereSeparator: \.isNewline)
            .first { $0.hasPrefix("Error:") }.map(String.init)
        guard r.succeeded, errorLine == nil else {
            throw ToolError.failed(tool: "avdmanager", message: errorLine ?? r.combined)
        }
        return r
    }

    public func listDevices() async throws -> [HardwareProfile] {
        try await Self.parseDevices(run(["list", "device"]).stdout)
    }

    /// Parses blocks like:
    /// ```
    /// id: 15 or "medium_phone"
    ///     Name: Medium Phone
    ///     OEM : Generic
    ///     Tag : android-wear      (optional)
    /// ```
    public static func parseDevices(_ text: String) -> [HardwareProfile] {
        var profiles: [HardwareProfile] = []
        var current: HardwareProfile?
        for raw in text.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("id:") {
                if let current {
                    profiles.append(current)
                }
                let id = line.split(separator: "\"").dropFirst().first.map(String.init) ?? ""
                current = HardwareProfile(id: id, name: id, oem: "", tag: nil)
            } else if let value = Self.value(line, key: "Name") {
                current?.name = value
            } else if let value = Self.value(line, key: "OEM") {
                current?.oem = value
            } else if let value = Self.value(line, key: "Tag") {
                current?.tag = value.isEmpty ? nil : value
            }
        }
        if let current {
            profiles.append(current)
        }
        return profiles.filter { !$0.id.isEmpty }
    }

    private static func value(_ line: String, key: String) -> String? {
        guard line.hasPrefix(key), let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespaces) == key else { return nil }
        return line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
    }

    /// `avdmanager create avd`; answers "no" to its custom-hardware-profile prompt.
    public func create(id: String, systemImagePackage: String, deviceID: String) async throws {
        try FileManager.default.createDirectory(at: avdHome, withIntermediateDirectories: true)
        try await run(
            ["create", "avd", "--name", id, "--package", systemImagePackage, "--device", deviceID],
            input: Data("no\n".utf8)
        )
    }
}
