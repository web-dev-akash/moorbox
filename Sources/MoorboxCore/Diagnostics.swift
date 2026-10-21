import Foundation

public enum LogFiles {
    /// Keeps one previous log (`.1`) and starts fresh when the current one exceeds `maxBytes`.
    public static func rotate(_ url: URL, maxBytes: Int64 = 5 * 1_048_576) {
        let fm = FileManager.default
        guard let size = (try? fm.attributesOfItem(atPath: url.path))?[.size] as? Int64, size > maxBytes else { return }
        let previous = url.appendingPathExtension("1")
        try? fm.removeItem(at: previous)
        try? fm.moveItem(at: url, to: previous)
    }

    /// The last `maxBytes` of a file, decoded leniently.
    public static func tail(_ url: URL, maxBytes: Int = 64 * 1024) -> String {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "" }
        defer { try? handle.close() }
        let end = (try? handle.seekToEnd()) ?? 0
        try? handle.seek(toOffset: end > UInt64(maxBytes) ? end - UInt64(maxBytes) : 0)
        return String(decoding: (try? handle.readToEnd()) ?? Data(), as: UTF8.self)
    }
}

/// Removes personal details before a diagnostics report leaves the machine.
public enum Redactor {
    public static func redact(_ text: String, home: String = NSHomeDirectory(), user: String = NSUserName()) -> String {
        var out = text.replacingOccurrences(of: #"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#,
                                            with: "<email>", options: .regularExpression)
        out = out.replacingOccurrences(of: home, with: "~")
        if user.count > 2 { out = out.replacingOccurrences(of: user, with: "<user>") }
        // gRPC tokens/keys from emulator discovery files and similar secrets.
        out = out.replacingOccurrences(of: #"(?im)^(\s*[\w.]*(token|jwk|jwks|secret|password|key)[\w.]*\s*[=:]\s*).+$"#,
                                       with: "$1<redacted>", options: .regularExpression)
        return out
    }
}

public struct Diagnosis: Equatable, Sendable {
    public var summary: String
    public var remedy: String

    public init(summary: String, remedy: String) {
        self.summary = summary
        self.remedy = remedy
    }
}

/// Turns emulator output into an explanation and a next step.
/// Patterns are taken from real emulator 36.x output.
public enum EmulatorDiagnosis {
    public static let rules: [(pattern: String, Diagnosis)] = [
        ("Unknown AVD name", Diagnosis(summary: "The emulator could not find this device's definition.",
            remedy: "The device's .ini file may have been moved or deleted. Refresh the device list, or recreate the device.")),
        ("Cannot find AVD system path", Diagnosis(summary: "The device's Android system image is missing.",
            remedy: "Install the matching system image from Android Versions, or check the SDK location in Settings.")),
        ("Another emulator instance is running", Diagnosis(summary: "This device is already running in another emulator.",
            remedy: "Stop the other instance. If none is running, a previous session crashed; quit Moorbox and any emulator processes, then try again.")),
        ("is already running", Diagnosis(summary: "This device is already running in another emulator.",
            remedy: "Stop the other instance first, or start it with a different device.")),
        ("not supported by the QEMU2 emulator on aarch64 host", Diagnosis(summary: "This system image is for a different CPU architecture.",
            remedy: "Create a device with an arm64-v8a image; x86 images can't run on Apple Silicon.")),
        ("hasSufficientDiskSpace", Diagnosis(summary: "There isn't enough free disk space to run this device.",
            remedy: "Free up disk space, or reduce the device's storage size.")),
        ("HVF error", Diagnosis(summary: "Hardware virtualization (Hypervisor.framework) failed.",
            remedy: "Hardware acceleration is unavailable, which happens inside another virtual machine. Run Moorbox directly on the Mac.")),
        ("Missing emulator engine program", Diagnosis(summary: "The emulator installation is incomplete.",
            remedy: "Reinstall the Android Emulator from Setup.")),
        ("snapshot", Diagnosis(summary: "The quick-boot snapshot could not be used.",
            remedy: "Use Cold Boot, or Reset Quick Boot in the device's menu. Your apps and data are kept.")),
    ]

    public static func diagnose(log: String, exitCode: Int32?) -> Diagnosis {
        let failureLines = log.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix("FATAL") || $0.hasPrefix("ERROR") || $0.hasPrefix("PANIC") }
            .joined(separator: "\n")
        for (pattern, diagnosis) in rules where failureLines.localizedCaseInsensitiveContains(pattern) {
            return diagnosis
        }
        let code = exitCode.map { " (exit code \($0))" } ?? ""
        return Diagnosis(summary: "The emulator stopped unexpectedly\(code).",
                         remedy: "Try a Cold Boot. If it keeps failing, open Diagnostics to read the emulator log.")
    }
}

/// What the UI shows for a device.
public enum DeviceState: Equatable, Sendable {
    case stopped
    case starting
    case booting(serial: String)
    case running(serial: String)
    case stopping
    case failed(Diagnosis)

    public var isActive: Bool {
        switch self {
        case .starting, .booting, .running, .stopping: true
        case .stopped, .failed: false
        }
    }

    public var serial: String? {
        switch self {
        case let .booting(s), let .running(s): s
        default: nil
        }
    }

    public var label: String {
        switch self {
        case .stopped: "Stopped"
        case .starting: "Starting…"
        case .booting: "Booting Android…"
        case .running: "Running"
        case .stopping: "Shutting down…"
        case .failed: "Failed to run"
        }
    }

    /// Operations the app has in flight for a device.
    public enum Pending: Equatable, Sendable { case starting, stopping }

    /// Derives the displayed state from observed facts. The process registry is the
    /// source of truth; `pending` only covers the gap before the registry catches up.
    public static func resolve(instance: RunningInstance?, bootCompleted: Bool, pending: Pending?, lastFailure: Diagnosis?) -> DeviceState {
        switch (instance, pending) {
        case (_?, .stopping?): return .stopping
        case let (instance?, _): return bootCompleted ? .running(serial: instance.serial) : .booting(serial: instance.serial)
        case (nil, .starting?): return .starting
        case (nil, .stopping?): return .stopping
        case (nil, nil): return lastFailure.map(DeviceState.failed) ?? .stopped
        }
    }
}
