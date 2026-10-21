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
    case untrustedURL(String)

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
        case let .untrustedURL(url): return "Refusing to download from an untrusted location: \(url)"
        }
    }
}

public enum Checksum: Sendable, Equatable {
    case sha1(String)
    case sha256(String)

    var expected: String {
        switch self { case let .sha1(v), let .sha256(v): v.lowercased() }
    }
}

public enum ArchiveFormat: Sendable { case zip, tarGz }

/// One downloadable archive and how to trust it.
public struct ArchiveSpec: Sendable {
    public var url: URL
    public var size: Int64
    public var checksum: Checksum
    public var format: ArchiveFormat
    /// Only these hosts may serve the download (always over HTTPS).
    public var trustedHosts: Set<String>

    public init(url: URL, size: Int64, checksum: Checksum, format: ArchiveFormat, trustedHosts: Set<String>) {
        self.url = url
        self.size = size
        self.checksum = checksum
        self.format = format
        self.trustedHosts = trustedHosts
    }
}

/// Download → verify → extract → audit → atomic move.
///
/// Work happens in a staging folder on the destination's volume (so the last step is a
/// rename), and the staging folder is always removed: on success, failure or cancellation.
/// An existing destination is only replaced when `replacing` is true, and the old copy is
/// kept until the new one is in place.
public enum ArchiveInstaller {
    /// Download + extracted size, plus headroom.
    public static func requiredSpace(for size: Int64) -> Int64 { size * 3 + 512 * 1_048_576 }

    public static func install(
        _ spec: ArchiveSpec, to destination: URL, stagingRoot: URL, replacing: Bool = false,
        progress: @escaping @Sendable (InstallPhase) -> Void
    ) async throws {
        guard spec.url.scheme == "https", let host = spec.url.host, spec.trustedHosts.contains(host) else {
            throw InstallError.untrustedURL(spec.url.absoluteString)
        }
        let fm = FileManager.default
        if fm.fileExists(atPath: destination.path), !replacing {
            throw InstallError.alreadyInstalled(destination.lastPathComponent)
        }
        try fm.createDirectory(at: stagingRoot, withIntermediateDirectories: true)
        let needed = requiredSpace(for: spec.size)
        if let available = HostInfo.availableDiskSpace(at: stagingRoot), available < needed {
            throw InstallError.insufficientDiskSpace(needed: needed, available: available)
        }

        let staging = stagingRoot.appendingPathComponent(UUID().uuidString)
        try fm.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: staging) }

        // Partial downloads are kept (named by checksum) so a retry resumes, even after relaunch.
        let partial = stagingRoot.appendingPathComponent("downloads/\(spec.checksum.expected).part")
        try await Downloader().download(spec.url, to: partial, expectedSize: spec.size) { received, total in
            progress(.downloading(received: received, total: total > 0 ? total : spec.size))
        }
        try Task.checkCancellation()

        progress(.verifying)
        let actual = try digest(of: partial, spec.checksum)
        guard actual == spec.checksum.expected else {
            try? fm.removeItem(at: partial)
            throw InstallError.checksumMismatch(expected: spec.checksum.expected, actual: actual)
        }
        let archive = staging.appendingPathComponent("archive")
        try fm.moveItem(at: partial, to: archive)

        progress(.extracting)
        let extracted = staging.appendingPathComponent("x")
        try fm.createDirectory(at: extracted, withIntermediateDirectories: true)
        // Both tools refuse absolute paths and ".." components by default; symlinks are audited below.
        switch spec.format {
        case .zip:
            try await Shell.check(URL(fileURLWithPath: "/usr/bin/unzip"), ["-q", archive.path, "-d", extracted.path], timeout: 1800)
        case .tarGz:
            try await Shell.check(URL(fileURLWithPath: "/usr/bin/tar"), ["-xzf", archive.path, "-C", extracted.path], timeout: 1800)
        }
        try fm.removeItem(at: archive)
        let top = try validateExtraction(at: extracted)

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

    /// Archives must contain exactly one top-level directory, and no symlink may point
    /// outside the extraction directory. Returns the top-level directory.
    static func validateExtraction(at root: URL) throws -> URL {
        let fm = FileManager.default
        let resolvedRoot = root.resolvingSymlinksInPath()
        let rootPath = resolvedRoot.path + "/"
        let entries = try fm.contentsOfDirectory(atPath: root.path).filter { $0 != "__MACOSX" && $0 != ".DS_Store" }
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
            guard resolved.standardizedFileURL.path.hasPrefix(rootPath) else {
                throw InstallError.unsafeArchive("symbolic link \(url.lastPathComponent) points outside the package")
            }
        }
        return top
    }

    static func digest(of file: URL, _ checksum: Checksum) throws -> String {
        let handle = try FileHandle(forReadingFrom: file)
        defer { try? handle.close() }
        var sha1 = Insecure.SHA1(), sha256 = SHA256()
        while let chunk = try handle.read(upToCount: 4 * 1_048_576), !chunk.isEmpty {
            switch checksum {
            case .sha1: sha1.update(data: chunk)
            case .sha256: sha256.update(data: chunk)
            }
        }
        let bytes: [UInt8] = switch checksum {
        case .sha1: Array(sha1.finalize())
        case .sha256: Array(sha256.finalize())
        }
        return bytes.map { String(format: "%02x", $0) }.joined()
    }
}

/// Installs Google's command-line tools, the one SDK package Moorbox installs itself
/// (as Android Studio does). Everything else is installed by Google's Android CLI.
public enum CommandLineToolsInstaller {
    public static let packagePath = "cmdline-tools;latest"

    public static func install(
        _ package: RemotePackage, into sdk: AndroidSDK, host: CPUArchitecture, replacing: Bool = false,
        progress: @escaping @Sendable (InstallPhase) -> Void
    ) async throws {
        guard let archive = package.archive(for: host) else { throw InstallError.notAvailableForHost(package.displayName) }
        guard let relative = package.installDirectory else { throw InstallError.unsafeArchive("invalid package path \(package.path)") }
        let spec = ArchiveSpec(url: archive.url, size: archive.size, checksum: .sha1(archive.sha1), format: .zip,
                               trustedHosts: [SDKRepository.trustedHost])
        try await ArchiveInstaller.install(spec, to: sdk.root.appendingPathComponent(relative),
                                           stagingRoot: sdk.root.appendingPathComponent(".moorbox-staging"),
                                           replacing: replacing, progress: progress)
    }
}

/// Resumable HTTP download into a partial file, using standard `Range` requests.
///
/// The partial file is kept when a download fails or is cancelled, so a retry, even after
/// the app restarts, continues from where it stopped. A `206 Partial Content` reply is
/// appended; a `200` means the server ignored the range, so the file is restarted. The
/// caller's checksum check guards the final result either way.
final class Downloader: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Error>?
    private var handle: FileHandle?
    private var received: Int64 = 0
    private var expected: Int64 = 0
    private var requestedOffset: Int64 = 0
    private var failure: Error?
    private var onProgress: (@Sendable (Int64, Int64) -> Void)?
    private var task: URLSessionDataTask?
    private var lastReport = Date.distantPast

    func download(_ url: URL, to partial: URL, expectedSize: Int64,
                  progress: @escaping @Sendable (Int64, Int64) -> Void) async throws {
        let fm = FileManager.default
        try fm.createDirectory(at: partial.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fm.fileExists(atPath: partial.path) { fm.createFile(atPath: partial.path, contents: nil) }
        let existing = ((try? fm.attributesOfItem(atPath: partial.path))?[.size] as? Int64) ?? 0
        if existing == expectedSize, expectedSize > 0 { progress(existing, expectedSize); return }

        var request = URLRequest(url: url)
        // Archives are already compressed. With gzip allowed, dl.google.com serves a gzip-encoded
        // variant whose byte ranges can't be decoded mid-stream (NSURLErrorCannotDecodeRawData),
        // so ask for the file as-is; ranges then match the bytes on disk.
        request.setValue("identity", forHTTPHeaderField: "Accept-Encoding")
        if existing > 0, existing < expectedSize { request.setValue("bytes=\(existing)-", forHTTPHeaderField: "Range") }
        let offset = existing < expectedSize ? existing : 0
        let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        let fileHandle = try FileHandle(forWritingTo: partial)
        lock.withLock {
            handle = fileHandle
            received = offset
            expected = expectedSize
            requestedOffset = offset
            failure = nil
            onProgress = progress
            lastReport = .distantPast
        }
        defer { try? fileHandle.close() }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                let task = session.dataTask(with: request)
                lock.withLock {
                    continuation = c
                    self.task = task
                }
                task.resume()
            }
        } onCancel: {
            lock.withLock { task }?.cancel()
        }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let ok: Bool = lock.withLock {
            guard let handle else { return false }
            do {
                switch status {
                case 206 where requestedOffset > 0:
                    try handle.seek(toOffset: UInt64(requestedOffset))
                    try handle.truncate(atOffset: UInt64(requestedOffset))
                case 200:
                    // Server sent the whole file (range ignored or not requested): start over.
                    try handle.truncate(atOffset: 0)
                    try handle.seek(toOffset: 0)
                    received = 0
                default:
                    failure = RepositoryError.malformed("HTTP \(status)")
                    return false
                }
                return true
            } catch {
                failure = error
                return false
            }
        }
        completionHandler(ok ? .allow : .cancel)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        let report: (@Sendable (Int64, Int64) -> Void, Int64, Int64)? = lock.withLock {
            do { try handle?.write(contentsOf: data) } catch {
                failure = error
                dataTask.cancel()
                return nil
            }
            received += Int64(data.count)
            // Throttle UI updates to ~5 per second.
            guard Date().timeIntervalSince(lastReport) > 0.2, let onProgress else { return nil }
            lastReport = Date()
            return (onProgress, received, expected)
        }
        if let (callback, done, total) = report { callback(done, total) }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        let (c, failure, done, total, callback) = lock.withLock {
            defer { continuation = nil }
            return (continuation, self.failure, received, expected, onProgress)
        }
        if let failure { c?.resume(throwing: failure); return }
        if let error {
            c?.resume(throwing: (error as? URLError)?.code == .cancelled ? CancellationError() : error)
            return
        }
        callback?(done, total)
        c?.resume()
    }
}
