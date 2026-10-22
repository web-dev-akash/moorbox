import Foundation
import MoorboxCore

// MARK: - Player windows

extension AppModel {
    func playerSession(for deviceID: String) -> PlayerSession {
        if let session = playerSessions[deviceID] {
            return session
        }
        let session = PlayerSession(deviceID: deviceID)
        playerSessions[deviceID] = session
        let device = devices.first { $0.id == deviceID }
        session.update(instance: device.flatMap { runtime?.instance(for: $0, in: instances) }, device: device)
        return session
    }

    /// Closing a player window stops its device: an emulator with a hidden window would
    /// otherwise keep running unseen. Stopping saves the quick-boot snapshot.
    func playerWindowClosed(_ deviceID: String) {
        playerSessions.removeValue(forKey: deviceID)?.close()
        guard embeddedLaunches.contains(deviceID),
              let device = devices.first(where: { $0.id == deviceID }), state(of: device).isActive,
              state(of: device) != .stopping else { return }
        if state(of: device) == .starting {
            cancelStart(device)
        } else {
            stop(device)
        }
    }

    var hasEmbeddedLaunchesRunning: Bool {
        devices.contains { embeddedLaunches.contains($0.id) && state(of: $0).isActive }
    }

    /// Embedded-display devices have no window of their own, so stop them when Moorbox quits.
    func stopEmbeddedDevicesForQuit() async {
        guard let runtime else { return }
        let embedded = devices.filter { embeddedLaunches.contains($0.id) }.compactMap { runtime.instance(for: $0, in: instances) }
        await withTaskGroup(of: Void.self) { group in
            for instance in embedded {
                group.addTask { try? await runtime.stop(instance, timeout: 60) }
            }
        }
    }

    func installAPK(_ url: URL, on deviceID: String) {
        guard let adb, let device = devices.first(where: { $0.id == deviceID }), let serial = state(of: device).serial else {
            showPlayerMessage("Start the device before installing apps.", on: deviceID)
            return
        }
        do { try ADB.validateAPK(url) } catch {
            showPlayerMessage(error.localizedDescription, on: deviceID)
            return
        }
        showPlayerMessage("Installing \(url.lastPathComponent)…", on: deviceID, autoHide: false)
        let access = url.startAccessingSecurityScopedResource()
        Task {
            defer {
                if access {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            do {
                _ = try await adb.install(url, serial: serial)
                showPlayerMessage("Installed \(url.lastPathComponent).", on: deviceID)
                log(.info, "Installed \(url.lastPathComponent) on \(device.displayName).")
            } catch {
                showPlayerMessage(error.localizedDescription, on: deviceID)
                log(.error, "Installing \(url.lastPathComponent) failed: \(error.localizedDescription)")
            }
        }
    }

    func showPlayerMessage(_ text: String, on deviceID: String, autoHide: Bool = true) {
        playerMessages[deviceID] = text
        guard autoHide else { return }
        Task {
            try? await Task.sleep(for: .seconds(4))
            if playerMessages[deviceID] == text {
                playerMessages[deviceID] = nil
            }
        }
    }
}
