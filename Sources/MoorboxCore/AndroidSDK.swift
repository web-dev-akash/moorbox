import CryptoKit
import Foundation

public struct InstalledSystemImage: Hashable, Sendable, Identifiable {
    /// `system-images;android-36;google_apis;arm64-v8a`
    public var packagePath: String
    /// Relative to the SDK root, with trailing slash, as written to `image.sysdir.1`.
    public var relativeDirectory: String
    /// Directory name of the platform segment, e.g. `android-36` or `android-CANARY`.
    public var platformDirectory: String
    public var apiLevel: String
    public var codename: String?
    public var tagID: String
    public var tagDisplay: String
    public var abi: String
    public var revision: String?

    public var id: String { packagePath }
    public var hasPlayStore: Bool { tagID.contains("playstore") }
    public var displayName: String { AndroidVersion.displayName(apiLevel: apiLevel, codename: codename) }
}

/// What the app found when it inspected an SDK directory.
public struct SDKHealth: Sendable {
    public var emulatorRevision: Revision?
    public var emulatorArchitectures: Set<CPUArchitecture>
    public var adbPresent: Bool
    public var problems: [String]

    public var isReady: Bool { problems.isEmpty }
}

public struct AndroidSDK: Hashable, Sendable {
    public let root: URL

    public init(root: URL) { self.root = root.standardizedFileURL }

    public var emulatorBinary: URL { root.appendingPathComponent("emulator/emulator") }
    public var adbBinary: URL { root.appendingPathComponent("platform-tools/adb") }
    public var licensesDirectory: URL { root.appendingPathComponent("licenses") }

    public var emulatorRevision: Revision? {
        Properties.read(root.appendingPathComponent("emulator/source.properties"))?["Pkg.Revision"]
            .flatMap(Revision.init(string:))
    }

    public var platformToolsRevision: Revision? {
        Properties.read(root.appendingPathComponent("platform-tools/source.properties"))?["Pkg.Revision"]
            .flatMap(Revision.init(string:))
    }

    /// Default location used by Android Studio; also where Moorbox installs a new SDK.
    public static func defaultLocation(home: URL = FileManager.default.homeDirectoryForCurrentUser) -> URL {
        home.appendingPathComponent("Library/Android/sdk")
    }

    /// Places an existing SDK may live, in priority order. GUI apps usually don't
    /// inherit shell variables, so the default location matters most.
    public static func candidateLocations(
        preferred: URL?, environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> [URL] {
        var urls: [URL] = []
        if let preferred { urls.append(preferred) }
        for key in ["ANDROID_HOME", "ANDROID_SDK_ROOT"] {
            if let value = environment[key], !value.isEmpty { urls.append(URL(fileURLWithPath: value)) }
        }
        urls.append(defaultLocation(home: home))
        var seen = Set<String>()
        return urls.map(\.standardizedFileURL).filter { seen.insert($0.path).inserted }
    }

    /// The first candidate that looks like an SDK (has an emulator or platform-tools).
    public static func discover(
        preferred: URL?, environment: [String: String] = ProcessInfo.processInfo.environment,
        home: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> AndroidSDK? {
        let fm = FileManager.default
        return candidateLocations(preferred: preferred, environment: environment, home: home)
            .map(AndroidSDK.init(root:))
            .first { fm.fileExists(atPath: $0.emulatorBinary.path) || fm.fileExists(atPath: $0.adbBinary.path) }
    }

    public func health(host: HostInfo) -> SDKHealth {
        let fm = FileManager.default
        var problems: [String] = []
        let archs = machOArchitectures(of: emulatorBinary)
        let revision = emulatorRevision
        if !fm.isExecutableFile(atPath: emulatorBinary.path) {
            problems.append("The Android Emulator is not installed in this SDK.")
        } else if !archs.contains(host.architecture) {
            problems.append("The installed emulator is built for \(archs.map(\.rawValue).sorted().joined(separator: ", ")), not this Mac (\(host.architecture.rawValue)). Reinstall the emulator for this architecture.")
        }
        let adb = fm.isExecutableFile(atPath: adbBinary.path)
        if !adb { problems.append("Android platform-tools (adb) are not installed in this SDK.") }
        return SDKHealth(emulatorRevision: revision, emulatorArchitectures: archs, adbPresent: adb, problems: problems)
    }

    /// Scans `system-images/<platform>/<tag>/<abi>/`.
    public func installedSystemImages() -> [InstalledSystemImage] {
        let fm = FileManager.default
        let base = root.appendingPathComponent("system-images")
        func dirs(_ url: URL) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: url.path)) ?? []).filter { !$0.hasPrefix(".") }.sorted()
        }
        var images: [InstalledSystemImage] = []
        for platform in dirs(base) {
            for tag in dirs(base.appendingPathComponent(platform)) {
                for abi in dirs(base.appendingPathComponent("\(platform)/\(tag)")) {
                    let dir = base.appendingPathComponent("\(platform)/\(tag)/\(abi)")
                    // A directory without these files is an incomplete or foreign install.
                    guard fm.fileExists(atPath: dir.appendingPathComponent("system.img").path),
                          let props = Properties.read(dir.appendingPathComponent("source.properties")) else { continue }
                    images.append(InstalledSystemImage(
                        packagePath: "system-images;\(platform);\(tag);\(abi)",
                        relativeDirectory: "system-images/\(platform)/\(tag)/\(abi)/",
                        platformDirectory: platform,
                        apiLevel: props["AndroidVersion.ApiLevel"] ?? platform.replacingOccurrences(of: "android-", with: ""),
                        codename: props["AndroidVersion.CodeName"],
                        tagID: props["SystemImage.TagId"] ?? tag,
                        tagDisplay: props["SystemImage.TagDisplay"] ?? tag,
                        abi: props["SystemImage.Abi"] ?? abi,
                        revision: props["Pkg.Revision"]
                    ))
                }
            }
        }
        return images.sorted { AndroidVersion.parse($0.apiLevel) > AndroidVersion.parse($1.apiLevel) }
    }

    public func isInstalled(_ package: RemotePackage) -> Bool {
        guard let dir = package.installDirectory else { return false }
        let url = root.appendingPathComponent(dir)
        return FileManager.default.fileExists(atPath: url.appendingPathComponent("source.properties").path)
            || FileManager.default.fileExists(atPath: url.appendingPathComponent("package.xml").path)
    }

    // MARK: Licenses
    //
    // sdkmanager records acceptance by appending sha1(trimmed license text) as a line in
    // `licenses/<license-id>`. We use the same format so Android Studio and sdkmanager
    // see the same consent, and we only ever append.

    public static func licenseHash(_ license: License) -> String {
        let text = license.text.trimmingCharacters(in: .whitespacesAndNewlines)
        return Insecure.SHA1.hash(data: Data(text.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    public func hasAccepted(_ license: License) -> Bool {
        let file = licensesDirectory.appendingPathComponent(license.id)
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return false }
        let hash = Self.licenseHash(license)
        return text.split(whereSeparator: \.isNewline).contains { $0.trimmingCharacters(in: .whitespaces) == hash }
    }

    public func recordAcceptance(of license: License) throws {
        guard !hasAccepted(license) else { return }
        guard license.id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else {
            throw RepositoryError.malformed("invalid license id")
        }
        try FileManager.default.createDirectory(at: licensesDirectory, withIntermediateDirectories: true)
        let file = licensesDirectory.appendingPathComponent(license.id)
        var existing = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        if !existing.isEmpty, !existing.hasSuffix("\n") { existing += "\n" }
        try (existing + Self.licenseHash(license) + "\n").write(to: file, atomically: true, encoding: .utf8)
    }
}
