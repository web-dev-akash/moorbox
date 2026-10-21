import Foundation

public struct StartOptions: Sendable, Equatable {
    /// Ignore the quick-boot snapshot and boot Android from scratch.
    public var coldBoot = false
    /// Run without a window (CI / benchmarks).
    public var headless = false
    /// Don't save a quick-boot snapshot on shutdown (faster stop, slower next start).
    public var skipSnapshotSave = false

    public init(coldBoot: Bool = false, headless: Bool = false, skipSnapshotSave: Bool = false) {
        self.coldBoot = coldBoot
        self.headless = headless
        self.skipSnapshotSave = skipSnapshotSave
    }
}

public struct RunningInstance: Hashable, Sendable {
    public var pid: pid_t
    public var avdID: String
    public var avdDirectory: String
    public var consolePort: Int

    /// adb serial for an emulator: `emulator-<console port>`.
    public var serial: String { "emulator-\(consolePort)" }
}

public enum RuntimeError: LocalizedError, Equatable {
    case notInstalled(String)
    case alreadyRunning(String)
    case missingSystemImage(String)
    case stopTimedOut(String)

    public var errorDescription: String? {
        switch self {
        case let .notInstalled(what): "\(what) Open Setup to install it."
        case let .alreadyRunning(name): "“\(name)” is already running."
        case let .missingSystemImage(path):
            "The Android system image this device uses is not installed (\(path)). Install it from Android Versions."
        case let .stopTimedOut(name):
            "“\(name)” did not shut down in time. You can force it to stop; unsaved state in the device will be lost, but its data and installed apps are kept."
        }
    }
}

/// The boundary between the UI and whatever actually runs Android. The UI only talks
/// to this protocol; `EmulatorRuntime` is the implementation backed by the official
/// Android Emulator. See docs/architecture/ADR-001-runtime-strategy.md.
public protocol AndroidRuntime: Sendable {
    var name: String { get }
    func runningInstances() -> [RunningInstance]
    /// Launches the device and returns its process ID. Does not wait for boot.
    func start(_ device: VirtualDevice, options: StartOptions) throws -> pid_t
    /// Asks the device to shut down gracefully and waits for the process to exit.
    func stop(_ instance: RunningInstance, timeout: TimeInterval) async throws
    /// Terminates the device process. Only targets the PID the runtime itself reported.
    func forceStop(_ instance: RunningInstance)
    func logFile(for device: VirtualDevice) -> URL
}

public struct EmulatorRuntime: AndroidRuntime {
    public let sdk: AndroidSDK
    public let avdHome: URL
    public let logDirectory: URL
    public let discoveryDirectory: URL
    public var name: String { "Android Emulator" + (sdk.emulatorRevision.map { " \($0)" } ?? "") }

    /// The emulator's running-instance registry on macOS (see `emulator -help-all`).
    public static let defaultDiscoveryDirectory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Caches/TemporaryItems/avd/running")

    public init(sdk: AndroidSDK, avdHome: URL, logDirectory: URL, discoveryDirectory: URL = defaultDiscoveryDirectory) {
        self.sdk = sdk
        self.avdHome = avdHome
        self.logDirectory = logDirectory
        self.discoveryDirectory = discoveryDirectory
    }

    var adb: ADB { ADB(executable: sdk.adbBinary) }

    public static func arguments(for device: VirtualDevice, options: StartOptions) -> [String] {
        // No usage metrics or crash uploads, and never block startup on the emulator's
        // consent dialogs (a crash on a previous exit otherwise shows a modal prompt).
        var args = ["-avd", device.id, "-no-metrics", "-crash-report-mode", "never"]
        if options.coldBoot { args.append("-no-snapshot-load") }
        if options.skipSnapshotSave { args.append("-no-snapshot-save") }
        if options.headless { args += ["-no-window", "-no-audio"] }
        return args
    }

    public func environment(base: [String: String] = ProcessInfo.processInfo.environment) -> [String: String] {
        var env = base
        env["ANDROID_HOME"] = sdk.root.path
        env["ANDROID_SDK_ROOT"] = sdk.root.path
        env["ANDROID_AVD_HOME"] = avdHome.path
        return env
    }

    public func logFile(for device: VirtualDevice) -> URL {
        logDirectory.appendingPathComponent("\(device.id).log")
    }

    public func start(_ device: VirtualDevice, options: StartOptions) throws -> pid_t {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: sdk.emulatorBinary.path) else {
            throw RuntimeError.notInstalled("The Android Emulator is not installed.")
        }
        if let dir = device.systemImageDirectory,
           !fm.fileExists(atPath: sdk.root.appendingPathComponent(dir).appendingPathComponent("system.img").path) {
            throw RuntimeError.missingSystemImage(dir)
        }
        if instance(for: device) != nil { throw RuntimeError.alreadyRunning(device.displayName) }

        try fm.createDirectory(at: logDirectory, withIntermediateDirectories: true)
        let log = logFile(for: device)
        LogFiles.rotate(log)
        let header = "=== \(Date()) emulator \(Self.arguments(for: device, options: options).joined(separator: " "))\n"
        try? header.write(to: log, atomically: false, encoding: .utf8)
        return try Shell.spawnDetached(sdk.emulatorBinary, Self.arguments(for: device, options: options),
                                       environment: environment(), logFile: log)
    }

    /// Reads the emulator's `pid_<pid>.ini` files. They can outlive the process, so each
    /// one is checked for a live PID.
    public func runningInstances() -> [RunningInstance] {
        let files = (try? FileManager.default.contentsOfDirectory(at: discoveryDirectory, includingPropertiesForKeys: nil)) ?? []
        return files.compactMap { url -> RunningInstance? in
            guard let instance = Self.parseDiscoveryFile(url) else { return nil }
            return Self.isEmulatorProcess(instance.pid) ? instance : nil
        }
    }

    /// Guards against PID reuse: a stale discovery file must never make us treat (or
    /// signal) an unrelated process as an emulator.
    public static func isEmulatorProcess(_ pid: pid_t) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 4 * Int(MAXPATHLEN))
        let length = Shell.isAlive(pid) ? proc_pidpath(pid, &buffer, UInt32(buffer.count)) : 0
        guard length > 0 else { return false }
        let name = URL(fileURLWithPath: String(decoding: buffer[..<Int(length)], as: UTF8.self)).lastPathComponent
        return name.hasPrefix("qemu-system") || name == "emulator"
    }

    static func parseDiscoveryFile(_ url: URL) -> RunningInstance? {
        let name = url.lastPathComponent
        guard name.hasPrefix("pid_"), name.hasSuffix(".ini"),
              let pid = pid_t(name.dropFirst(4).dropLast(4)),
              let props = Properties.read(url),
              let avd = props["avd.id"] ?? props["avd.name"], // avd.name is the display name
              let port = props["port.serial"].flatMap({ Int($0) }) else { return nil }
        return RunningInstance(pid: pid, avdID: avd, avdDirectory: props["avd.dir"] ?? "", consolePort: port)
    }

    /// Matches on the AVD directory first so devices with the same name in another
    /// AVD home are never confused with ours.
    public func instance(for device: VirtualDevice, in instances: [RunningInstance]? = nil) -> RunningInstance? {
        let all = instances ?? runningInstances()
        let dir = device.directory.resolvingSymlinksInPath().path
        return all.first { !$0.avdDirectory.isEmpty && URL(fileURLWithPath: $0.avdDirectory).resolvingSymlinksInPath().path == dir }
            ?? all.first { $0.avdDirectory.isEmpty && $0.avdID == device.id }
    }

    /// `adb emu kill` makes the emulator save its quick-boot snapshot and exit cleanly.
    public func stop(_ instance: RunningInstance, timeout: TimeInterval = 90) async throws {
        _ = try? await adb.run(["-s", instance.serial, "emu", "kill"], timeout: 15)
        let deadline = Date().addingTimeInterval(timeout)
        while Shell.isAlive(instance.pid) {
            if Date() > deadline { throw RuntimeError.stopTimedOut(instance.avdID) }
            try await Task.sleep(for: .milliseconds(250))
        }
    }

    public func forceStop(_ instance: RunningInstance) {
        guard Self.isEmulatorProcess(instance.pid) else { return }
        kill(instance.pid, SIGTERM)
        DispatchQueue.global().asyncAfter(deadline: .now() + 10) {
            if Self.isEmulatorProcess(instance.pid) { kill(instance.pid, SIGKILL) }
        }
    }
}
