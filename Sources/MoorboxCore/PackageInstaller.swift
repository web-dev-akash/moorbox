import CryptoKit
import Foundation

public enum InstallPhase: Sendable, Equatable {
    case downloading(received: Int64, total: Int64)
    case verifying
    case extracting
    case finished
}

public enum InstallError: LocalizedError, Equatable {
    case notAvailableForHost(String)
    case alreadyInstalled(String)
    case insufficientDiskSpace(needed: Int64, available: Int64)
    case checksumMismatch(expected: String, actual: String)
    case unsafeArchive(String)
    case unexpectedLayout(String)
    case licenseNotAccepted(String)

    public var errorDescription: String? {
        let f = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
        switch self {
        case let .notAvailableForHost(p): return "\(p) is not offered for this Mac's architecture."
        case let .alreadyInstalled(p): return "\(p) is already installed."
        case let .insufficientDiskSpace(needed, available):
            return "Not enough disk space: about \(f(needed)) is needed but only \(f(available)) is available. Free up space and try again."
        case .checksumMismatch:
            return "The download was corrupted (checksum mismatch) and has been discarded. Try again."
        case let .unsafeArchive(why): return "The archive was rejected because it is unsafe: \(why)"
        case let .unexpectedLayout(why): return "The archive has an unexpected layout: \(why)"
        case let .licenseNotAccepted(id): return "The license \(id) must be accepted before installing."
        }
    }
}

/// Installs SDK packages into an SDK directory the same way sdkmanager lays them out.
///
/// Work happens in `<sdk>/.moorbox-staging/<uuid>/` (same volume, so the final step is a
/// rename) and the staging directory is always removed, whether the install succeeds,
/// fails, or is cancelled. Existing packages are only replaced when `replacing` is true,
/// and the old copy is kept until the new one is in place.
public struct PackageInstaller: Sendable {
    public let sdk: AndroidSDK
    public let host: CPUArchitecture

    public init(sdk: AndroidSDK, host: CPUArchitecture) {
        self.sdk = sdk
        self.host = host
    }

    /// Download + extracted size, plus headroom.
    public static func requiredSpace(for archive: Archive) -> Int64 { archive.size * 3 + 512 * 1_048_576 }

    public func install(
        _ package: RemotePackage, license: License?, replacing: Bool = false,
        progress: @escaping @Sendable (InstallPhase) -> Void
    ) async throws {
        guard let archive = package.archive(for: host) else { throw InstallError.notAvailableForHost(package.displayName) }
        guard let relative = package.installDirectory else { throw InstallError.unsafeArchive("invalid package path \(package.path)") }
        try SDKRepository.validateDownloadURL(archive.url)
        if let license, !sdk.hasAccepted(license) { throw InstallError.licenseNotAccepted(license.id) }
        let fm = FileManager.default
        let destination = sdk.root.appendingPathComponent(relative)
        if fm.fileExists(atPath: destination.path), !replacing { throw InstallError.alreadyInstalled(package.displayName) }

        try fm.createDirectory(at: sdk.root, withIntermediateDirectories: true)
        let needed = Self.requiredSpace(for: archive)
        if let available = HostInfo.availableDiskSpace(at: sdk.root), available < needed {
            throw InstallError.insufficientDiskSpace(needed: needed, available: available)
        }

        let staging = sdk.root.appendingPathComponent(".moorbox-staging/\(UUID().uuidString)")
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        let zip = staging.appendingPathComponent("archive.zip")
        try await Downloader().download(archive.url, to: zip) { received, total in
            progress(.downloading(received: received, total: total > 0 ? total : archive.size))
        }
        try Task.checkCancellation()

        progress(.verifying)
        let actual = try Self.sha1(of: zip)
        guard actual == archive.sha1 else { throw InstallError.checksumMismatch(expected: archive.sha1, actual: actual) }

        progress(.extracting)
        let extracted = staging.appendingPathComponent("x")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        // Info-ZIP refuses absolute paths and strips "../" components; we also audit symlinks below.
        try await Shell.check(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", zip.path, "-d", extracted.path], timeout: 1800)
        try fm.removeItem(at: zip)
        let top = try Self.validateExtraction(at: extracted)

        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            let old = staging.appendingPathComponent("previous")
            try fm.moveItem(at: destination, to: old)
            do { try fm.moveItem(at: top, to: destination) } catch {
                try? fm.moveItem(at: old, to: destination) // put the working copy back
                throw error
            }
        } else {
            try fm.moveItem(at: top, to: destination)
        }
        progress(.finished)
    }

    /// Every SDK archive contains exactly one top-level directory. Rejects symlinks that
    /// point outside the extraction directory. Returns the top-level directory.
    static func validateExtraction(at root: URL) throws -> URL {
        let fm = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path + "/"
        let entries = try fm.contentsOfDirectory(atPath: root.path).filter { $0 != "__MACOSX" }
        guard entries.count == 1 else {
            throw InstallError.unexpectedLayout("expected one top-level folder, found \(entries.count)")
        }
        let top = root.appendingPathComponent(entries[0])
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: top.path, isDirectory: &isDir), isDir.boolValue else {
            throw InstallError.unexpectedLayout("top-level entry is not a folder")
        }
        guard let walker = fm.enumerator(at: resolvedRoot, includingPropertiesForKeys: [.isSymbolicLinkKey]) else { return top }
        for case let url as URL in walker {
            guard (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == true else { continue }
            let target = try fm.destinationOfSymbolicLink(atPath: url.path)
            let resolved = target.hasPrefix("/") ? URL(fileURLWithPath: target)
                : url.deletingLastPathComponent().appendingPathComponent(target)
            let path = resolved.standardizedFileURL.path
            guard path.hasPrefix(rootPath) else {
                throw InstallError.unsafeArchive("symbolic link \(url.lastPathComponent) points outside the package")
            }
        }
        return top
    }

    static func sha1(of file: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var hasher = Insecure.SHA1()
        while let chunk = try handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}

/// URLSession download with byte progress, cancellation, and resume data.
/// Resume data is kept in memory for the app session so "Retry" continues a
/// failed or cancelled download instead of starting over.
final class Downloader: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    private static let resumeLock = NSLock()
    nonisolated(unsafe) private static var resumeData: [URL: Data] = [:]

    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var destination: URL?
    private var moveError: Error?
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var task: URLSessionDownloadTask?
    private var lastReport = Date.distantPast

    func download(_ url: URL, to destination: URL, progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let resume = Self.resumeLock.withLock { Self.resumeData.removeValue(forKey: url) }
                let task = resume.map { session.downloadTask(withResumeData: $0) } ?? session.downloadTask(with: url)
                lock.withLock {
                    self.continuation = c
                    self.destination = destination
                    self.onProgress = progress
                    self.task = task
                }
                task.resume()
            }
        } onCancel: {
            lock.withLock { task }?.cancel { data in
                if let data { Self.resumeLock.withLock { Self.resumeData[url] = data } }
            }
        }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData _: Int64,
                    totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        let (report, cb): (Bool, (@Sendable (Int64, Int64) -> Void)?) = lock.withLock {
            // Throttle UI updates to ~5 per second.
            guard Date().timeIntervalSince(lastReport) > 0.2 else { return (false, nil) }
            lastReport = Date()
            return (true, onProgress)
        }
        if report { cb?(totalBytesWritten, totalBytesExpectedToWrite) }
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        // The temporary file is deleted when this method returns, so move it now.
        // 206 Partial Content is the normal reply when resuming.
        if let http = downloadTask.response as? HTTPURLResponse, ![200, 206].contains(http.statusCode) {
            lock.withLock { moveError = RepositoryError.malformed("HTTP \(http.statusCode)") }
            return
        }
        do {
            if let destination = lock.withLock({ self.destination }) {
                try? FileManager.default.removeItem(at: destination)
                try FileManager.default.moveItem(at: location, to: destination)
            }
        } catch {
            lock.withLock { moveError = error }
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let data = (error as NSError?)?.userInfo[NSURLSessionDownloadTaskResumeData] as? Data, let url = task.originalRequest?.url {
            Self.resumeLock.withLock { Self.resumeData[url] = data }
        }
        let (c, moveError) = lock.withLock { () -> (CheckedContinuation<Void, Error>?, Error?) in
            defer { continuation = nil }
            return (continuation, self.moveError)
        }
        if let error = error ?? moveError {
            if (error as? URLError)?.code == .cancelled { c?.resume(throwing: CancellationError()) } else { c?.resume(throwing: error) }
        } else {
            c?.resume()
        }
    }
}
