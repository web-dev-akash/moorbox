import AppKit
import MoorboxCore

// MARK: - Device controls

extension AppModel {
    func rotate(_ device: VirtualDevice) {
        deviceCommand(device, "Rotate") { adb, serial in try await adb.emulatorConsole(["rotate"], serial: serial) }
    }

    func press(_ key: ADB.Key, on device: VirtualDevice) {
        deviceCommand(device, "Key press") { adb, serial in try await adb.press(key, serial: serial) }
    }

    /// Saves a PNG to the Desktop, like macOS screenshots, and reveals it.
    func screenshot(_ device: VirtualDevice) {
        deviceCommand(device, "Screenshot") { [weak self] adb, serial in
            let png = try await adb.screenshotPNG(serial: serial)
            let formatter = DateFormatter()
            formatter.dateFormat = "yyyy-MM-dd 'at' HH.mm.ss"
            let desktop = FileManager.default.urls(for: .desktopDirectory, in: .userDomainMask)[0]
            let url = desktop.appendingPathComponent("\(device.displayName) \(formatter.string(from: Date())).png")
            try png.write(to: url, options: .atomic)
            await MainActor.run {
                NSWorkspace.shared.activateFileViewerSelecting([url])
                self?.log(.info, "Saved screenshot to \(url.path).")
            }
        }
    }

    private func deviceCommand(
        _ device: VirtualDevice,
        _ name: String,
        _ body: @escaping @Sendable (ADB, String) async throws -> Void
    ) {
        guard let adb, let serial = state(of: device).serial else { alertMessage = "Start the device first."; return }
        Task {
            do { try await body(adb, serial) } catch {
                alertMessage = "\(name) failed: \(error.localizedDescription)"
                log(.error, "\(name) failed: \(error.localizedDescription)")
            }
        }
    }
}
