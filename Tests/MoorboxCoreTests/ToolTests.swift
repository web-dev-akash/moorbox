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
    @Test func sha1OfFile() throws {
        let tmp = try TempDir()
        try tmp.write("f", "abc")
        #expect(try PackageInstaller.sha1(of: tmp.url.appendingPathComponent("f")) == "a9993e364706816aba3e25717850c26c9cd0d89d")
    }

    @Test func acceptsSingleTopLevelFolder() throws {
        let tmp = try TempDir()
        try tmp.write("x/arm64-v8a/system.img")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent("x/arm64-v8a/link").path, withDestinationPath: "system.img")
        let top = try PackageInstaller.validateExtraction(at: tmp.url.appendingPathComponent("x"))
        #expect(top.lastPathComponent == "arm64-v8a")
    }

    @Test func rejectsEscapingSymlinks() throws {
        let tmp = try TempDir()
        try tmp.write("x/pkg/file")
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent("x/pkg/evil").path, withDestinationPath: "../../../etc")
        #expect(throws: InstallError.self) { try PackageInstaller.validateExtraction(at: tmp.url.appendingPathComponent("x")) }
        try FileManager.default.removeItem(at: tmp.url.appendingPathComponent("x/pkg/evil"))
        try FileManager.default.createSymbolicLink(atPath: tmp.url.appendingPathComponent("x/pkg/abs").path, withDestinationPath: "/etc/passwd")
        #expect(throws: InstallError.self) { try PackageInstaller.validateExtraction(at: tmp.url.appendingPathComponent("x")) }
    }

    @Test func rejectsUnexpectedLayout() throws {
        let tmp = try TempDir()
        try tmp.write("x/a/file")
        try tmp.write("x/b/file")
        #expect(throws: InstallError.self) { try PackageInstaller.validateExtraction(at: tmp.url.appendingPathComponent("x")) }
        try tmp.write("y/loose-file")
        #expect(throws: InstallError.self) { try PackageInstaller.validateExtraction(at: tmp.url.appendingPathComponent("y")) }
    }

    @Test func refusesBeforeDownloading() async throws {
        let tmp = try TempDir()
        let catalog = try loadCatalog()
        let pkg = try #require(catalog.latestStable("platform-tools", for: .arm64))
        let license = try #require(catalog.licenses[pkg.licenseID!])
        let installer = PackageInstaller(sdk: AndroidSDK(root: tmp.url), host: .arm64)
        // License not yet accepted.
        await #expect(throws: InstallError.licenseNotAccepted(license.id)) {
            try await installer.install(pkg, license: license) { _ in }
        }
        // Already installed and not replacing.
        try AndroidSDK(root: tmp.url).recordAcceptance(of: license)
        try tmp.write("platform-tools/source.properties", "Pkg.Revision=1\n")
        await #expect(throws: InstallError.alreadyInstalled(pkg.displayName)) {
            try await installer.install(pkg, license: license) { _ in }
        }
        // Untrusted host in metadata.
        var evil = pkg
        evil.path = "evil"
        evil.archives = evil.archives.map { var a = $0; a.url = URL(string: "https://example.com/x.zip")!; return a }
        await #expect(throws: RepositoryError.self) { try await installer.install(evil, license: nil) { _ in } }
        #expect(!FileManager.default.fileExists(atPath: tmp.url.appendingPathComponent(".moorbox-staging").path))
    }
}
