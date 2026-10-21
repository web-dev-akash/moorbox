import Foundation
import Testing
@testable import MoorboxCore

let testImage = InstalledSystemImage(
    packagePath: "system-images;android-36;google_apis;arm64-v8a",
    relativeDirectory: "system-images/android-36/google_apis/arm64-v8a/",
    platformDirectory: "android-36", apiLevel: "36", codename: nil,
    tagID: "google_apis", tagDisplay: "Google APIs", abi: "arm64-v8a", revision: "7")

let bigHost = HostInfo(macOSVersion: "26.0", architecture: .arm64, physicalMemory: 24 << 30, cpuCount: 14, hypervisorSupported: true)
let smallHost = HostInfo(macOSVersion: "26.0", architecture: .arm64, physicalMemory: 8 << 30, cpuCount: 8, hypervisorSupported: true)

@Suite struct ResourceTests {
    @Test func limitsDependOnHostAndAPI() {
        let big = ResourceLimits.compute(host: bigHost, apiLevel: "36")
        #expect(big.ramMB == 2048...8192)
        #expect(big.cores == 1...8)
        let small = ResourceLimits.compute(host: smallHost, apiLevel: "36")
        #expect(small.ramMB == 2048...4096)
        #expect(small.cores == 1...6)
        // API 37+ needs at least 4 GB.
        #expect(ResourceLimits.compute(host: bigHost, apiLevel: "37.0").ramMB.lowerBound == 4096)
        #expect(ResourceLimits.compute(host: smallHost, apiLevel: "37").ramMB == 4096...4096)
    }

    @Test func presetsAreClampedToLimits() {
        let small = ResourceLimits.compute(host: smallHost, apiLevel: "37")
        let lw = small.clamp(.lightweight)
        #expect(lw.ramMB == 4096) // raised to the API 37 minimum
        let perf = small.clamp(.performance)
        #expect(perf.ramMB == 4096)
        #expect(perf.cores == 6)
        let big = ResourceLimits.compute(host: bigHost, apiLevel: "35")
        #expect(big.clamp(.balanced) == .balanced)
    }
}

@Suite struct AVDTests {
    func spec(_ name: String = "Test Phone", ram: Int = 2048) -> DeviceSpec {
        var s = DeviceSpec(displayName: name, image: testImage, profile: DeviceProfile.all[0], resources: .lightweight)
        s.ramMB = ram
        return s
    }

    @Test func idsAreSanitised() {
        #expect(AVDStore.makeID(from: "My Phone (API 36)") == "My_Phone__API_36")
        #expect(AVDStore.makeID(from: "../../etc") == "etc")
        #expect(AVDStore.makeID(from: "Téléphone") == "T_l_phone")
        #expect(AVDStore.makeID(from: "!!!") == "")
    }

    @Test func validation() throws {
        let limits = ResourceLimits.compute(host: bigHost, apiLevel: "36")
        try AVDStore.validate(spec(), limits: limits)
        #expect(throws: AVDError.self) { try AVDStore.validate(spec("  "), limits: limits) }
        #expect(throws: AVDError.self) { try AVDStore.validate(spec("???"), limits: limits) }
        #expect(throws: AVDError.self) { try AVDStore.validate(spec(ram: 1024), limits: limits) }
        #expect(throws: AVDError.self) { try AVDStore.validate(spec(ram: 16384), limits: limits) }
        var badScreen = spec()
        badScreen.profile.width = 100
        #expect(throws: AVDError.self) { try AVDStore.validate(badScreen, limits: limits) }
    }

    @Test func configContainsRuntimeKeys() {
        let config = AVDStore.config(id: "Test_Phone", spec: spec())
        #expect(config["AvdId"] == "Test_Phone")
        #expect(config["image.sysdir.1"] == "system-images/android-36/google_apis/arm64-v8a/")
        #expect(config["hw.cpu.arch"] == "arm64")
        #expect(config["abi.type"] == "arm64-v8a")
        #expect(config["hw.ramSize"] == "2048")
        #expect(config["hw.cpu.ncore"] == "2")
        #expect(config["disk.dataPartition.size"] == "4G")
        #expect(config["hw.lcd.width"] == "1080")
        #expect(config["PlayStore.enabled"] == "false")
        #expect(config["fastboot.forceFastBoot"] == "yes")
    }

    @Test func createListUpdateRename() throws {
        let tmp = try TempDir()
        let store = AVDStore(home: tmp.url)
        let limits = ResourceLimits.compute(host: bigHost, apiLevel: "36")
        let device = try store.create(spec(), limits: limits)
        #expect(device.id == "Test_Phone")
        #expect(device.target == "android-36")
        #expect(device.apiLevel == "36")
        #expect(device.ramMB == 2048)
        #expect(device.hasUserData == false)
        #expect(throws: AVDError.nameTaken("Test Phone")) { try store.create(spec(), limits: limits) }

        // Unknown keys written by other tools must survive updates.
        try tmp.write("Test_Phone.avd/config.ini", Properties.serialize(device.config.merging(["custom.key": "kept"]) { a, _ in a }))
        try store.update(device, changes: ["hw.ramSize": "3072"])
        try store.rename(device, to: "Renamed")
        let reloaded = try #require(store.list().first)
        #expect(reloaded.displayName == "Renamed")
        #expect(reloaded.ramMB == 3072)
        #expect(reloaded.config["custom.key"] == "kept")
        #expect(reloaded.id == "Test_Phone") // the on-disk id never changes
        #expect(throws: AVDError.self) { try store.rename(device, to: " ") }
    }

    @Test func readsAndroidStudioDevices() throws {
        let tmp = try TempDir()
        try tmp.write("Pixel_6.ini", "avd.ini.encoding=UTF-8\npath=\(tmp.url.path)/Pixel_6.avd\npath.rel=avd/Pixel_6.avd\ntarget=android-34\n")
        try tmp.write("Pixel_6.avd/config.ini", "avd.ini.displayname=Pixel 6\nhw.ramSize=2G\nimage.sysdir.1=system-images/android-34/google_apis/arm64-v8a/\nhw.lcd.width=1080\nhw.lcd.height=2400\nhw.lcd.density=420\n")
        try tmp.write("Orphan.ini", "path=/nonexistent/Orphan.avd\n")
        let devices = AVDStore(home: tmp.url).list()
        #expect(devices.count == 1)
        #expect(devices[0].displayName == "Pixel 6")
        #expect(devices[0].ramMB == 2048)
        #expect(devices[0].apiLevel == "34")
        #expect(devices[0].resolution == "1080×2400 @ 420 dpi")
    }

    @Test func avdHomeLookupOrder() {
        let home = URL(fileURLWithPath: "/Users/t")
        #expect(AVDStore.defaultHome(environment: [:], home: home).path == "/Users/t/.android/avd")
        #expect(AVDStore.defaultHome(environment: ["ANDROID_USER_HOME": "/x"], home: home).path == "/x/avd")
        #expect(AVDStore.defaultHome(environment: ["ANDROID_AVD_HOME": "/y", "ANDROID_USER_HOME": "/x"], home: home).path == "/y")
    }

    @Test func quickBootResetKeepsUserData() throws {
        let tmp = try TempDir()
        let store = AVDStore(home: tmp.url)
        let device = try store.create(spec(), limits: ResourceLimits.compute(host: bigHost, apiLevel: "36"))
        try tmp.write("Test_Phone.avd/userdata-qemu.img", "data")
        try tmp.write("Test_Phone.avd/snapshots/default_boot/snapshot.pb", "snap")
        #expect(device.hasQuickBootSnapshot)
        try store.deleteQuickBootSnapshot(device)
        #expect(!device.hasQuickBootSnapshot)
        #expect(device.hasUserData)
    }
}

@Suite struct RuntimeTests {
    let device = VirtualDevice(id: "Test_Phone", iniFile: URL(fileURLWithPath: "/a/Test_Phone.ini"),
                               directory: URL(fileURLWithPath: "/a/Test_Phone.avd"), config: [:], target: nil)

    @Test func launchArguments() {
        let base = ["-avd", "Test_Phone", "-no-metrics", "-crash-report-mode", "never"]
        #expect(EmulatorRuntime.arguments(for: device, options: StartOptions()) == base)
        #expect(EmulatorRuntime.arguments(for: device, options: StartOptions(coldBoot: true, headless: true))
            == base + ["-no-snapshot-load", "-no-window", "-no-audio"])
    }

    @Test func environmentPointsAtSDKAndAVDHome() {
        let runtime = EmulatorRuntime(sdk: AndroidSDK(root: URL(fileURLWithPath: "/sdk")), avdHome: URL(fileURLWithPath: "/avds"),
                                      logDirectory: URL(fileURLWithPath: "/logs"))
        let env = runtime.environment(base: ["PATH": "/usr/bin", "ANDROID_HOME": "/other"])
        #expect(env["ANDROID_HOME"] == "/sdk")
        #expect(env["ANDROID_SDK_ROOT"] == "/sdk")
        #expect(env["ANDROID_AVD_HOME"] == "/avds")
        #expect(env["PATH"] == "/usr/bin")
    }

    @Test func discoveryFilesAndMatching() throws {
        let tmp = try TempDir()
        // Real format observed from emulator 36.5.11.
        try tmp.write("pid_\(getpid()).ini", """
            avd.id=Test_Phone
            port.serial=5556
            port.adb=5557
            avd.name=Test Phone
            avd.dir=/a/Test_Phone.avd
            grpc.token=secret
            """)
        try tmp.write("pid_abc.ini", "avd.name=x\nport.serial=1\n")
        try tmp.write("other.txt", "")
        let parsed = try #require(EmulatorRuntime.parseDiscoveryFile(tmp.url.appendingPathComponent("pid_\(getpid()).ini")))
        #expect(parsed.serial == "emulator-5556")
        #expect(parsed.avdID == "Test_Phone") // avd.id, not the display name in avd.name
        #expect(parsed.avdDirectory == "/a/Test_Phone.avd")
        #expect(EmulatorRuntime.parseDiscoveryFile(tmp.url.appendingPathComponent("pid_abc.ini")) == nil)

        let runtime = EmulatorRuntime(sdk: AndroidSDK(root: tmp.url), avdHome: tmp.url, logDirectory: tmp.url, discoveryDirectory: tmp.url)
        #expect(runtime.instance(for: device, in: [parsed]) == parsed)
        var elsewhere = parsed
        elsewhere.avdDirectory = "/other/home/Test_Phone.avd"
        #expect(runtime.instance(for: device, in: [elsewhere]) == nil) // same name, different AVD home
        // The test runner is alive but is not an emulator, so a stale/reused PID is ignored.
        #expect(runtime.runningInstances().isEmpty)
    }
}

@Suite struct DeviceStateTests {
    let instance = RunningInstance(pid: 1, avdID: "a", avdDirectory: "/a", consolePort: 5554)
    let failure = Diagnosis(summary: "boom", remedy: "fix")

    @Test func transitions() {
        #expect(DeviceState.resolve(instance: nil, bootCompleted: false, pending: nil, lastFailure: nil) == .stopped)
        #expect(DeviceState.resolve(instance: nil, bootCompleted: false, pending: .starting, lastFailure: nil) == .starting)
        #expect(DeviceState.resolve(instance: instance, bootCompleted: false, pending: .starting, lastFailure: nil) == .booting(serial: "emulator-5554"))
        #expect(DeviceState.resolve(instance: instance, bootCompleted: true, pending: nil, lastFailure: nil) == .running(serial: "emulator-5554"))
        #expect(DeviceState.resolve(instance: instance, bootCompleted: true, pending: .stopping, lastFailure: nil) == .stopping)
        #expect(DeviceState.resolve(instance: nil, bootCompleted: false, pending: nil, lastFailure: failure) == .failed(failure))
        // A live instance always wins over a stale failure.
        #expect(DeviceState.resolve(instance: instance, bootCompleted: true, pending: nil, lastFailure: failure) == .running(serial: "emulator-5554"))
    }

    @Test func flags() {
        #expect(DeviceState.running(serial: "s").isActive)
        #expect(DeviceState.running(serial: "s").serial == "s")
        #expect(!DeviceState.stopped.isActive)
        #expect(DeviceState.starting.serial == nil)
        #expect(!DeviceState.failed(failure).isActive)
    }
}
