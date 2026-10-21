import Foundation

public struct Revision: Comparable, Hashable, Sendable, CustomStringConvertible {
    public var major: Int, minor: Int, micro: Int, preview: Int?

    public init(_ major: Int, _ minor: Int = 0, _ micro: Int = 0, preview: Int? = nil) {
        (self.major, self.minor, self.micro, self.preview) = (major, minor, micro, preview)
    }

    /// Parses "36.5.11", "36.5.11.0" or "14" (the format of `Pkg.Revision`).
    public init?(string: String) {
        let parts = string.split(separator: " ")[0].split(separator: ".").map { Int($0) }
        guard let major = parts.first ?? nil else { return nil }
        self.init(major, parts.count > 1 ? parts[1] ?? 0 : 0, parts.count > 2 ? parts[2] ?? 0 : 0)
    }

    public var description: String {
        "\(major).\(minor).\(micro)" + (preview.map { " rc\($0)" } ?? "")
    }

    public static func < (a: Revision, b: Revision) -> Bool {
        if (a.major, a.minor, a.micro) != (b.major, b.minor, b.micro) {
            return (a.major, a.minor, a.micro) < (b.major, b.minor, b.micro)
        }
        // A final release sorts after its previews.
        return (a.preview ?? .max) < (b.preview ?? .max)
    }
}

public struct License: Hashable, Sendable, Identifiable {
    public var id: String
    public var text: String
}

public struct Archive: Hashable, Sendable {
    public var url: URL
    public var size: Int64
    public var sha1: String
    public var hostOS: String?
    public var hostArch: String?
}

public struct SystemImageDetails: Hashable, Sendable {
    /// Repository API level string: "35", "36.1", or "36x" for extension-level images.
    public var apiLevel: String
    /// Present only on preview/beta/canary images.
    public var codename: String?
    public var tagIDs: [String]
    public var tagDisplay: String
    public var abi: String
    public var extensionLevel: Int?
    public var baseExtension: Bool

    public var isPreview: Bool { codename != nil }
    public var hasPlayStore: Bool { tagIDs.contains { $0.contains("playstore") } }
    public var uses16KPages: Bool { tagIDs.contains("page_size_16kb") }
    /// Google APIs without the Play Store. Images may carry extra capability tags
    /// (e.g. `ai_glasses_compatible`), so test membership, not equality.
    public var isGoogleAPIs: Bool { tagIDs.contains("google_apis") && !hasPlayStore }

    /// (major, minor) parsed from the leading digits of `apiLevel`, for sorting.
    public var apiVersion: (major: Int, minor: Int) { AndroidVersion.parse(apiLevel) }
}

public struct RemotePackage: Hashable, Sendable, Identifiable {
    /// SDK path, e.g. `system-images;android-36;google_apis;arm64-v8a` or `emulator`.
    public var path: String
    public var displayName: String
    public var revision: Revision
    public var licenseID: String?
    public var channel: String
    public var obsolete: Bool
    public var archives: [Archive]
    public var systemImage: SystemImageDetails?
    public var minEmulatorRevision: Revision?

    public var id: String { path }

    /// The archive for this host, or nil if the package isn't offered for it.
    public func archive(for arch: CPUArchitecture) -> Archive? {
        archives.first { a in
            (a.hostOS == nil || a.hostOS == "macosx") && (a.hostArch == nil || a.hostArch == arch.repositoryName)
        }
    }

    /// Relative install directory inside the SDK, validated against path traversal.
    public var installDirectory: String? {
        let parts = path.split(separator: ";", omittingEmptySubsequences: false).map(String.init)
        let safe = parts.allSatisfy { p in
            !p.isEmpty && p != "." && p != ".." && !p.contains("/") && !p.contains("\\")
        }
        return safe ? parts.joined(separator: "/") : nil
    }
}

public struct Catalog: Sendable {
    public var packages: [RemotePackage]
    public var licenses: [String: License]

    public init(packages: [RemotePackage] = [], licenses: [String: License] = [:]) {
        self.packages = packages
        self.licenses = licenses
    }

    mutating func merge(_ other: Catalog) {
        packages += other.packages
        licenses.merge(other.licenses) { current, _ in current }
    }

    /// Latest stable-channel revision of a host package such as `emulator` or `platform-tools`.
    public func latestStable(_ path: String, for arch: CPUArchitecture) -> RemotePackage? {
        packages.filter { $0.path == path && $0.channel == "stable" && $0.archive(for: arch) != nil }
            .max { $0.revision < $1.revision }
    }

    /// System images that can run accelerated on this host, newest first. Obsolete
    /// packages and images whose ABI doesn't match the host CPU are excluded.
    public func systemImages(for arch: CPUArchitecture, includePreviews: Bool) -> [RemotePackage] {
        packages.filter { p in
            guard let img = p.systemImage, !p.obsolete, p.archive(for: arch) != nil else { return false }
            return img.abi == arch.nativeAndroidABI && (includePreviews || !img.isPreview)
        }
        .sorted { a, b in
            let (x, y) = (a.systemImage!, b.systemImage!)
            if x.apiVersion != y.apiVersion { return x.apiVersion > y.apiVersion }
            return SystemImageRanking.score(x) > SystemImageRanking.score(y)
        }
    }

    /// The default suggestion: the newest stable, base-extension, 4 KB page-size image,
    /// preferring Google APIs (Play Store images are listed but opt-in).
    public func recommendedSystemImage(for arch: CPUArchitecture) -> RemotePackage? {
        let stable = systemImages(for: arch, includePreviews: false)
        return stable.first { p in
            let img = p.systemImage!
            return img.baseExtension && !img.uses16KPages && img.isGoogleAPIs
        } ?? stable.first
    }
}

enum SystemImageRanking {
    static func score(_ img: SystemImageDetails) -> Int {
        var s = 0
        if img.baseExtension { s += 8 }
        if !img.uses16KPages { s += 4 }
        if img.isGoogleAPIs { s += 2 } else if img.hasPlayStore { s += 1 }
        return s
    }
}

public enum AndroidVersion {
    /// Marketing names for API levels known when this build was made. Anything newer
    /// still works; it's just shown as "API N".
    static let names: [Int: String] = [
        21: "5.0", 22: "5.1", 23: "6.0", 24: "7.0", 25: "7.1", 26: "8.0", 27: "8.1", 28: "9",
        29: "10", 30: "11", 31: "12", 32: "12L", 33: "13", 34: "14", 35: "15", 36: "16", 37: "17",
    ]

    public static func parse(_ apiLevel: String) -> (major: Int, minor: Int) {
        let parts = apiLevel.split(separator: ".")
        let major = Int(parts.first?.prefix(while: \.isNumber) ?? "") ?? 0
        let minor = parts.count > 1 ? Int(parts[1].prefix(while: \.isNumber)) ?? 0 : 0
        return (major, minor)
    }

    /// "Android 16", or "API 41" for levels newer than this build knows.
    public static func shortName(apiLevel: String) -> String {
        let major = parse(apiLevel).major
        return names[major].map { "Android \($0)" } ?? "API \(apiLevel)"
    }

    /// "Android 16 (API 36)", "Android 16 (API 36.1)", "API 41".
    public static func displayName(apiLevel: String, codename: String? = nil) -> String {
        if let codename { return "Preview \(codename) (API \(apiLevel))" }
        let major = parse(apiLevel).major
        guard let name = names[major] else { return "API \(apiLevel)" }
        return "Android \(name) (API \(apiLevel))"
    }
}

public enum RepositoryError: LocalizedError {
    case malformed(String)

    public var errorDescription: String? {
        switch self {
        case let .malformed(what): "The Android SDK repository metadata could not be read (\(what))."
        }
    }
}

/// Parses Google's SDK repository XML (`repository2-3.xml`, `sys-img2-3.xml`), the same
/// metadata sdkmanager and Android Studio use.
public enum RepositoryParser {
    public static func parse(_ data: Data, baseURL: URL) throws -> Catalog {
        let doc: XMLDocument
        do { doc = try XMLDocument(data: data) } catch { throw RepositoryError.malformed(error.localizedDescription) }
        guard let root = doc.rootElement() else { throw RepositoryError.malformed("no root element") }

        var licenses: [String: License] = [:]
        for el in root.elements(forName: "license") {
            if let id = el.attribute(forName: "id")?.stringValue {
                licenses[id] = License(id: id, text: el.stringValue ?? "")
            }
        }
        var channels: [String: String] = [:]
        for el in root.elements(forName: "channel") {
            if let id = el.attribute(forName: "id")?.stringValue { channels[id] = el.stringValue }
        }

        var packages: [RemotePackage] = []
        for el in root.elements(forName: "remotePackage") {
            guard let path = el.attribute(forName: "path")?.stringValue,
                  let revEl = el.child("revision"), let revision = parseRevision(revEl) else { continue }
            let archives = (el.child("archives")?.elements(forName: "archive") ?? []).compactMap {
                parseArchive($0, baseURL: baseURL)
            }
            let channelRef = el.child("channelRef")?.attribute(forName: "ref")?.stringValue ?? "channel-0"
            let minEmulator = el.child("dependencies")?.elements(forName: "dependency")
                .first { $0.attribute(forName: "path")?.stringValue == "emulator" }?
                .child("min-revision").flatMap(parseRevision)
            packages.append(RemotePackage(
                path: path,
                displayName: el.child("display-name")?.stringValue ?? path,
                revision: revision,
                licenseID: el.child("uses-license")?.attribute(forName: "ref")?.stringValue,
                channel: channels[channelRef] ?? "stable",
                obsolete: el.attribute(forName: "obsolete")?.stringValue == "true",
                archives: archives,
                systemImage: el.child("type-details").flatMap(parseSystemImage),
                minEmulatorRevision: minEmulator
            ))
        }
        return Catalog(packages: packages, licenses: licenses)
    }

    static func parseRevision(_ el: XMLElement) -> Revision? {
        guard let major = el.int("major") else { return nil }
        return Revision(major, el.int("minor") ?? 0, el.int("micro") ?? 0, preview: el.int("preview"))
    }

    static func parseArchive(_ el: XMLElement, baseURL: URL) -> Archive? {
        guard let complete = el.child("complete"),
              let urlText = complete.child("url")?.stringValue,
              let url = URL(string: urlText, relativeTo: baseURL)?.absoluteURL,
              let size = complete.child("size")?.stringValue.flatMap({ Int64($0) }),
              let checksum = complete.child("checksum"),
              checksum.attribute(forName: "type")?.stringValue ?? "sha1" == "sha1",
              let sha1 = checksum.stringValue?.lowercased(), sha1.count == 40 else { return nil }
        return Archive(url: url, size: size, sha1: sha1,
                       hostOS: el.child("host-os")?.stringValue, hostArch: el.child("host-arch")?.stringValue)
    }

    static func parseSystemImage(_ details: XMLElement) -> SystemImageDetails? {
        guard let api = details.child("api-level")?.stringValue else { return nil }
        // Newer metadata may list several ABIs under <abis>; accept either form.
        guard let abi = details.child("abi")?.stringValue ?? details.child("abis")?.child("abi")?.stringValue else { return nil }
        let tags = details.elements(forName: "tag")
        guard !tags.isEmpty else { return nil }
        return SystemImageDetails(
            apiLevel: api,
            codename: details.child("codename")?.stringValue,
            tagIDs: tags.compactMap { $0.child("id")?.stringValue },
            tagDisplay: tags.compactMap { $0.child("display")?.stringValue }.joined(separator: ", "),
            abi: abi,
            extensionLevel: details.int("extension-level"),
            baseExtension: details.child("base-extension")?.stringValue != "false"
        )
    }
}

private extension XMLElement {
    func child(_ name: String) -> XMLElement? { elements(forName: name).first }
    func int(_ name: String) -> Int? { child(name)?.stringValue.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }
}

/// Fetches the official repository metadata from dl.google.com.
public struct SDKRepository: Sendable {
    public static let baseURL = URL(string: "https://dl.google.com/android/repository/")!
    /// The system-image sites listed in `addons_list-5.xml` that matter for phone/tablet AVDs.
    public static let systemImageSites = ["android", "google_apis", "google_apis_playstore"]

    public init() {}

    public static var metadataURLs: [URL] {
        [baseURL.appendingPathComponent("repository2-3.xml")] + systemImageSites.map {
            baseURL.appendingPathComponent("sys-img/\($0)/sys-img2-3.xml")
        }
    }

    public func fetchCatalog(session: URLSession = .shared) async throws -> Catalog {
        try await withThrowingTaskGroup(of: Catalog.self) { group in
            for url in Self.metadataURLs {
                group.addTask {
                    let (data, response) = try await session.data(from: url)
                    if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                        throw RepositoryError.malformed("HTTP \(http.statusCode) for \(url.lastPathComponent)")
                    }
                    return try RepositoryParser.parse(data, baseURL: url.deletingLastPathComponent())
                }
            }
            var catalog = Catalog()
            for try await part in group { catalog.merge(part) }
            return catalog
        }
    }

    /// SDK downloads are only ever made over HTTPS from Google's SDK host.
    public static let trustedHost = "dl.google.com"
}
