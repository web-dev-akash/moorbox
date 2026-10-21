import Foundation

public enum ADBError: LocalizedError, Equatable {
    case invalidPackageName(String)
    case notAnAPK(String)
    case installFailed(code: String, explanation: String, raw: String)
    case noLaunchableActivity(String)
    case bootTimedOut(Int)
    case commandFailed(String)

    public var errorDescription: String? {
        switch self {
        case let .invalidPackageName(n): "“\(n)” is not a valid Android package name."
        case let .notAnAPK(n): "“\(n)” is not an APK file."
        case let .installFailed(code, explanation, _): "\(explanation) (\(code))"
        case let .noLaunchableActivity(p): "\(p) has no launcher activity, so it can't be opened directly."
        case let .bootTimedOut(s): "Android did not finish booting within \(s) seconds. Check Diagnostics for the emulator log."
        case let .commandFailed(message): message
        }
    }
}

public struct ADB: Sendable {
    public let executable: URL

    public init(executable: URL) { self.executable = executable }

    public func run(_ arguments: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        try await Shell.run(executable, arguments, timeout: timeout)
    }

    @discardableResult
    func check(_ serial: String, _ arguments: [String], timeout: TimeInterval = 30) async throws -> CommandResult {
        let r = try await run(["-s", serial] + arguments, timeout: timeout)
        guard r.succeeded else { throw ADBError.commandFailed(r.combined.isEmpty ? "adb exited with code \(r.exitCode)" : r.combined) }
        return r
    }

    /// `adb version` → "37.0.1-15733141".
    public static func parseVersion(_ output: String) -> String? {
        output.split(whereSeparator: \.isNewline).first { $0.hasPrefix("Version ") }
            .map { String($0.dropFirst("Version ".count)).trimmingCharacters(in: .whitespaces) }
    }

    public func version() async -> String? {
        (try? await run(["version"], timeout: 10)).flatMap { Self.parseVersion($0.stdout) }
    }

    public struct OtherInstallation: Hashable, Sendable {
        public var path: String
        public var version: String
    }

    /// Other adb binaries in the usual PATH locations (e.g. Homebrew's android-platform-tools)
    /// whose version differs from this one. Two adb versions restart each other's server,
    /// which disconnects devices. Reported only; Moorbox never removes them.
    public func conflictingInstallations(candidates: [String] = ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"]) async -> [OtherInstallation] {
        guard let mine = await version() else { return [] }
        let ownPath = executable.resolvingSymlinksInPath().path
        var result: [OtherInstallation] = []
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath()
            guard resolved.path != ownPath, let other = await ADB(executable: resolved).version(), other != mine else { continue }
            result.append(OtherInstallation(path: path, version: other))
        }
        return result
    }

    public func startServer() async throws {
        try await Shell.check(executable, ["start-server"], timeout: 20)
    }

    /// `adb devices` → [(serial, state)], e.g. ("emulator-5554", "device").
    public static func parseDevices(_ output: String) -> [(serial: String, state: String)] {
        output.split(whereSeparator: \.isNewline).dropFirst().compactMap { line in
            let cols = line.split(whereSeparator: { $0 == "\t" || $0 == " " })
            return cols.count >= 2 ? (String(cols[0]), String(cols[1])) : nil
        }
    }

    public func devices() async throws -> [(serial: String, state: String)] {
        let r = try await run(["devices"], timeout: 15)
        return Self.parseDevices(r.stdout)
    }

    public func isBootCompleted(_ serial: String) async -> Bool {
        let r = try? await run(["-s", serial, "shell", "getprop", "sys.boot_completed"], timeout: 10)
        return r?.stdout.trimmingCharacters(in: .whitespacesAndNewlines) == "1"
    }

    /// Polls until Android reports boot completion. Only runs while a device is booting.
    public func waitForBoot(_ serial: String, timeout: TimeInterval = 300, processAlive: @Sendable () -> Bool = { true }) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            try Task.checkCancellation()
            guard processAlive() else { throw ADBError.commandFailed("The emulator exited before Android finished booting.") }
            if await isBootCompleted(serial) { return }
            try await Task.sleep(for: .seconds(1))
        }
        throw ADBError.bootTimedOut(Int(timeout))
    }

    // MARK: Apps

    /// Android package names: two or more dot-separated Java identifiers. Strictly
    /// validated because `adb shell` arguments are interpreted by the device's shell.
    public static func isValidPackageName(_ name: String) -> Bool {
        name.count <= 255 && name.range(of: #"^[A-Za-z][A-Za-z0-9_]*(\.[A-Za-z][A-Za-z0-9_]*)+$"#, options: .regularExpression) != nil
    }

    /// Checks the extension and the ZIP signature, so a renamed file fails early with a clear message.
    public static func validateAPK(_ url: URL) throws {
        guard url.pathExtension.lowercased() == "apk" else { throw ADBError.notAnAPK(url.lastPathComponent) }
        guard let handle = try? FileHandle(forReadingFrom: url), let magic = try? handle.read(upToCount: 4),
              magic == Data([0x50, 0x4B, 0x03, 0x04]) else { throw ADBError.notAnAPK(url.lastPathComponent) }
        try? handle.close()
    }

    public func install(_ apk: URL, serial: String) async throws -> String {
        try Self.validateAPK(apk)
        let r = try await run(["-s", serial, "install", "-r", apk.path], timeout: 600)
        if r.succeeded, r.stdout.contains("Success") { return r.combined }
        throw Self.installError(from: r.combined)
    }

    static let installFailures: [String: String] = [
        "INSTALL_FAILED_NO_MATCHING_ABIS": "The app's native code doesn't support this device's CPU architecture.",
        "INSTALL_FAILED_OLDER_SDK": "The app requires a newer Android version than this device runs.",
        "INSTALL_FAILED_UPDATE_INCOMPATIBLE": "A version of this app signed with a different key is already installed. Uninstall it first.",
        "INSTALL_FAILED_VERSION_DOWNGRADE": "A newer version of this app is already installed.",
        "INSTALL_FAILED_INSUFFICIENT_STORAGE": "The device doesn't have enough free storage. Increase its storage or remove apps.",
        "INSTALL_FAILED_TEST_ONLY": "The APK is marked test-only and can only be installed by development tools.",
        "INSTALL_PARSE_FAILED_NO_CERTIFICATES": "The APK is not signed.",
        "INSTALL_PARSE_FAILED_NOT_APK": "The file is not a valid APK.",
        "INSTALL_FAILED_INVALID_APK": "The APK is invalid or corrupted.",
        "INSTALL_FAILED_ALREADY_EXISTS": "The app is already installed.",
        "INSTALL_FAILED_DEPRECATED_SDK_VERSION": "The app targets an Android version too old for this device to install.",
    ]

    static func installError(from output: String) -> ADBError {
        let code = output.range(of: #"INSTALL_[A-Z_]+"#, options: .regularExpression).map { String(output[$0]) }
        if let code {
            return .installFailed(code: code, explanation: installFailures[code] ?? "Android rejected the APK.", raw: output)
        }
        if output.contains("device offline") || output.contains("not found") {
            return .commandFailed("The device is not connected to adb. Wait for it to finish booting, or restart it.")
        }
        return .commandFailed(output.isEmpty ? "adb install failed." : output)
    }

    public func uninstall(_ package: String, serial: String) async throws {
        guard Self.isValidPackageName(package) else { throw ADBError.invalidPackageName(package) }
        let r = try await run(["-s", serial, "uninstall", package], timeout: 120)
        guard r.succeeded, r.stdout.contains("Success") else {
            throw ADBError.commandFailed(r.combined.isEmpty ? "Uninstall failed." : r.combined)
        }
    }

    /// User-installed packages (`pm list packages -3`), sorted.
    public func userPackages(serial: String) async throws -> [String] {
        let r = try await check(serial, ["shell", "pm", "list", "packages", "-3"])
        return r.stdout.split(whereSeparator: \.isNewline)
            .compactMap { $0.hasPrefix("package:") ? String($0.dropFirst(8)).trimmingCharacters(in: .whitespaces) : nil }
            .sorted()
    }

    /// Parses `cmd package resolve-activity --brief` output: the last line is `pkg/.Activity`.
    static func parseResolvedActivity(_ output: String) -> String? {
        let last = output.split(whereSeparator: \.isNewline).last.map { $0.trimmingCharacters(in: .whitespaces) }
        guard let last, last.contains("/"), !last.contains(" ") else { return nil }
        return last
    }

    public func launch(_ package: String, serial: String) async throws {
        guard Self.isValidPackageName(package) else { throw ADBError.invalidPackageName(package) }
        let resolved = try await check(serial, ["shell", "cmd", "package", "resolve-activity", "--brief",
                                                "-a", "android.intent.action.MAIN", "-c", "android.intent.category.LAUNCHER", package])
        guard let component = Self.parseResolvedActivity(resolved.stdout) else { throw ADBError.noLaunchableActivity(package) }
        let r = try await check(serial, ["shell", "am", "start", "-n", component])
        if r.stdout.contains("Error") { throw ADBError.commandFailed(r.combined) }
    }

    // MARK: Device controls

    public func screenshotPNG(serial: String) async throws -> Data {
        let r = try await check(serial, ["exec-out", "screencap", "-p"], timeout: 30)
        guard r.output.starts(with: [0x89, 0x50, 0x4E, 0x47]) else { throw ADBError.commandFailed("The device returned an invalid screenshot.") }
        return r.output
    }

    public enum Key: String, CaseIterable, Sendable {
        case home = "KEYCODE_HOME", back = "KEYCODE_BACK", recents = "KEYCODE_APP_SWITCH", power = "KEYCODE_POWER"
        case volumeUp = "KEYCODE_VOLUME_UP", volumeDown = "KEYCODE_VOLUME_DOWN"
    }

    public func press(_ key: Key, serial: String) async throws {
        try await check(serial, ["shell", "input", "keyevent", key.rawValue])
    }

    /// Emulator console command via adb (e.g. `rotate`).
    public func emulatorConsole(_ command: [String], serial: String) async throws {
        try await check(serial, ["emu"] + command)
    }

    public func logcat(serial: String, lines: Int = 500) async throws -> String {
        try await check(serial, ["logcat", "-d", "-t", String(lines)], timeout: 30).stdout
    }
}
