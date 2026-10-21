import Foundation

public struct CommandResult: Sendable {
    public var exitCode: Int32
    public var output: Data
    public var errorOutput: Data

    public var stdout: String { String(decoding: output, as: UTF8.self) }
    public var stderr: String { String(decoding: errorOutput, as: UTF8.self) }
    public var succeeded: Bool { exitCode == 0 }
    /// stdout and stderr together, for showing to the user.
    public var combined: String {
        [stdout, stderr].map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }.joined(separator: "\n")
    }

    public init(exitCode: Int32, output: Data = Data(), errorOutput: Data = Data()) {
        self.exitCode = exitCode
        self.output = output
        self.errorOutput = errorOutput
    }
}

public enum CommandError: LocalizedError, Equatable {
    case launchFailed(executable: String, reason: String)
    case timedOut(executable: String, seconds: Int)
    case failed(executable: String, exitCode: Int32, message: String)

    public var errorDescription: String? {
        switch self {
        case let .launchFailed(exe, reason): "Could not start \(exe): \(reason)"
        case let .timedOut(exe, seconds): "\(exe) did not finish within \(seconds) seconds and was stopped."
        case let .failed(exe, code, message):
            message.isEmpty ? "\(exe) failed with exit code \(code)." : message
        }
    }
}

/// Runs external tools. Executables are always invoked directly with an argument
/// array; nothing is ever passed through a shell.
public enum Shell {
    /// Runs a process to completion and captures its output.
    /// Cancelling the calling task, or exceeding `timeout`, terminates the process.
    public static func run(
        _ executable: URL,
        _ arguments: [String],
        environment: [String: String]? = nil,
        timeout: TimeInterval = 60
    ) async throws -> CommandResult {
        try Task.checkCancellation()
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe

        let control = ProcessControl(process)
        let name = executable.lastPathComponent
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<CommandResult, Error>) in
                let readers = DispatchGroup()
                let out = Buffer(), err = Buffer()
                out.collect(from: outPipe, group: readers)
                err.collect(from: errPipe, group: readers)

                process.terminationHandler = { finished in
                    DispatchQueue.global().async {
                        // A daemonising child (e.g. `adb start-server`) can keep the pipe open
                        // forever, so only wait briefly for EOF after the process itself exits.
                        _ = readers.wait(timeout: .now() + 2)
                        let result = CommandResult(exitCode: finished.terminationStatus, output: out.data, errorOutput: err.data)
                        switch control.stopReason {
                        case .timeout: continuation.resume(throwing: CommandError.timedOut(executable: name, seconds: Int(timeout)))
                        case .cancel: continuation.resume(throwing: CancellationError())
                        case nil: continuation.resume(returning: result)
                        }
                    }
                }
                do {
                    try process.run()
                } catch {
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    continuation.resume(throwing: CommandError.launchFailed(executable: executable.path, reason: error.localizedDescription))
                    return
                }
                DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { control.stop(.timeout) }
            }
        } onCancel: {
            control.stop(.cancel)
        }
    }

    /// Like `run`, but throws `CommandError.failed` on a non-zero exit code.
    @discardableResult
    public static func check(
        _ executable: URL, _ arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval = 60
    ) async throws -> CommandResult {
        let result = try await run(executable, arguments, environment: environment, timeout: timeout)
        guard result.succeeded else {
            throw CommandError.failed(executable: executable.lastPathComponent, exitCode: result.exitCode, message: result.combined)
        }
        return result
    }

    /// Starts a long-lived process (the emulator) in its own session, so it is not
    /// killed when the app quits or when a terminal sends signals to the app's
    /// process group. Only the listed descriptors are inherited; output goes to `logFile`.
    public static func spawnDetached(
        _ executable: URL, _ arguments: [String], environment: [String: String], logFile: URL
    ) throws -> pid_t {
        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        defer { posix_spawn_file_actions_destroy(&actions) }
        posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
        posix_spawn_file_actions_addopen(&actions, 1, logFile.path, O_WRONLY | O_CREAT | O_APPEND, 0o644)
        posix_spawn_file_actions_adddup2(&actions, 1, 2)

        let argv = ([executable.path] + arguments).map { strdup($0) } + [nil]
        let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
        defer { (argv + envp).forEach { free($0) } }

        var pid: pid_t = 0
        let rc = posix_spawn(&pid, executable.path, &actions, &attributes, argv, envp)
        guard rc == 0 else {
            throw CommandError.launchFailed(executable: executable.path, reason: String(cString: strerror(rc)))
        }
        return pid
    }

    /// True if a process with this PID exists and has not exited. An exited child that
    /// hasn't been reaped yet (a zombie) still answers `kill(pid, 0)`, so check its state.
    public static func isAlive(_ pid: pid_t) -> Bool {
        guard pid > 0 else { return false }
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return false }
        return info.kp_proc.p_stat != SZOMB
    }
}

private final class Buffer: @unchecked Sendable {
    private let lock = NSLock()
    private var storage = Data()
    var data: Data { lock.withLock { storage } }

    func collect(from pipe: Pipe, group: DispatchGroup) {
        group.enter()
        pipe.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            if chunk.isEmpty {
                handle.readabilityHandler = nil
                group.leave()
            } else {
                self.lock.withLock { self.storage.append(chunk) }
            }
        }
    }
}

private final class ProcessControl: @unchecked Sendable {
    enum Reason { case timeout, cancel }
    private let lock = NSLock()
    private let process: Process
    private var reason: Reason?

    init(_ process: Process) { self.process = process }
    var stopReason: Reason? { lock.withLock { reason } }

    func stop(_ why: Reason) {
        guard process.isRunning else { return }
        lock.withLock { if reason == nil { reason = why } }
        process.terminate()
        let pid = process.processIdentifier
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { [process] in
            if process.isRunning { kill(pid, SIGKILL) }
        }
    }
}
