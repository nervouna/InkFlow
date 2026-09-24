import SwiftUI

struct UpdateSettingsView: View {
    @ObservedObject var updaterAccess: IFUpdaterAccess

    private var automaticChecks: Binding<Bool> {
        Binding(
            get: { updaterAccess.automaticallyChecksForUpdates },
            set: { updaterAccess.automaticallyChecksForUpdates = $0 }
        )
    }

    private var automaticInstall: Binding<Bool> {
        Binding(
            get: { updaterAccess.automaticallyDownloadsUpdates },
            set: { updaterAccess.automaticallyDownloadsUpdates = $0 }
        )
    }

    var body: some View {
        Form {
            Section {
                Toggle("自动检查更新", isOn: automaticChecks)
                    .help("启用后每日检查一次新版本")
                    .accessibilityIdentifier("settings.updates.check")
                Toggle("自动下载并安装更新", isOn: automaticInstall)
                    .help("启用后自动下载更新，并在墨流退出时安装")
                    .accessibilityIdentifier("settings.updates.download")
                    .disabled(!updaterAccess.allowsAutomaticUpdates)
                Button("立即检查更新…") {
                    updaterAccess.checkForUpdates()
                }
                .accessibilityIdentifier("settings.updates.check-now")
                .disabled(!updaterAccess.canCheckForUpdates)
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.updates")
    }
}
