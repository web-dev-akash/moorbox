import Foundation
@testable import MoorboxCore
import Testing

func fixture(_ name: String) throws -> Data {
    let url = try #require(Bundle.module.url(forResource: "Fixtures/\(name)", withExtension: nil))
    return try Data(contentsOf: url)
}

func loadCatalog() throws -> Catalog {
    var catalog = try RepositoryParser.parse(fixture("repository2-3.xml"), baseURL: SDKRepository.baseURL)
    try catalog.merge(RepositoryParser.parse(
        fixture("sys-img-google_apis.xml"),
        baseURL: SDKRepository.baseURL.appendingPathComponent("sys-img/google_apis/")
    ))
    return catalog
}

struct RepositoryParserTests {
    @Test func parsesHostPackagesAndChannels() throws {
        let catalog = try loadCatalog()
        let emulators = catalog.packages.filter { $0.path == "emulator" }
        #expect(emulators.count == 2)
        #expect(Set(emulators.map(\.channel)) == ["stable", "dev"])

        let stable = try #require(catalog.latestStable("emulator", for: .arm64))
        #expect(stable.revision == Revision(37, 2, 12))
        #expect(stable.licenseID == "android-sdk-license")
        let archive = try #require(stable.archive(for: .arm64))
        #expect(archive.url.absoluteString == "https://dl.google.com/android/repository/emulator-darwin_aarch64-16428233.zip")
        #expect(archive.sha1.count == 40)
        #expect(stable.archive(for: .x86_64)?.url.lastPathComponent.contains("darwin_x64") == true)

        // platform-tools ships one universal macOS archive (no host-arch).
        let tools = try #require(catalog.latestStable("platform-tools", for: .arm64))
        #expect(tools.archive(for: .arm64)?.url.lastPathComponent == "platform-tools_r37.0.1-darwin.zip")
    }

    @Test func parsesSystemImageDetails() throws {
        let catalog = try loadCatalog()
        let pkg = try #require(catalog.packages.first { $0.path == "system-images;android-37.2;google_apis_ps16k;arm64-v8a" })
        let img = try #require(pkg.systemImage)
        #expect(img.apiLevel == "37.2")
        #expect(img.tagIDs == ["google_apis", "page_size_16kb"])
        #expect(img.uses16KPages)
        #expect(!img.isPreview)
        #expect(pkg.licenseID == "android-sdk-arm-dbt-license")
        #expect(pkg.archive(for: .arm64)?.url.absoluteString.hasPrefix("https://dl.google.com/android/repository/sys-img/google_apis/") == true)

        let canary = try #require(catalog.packages.first { $0.path == "system-images;android-CANARY;google_apis_ps16k;arm64-v8a" })
        #expect(canary.systemImage?.codename == "CANARY")
        #expect(canary.systemImage?.isPreview == true)

        let ext = try #require(catalog.packages.first { $0.path == "system-images;android-36-ext19;google_apis;arm64-v8a" })
        #expect(ext.systemImage?.apiLevel == "36x")
        #expect(ext.systemImage?.apiVersion.major == 36)
        #expect(ext.systemImage?.baseExtension == false)
        #expect(ext.minEmulatorRevision != nil)
        #expect(catalog.licenses["android-sdk-arm-dbt-license"]?.text.contains("License Agreement") == true)
    }

    @Test func filtersByHostArchitectureAndPreviewFlag() throws {
        let catalog = try loadCatalog()
        let arm = catalog.systemImages(for: .arm64, includePreviews: false)
        #expect(!arm.isEmpty)
        #expect(arm.allSatisfy { $0.systemImage?.abi == "arm64-v8a" && $0.systemImage?.isPreview == false })
        let withPreviews = catalog.systemImages(for: .arm64, includePreviews: true)
        #expect(withPreviews.count > arm.count)
        // Newest first.
        let majors = arm.map { $0.systemImage!.apiVersion.major }
        #expect(majors == majors.sorted(by: >))
        let intel = catalog.systemImages(for: .x86_64, includePreviews: false)
        #expect(intel.allSatisfy { $0.systemImage?.abi == "x86_64" })
    }

    @Test func recommendsNewestStableStandardImage() throws {
        let catalog = try loadCatalog()
        // 37.2 exists only as a 16 KB page-size image, so 37.0 google_apis is the default.
        let rec = try #require(catalog.recommendedSystemImage(for: .arm64))
        #expect(rec.path == "system-images;android-37.0;google_apis;arm64-v8a")
    }

    @Test func rejectsMalformedXML() {
        #expect(throws: RepositoryError.self) { try RepositoryParser.parse(Data("<not-xml".utf8), baseURL: SDKRepository.baseURL) }
    }

    @Test func installDirectoryRejectsTraversal() {
        func pkg(_ path: String) -> RemotePackage {
            RemotePackage(
                path: path,
                displayName: path,
                revision: Revision(1),
                licenseID: nil,
                channel: "stable",
                obsolete: false,
                archives: [],
                systemImage: nil,
                minEmulatorRevision: nil
            )
        }
        #expect(pkg("system-images;android-36;google_apis;arm64-v8a").installDirectory == "system-images/android-36/google_apis/arm64-v8a")
        #expect(pkg("emulator").installDirectory == "emulator")
        #expect(pkg("system-images;..;x").installDirectory == nil)
        #expect(pkg("a;b/c").installDirectory == nil)
        #expect(pkg("a;;b").installDirectory == nil)
    }
}

struct VersionTests {
    @Test func revisionParsingAndOrdering() {
        #expect(Revision(string: "36.5.11.0") == Revision(36, 5, 11))
        #expect(Revision(string: "14") == Revision(14))
        #expect(Revision(string: "abc") == nil)
        #expect(Revision(36, 5, 11) < Revision(37, 0, 0))
        #expect(Revision(37, 0, 0, preview: 1) < Revision(37, 0, 0))
    }

    @Test func androidVersionNames() {
        #expect(AndroidVersion.displayName(apiLevel: "36") == "Android 16 (API 36)")
        #expect(AndroidVersion.displayName(apiLevel: "36.1") == "Android 16 (API 36.1)")
        #expect(AndroidVersion.displayName(apiLevel: "99") == "API 99")
        #expect(AndroidVersion.shortName(apiLevel: "34") == "Android 14")
        #expect(AndroidVersion.shortName(apiLevel: "36.1") == "Android 16")
        #expect(AndroidVersion.shortName(apiLevel: "99") == "API 99")
        #expect(AndroidVersion.displayName(apiLevel: "37.1", codename: "CANARY") == "Preview CANARY (API 37.1)")
        #expect(AndroidVersion.parse("36x").major == 36)
        #expect(AndroidVersion.parse("36x").minor == 0)
        #expect(AndroidVersion.parse("37.2").minor == 2)
    }
}
