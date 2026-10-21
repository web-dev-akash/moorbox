import Foundation
@testable import MoorboxCore
import Testing

/// Opt-in tests against the real network, Google's tools and the emulator. They never
/// modify your SDK or devices: each uses its own SDK and AVD folders.
///
///     MOORBOX_INTEGRATION=1 swift test --filter Integration
///
/// Options:
/// - MOORBOX_TEST_SDK: a prepared SDK (with cmdline-tools, emulator, platform-tools and an arm64
///   image) to reuse for the device lifecycle test instead of building one.
/// - MOORBOX_TEST_APK: defaults to .build/test-apk/moorbox-hello.apk (scripts/build-test-apk.sh).
/// - MOORBOX_INTEGRATION_FRESH=1: also install everything from scratch (~1.4 GB download).
/// - MOORBOX_INTEGRATION_JDK=1: also download and install Temurin (~200 MB).
let integrationEnabled = ProcessInfo.processInfo.environment["MOORBOX_INTEGRATION"] == "1"
let env = ProcessInfo.processInfo.environment

func log(_ message: String) {
    print("[integration] \(message)")
}

func elapsed(_ since: Date) -> String {
    String(format: "%.1fs", Date().timeIntervalSince(since))
}

@Suite(.serialized, .enabled(if: integrationEnabled))
struct IntegrationTests {
    let host = HostInfo.current()

    @Test(.timeLimit(.minutes(2)))
    func liveCatalogHasRuntimeAndImagesForThisMac() async throws {
        let catalog = try await SDKRepository().fetchCatalog()
        let emulator = try #require(catalog.latestStable("emulator", for: host.architecture))
        let tools = try #require(catalog.latestStable(CommandLineToolsInstaller.packagePath, for: host.architecture))
        let image = try #require(catalog.recommendedSystemImage(for: host.architecture))
        #expect(image.licenseID.flatMap { catalog.licenses[$0] } != nil)
        log("cmdline-tools \(tools.revision); emulator \(emulator.revision); recommended \(image.path)")
    }

    /// Moorbox installs cmdline-tools itself (verified download); Google's Android CLI then
    /// installs platform-tools. Also checks that `--no-metrics` keeps the CLI's analytics untouched.
    @Test(.timeLimit(.minutes(10)))
    func bootstrapsOfficialToolsIntoFreshSDK() async throws {
        let tmp = try TempDir()
        let sdk = AndroidSDK(root: tmp.url.appendingPathComponent("sdk"))
        let catalog = try await SDKRepository().fetchCatalog()
        let tools = try #require(catalog.latestStable(CommandLineToolsInstaller.packagePath, for: host.architecture))
        var t0 = Date()
        try await CommandLineToolsInstaller.install(tools, into: sdk, host: host.architecture) { _ in }
        log("cmdline-tools \(tools.revision) installed in \(elapsed(t0))")
        #expect(sdk.commandLineToolsRevision != nil)

        let analytics = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".android/cli/analytics")
        let before = Self.snapshot(analytics)
        let cli = AndroidCLI(sdk: sdk)
        let platformTools = try #require(catalog.latestStable("platform-tools", for: host.architecture))
        t0 = Date()
        let phases = PhaseLog()
        try await cli.install(platformTools, host: host.architecture) { phases.append($0) }
        log("platform-tools \(platformTools.revision) installed by the Android CLI in \(elapsed(t0))")
        #expect(FileManager.default.isExecutableFile(atPath: sdk.adbBinary.path))
        #expect(FileManager.default.fileExists(atPath: sdk.root.appendingPathComponent("platform-tools/package.xml").path))
        #expect(phases.values.last == .finished)
        #expect(Self.snapshot(analytics) == before, "the Android CLI wrote analytics despite --no-metrics")

        try await cli.remove(platformTools.path)
        #expect(!FileManager.default.fileExists(atPath: sdk.adbBinary.path))
    }

    /// Cancel mid-download, then retry: the retry continues from the bytes already received
    /// (HTTP Range on a kept partial file, which also survives relaunching the app).
    @Test(.timeLimit(.minutes(5)))
    func cancelledDownloadResumes() async throws {
        let tmp = try TempDir()
        let catalog = try await SDKRepository().fetchCatalog()
        let pkg = try #require(catalog.latestStable(CommandLineToolsInstaller.packagePath, for: host.architecture))
        let sdk = AndroidSDK(root: tmp.url.appendingPathComponent("sdk"))

        let first = PhaseLog()
        let task = Task { try await CommandLineToolsInstaller.install(pkg, into: sdk, host: host.architecture) { first.append($0) } }
        while !first.values.contains(where: {
            if case let .downloading(r, _) = $0 {
                return r > 2_000_000
            }; return false
        }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(sdk.commandLineToolsRevision == nil)
        let partials = (try? FileManager.default.contentsOfDirectory(atPath: sdk.root.appendingPathComponent(".moorbox-staging/downloads").path)) ?? []
        #expect(partials.count == 1, "the partial download should be kept for resuming")

        let second = PhaseLog()
        try await CommandLineToolsInstaller.install(pkg, into: sdk, host: host.architecture) { second.append($0) }
        guard case let .downloading(resumedAt, _)? = second.values.first(where: {
            if case .downloading = $0 {
                return true
            }; return false
        }) else {
            Issue.record("no download progress reported"); return
        }
        log("resumed download at \(resumedAt) bytes")
        #expect(resumedAt > 1_000_000)
        #expect(sdk.commandLineToolsRevision != nil)
    }

    @Test(.timeLimit(.minutes(10)), .enabled(if: env["MOORBOX_INTEGRATION_JDK"] == "1"))
    func installsTemurinJDK() async throws {
        let tmp = try TempDir()
        let release = try await Adoptium.fetchLatest(for: host.architecture)
        let t0 = Date()
        let jdk = try await Adoptium.install(release, managedRoot: tmp.url) { _ in }
        log("Temurin \(release.version) (\(release.size / 1_048_576) MB) installed in \(elapsed(t0))")
        #expect(jdk.majorVersion == Adoptium.featureVersion)
        let found = await JavaLocator.find(managedRoot: tmp.url, environment: [:])
        #expect(found?.source == .moorbox)
        let r = try await Shell.check(jdk.javaBinary, ["-version"])
        #expect(r.stderr.contains("Temurin"))
    }

    /// End-to-end with Google's tools: avdmanager creates the device → cold boot → APK
    /// install/launch → screenshot/rotate → graceful stop with snapshot → quick boot →
    /// app data persisted → uninstall → stop.
    @Test(.timeLimit(.minutes(25)))
    func deviceLifecycleWithOfficialTools() async throws {
        let java = try #require(
            await JavaLocator.find(managedRoot: URL(fileURLWithPath: "/nonexistent")),
            "No JDK 17+ found (avdmanager needs one)"
        )
        let tmp = try TempDir()
        let (sdk, image) = try await preparedSDK(in: tmp)
        let store = AVDStore(home: tmp.url.appendingPathComponent("avd"))
        let runtime = EmulatorRuntime(sdk: sdk, avdHome: store.home, logDirectory: tmp.url.appendingPathComponent("logs"))
        let adb = ADB(executable: sdk.adbBinary)
        try await adb.startServer()

        let manager = AVDManager(sdk: sdk, java: java, avdHome: store.home)
        let profiles = try await manager.listDevices()
        #expect(profiles.contains { $0.id == "medium_phone" })
        let limits = ResourceLimits.compute(host: host, apiLevel: image.apiLevel)
        let spec = DeviceSpec(
            displayName: "Moorbox IT \(UUID().uuidString.prefix(6))",
            image: image,
            profileID: "medium_phone",
            resources: limits.clamp(.lightweight)
        )
        var t0 = Date()
        let device = try await store.create(spec, limits: limits, using: manager)
        log("avdmanager created \(device.id) (\(image.packagePath), Java \(java.version) from \(java.source.rawValue)) in \(elapsed(t0))")
        #expect(device.ramMB == spec.ramMB)
        #expect(device.config["hw.gpu.enabled"] == "yes")
        #expect(device.config["hw.device.name"] == "medium_phone")

        t0 = Date()
        let pid = try runtime.start(device, options: StartOptions(coldBoot: true, headless: true))
        defer {
            if Shell.isAlive(pid) {
                kill(pid, SIGKILL)
            }; var s: Int32 = 0; waitpid(pid, &s, WNOHANG)
        }
        let instance = try await waitForInstance(runtime, device, pid: pid)
        #expect(instance.pid == pid)
        #expect(throws: RuntimeError.alreadyRunning(device.displayName)) {
            _ = try runtime.start(device, options: StartOptions(headless: true))
        }
        try await adb.waitForBoot(instance.serial, timeout: 600) { Shell.isAlive(pid) }
        log("cold boot to sys.boot_completed: \(elapsed(t0)) (\(instance.serial))")

        let apk = URL(fileURLWithPath: env["MOORBOX_TEST_APK"] ?? ".build/test-apk/moorbox-hello.apk")
        let hasAPK = FileManager.default.fileExists(atPath: apk.path)
        if hasAPK {
            t0 = Date()
            #expect(try await adb.install(apk, serial: instance.serial).contains("Success"))
            let installed = try await adb.userPackages(serial: instance.serial)
            #expect(installed.contains("org.moorbox.hello"))
            try await adb.launch("org.moorbox.hello", serial: instance.serial)
            log("APK install + launch: \(elapsed(t0))")
            try await Task.sleep(for: .seconds(2))
            let top = try await Shell.check(sdk.adbBinary, ["-s", instance.serial, "shell", "dumpsys", "activity", "activities"])
            #expect(top.stdout.contains("org.moorbox.hello/.MainActivity"))
            await #expect(throws: ADBError.self) { try await adb.launch("org.moorbox.doesnotexist", serial: instance.serial) }
        } else {
            Issue.record("Test APK missing at \(apk.path); run scripts/build-test-apk.sh")
        }

        #expect(try await adb.screenshotPNG(serial: instance.serial).count > 1000)
        try await adb.emulatorConsole(["rotate"], serial: instance.serial)
        try await adb.press(.home, serial: instance.serial)
        #expect(try await !(adb.logcat(serial: instance.serial, lines: 50)).isEmpty)

        t0 = Date()
        try await runtime.stop(instance, timeout: 120)
        log("graceful stop: \(elapsed(t0))")
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(device.hasQuickBootSnapshot)
        #expect(device.hasUserData, "avdmanager writes disk.dataPartition.path=<temp>; user data must still persist")

        t0 = Date()
        let pid2 = try runtime.start(device, options: StartOptions(headless: true))
        defer {
            if Shell.isAlive(pid2) {
                kill(pid2, SIGKILL)
            }; var s: Int32 = 0; waitpid(pid2, &s, WNOHANG)
        }
        let instance2 = try await waitForInstance(runtime, device, pid: pid2)
        try await adb.waitForBoot(instance2.serial, timeout: 300) { Shell.isAlive(pid2) }
        log("quick boot to sys.boot_completed: \(elapsed(t0))")
        if hasAPK {
            let kept = try await adb.userPackages(serial: instance2.serial)
            #expect(kept.contains("org.moorbox.hello"), "installed app did not survive a restart")
            try await adb.uninstall("org.moorbox.hello", serial: instance2.serial)
            let remaining = try await adb.userPackages(serial: instance2.serial)
            #expect(!remaining.contains("org.moorbox.hello"))
        }
        try await runtime.stop(instance2, timeout: 120)
        waitpid(pid2, &status, 0)
        #expect(LogFiles.tail(runtime.logFile(for: device)).contains("emulator -avd \(device.id)"))
        #expect(store.list().contains { $0.id == device.id }) // nothing deleted on the way
    }

    /// The no-Android-Studio path with only official tools: empty folder → cmdline-tools →
    /// Android CLI installs emulator, platform-tools and an image → avdmanager → boots.
    @Test(.timeLimit(.minutes(40)), .enabled(if: env["MOORBOX_INTEGRATION_FRESH"] == "1"))
    func freshSDKFromScratchBootsADevice() async throws {
        let java = try #require(await JavaLocator.find(managedRoot: URL(fileURLWithPath: "/nonexistent")))
        let tmp = try TempDir()
        let sdk = AndroidSDK(root: tmp.url.appendingPathComponent("sdk"))
        let catalog = try await SDKRepository().fetchCatalog()
        let arch = host.architecture
        try await CommandLineToolsInstaller.install(
            #require(catalog.latestStable(CommandLineToolsInstaller.packagePath, for: arch)),
            into: sdk,
            host: arch
        ) { _ in }
        let image = try #require(catalog.systemImages(for: arch, includePreviews: false).first { $0.systemImage!.tagIDs == ["default"] })
        let cli = AndroidCLI(sdk: sdk)
        for pkg in try [#require(catalog.latestStable("emulator", for: arch)), #require(catalog.latestStable("platform-tools", for: arch)), image] {
            let t0 = Date()
            try await cli.install(pkg, host: arch) { _ in }
            log("Android CLI installed \(pkg.path) \(pkg.revision) (\((pkg.archive(for: arch)?.size ?? 0) / 1_048_576) MB) in \(elapsed(t0))")
        }
        #expect(sdk.health(host: host).isReady)
        let installed = try #require(sdk.installedSystemImages().first)
        let store = AVDStore(home: tmp.url.appendingPathComponent("avd"))
        let limits = ResourceLimits.compute(host: host, apiLevel: installed.apiLevel)
        let device = try await store.create(
            DeviceSpec(
                displayName: "Fresh",
                image: installed,
                profileID: "medium_phone",
                resources: limits.clamp(.lightweight)
            ),
            limits: limits,
            using: AVDManager(sdk: sdk, java: java, avdHome: store.home)
        )
        let runtime = EmulatorRuntime(sdk: sdk, avdHome: store.home, logDirectory: tmp.url.appendingPathComponent("logs"))
        let adb = ADB(executable: sdk.adbBinary)
        try await adb.startServer()
        let t0 = Date()
        let pid = try runtime.start(device, options: StartOptions(headless: true))
        defer {
            if Shell.isAlive(pid) {
                kill(pid, SIGKILL)
            }; var s: Int32 = 0; waitpid(pid, &s, WNOHANG)
        }
        let instance = try await waitForInstance(runtime, device, pid: pid)
        try await adb.waitForBoot(instance.serial, timeout: 600) { Shell.isAlive(pid) }
        log("fresh SDK: first boot of \(installed.packagePath) in \(elapsed(t0))")
        try await runtime.stop(instance, timeout: 120)
    }

    // MARK: Helpers

    /// MOORBOX_TEST_SDK if set; otherwise a temp SDK with official tools whose system image is
    /// an APFS clone of one already on this Mac (no extra disk space, no image download).
    func preparedSDK(in tmp: TempDir) async throws -> (AndroidSDK, InstalledSystemImage) {
        if let path = env["MOORBOX_TEST_SDK"] {
            let sdk = AndroidSDK(root: URL(fileURLWithPath: path))
            let image = try #require(sdk.installedSystemImages().first { $0.abi == host.architecture.nativeAndroidABI })
            return (sdk, image)
        }
        let source = try #require(AndroidSDK.discover(preferred: nil), "No Android SDK with a system image on this Mac")
        let image = try #require(source.installedSystemImages().first { $0.abi == host.architecture.nativeAndroidABI })
        let sdk = AndroidSDK(root: tmp.url.appendingPathComponent("sdk"))
        let catalog = try await SDKRepository().fetchCatalog()
        let arch = host.architecture
        try await CommandLineToolsInstaller.install(
            #require(catalog.latestStable(CommandLineToolsInstaller.packagePath, for: arch)),
            into: sdk,
            host: arch
        ) { _ in }
        let cli = AndroidCLI(sdk: sdk)
        for path in ["emulator", "platform-tools"] {
            try await cli.install(#require(catalog.latestStable(path, for: arch)), host: arch) { _ in }
        }
        let destination = sdk.root.appendingPathComponent(image.relativeDirectory)
        try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        try await Shell.check(URL(fileURLWithPath: "/bin/cp"), [
            "-cR",
            source.root.appendingPathComponent(image.relativeDirectory).path,
            destination.path,
        ])
        return try (sdk, #require(sdk.installedSystemImages().first))
    }

    func waitForInstance(_ runtime: EmulatorRuntime, _ device: VirtualDevice, pid: pid_t) async throws -> RunningInstance {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let i = runtime.instance(for: device) {
                return i
            }
            guard Shell.isAlive(pid) else {
                Issue.record("emulator exited early:\n\(LogFiles.tail(runtime.logFile(for: device), maxBytes: 4000))")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ADBError.bootTimedOut(180)
    }

    static func snapshot(_ dir: URL) -> [String: Date] {
        var result: [String: Date] = [:]
        let walker = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey])
        while let url = walker?.nextObject() as? URL {
            result[url.path] = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate
        }
        return result
    }
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InstallPhase] = []
    var values: [InstallPhase] {
        lock.withLock { storage }
    }

    func append(_ p: InstallPhase) {
        lock.withLock { storage.append(p) }
    }
}
