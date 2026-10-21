import MoorboxCore
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Form {
            Section("Android SDK") {
                LabeledContent("Location") {
                    Text(model.sdk?.root.path ?? "Not found").textSelection(.enabled)
                }
                HStack {
                    Button("Choose…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        panel.canCreateDirectories = true
                        if panel.runModal() == .OK, let url = panel.url {
                            model.sdkPathOverride = url.path
                        }
                    }
                    Button("Detect Automatically") { model.sdkPathOverride = nil }
                        .disabled(model.sdkPathOverride == nil)
                }
                Text(
                    """
                    Moorbox reuses an existing SDK (for example Android Studio’s) so images aren’t downloaded twice. \
                    It only adds packages you confirm and never removes an SDK.
                    """
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Android Versions") {
                Toggle("Show preview and beta Android versions", isOn: $model.showPreviews)
            }
            Section("Data locations") {
                LabeledContent("Virtual devices", value: model.avdStore.home.path)
                LabeledContent("Emulator logs", value: AppModel.logDirectory.path)
                Text(
                    """
                    Downloaded Android components live in the SDK folder; your devices (apps, files, snapshots) live \
                    in the virtual devices folder. Uninstalling Moorbox leaves both in place.
                    """
                )
                .font(.caption).foregroundStyle(.secondary)
            }
            Section("Privacy") {
                Text(
                    """
                    Moorbox has no account, no telemetry and no crash uploads. It only contacts dl.google.com to \
                    list and download Android components you choose.
                    """
                )
                .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .frame(width: 560, height: 520)
    }
}
