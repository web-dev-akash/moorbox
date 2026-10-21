import Foundation
import Testing
@testable import MoorboxCore

/// Opt-in tests against the real network, SDK and emulator. They never touch the
/// user's own devices: AVDs are created in a temporary AVD home and removed afterwards.
///
///     MOORBOX_INTEGRATION=1 swift test --filter Integration
///
/// Optional: MOORBOX_SDK (SDK root), MOORBOX_TEST_APK (defaults to .build/test-apk/moorbox-hello.apk,
/// built by scripts/build-test-apk.sh).
let integrationEnabled = ProcessInfo.processInfo.environment["MOORBOX_INTEGRATION"] == "1"
let env = ProcessInfo.processInfo.environment

func log(_ message: String) { print("[integration] \(message)") }

@Suite(.serialized, .enabled(if: integrationEnabled))
struct IntegrationTests {
    @Test(.timeLimit(.minutes(2)))
    func liveCatalogHasRuntimeAndImagesForThisMac() async throws {
        let catalog = try await SDKRepository().fetchCatalog()
        let arch = HostInfo.current().architecture
        let emulator = try #require(catalog.latestStable("emulator", for: arch))
        let image = try #require(catalog.recommendedSystemImage(for: arch))
        #expect(catalog.latestStable("platform-tools", for: arch) != nil)
        #expect(image.licenseID.flatMap { catalog.licenses[$0] } != nil)
        log("emulator \(emulator.revision); recommended image \(image.path); \(catalog.packages.count) packages")
    }

    /// Real download → SHA-1 verification → extraction → atomic install, into a temp SDK.
    @Test(.timeLimit(.minutes(5)))
    func installsPlatformToolsIntoFreshSDK() async throws {
        let tmp = try TempDir()
        let sdk = AndroidSDK(root: tmp.url.appendingPathComponent("sdk"))
        let arch = HostInfo.current().architecture
        let catalog = try await SDKRepository().fetchCatalog()
        let pkg = try #require(catalog.latestStable("platform-tools", for: arch))
        let license = try #require(pkg.licenseID.flatMap { catalog.licenses[$0] })
        try sdk.recordAcceptance(of: license) // the test stands in for the user's consent
        let phases = PhaseLog()
        let start = Date()
        try await PackageInstaller(sdk: sdk, host: arch).install(pkg, license: license) { phases.append($0) }
        log("platform-tools \(pkg.revision) installed in \(String(format: "%.1f", Date().timeIntervalSince(start)))s")
        #expect(FileManager.default.isExecutableFile(atPath: sdk.adbBinary.path))
        #expect(machOArchitectures(of: sdk.adbBinary).contains(arch))
        #expect(sdk.platformToolsRevision == pkg.revision)
        #expect(phases.values.contains(.verifying))
        #expect(phases.values.last == .finished)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: sdk.root.appendingPathComponent(".moorbox-staging").path)) ?? []
        #expect(leftovers.isEmpty)
        let r = try await Shell.check(sdk.adbBinary, ["version"])
        #expect(r.stdout.contains("Android Debug Bridge"))
    }

    /// Cancel mid-download, then retry: the retry must continue from the bytes already
    /// received (URLSession resume data), and the install must still verify and succeed.
    @Test(.timeLimit(.minutes(5)))
    func cancelledDownloadResumes() async throws {
        let tmp = try TempDir()
        let sdk = AndroidSDK(root: tmp.url.appendingPathComponent("sdk"))
        let arch = HostInfo.current().architecture
        let catalog = try await SDKRepository().fetchCatalog()
        let pkg = try #require(catalog.latestStable("platform-tools", for: arch))
        let license = try #require(pkg.licenseID.flatMap { catalog.licenses[$0] })
        try sdk.recordAcceptance(of: license)
        let installer = PackageInstaller(sdk: sdk, host: arch)

        let first = PhaseLog()
        let task = Task { try await installer.install(pkg, license: license) { first.append($0) } }
        while !first.values.contains(where: { if case let .downloading(r, _) = $0 { return r > 2_000_000 }; return false }) {
            try await Task.sleep(for: .milliseconds(20))
        }
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(!FileManager.default.fileExists(atPath: sdk.root.appendingPathComponent("platform-tools").path))
        try await Task.sleep(for: .milliseconds(500)) // resume data arrives asynchronously after cancel

        let second = PhaseLog()
        try await installer.install(pkg, license: license) { second.append($0) }
        guard case let .downloading(resumedAt, _)? = second.values.first(where: { if case .downloading = $0 { return true }; return false }) else {
            Issue.record("no download progress reported"); return
        }
        log("resumed download at \(resumedAt) bytes")
        #expect(resumedAt > 1_000_000)
        #expect(sdk.platformToolsRevision == pkg.revision)
    }

    /// The first end-to-end milestone: create → cold boot → adb → APK install/launch →
    /// screenshot/rotate → graceful stop with snapshot → quick boot → data persisted → stop.
    @Test(.timeLimit(.minutes(20)))
    func deviceLifecycleEndToEnd() async throws {
        let host = HostInfo.current()
        let sdk = try #require(AndroidSDK.discover(preferred: env["MOORBOX_SDK"].map { URL(fileURLWithPath: $0) }),
                               "No Android SDK found")
        try #require(sdk.health(host: host).isReady, "SDK not ready: \(sdk.health(host: host).problems)")
        let image = try #require(sdk.installedSystemImages().first { $0.abi == host.architecture.nativeAndroidABI },
                                 "No system image for this host installed")
        let tmp = try TempDir()
        let store = AVDStore(home: tmp.url.appendingPathComponent("avd"))
        try FileManager.default.createDirectory(at: store.home, withIntermediateDirectories: true)
        let runtime = EmulatorRuntime(sdk: sdk, avdHome: store.home, logDirectory: tmp.url.appendingPathComponent("logs"))
        let adb = ADB(executable: sdk.adbBinary)
        try await adb.startServer()

        let limits = ResourceLimits.compute(host: host, apiLevel: image.apiLevel)
        let spec = DeviceSpec(displayName: "Moorbox IT \(UUID().uuidString.prefix(6))", image: image,
                              profile: DeviceProfile.all[1], resources: limits.clamp(.lightweight))
        let device = try store.create(spec, limits: limits)
        log("created \(device.id) with \(image.packagePath), \(spec.ramMB) MB, \(spec.cores) cores")

        // Cold boot.
        var t0 = Date()
        let pid = try runtime.start(device, options: StartOptions(coldBoot: true, headless: true))
        defer { if Shell.isAlive(pid) { kill(pid, SIGKILL) }; var s: Int32 = 0; waitpid(pid, &s, WNOHANG) }
        let instance = try await waitForInstance(runtime, device, pid: pid)
        #expect(instance.pid == pid)
        #expect(throws: RuntimeError.alreadyRunning(device.displayName)) {
            _ = try runtime.start(device, options: StartOptions(headless: true))
        }
        try await adb.waitForBoot(instance.serial, timeout: 600) { Shell.isAlive(pid) }
        let coldBoot = Date().timeIntervalSince(t0)
        log("cold boot to sys.boot_completed: \(String(format: "%.1f", coldBoot))s (\(instance.serial))")
        log("emulator RSS after boot: \(rssMB(pid)) MB")

        // APK workflow.
        let apk = URL(fileURLWithPath: env["MOORBOX_TEST_APK"] ?? ".build/test-apk/moorbox-hello.apk")
        if FileManager.default.fileExists(atPath: apk.path) {
            t0 = Date()
            let out = try await adb.install(apk, serial: instance.serial)
            #expect(out.contains("Success"))
            let installed = try await adb.userPackages(serial: instance.serial)
            #expect(installed.contains("org.moorbox.hello"))
            try await adb.launch("org.moorbox.hello", serial: instance.serial)
            log("APK install + launch: \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
            try await Task.sleep(for: .seconds(2))
            let top = try await Shell.check(sdk.adbBinary, ["-s", instance.serial, "shell", "dumpsys", "activity", "activities"])
            #expect(top.stdout.contains("org.moorbox.hello/.MainActivity"))
            // Real failure reporting: a non-APK and an unknown package.
            await #expect(throws: ADBError.self) { try await adb.launch("org.moorbox.doesnotexist", serial: instance.serial) }
        } else {
            log("SKIPPED APK checks: \(apk.path) not found (run scripts/build-test-apk.sh)")
        }

        let png = try await adb.screenshotPNG(serial: instance.serial)
        #expect(png.count > 1000)
        try await adb.emulatorConsole(["rotate"], serial: instance.serial)
        try await adb.press(.home, serial: instance.serial)
        let logcat = try await adb.logcat(serial: instance.serial, lines: 50)
        #expect(!logcat.isEmpty)

        // Graceful stop saves a quick-boot snapshot; user data stays.
        t0 = Date()
        try await runtime.stop(instance, timeout: 120)
        log("graceful stop: \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(device.hasQuickBootSnapshot)
        #expect(device.hasUserData)
        #expect(runtime.instance(for: device) == nil)

        // Quick boot from the snapshot.
        t0 = Date()
        let pid2 = try runtime.start(device, options: StartOptions(headless: true))
        defer { if Shell.isAlive(pid2) { kill(pid2, SIGKILL) }; var s: Int32 = 0; waitpid(pid2, &s, WNOHANG) }
        let instance2 = try await waitForInstance(runtime, device, pid: pid2)
        try await adb.waitForBoot(instance2.serial, timeout: 300) { Shell.isAlive(pid2) }
        log("quick boot to sys.boot_completed: \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        if FileManager.default.fileExists(atPath: apk.path) {
            let kept = try await adb.userPackages(serial: instance2.serial)
            #expect(kept.contains("org.moorbox.hello"))
            try await adb.uninstall("org.moorbox.hello", serial: instance2.serial)
            let remaining = try await adb.userPackages(serial: instance2.serial)
            #expect(!remaining.contains("org.moorbox.hello"))
        }
        try await runtime.stop(instance2, timeout: 120)
        waitpid(pid2, &status, 0)
        let logText = LogFiles.tail(runtime.logFile(for: device))
        #expect(logText.contains("emulator -avd \(device.id)"))
        #expect(store.list().contains { $0.id == device.id }) // nothing deleted on the way
    }

    /// The no-Android-Studio path: empty folder → emulator + platform-tools + system image
    /// downloaded and verified → device boots. Downloads ~1.3 GB, so it has its own switch:
    /// MOORBOX_INTEGRATION_FRESH=1.
    @Test(.timeLimit(.minutes(30)), .enabled(if: env["MOORBOX_INTEGRATION_FRESH"] == "1"))
    func freshSDKFromScratchBootsADevice() async throws {
        let host = HostInfo.current()
        let tmp = try TempDir()
        let sdk = AndroidSDK(root: tmp.url.appendingPathComponent("sdk"))
        let catalog = try await SDKRepository().fetchCatalog()
        let installer = PackageInstaller(sdk: sdk, host: host.architecture)
        // Smallest image for this host: AOSP "default" tag, newest stable.
        let image = try #require(catalog.systemImages(for: host.architecture, includePreviews: false)
            .filter { $0.systemImage!.tagIDs == ["default"] }.first)
        let packages = [try #require(catalog.latestStable("emulator", for: host.architecture)),
                        try #require(catalog.latestStable("platform-tools", for: host.architecture)), image]
        for pkg in packages {
            let license = try #require(pkg.licenseID.flatMap { catalog.licenses[$0] })
            try sdk.recordAcceptance(of: license)
            let t0 = Date()
            try await installer.install(pkg, license: license) { _ in }
            log("installed \(pkg.path) \(pkg.revision) (\((pkg.archive(for: host.architecture)?.size ?? 0) / 1_048_576) MB) in \(String(format: "%.0f", Date().timeIntervalSince(t0)))s")
        }
        #expect(sdk.health(host: host).isReady)
        let installed = try #require(sdk.installedSystemImages().first)
        #expect(installed.packagePath == image.path)

        let store = AVDStore(home: tmp.url.appendingPathComponent("avd"))
        try FileManager.default.createDirectory(at: store.home, withIntermediateDirectories: true)
        let limits = ResourceLimits.compute(host: host, apiLevel: installed.apiLevel)
        let device = try store.create(DeviceSpec(displayName: "Fresh", image: installed, profile: DeviceProfile.all[1],
                                                 resources: limits.clamp(.lightweight)), limits: limits)
        let runtime = EmulatorRuntime(sdk: sdk, avdHome: store.home, logDirectory: tmp.url.appendingPathComponent("logs"))
        let adb = ADB(executable: sdk.adbBinary)
        try await adb.startServer()
        let t0 = Date()
        let pid = try runtime.start(device, options: StartOptions(headless: true))
        defer { if Shell.isAlive(pid) { kill(pid, SIGKILL) }; var s: Int32 = 0; waitpid(pid, &s, WNOHANG) }
        let instance = try await waitForInstance(runtime, device, pid: pid)
        try await adb.waitForBoot(instance.serial, timeout: 600) { Shell.isAlive(pid) }
        log("fresh SDK: first boot of \(installed.packagePath) in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        try await runtime.stop(instance, timeout: 120)
    }

    func waitForInstance(_ runtime: EmulatorRuntime, _ device: VirtualDevice, pid: pid_t) async throws -> RunningInstance {
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if let i = runtime.instance(for: device) { return i }
            guard Shell.isAlive(pid) else {
                Issue.record("emulator exited early:\n\(LogFiles.tail(runtime.logFile(for: device), maxBytes: 4000))")
                throw CancellationError()
            }
            try await Task.sleep(for: .milliseconds(500))
        }
        throw ADBError.bootTimedOut(180)
    }

    func rssMB(_ pid: pid_t) -> Int {
        var info = proc_taskinfo()
        let size = proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, Int32(MemoryLayout<proc_taskinfo>.size))
        return size > 0 ? Int(info.pti_resident_size / 1_048_576) : -1
    }
}

final class PhaseLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [InstallPhase] = []
    var values: [InstallPhase] { lock.withLock { storage } }
    func append(_ p: InstallPhase) { lock.withLock { storage.append(p) } }
}
