import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var settings: IFSettings

    var body: some View {
        Form {
            Section {
                Toggle("自动检查更新", isOn: $settings.automaticUpdateChecksEnabled)
                    .help("启用后每日检查一次新版本")
                    .accessibilityIdentifier("settings.updates.check")
                Toggle("自动下载更新", isOn: $settings.automaticUpdateDownloadsEnabled)
                    .help("发现新版本后下载并打开安装器，由你点击安装")
                    .accessibilityIdentifier("settings.updates.download")
                    .disabled(!settings.automaticUpdateChecksEnabled)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.updates")
    }
}
