import Foundation

/// A JDK that can run Google's `avdmanager` (which needs Java 17 or newer).
public struct JavaRuntime: Hashable, Sendable {
    public enum Source: String, Sendable {
        case environment = "JAVA_HOME"
        case moorbox = "Installed by Moorbox"
        case androidStudio = "Android Studio"
        case system = "System (java_home)"
    }

    public var home: URL
    public var version: String
    public var majorVersion: Int
    public var source: Source

    public var javaBinary: URL {
        home.appendingPathComponent("bin/java")
    }
}

public enum JavaLocator {
    public static let minimumMajorVersion = 17

    /// Where Moorbox keeps JDKs it installed, one folder per release.
    public static func managedRoot(applicationSupport: URL) -> URL {
        applicationSupport.appendingPathComponent("JDK")
    }

    /// Parses a JDK `release` file. `JAVA_VERSION="21.0.10"` → ("21.0.10", 21);
    /// legacy `"1.8.0_402"` → ("1.8.0_402", 8).
    public static func parseRelease(_ text: String) -> (version: String, major: Int)? {
        guard let line = text.split(whereSeparator: \.isNewline).first(where: { $0.hasPrefix("JAVA_VERSION=") }) else { return nil }
        let version = line.dropFirst("JAVA_VERSION=".count).trimmingCharacters(in: CharacterSet(charactersIn: "\" "))
        let parts = version.split(separator: ".").compactMap { Int($0.prefix(while: \.isNumber)) }
        guard let first = parts.first else { return nil }
        let major = first == 1 && parts.count > 1 ? parts[1] : first
        return (version, major)
    }

    /// Validates a JDK home: it must contain an executable `bin/java` and a readable `release` file.
    public static func inspect(home: URL, source: JavaRuntime.Source) -> JavaRuntime? {
        let fm = FileManager.default
        guard fm.isExecutableFile(atPath: home.appendingPathComponent("bin/java").path),
              let text = try? String(contentsOf: home.appendingPathComponent("release"), encoding: .utf8),
              let (version, major) = parseRelease(text) else { return nil }
        return JavaRuntime(home: home.standardizedFileURL, version: version, majorVersion: major, source: source)
    }

    /// Candidate JDK homes in priority order. Only paths are listed; `find` validates them.
    static func candidates(environment: [String: String], managedRoot: URL) -> [(URL, JavaRuntime.Source)] {
        var result: [(URL, JavaRuntime.Source)] = []
        if let home = environment["JAVA_HOME"], !home.isEmpty {
            result.append((URL(fileURLWithPath: home), .environment))
        }
        let fm = FileManager.default
        let managed = ((try? fm.contentsOfDirectory(atPath: managedRoot.path)) ?? []).filter { !$0.hasPrefix(".") }
            .sorted { $0.localizedStandardCompare($1) == .orderedDescending }
        result += managed.map { (managedRoot.appendingPathComponent("\($0)/Contents/Home"), .moorbox) }
        let apps = ((try? fm.contentsOfDirectory(atPath: "/Applications")) ?? []).filter { $0.hasPrefix("Android Studio") && $0.hasSuffix(".app") }
        result += apps.sorted().map { (URL(fileURLWithPath: "/Applications/\($0)/Contents/jbr/Contents/Home"), .androidStudio) }
        return result
    }

    /// The best usable JDK (17+), or nil. Also asks macOS's `java_home` registry.
    public static func find(managedRoot: URL, environment: [String: String] = ProcessInfo.processInfo.environment) async -> JavaRuntime? {
        for (home, source) in candidates(environment: environment, managedRoot: managedRoot) {
            if let jdk = inspect(home: home, source: source), jdk.majorVersion >= minimumMajorVersion {
                return jdk
            }
        }
        let javaHome = URL(fileURLWithPath: "/usr/libexec/java_home")
        guard let r = try? await Shell.run(javaHome, ["-v", "\(minimumMajorVersion)+"], timeout: 10), r.succeeded else { return nil }
        let path = r.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !path.isEmpty, let jdk = inspect(home: URL(fileURLWithPath: path), source: .system),
              jdk.majorVersion >= minimumMajorVersion else { return nil }
        return jdk
    }
}

/// An Eclipse Temurin JDK build published by the Adoptium project.
public struct JDKRelease: Hashable, Sendable {
    public var releaseName: String
    public var version: String
    public var archiveName: String
    public var url: URL
    public var sha256: String
    public var size: Int64
}

/// Adoptium's public API (https://api.adoptium.net), which publishes Temurin builds with SHA-256 checksums.
public enum Adoptium {
    public static let featureVersion = 21 // current LTS
    public static let licenseName = "GNU General Public License, version 2, with the Classpath Exception"
    public static let licenseURL = URL(constant: "https://openjdk.org/legal/gplv2+ce.html")
    public static let projectURL = URL(constant: "https://adoptium.net/temurin/")
    /// Release binaries are served from Adoptium's GitHub releases.
    public static let trustedHosts: Set<String> = ["github.com"]

    public static func latestURL(for arch: CPUArchitecture, feature: Int = featureVersion) -> URL? {
        var components = URLComponents(string: "https://api.adoptium.net/v3/assets/latest/\(feature)/hotspot")
        components?.queryItems = [
            URLQueryItem(name: "architecture", value: arch == .arm64 ? "aarch64" : "x64"),
            URLQueryItem(name: "image_type", value: "jdk"),
            URLQueryItem(name: "os", value: "mac"),
            URLQueryItem(name: "vendor", value: "eclipse"),
        ]
        return components?.url
    }

    /// Picks the `.tar.gz` JDK package from an `assets/latest` response.
    public static func parse(_ data: Data) throws -> JDKRelease {
        struct Asset: Decodable {
            struct Binary: Decodable {
                struct Package: Decodable { let name: String; let link: URL; let checksum: String; let size: Int64 }
                let package: Package
                let imageType: String
            }

            struct Version: Decodable { let semver: String }
            let binary: Binary
            let releaseName: String
            let version: Version
        }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        let assets = try decoder.decode([Asset].self, from: data)
        guard let asset = assets.first(where: { $0.binary.imageType == "jdk" && $0.binary.package.name.hasSuffix(".tar.gz") }) else {
            throw RepositoryError.malformed("no JDK archive in the Adoptium response")
        }
        let p = asset.binary.package
        guard p.checksum.count == 64, p.link.host.map(trustedHosts.contains) == true,
              p.link.path.hasPrefix("/adoptium/") else {
            throw RepositoryError.malformed("unexpected JDK download location \(p.link.absoluteString)")
        }
        return JDKRelease(
            releaseName: asset.releaseName,
            version: asset.version.semver,
            archiveName: p.name,
            url: p.link,
            sha256: p.checksum.lowercased(),
            size: p.size
        )
    }

    public static func fetchLatest(for arch: CPUArchitecture, session: URLSession = .shared) async throws -> JDKRelease {
        guard let url = latestURL(for: arch) else { throw RepositoryError.malformed("invalid Adoptium API URL") }
        let (data, response) = try await session.data(from: url)
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            throw RepositoryError.malformed("Adoptium API returned HTTP \(http.statusCode)")
        }
        return try parse(data)
    }

    /// Downloads, verifies (SHA-256) and installs the JDK under `managedRoot/<release>`.
    /// No administrator rights are needed and nothing outside that folder is touched.
    public static func install(
        _ release: JDKRelease,
        managedRoot: URL,
        progress: @escaping @Sendable (InstallPhase) -> Void
    ) async throws -> JavaRuntime {
        let safeName = release.releaseName.replacingOccurrences(of: "/", with: "_")
        let destination = managedRoot.appendingPathComponent(safeName)
        let spec = ArchiveSpec(
            url: release.url,
            size: release.size,
            checksum: .sha256(release.sha256),
            format: .tarGz,
            trustedHosts: trustedHosts
        )
        try await ArchiveInstaller.install(
            spec,
            to: destination,
            stagingRoot: managedRoot.appendingPathComponent(".staging"),
            progress: progress
        )
        guard let jdk = JavaLocator.inspect(home: destination.appendingPathComponent("Contents/Home"), source: .moorbox) else {
            throw InstallError.unexpectedLayout("the downloaded JDK has no Contents/Home/bin/java")
        }
        return jdk
    }
}
