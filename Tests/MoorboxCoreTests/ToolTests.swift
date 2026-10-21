import Foundation
import Testing
@testable import MoorboxCore

@Suite struct ADBTests {
    @Test func parsesDevices() {
        let out = "List of devices attached\nemulator-5554\tdevice\nemulator-5556\toffline\n\n"
        let devices = ADB.parseDevices(out)
        #expect(devices.map(\.serial) == ["emulator-5554", "emulator-5556"])
        #expect(devices.map(\.state) == ["device", "offline"])
        #expect(ADB.parseDevices("List of devices attached\n").isEmpty)
    }

    @Test func parsesVersion() {
        let out = "Android Debug Bridge version 1.0.41\nVersion 37.0.1-15733141\nInstalled as /opt/homebrew/bin/adb\n"
        #expect(ADB.parseVersion(out) == "37.0.1-15733141")
        #expect(ADB.parseVersion("garbage") == nil)
    }

    @Test func packageNamesAreStrict() {
        #expect(ADB.isValidPackageName("com.example.app"))
        #expect(ADB.isValidPackageName("org.my_app.v2"))
        #expect(!ADB.isValidPackageName("single"))
        #expect(!ADB.isValidPackageName("com.example;reboot"))
        #expect(!ADB.isValidPackageName("com.example && rm -rf /"))
        #expect(!ADB.isValidPackageName("com.$(id).x"))
        #expect(!ADB.isValidPackageName("com..x"))
        #expect(!ADB.isValidPackageName("1com.x"))
    }

    @Test func installErrorsAreExplained() {
        let err = ADB.installError(from: "Performing Streamed Install\nadb: failed to install app.apk: Failure [INSTALL_FAILED_NO_MATCHING_ABIS: Failed to extract native libraries, res=-113]")
        guard case let .installFailed(code, explanation, _) = err else { Issue.record("wrong case \(err)"); return }
        #expect(code == "INSTALL_FAILED_NO_MATCHING_ABIS")
        #expect(explanation.contains("CPU architecture"))
        if case let .installFailed(code, explanation, _) = ADB.installError(from: "Failure [INSTALL_FAILED_SOMETHING_NEW]") {
            #expect(code == "INSTALL_FAILED_SOMETHING_NEW")
            #expect(explanation == "Android rejected the APK.")
        } else { Issue.record("expected installFailed") }
        #expect(ADB.installError(from: "adb: device offline") == .commandFailed("The device is not connected to adb. Wait for it to finish booting, or restart it."))
    }

    @Test func resolvesLauncherActivity() {
        #expect(ADB.parseResolvedActivity("priority=0 preferredOrder=0 match=0x108000\ncom.example/.MainActivity\n") == "com.example/.MainActivity")
        #expect(ADB.parseResolvedActivity("No activity found\n") == nil)
        #expect(ADB.parseResolvedActivity("") == nil)
    }

    @Test func validatesAPKFiles() throws {
        let tmp = try TempDir()
        let good = tmp.url.appendingPathComponent("app.apk")
        try Data([0x50, 0x4B, 0x03, 0x04, 0, 0]).write(to: good)
        try ADB.validateAPK(good)
        let renamed = tmp.url.appendingPathComponent("fake.apk")
        try Data("hello".utf8).write(to: renamed)
        #expect(throws: ADBError.notAnAPK("fake.apk")) { try ADB.validateAPK(renamed) }
        let wrongExt = tmp.url.appendingPathComponent("app.zip")
        try Data([0x50, 0x4B, 0x03, 0x04]).write(to: wrongExt)
        #expect(throws: ADBError.notAnAPK("app.zip")) { try ADB.validateAPK(wrongExt) }
        #expect(throws: ADBError.notAnAPK("missing.apk")) { try ADB.validateAPK(tmp.url.appendingPathComponent("missing.apk")) }
    }
}

@Suite struct DiagnosticsTests {
    @Test func diagnosesRealEmulatorOutput() {
        // Captured from emulator 36.5.11 on macOS.
        let unknown = """
            ERROR        | Unknown AVD name [Nope], use -list-avds to see valid list.
            ERROR        | ANDROID_AVD_HOME is defined but there is no file Nope.ini in $ANDROID_AVD_HOME
            """
        #expect(EmulatorDiagnosis.diagnose(log: unknown, exitCode: 1).summary.contains("could not find this device"))
        let missing = """
            WARNING      | emulator has searched the above paths but found no valid sdk root directory.
            FATAL        | Cannot find AVD system path. Please define ANDROID_SDK_ROOT
            """
        #expect(EmulatorDiagnosis.diagnose(log: missing, exitCode: 1).summary.contains("system image is missing"))
        // Informational lines mentioning "snapshot" must not trigger the snapshot rule.
        let normal = "INFO         | Loading snapshot 'default_boot'...\nWARNING      | Failed to load snapshot 'default_boot'"
        #expect(EmulatorDiagnosis.diagnose(log: normal, exitCode: 3).summary == "The emulator stopped unexpectedly (exit code 3).")
    }

    @Test func redactsPersonalData() {
        let text = """
            SDK: /Users/alice/Library/Android/sdk
            grpc.token=abc123
            contact alice@example.com
            user alice ran it
            """
        let out = Redactor.redact(text, home: "/Users/alice", user: "alice")
        #expect(out.contains("SDK: ~/Library/Android/sdk"))
        #expect(out.contains("grpc.token=<redacted>"))
        #expect(!out.contains("abc123"))
        #expect(out.contains("<email>"))
        #expect(!out.contains("alice"))
    }

    @Test func logRotationAndTail() throws {
        let tmp = try TempDir()
        let log = tmp.url.appendingPathComponent("d.log")
        try String(repeating: "x", count: 2000).write(to: log, atomically: true, encoding: .utf8)
        LogFiles.rotate(log, maxBytes: 5000)
        #expect(FileManager.default.fileExists(atPath: log.path)) // under the limit: untouched
        LogFiles.rotate(log, maxBytes: 1000)
        #expect(!FileManager.default.fileExists(atPath: log.path))
        #expect(FileManager.default.fileExists(atPath: log.appendingPathExtension("1").path))
        try "line1\nline2\nline3\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(LogFiles.tail(log, maxBytes: 6) == "line3\n")
        #expect(LogFiles.tail(tmp.url.appendingPathComponent("none")) == "")
    }
}

@Suite struct ShellTests {
    @Test func capturesOutputAndExitCode() async throws {
        let r = try await Shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo out; echo err >&2; exit 3"])
        #expect(r.stdout == "out\n")
        #expect(r.stderr == "err\n")
        #expect(r.exitCode == 3)
        #expect(!r.succeeded)
    }

    @Test func argumentsAreNotShellInterpreted() async throws {
        let r = try await Shell.run(URL(fileURLWithPath: "/bin/echo"), ["$(whoami); rm -rf /"])
        #expect(r.stdout == "$(whoami); rm -rf /\n")
    }

    @Test func largeOutputDoesNotDeadlock() async throws {
        let r = try await Shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "head -c 1000000 /dev/zero"])
        #expect(r.output.count == 1_000_000)
    }

    @Test func timesOut() async throws {
        let start = Date()
        await #expect(throws: CommandError.timedOut(executable: "sleep", seconds: 0)) {
            try await Shell.run(URL(fileURLWithPath: "/bin/sleep"), ["10"], timeout: 0.3)
        }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func cancellationTerminatesProcess() async throws {
        let task = Task { try await Shell.run(URL(fileURLWithPath: "/bin/sleep"), ["10"]) }
        try await Task.sleep(for: .milliseconds(200))
        let start = Date()
        task.cancel()
        await #expect(throws: CancellationError.self) { try await task.value }
        #expect(Date().timeIntervalSince(start) < 5)
    }

    @Test func checkThrowsOnFailureAndMissingExecutable() async throws {
        await #expect(throws: CommandError.self) { try await Shell.check(URL(fileURLWithPath: "/usr/bin/false"), []) }
        await #expect(throws: CommandError.self) { try await Shell.run(URL(fileURLWithPath: "/nonexistent/tool"), []) }
    }

    @Test func spawnDetachedWritesLogAndCanBeObserved() async throws {
        let tmp = try TempDir()
        let log = tmp.url.appendingPathComponent("out.log")
        let pid = try Shell.spawnDetached(URL(fileURLWithPath: "/bin/sh"), ["-c", "echo \"$MOORBOX_TEST\"; echo e >&2"],
                                          environment: ["MOORBOX_TEST": "hello"], logFile: log)
        // Exited but not yet reaped (a zombie) must count as not alive.
        let deadline = Date().addingTimeInterval(5)
        while Shell.isAlive(pid), Date() < deadline { try await Task.sleep(for: .milliseconds(50)) }
        #expect(!Shell.isAlive(pid))
        #expect(kill(pid, 0) == 0) // still a zombie at this point
        var status: Int32 = 0
        waitpid(pid, &status, 0)
        #expect(try String(contentsOf: log, encoding: .utf8) == "hello\ne\n")
        #expect(!Shell.isAlive(pid))
        // Own session, so terminal signals to the app's process group don't reach it.
        let child = try Shell.spawnDetached(URL(fileURLWithPath: "/bin/sleep"), ["5"], environment: [:], logFile: log)
        defer { kill(child, SIGKILL); waitpid(child, &status, 0) }
        #expect(getsid(child) == child)
    }
}

@Suite struct InstallerTests {
    @Test func digests() throws {
        let tmp = try TempDir()
        try tmp.write("f", "abc")
        let f = tmp.url.appendingPathComponent("f")
        #expect(try ArchiveInstaller.digest(of: f, .sha1("")) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        #expect(try ArchiveInstaller.digest(of: f, .sha256("")) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func acceptsSingleTopLevelFolder() throws {
        let tmp = try TempDir()
        try tmp.write("x/arm64-v8a/system.img")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent("x/arm64-v8a/link").path, withDestinationPath: "system.img")
        let top = try ArchiveInstaller.validateExtraction(at: tmp.url.appendingPathComponent("x"))
        #expect(top.lastPathComponent == "arm64-v8a")
    }

    @Test func rejectsEscapingSymlinks() throws {
        let tmp = try TempDir()
        try tmp.write("x/pkg/file")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent("x/pkg/evil").path, withDestinationPath: "../../../etc")
        #expect(throws: InstallError.self) { try ArchiveInstaller.validateExtraction(at: tmp.url.appendingPathComponent("x")) }
        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("x/pkg/evil"))
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent("x/pkg/abs").path, withDestinationPath: "/etc/passwd")
        #expect(throws: InstallError.self) { try ArchiveInstaller.validateExtraction(at: tmp.url.appendingPathComponent("x")) }
    }

    @Test func rejectsUnexpectedLayout() throws {
        let tmp = try TempDir()
        try tmp.write("x/a/file")
        try tmp.write("x/b/file")
        #expect(throws: InstallError.self) { try ArchiveInstaller.validateExtraction(at: tmp.url.appendingPathComponent("x")) }
        try tmp.write("y/loose-file")
        #expect(throws: InstallError.self) { try ArchiveInstaller.validateExtraction(at: tmp.url.appendingPathComponent("y")) }
    }

    @Test func refusesBeforeDownloading() async throws {
        let tmp = try TempDir()
        let destination = tmp.url.appendingPathComponent("pkg")
        func spec(_ url: String, hosts: Set<String> = ["dl.google.com"]) -> ArchiveSpec {
            ArchiveSpec(url: URL(string: url)!, size: 10, checksum: .sha1(String(repeating: "0", count: 40)), format: .zip, trustedHosts: hosts)
        }
        await #expect(throws: InstallError.untrustedURL("http://dl.google.com/x.zip")) {
            try await ArchiveInstaller.install(spec("http://dl.google.com/x.zip"), to: destination, stagingRoot: tmp.url) { _ in }
        }
        await #expect(throws: InstallError.untrustedURL("https://evil.example/x.zip")) {
            try await ArchiveInstaller.install(spec("https://evil.example/x.zip"), to: destination, stagingRoot: tmp.url) { _ in }
        }
        try tmp.write("pkg/source.properties")
        await #expect(throws: InstallError.alreadyInstalled("pkg")) {
            try await ArchiveInstaller.install(spec("https://dl.google.com/x.zip"), to: destination, stagingRoot: tmp.url) { _ in }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: tmp.url.path) == ["pkg"]) // no staging left behind
    }
}

@Suite struct JavaTests {
    @Test func parsesReleaseFiles() {
        #expect(JavaLocator.parseRelease("IMPLEMENTOR=\"JetBrains\"\nJAVA_VERSION=\"21.0.10\"\n")?.major == 21)
        #expect(JavaLocator.parseRelease("JAVA_VERSION=\"17.0.20\"")?.version == "17.0.20")
        #expect(JavaLocator.parseRelease("JAVA_VERSION=\"1.8.0_402\"")?.major == 8)
        #expect(JavaLocator.parseRelease("OS_NAME=Darwin") == nil)
    }

    func fakeJDK(_ tmp: TempDir, _ path: String, version: String) throws -> URL {
        try tmp.write("\(path)/release", "JAVA_VERSION=\"\(version)\"\n")
        try tmp.write("\(path)/bin/java", "#!/bin/sh\n")
        let java = tmp.url.appendingPathComponent("\(path)/bin/java")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: java.path)
        return tmp.url.appendingPathComponent(path)
    }

    @Test func prefersJavaHomeThenManagedNewestFirst() async throws {
        let tmp = try TempDir()
        let env = try fakeJDK(tmp, "env-jdk", version: "21.0.1")
        _ = try fakeJDK(tmp, "managed/jdk-17.0.9+9/Contents/Home", version: "17.0.9")
        _ = try fakeJDK(tmp, "managed/jdk-21.0.5+11/Contents/Home", version: "21.0.5")
        let managed = tmp.url.appendingPathComponent("managed")
        let fromEnv = await JavaLocator.find(managedRoot: managed, environment: ["JAVA_HOME": env.path])
        #expect(fromEnv?.source == .environment)
        let fromManaged = await JavaLocator.find(managedRoot: managed, environment: [:])
        #expect(fromManaged?.source == .moorbox)
        #expect(fromManaged?.version == "21.0.5")
    }

    @Test func rejectsTooOldOrBrokenJDKs() throws {
        let tmp = try TempDir()
        let old = try fakeJDK(tmp, "old", version: "11.0.2")
        #expect(JavaLocator.inspect(home: old, source: .environment)?.majorVersion == 11) // found, but…
        #expect(JavaLocator.minimumMajorVersion == 17) // …below the minimum, so find() skips it
        try tmp.write("broken/release", "JAVA_VERSION=\"21\"")
        #expect(JavaLocator.inspect(home: tmp.url.appendingPathComponent("broken"), source: .environment) == nil) // no bin/java
    }

    @Test func parsesAdoptiumResponse() throws {
        let release = try Adoptium.parse(fixture("adoptium-latest-21-aarch64.json"))
        #expect(release.archiveName.hasSuffix(".tar.gz"))
        #expect(release.url.host == "github.com")
        #expect(release.url.path.hasPrefix("/adoptium/"))
        #expect(release.sha256.count == 64)
        #expect(release.size > 100_000_000)
        #expect(release.releaseName.hasPrefix("jdk-21"))
        #expect(throws: (any Error).self) { try Adoptium.parse(Data("[]".utf8)) }
        let evil = Data(#"[{"binary":{"image_type":"jdk","package":{"name":"x.tar.gz","link":"https://evil.example/x.tar.gz","checksum":"\#(String(repeating: "a", count: 64))","size":1}},"release_name":"jdk-21","version":{"semver":"21"}}]"#.utf8)
        #expect(throws: RepositoryError.self) { try Adoptium.parse(evil) }
    }
}

@Suite struct GoogleToolTests {
    @Test func parsesAVDManagerDeviceList() throws {
        let profiles = AVDManager.parseDevices(String(decoding: try fixture("avdmanager-list-device.txt"), as: UTF8.self))
        #expect(profiles.count == 96)
        let medium = try #require(profiles.first { $0.id == "medium_phone" })
        #expect(medium.name == "Medium Phone")
        #expect(medium.oem == "Generic")
        #expect(medium.isPhoneOrTablet)
        #expect(profiles.contains { $0.id == "medium_tablet" && $0.isPhoneOrTablet })
        #expect(profiles.contains { $0.id == "pixel_9" })
        let wear = profiles.filter { $0.tag?.contains("wear") == true }
        #expect(!wear.isEmpty && wear.allSatisfy { !$0.isPhoneOrTablet })
    }

    @Test func androidCLIArguments() throws {
        let cli = AndroidCLI(sdk: AndroidSDK(root: URL(fileURLWithPath: "/sdk")))
        #expect(cli.arguments(["sdk", "list"]) == ["--no-metrics", "--sdk=/sdk", "sdk", "list"])
        #expect(AndroidCLI.cliPath("system-images;android-36;default;arm64-v8a") == "system-images/android-36/default/arm64-v8a")
        #expect(AndroidCLI.channelFlags("stable").isEmpty)
        #expect(AndroidCLI.channelFlags("beta") == ["--beta"])
        #expect(AndroidCLI.channelFlags("canary") == ["--canary"])
        let catalog = try loadCatalog()
        let emulatorDev = try #require(catalog.packages.first { $0.path == "emulator" && $0.channel == "dev" })
        #expect(AndroidCLI.installArguments(for: emulatorDev) == ["sdk", "install", "--canary", "emulator"])
    }

    @Test func cliErrorsDropNoise() {
        let out = "\rhttps://dl.google.com/x.zip...\nUnzipping x......\nDisable Android CLI metrics collection by using the --no-metrics flag.\nError: Package not found: foo\n"
        #expect(AndroidCLI.errorMessage(from: out) == "Error: Package not found: foo")
    }

    @Test func missingToolsAreReportedNotCrashed() async {
        let cli = AndroidCLI(sdk: AndroidSDK(root: URL(fileURLWithPath: "/nonexistent")))
        #expect(!cli.isInstalled)
        await #expect(throws: ToolError.notInstalled("Google's command-line tools")) { try await cli.remove("emulator") }
    }
}

@Suite struct ShellInputTests {
    @Test func feedsStandardInput() async throws {
        let r = try await Shell.run(URL(fileURLWithPath: "/bin/sh"), ["-c", "read answer; echo got:$answer"], input: Data("no\n".utf8))
        #expect(r.stdout == "got:no\n")
    }
}
