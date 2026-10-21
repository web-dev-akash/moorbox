import Foundation
@testable import MoorboxCore
import Testing

/// A fresh temporary directory, removed when the test ends.
final class TempDir {
    let url: URL
    init() throws {
        url = FileManager.default.temporaryDirectory.appendingPathComponent("moorbox-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func write(_ relative: String, _ content: String = "") throws {
        let file = url.appendingPathComponent(relative)
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try content.write(to: file, atomically: true, encoding: .utf8)
    }
}

struct SDKDiscoveryTests {
    @Test func candidateOrderAndDeduplication() {
        let home = URL(fileURLWithPath: "/Users/test")
        let urls = AndroidSDK.candidateLocations(
            preferred: URL(fileURLWithPath: "/custom"),
            environment: ["ANDROID_HOME": "/env/home", "ANDROID_SDK_ROOT": "/custom"], home: home
        )
        #expect(urls.map(\.path) == ["/custom", "/env/home", "/Users/test/Library/Android/sdk"])
    }

    @Test func discoversFirstDirectoryWithTools() throws {
        let tmp = try TempDir()
        try tmp.write("empty/README")
        try tmp.write("sdk/platform-tools/adb")
        let found = AndroidSDK.discover(
            preferred: tmp.url.appendingPathComponent("empty"),
            environment: ["ANDROID_HOME": tmp.url.appendingPathComponent("sdk").path],
            home: tmp.url
        )
        #expect(found?.root.lastPathComponent == "sdk")
        #expect(AndroidSDK.discover(preferred: nil, environment: [:], home: tmp.url) == nil)
    }

    @Test func healthReportsMissingAndWrongArchitecture() throws {
        let tmp = try TempDir()
        let sdk = AndroidSDK(root: tmp.url)
        let host = HostInfo(macOSVersion: "15.0", architecture: .arm64, physicalMemory: 16 << 30, cpuCount: 10, hypervisorSupported: true)
        #expect(sdk.health(host: host).problems.count == 2)

        // An x86_64-only emulator binary on an arm64 host.
        var header = Data([0xCF, 0xFA, 0xED, 0xFE, 0x07, 0x00, 0x00, 0x01])
        header.append(Data(count: 24))
        try FileManager.default.createDirectory(at: sdk.emulatorBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try header.write(to: sdk.emulatorBinary)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: sdk.emulatorBinary.path)
        try tmp.write("emulator/source.properties", "Pkg.Revision=36.5.11\n")
        let health = sdk.health(host: host)
        #expect(health.emulatorArchitectures == [.x86_64])
        #expect(health.emulatorRevision == Revision(36, 5, 11))
        #expect(health.problems.contains { $0.contains("not this Mac") })
    }

    @Test func scansInstalledSystemImages() throws {
        let tmp = try TempDir()
        try tmp.write("system-images/android-34/google_apis/arm64-v8a/system.img")
        try tmp.write("system-images/android-34/google_apis/arm64-v8a/source.properties", """
        Pkg.Revision=14
        AndroidVersion.ApiLevel=34
        SystemImage.Abi=arm64-v8a
        SystemImage.TagId=google_apis
        SystemImage.TagDisplay=Google APIs
        """)
        try tmp.write("system-images/android-36/default/arm64-v8a/system.img")
        try tmp.write("system-images/android-36/default/arm64-v8a/source.properties", "AndroidVersion.ApiLevel=36\n")
        try tmp.write("system-images/android-35/broken/arm64-v8a/source.properties", "AndroidVersion.ApiLevel=35\n") // no system.img
        let images = AndroidSDK(root: tmp.url).installedSystemImages()
        #expect(images.map(\.packagePath) == ["system-images;android-36;default;arm64-v8a", "system-images;android-34;google_apis;arm64-v8a"])
        #expect(images[1].relativeDirectory == "system-images/android-34/google_apis/arm64-v8a/")
        #expect(images[1].tagDisplay == "Google APIs")
        #expect(images[0].tagID == "default")
    }

    @Test func licenseHashMatchesSdkmanagerFormat() throws {
        let catalog = try loadCatalog()
        let license = try #require(catalog.licenses["android-sdk-license"])
        // Independently computed: sha1(text.strip()) in Python over the same fixture.
        #expect(AndroidSDK.licenseHash(license) == "9002c006f4b8d9a16e715a9fa4df30ddb8abf9d9")
    }

    @Test func detectsAcceptedLicensesWrittenByGoogleTools() throws {
        let tmp = try TempDir()
        let sdk = AndroidSDK(root: tmp.url)
        let license = License(id: "test-license", text: "  Some terms\n")
        #expect(!sdk.hasAccepted(license))
        // Format written by the Android CLI / sdkmanager: one sha1 per line, sometimes a leading blank line.
        try tmp.write("licenses/test-license", "\n24333f8a63b6825ea9c5514f83c2829b004d1fee\n\(AndroidSDK.licenseHash(license))")
        #expect(sdk.hasAccepted(license))
        #expect(!sdk.hasAccepted(License(id: "test-license", text: "Other terms")))
    }

    @Test func commandLineToolsDetection() throws {
        let tmp = try TempDir()
        let sdk = AndroidSDK(root: tmp.url)
        #expect(sdk.commandLineToolsRevision == nil)
        try tmp.write("cmdline-tools/latest/bin/android", "#!/bin/sh\n")
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: tmp.url.appendingPathComponent("cmdline-tools/latest/bin/android").path
        )
        try tmp.write("cmdline-tools/latest/source.properties", "Pkg.Revision=23.0\nPkg.Path=cmdline-tools;23.0\n")
        #expect(sdk.commandLineToolsRevision == Revision(23, 0))
        // An SDK holding only cmdline-tools is still discovered.
        #expect(AndroidSDK.discover(preferred: tmp.url, environment: [:], home: tmp.url)?.root == sdk.root)
    }
}

struct HostTests {
    @Test func machOThinAndFat() {
        var thin = Data([0xCF, 0xFA, 0xED, 0xFE, 0x0C, 0x00, 0x00, 0x01])
        thin.append(Data(count: 24))
        #expect(machOArchitectures(header: thin) == [.arm64])

        var fat = Data([0xCA, 0xFE, 0xBA, 0xBE, 0, 0, 0, 2])
        fat.append(Data([0x01, 0, 0, 0x07] + [UInt8](repeating: 0, count: 16)))
        fat.append(Data([0x01, 0, 0, 0x0C] + [UInt8](repeating: 0, count: 16)))
        #expect(machOArchitectures(header: fat) == [.arm64, .x86_64])
        #expect(machOArchitectures(header: Data("#!/bin/sh\n".utf8)).isEmpty)
        #expect(machOArchitectures(header: Data()).isEmpty)
    }

    @Test func currentHostIsSane() {
        let host = HostInfo.current()
        #expect(host.physicalMemory > 0)
        #expect(host.cpuCount > 0)
        #if arch(arm64)
            #expect(host.architecture == .arm64)
        #endif
    }

    @Test func propertiesRoundTrip() {
        let parsed = Properties.parse("# comment\na=1\n b = two words \nurl=https\\://x\nnoequals\n")
        #expect(parsed == ["a": "1", "b": "two words", "url": "https://x"])
        #expect(Properties.parse(Properties.serialize(["z": "1", "a": "2"])) == ["z": "1", "a": "2"])
        #expect(Properties.serialize(["z": "1", "a": "2"]) == "a=2\nz=1\n")
    }
}
