import AppKit
import MoorboxCore
import Foundation
import Observation

struct AppEvent: Identifiable {
    enum Level { case info, warning, error }
    let id = UUID()
    let date = Date()
    let level: Level
    let message: String
}

struct InstallProgress: Equatable {
    var phase: InstallPhase
    var error: String?
}

/// App-wide state. All SDK and runtime work is delegated to MoorboxCore; views only
/// read this model and call its methods.
@MainActor @Observable
final class AppModel {
    let host = HostInfo.current()
    let avdStore = AVDStore(home: AVDStore.defaultHome())
    static let supportDirectory = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Moorbox")
    static let logDirectory = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Logs/Moorbox")

    // Settings
    var sdkPathOverride: String? = UserDefaults.standard.string(forKey: "sdkPath") {
        didSet { UserDefaults.standard.set(sdkPathOverride, forKey: "sdkPath"); refresh() }
    }
    var showPreviews = UserDefaults.standard.bool(forKey: "showPreviews") {
        didSet { UserDefaults.standard.set(showPreviews, forKey: "showPreviews") }
    }
    var setupCompleted = UserDefaults.standard.bool(forKey: "setupCompleted") {
        didSet { UserDefaults.standard.set(setupCompleted, forKey: "setupCompleted") }
    }

    // Discovered state
    private(set) var sdk: AndroidSDK?
    private(set) var sdkHealth: SDKHealth?
    private(set) var devices: [VirtualDevice] = []
    private(set) var installedImages: [InstalledSystemImage] = []
    private(set) var instances: [RunningInstance] = []
    private var booted: Set<String> = []
    private var pending: [String: DeviceState.Pending] = [:]
    private var spawned: [String: pid_t] = [:]
    private(set) var failures: [String: Diagnosis] = [:]

    // Catalog / installs
    private(set) var catalog: Catalog?
    private(set) var catalogError: String?
    private(set) var isLoadingCatalog = false
    private(set) var installs: [String: InstallProgress] = [:]
    private var installTasks: [String: Task<Void, Never>] = [:]

    // UI
    var section: SidebarItem? = .devices
    var selectedDeviceID: String?
    var showSetup = false
    var showCreate = false
    var alertMessage: String?
    private(set) var events: [AppEvent] = []

    private var watchers: [Int32: DispatchSourceProcess] = [:]
    private var directoryWatcher: DispatchSourceFileSystemObject?
    private var bootTasks: [String: Task<Void, Never>] = [:]
    private var adbStarted = false

    init() {
        refresh()
        watchDiscoveryDirectory()
        if !setupCompleted || sdk == nil { showSetup = true }
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: Derived

    var runtime: EmulatorRuntime? {
        sdk.map { EmulatorRuntime(sdk: $0, avdHome: avdStore.home, logDirectory: Self.logDirectory) }
    }

    var adb: ADB? { sdk.map { ADB(executable: $0.adbBinary) } }

    var effectiveSDKLocation: URL {
        sdk?.root ?? sdkPathOverride.map { URL(fileURLWithPath: $0) } ?? AndroidSDK.defaultLocation()
    }

    var isRuntimeReady: Bool { sdkHealth?.isReady == true }

    func state(of device: VirtualDevice) -> DeviceState {
        DeviceState.resolve(instance: runtime?.instance(for: device, in: instances),
                            bootCompleted: booted.contains(device.id),
                            pending: pending[device.id], lastFailure: failures[device.id])
    }

    var runningDevices: [(device: VirtualDevice, serial: String)] {
        devices.compactMap { d in
            if case let .running(serial) = state(of: d) { return (d, serial) }
            return nil
        }
    }

    var selectedDevice: VirtualDevice? { devices.first { $0.id == selectedDeviceID } }

    // MARK: Refresh

    func refresh() {
        let preferred = sdkPathOverride.map { URL(fileURLWithPath: $0) }
        sdk = AndroidSDK.discover(preferred: preferred)
        sdkHealth = sdk?.health(host: host)
        installedImages = sdk?.installedSystemImages() ?? []
        devices = avdStore.list()
        refreshInstances()
    }

    func refreshInstances() {
        guard let runtime else { instances = []; return }
        instances = runtime.runningInstances()
        for instance in instances where watchers[instance.pid] == nil {
            watchProcess(instance.pid, deviceID: instance.avdID)
        }
        for device in devices {
            guard let instance = runtime.instance(for: device, in: instances) else {
                booted.remove(device.id)
                continue
            }
            if pending[device.id] == .starting { pending[device.id] = nil }
            if !booted.contains(device.id), bootTasks[device.id] == nil { waitForBoot(device, instance) }
        }
    }

    /// The emulator registers running instances in a directory; watching it gives
    /// instant state updates without polling.
    private func watchDiscoveryDirectory() {
        let dir = EmulatorRuntime.defaultDiscoveryDirectory
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.path, O_EVTONLY)
        guard fd >= 0 else { return }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.refreshInstances() } }
        source.setCancelHandler { close(fd) }
        source.resume()
        directoryWatcher = source
    }

    private func watchProcess(_ pid: pid_t, deviceID: String) {
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: .main)
        source.setEventHandler { [weak self] in
            var status: Int32 = 0
            // Reap our own child; for an emulator started elsewhere this returns -1 (ECHILD).
            let exitCode: Int32? = waitpid(pid, &status, WNOHANG) == pid ? (status & 0x7f == 0 ? (status >> 8) & 0xff : 128 + (status & 0x7f)) : nil
            MainActor.assumeIsolated { self?.processExited(pid, deviceID: deviceID, exitCode: exitCode) }
        }
        source.resume()
        watchers[pid] = source
        // A process that exited before the source was registered never delivers .exit.
        if !Shell.isAlive(pid) {
            source.cancel()
            var status: Int32 = 0
            let code: Int32? = waitpid(pid, &status, WNOHANG) == pid ? (status >> 8) & 0xff : nil
            processExited(pid, deviceID: deviceID, exitCode: code)
        }
    }

    private func processExited(_ pid: pid_t, deviceID: String, exitCode: Int32?) {
        watchers.removeValue(forKey: pid)?.cancel()
        bootTasks.removeValue(forKey: deviceID)?.cancel()
        let wasBooted = booted.contains(deviceID)
        let requested = pending[deviceID] == .stopping
        pending[deviceID] = nil
        if spawned[deviceID] == pid { spawned[deviceID] = nil }
        booted.remove(deviceID)
        refreshInstances()
        guard !requested, let device = devices.first(where: { $0.id == deviceID }) else {
            log(.info, "\(deviceID) stopped.")
            return
        }
        let logText = runtime.map { LogFiles.tail($0.logFile(for: device)) } ?? ""
        let diagnosis = EmulatorDiagnosis.diagnose(log: logText, exitCode: exitCode)
        let specific = EmulatorDiagnosis.rules.contains { $0.1 == diagnosis }
        // Closing the emulator window is a normal exit (code 0).
        if (exitCode ?? 0) != 0 || (!wasBooted && specific) {
            failures[deviceID] = diagnosis
            log(.error, "\(device.displayName): \(diagnosis.summary)")
        } else {
            log(.info, "\(device.displayName) stopped.")
        }
    }

    private func waitForBoot(_ device: VirtualDevice, _ instance: RunningInstance) {
        guard let adb else { return }
        bootTasks[device.id] = Task { [weak self] in
            await self?.ensureADBServer()
            let pid = instance.pid
            do {
                try await adb.waitForBoot(instance.serial, timeout: 600) { Shell.isAlive(pid) }
                guard let self else { return }
                self.booted.insert(device.id)
                self.log(.info, "\(device.displayName) finished booting (\(instance.serial)).")
            } catch is CancellationError {
            } catch {
                self?.log(.warning, "\(device.displayName): \(error.localizedDescription)")
            }
            self?.bootTasks[device.id] = nil
        }
    }

    func ensureADBServer() async {
        guard !adbStarted, let adb else { return }
        do {
            try await adb.startServer()
            adbStarted = true
        } catch {
            log(.error, "Could not start adb: \(error.localizedDescription)")
        }
    }

    // MARK: Device lifecycle

    func start(_ device: VirtualDevice, coldBoot: Bool = false) {
        guard let runtime else { alertMessage = "Set up the Android Emulator first."; return }
        failures[device.id] = nil
        do {
            let pid = try runtime.start(device, options: StartOptions(coldBoot: coldBoot))
            pending[device.id] = .starting
            spawned[device.id] = pid
            watchProcess(pid, deviceID: device.id)
            log(.info, "Starting \(device.displayName)\(coldBoot ? " (cold boot)" : "") — pid \(pid).")
        } catch {
            failures[device.id] = Diagnosis(summary: error.localizedDescription, remedy: "")
            log(.error, "\(device.displayName): \(error.localizedDescription)")
        }
    }

    func stop(_ device: VirtualDevice, then: (@MainActor () -> Void)? = nil) {
        guard let runtime, let instance = runtime.instance(for: device, in: instances) else { return }
        pending[device.id] = .stopping
        log(.info, "Shutting down \(device.displayName)…")
        Task {
            do {
                try await runtime.stop(instance, timeout: 90)
                then?()
            } catch {
                pending[device.id] = nil
                alertMessage = error.localizedDescription
                log(.warning, error.localizedDescription)
            }
        }
    }

    func restart(_ device: VirtualDevice) {
        stop(device) { [weak self] in
            guard let self, let fresh = self.devices.first(where: { $0.id == device.id }) else { return }
            self.start(fresh)
        }
    }

    /// Cancels a start that hasn't registered yet (e.g. the emulator is stuck before boot).
    /// Only signals the process Moorbox itself spawned, and only if it is still an emulator.
    func cancelStart(_ device: VirtualDevice) {
        guard pending[device.id] == .starting, let pid = spawned[device.id],
              EmulatorRuntime.isEmulatorProcess(pid) else { return }
        kill(pid, SIGTERM)
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) {
            if EmulatorRuntime.isEmulatorProcess(pid) { kill(pid, SIGKILL) }
        }
        log(.warning, "Cancelled starting \(device.displayName).")
    }

    func forceStop(_ device: VirtualDevice) {
        guard let runtime, let instance = runtime.instance(for: device, in: instances) else { return }
        pending[device.id] = .stopping
        runtime.forceStop(instance)
        log(.warning, "Force-stopping \(device.displayName).")
    }

    func create(_ spec: DeviceSpec) throws -> VirtualDevice {
        let limits = ResourceLimits.compute(host: host, apiLevel: spec.image.apiLevel)
        let device = try avdStore.create(spec, limits: limits)
        log(.info, "Created device \(device.displayName).")
        refresh()
        selectedDeviceID = device.id
        return device
    }

    func delete(_ device: VirtualDevice) {
        guard !state(of: device).isActive else { alertMessage = "Stop the device before deleting it."; return }
        do {
            try avdStore.moveToTrash(device)
            log(.info, "Moved \(device.displayName) to the Trash.")
            if selectedDeviceID == device.id { selectedDeviceID = nil }
        } catch {
            alertMessage = "Could not delete \(device.displayName): \(error.localizedDescription)"
        }
        refresh()
    }

    func rename(_ device: VirtualDevice, to name: String) {
        perform { try self.avdStore.rename(device, to: name) }
    }

    func updateResources(_ device: VirtualDevice, ramMB: Int, cores: Int, gpu: GPUMode) {
        perform {
            try self.avdStore.update(device, changes: ["hw.ramSize": String(ramMB), "hw.cpu.ncore": String(cores), "hw.gpu.mode": gpu.rawValue])
        }
    }

    func resetQuickBoot(_ device: VirtualDevice) {
        perform { try self.avdStore.deleteQuickBootSnapshot(device) }
        log(.info, "Removed the quick-boot snapshot for \(device.displayName). The next start is a cold boot.")
    }

    private func perform(_ body: () throws -> Void) {
        do { try body() } catch { alertMessage = error.localizedDescription }
        refresh()
    }

    // MARK: Device controls

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

    private func deviceCommand(_ device: VirtualDevice, _ name: String,
                               _ body: @escaping @Sendable (ADB, String) async throws -> Void) {
        guard let adb, let serial = state(of: device).serial else { alertMessage = "Start the device first."; return }
        Task {
            do { try await body(adb, serial) } catch {
                alertMessage = "\(name) failed: \(error.localizedDescription)"
                log(.error, "\(name) failed: \(error.localizedDescription)")
            }
        }
    }

    // MARK: Catalog & installs

    func loadCatalog(force: Bool = false) {
        guard force || (catalog == nil && !isLoadingCatalog) else { return }
        isLoadingCatalog = true
        catalogError = nil
        Task {
            do {
                catalog = try await SDKRepository().fetchCatalog()
                log(.info, "Loaded \(catalog?.packages.count ?? 0) packages from the Android SDK repository.")
            } catch {
                catalogError = "Couldn't load available Android versions: \(error.localizedDescription)"
                log(.error, catalogError!)
            }
            isLoadingCatalog = false
        }
    }

    func license(for package: RemotePackage) -> License? {
        package.licenseID.flatMap { catalog?.licenses[$0] }
    }

    func isInstalled(_ package: RemotePackage) -> Bool {
        sdk.map { $0.isInstalled(package) } ?? false
    }

    /// Why an image can't be used yet with the installed emulator, if at all.
    func emulatorRequirement(for package: RemotePackage) -> String? {
        guard let needed = package.minEmulatorRevision, let have = sdk?.emulatorRevision, have < needed else { return nil }
        return "Requires Android Emulator \(needed) or newer (installed: \(have)). Update the emulator in Setup."
    }

    /// Installs into the current SDK, or creates one at `effectiveSDKLocation`.
    /// The caller is responsible for showing the license and obtaining consent first.
    func install(_ package: RemotePackage, acceptLicense: Bool, replacing: Bool = false) {
        guard installTasks[package.path] == nil else { return }
        let sdk = self.sdk ?? AndroidSDK(root: effectiveSDKLocation)
        if replacing, package.path == "emulator", !instances.isEmpty {
            alertMessage = "Stop all running devices before updating the emulator."
            return
        }
        let license = self.license(for: package)
        do {
            if acceptLicense, let license { try sdk.recordAcceptance(of: license) }
        } catch {
            alertMessage = "Could not record license acceptance: \(error.localizedDescription)"
            return
        }
        installs[package.path] = InstallProgress(phase: .downloading(received: 0, total: package.archive(for: host.architecture)?.size ?? 0))
        log(.info, "Installing \(package.displayName) into \(sdk.root.path)…")
        let installer = PackageInstaller(sdk: sdk, host: host.architecture)
        let path = package.path
        installTasks[path] = Task {
            do {
                try await installer.install(package, license: license, replacing: replacing) { phase in
                    Task { @MainActor [weak self] in self?.installs[path]?.phase = phase }
                }
                installs[path] = nil
                log(.info, "Installed \(package.displayName).")
                if self.sdk == nil { sdkPathOverride = sdk.root.path }
            } catch is CancellationError {
                installs[path] = nil
                log(.info, "Cancelled installing \(package.displayName).")
            } catch {
                installs[path] = InstallProgress(phase: .finished, error: error.localizedDescription)
                log(.error, "Installing \(package.displayName) failed: \(error.localizedDescription)")
            }
            installTasks[path] = nil
            refresh()
        }
    }

    func removeImage(_ image: InstalledSystemImage) {
        guard let sdk else { return }
        let users = devices.filter { $0.systemImageDirectory == image.relativeDirectory }
        guard !users.contains(where: { state(of: $0).isActive }) else {
            alertMessage = "Stop the devices using this image first."
            return
        }
        perform { try FileManager.default.trashItem(at: sdk.root.appendingPathComponent(image.relativeDirectory), resultingItemURL: nil) }
        log(.info, "Moved \(image.packagePath) to the Trash.")
    }

    func cancelInstall(_ path: String) { installTasks[path]?.cancel() }
    func dismissInstallError(_ path: String) { installs[path] = nil }

    // MARK: Events

    func log(_ level: AppEvent.Level, _ message: String) {
        events.append(AppEvent(level: level, message: message))
        if events.count > 500 { events.removeFirst(events.count - 500) }
    }
}
