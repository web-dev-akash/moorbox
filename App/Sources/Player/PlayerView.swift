import MoorboxCore
import SwiftUI
import UniformTypeIdentifiers

/// One window per running device: the Android screen plus a BlueStacks-style side toolbar.
struct PlayerView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismissWindow) private var dismissWindow
    let deviceID: String
    @State private var showImporter = false

    var body: some View {
        let device = model.devices.first { $0.id == deviceID }
        let state = device.map(model.state(of:)) ?? .stopped
        let session = model.playerSession(for: deviceID)
        HStack(spacing: 0) {
            ZStack {
                DeviceDisplay(session: session) { model.installAPK($0, on: deviceID) }
                if session.image == nil || session.phase != .streaming {
                    overlay(state: state, session: session)
                }
                if let message = model.playerMessages[deviceID] {
                    VStack {
                        Spacer()
                        Text(message)
                            .font(.callout)
                            .padding(.horizontal, 12).padding(.vertical, 8)
                            .background(.regularMaterial, in: Capsule())
                            .padding(.bottom, 16)
                    }
                    .transition(.opacity)
                    .accessibilityAddTraits(.updatesFrequently)
                }
            }
            .frame(minWidth: 240, minHeight: 320)
            Divider()
            sideBar(device: device, running: state.serial != nil)
        }
        .background(Color.black)
        .navigationTitle(device?.displayName ?? deviceID)
        .navigationSubtitle(subtitle(state: state, session: session))
        .onAppear { model.selectedDeviceID = deviceID }
        .onChange(of: state) { _, new in
            if new == .stopped {
                dismissWindow(id: "player", value: deviceID)
            }
        }
        .onDisappear { model.playerWindowClosed(deviceID) }
        .fileImporter(isPresented: $showImporter, allowedContentTypes: [UTType(filenameExtension: "apk") ?? .data]) { result in
            if case let .success(url) = result {
                model.installAPK(url, on: deviceID)
            }
        }
    }

    func subtitle(state: DeviceState, session: PlayerSession) -> String {
        session.phase == .streaming && session.framesPerSecond > 0 ? "\(state.label) · \(session.framesPerSecond) fps" : state.label
    }

    func overlay(state: DeviceState, session: PlayerSession) -> some View {
        VStack(spacing: 10) {
            switch (state, session.phase) {
            case let (.failed(diagnosis), _):
                Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.orange)
                Text(diagnosis.summary).multilineTextAlignment(.center)
                Text(diagnosis.remedy).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            case let (_, .failed(message)):
                Image(systemName: "display.trianglebadge.exclamationmark").font(.largeTitle).foregroundStyle(.orange)
                Text("Couldn’t show the device screen").font(.headline)
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            default:
                ProgressView().controlSize(.large)
                Text(state == .stopping ? "Shutting down…" : "Starting Android…").font(.headline)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.black)
    }

    func sideBar(device: VirtualDevice?, running: Bool) -> some View {
        VStack(spacing: 6) {
            tool("chevron.backward", "Back", key: "GoBack")
            tool("circle", "Home", key: "GoHome")
            tool("square.on.square", "Recent apps", key: "AppSwitch")
            Divider().frame(width: 28).padding(.vertical, 4)
            tool("speaker.wave.3", "Volume up", key: "AudioVolumeUp")
            tool("speaker.wave.1", "Volume down", key: "AudioVolumeDown")
            button("rotate.right", "Rotate") {
                if let device {
                    model.rotate(device)
                }
            }
            button("camera", "Screenshot to Desktop") {
                if let device {
                    model.screenshot(device)
                }
            }
            button("square.and.arrow.down", "Install APK…") { showImporter = true }
            Spacer()
            button("power", "Stop device") {
                if let device {
                    model.stop(device)
                }
            }
        }
        .disabled(!running)
        .buttonStyle(.borderless)
        .padding(.vertical, 12)
        .frame(width: 44)
        .background(.bar)
    }

    func tool(_ icon: String, _ label: String, key: String) -> some View {
        button(icon, label) { model.playerSession(for: deviceID).key(key) }
    }

    func button(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: 15)).frame(width: 32, height: 28)
        }
        .help(label)
        .accessibilityLabel(label)
    }
}
