import SwiftUI

struct VoiceSettingsView: View {
    @ObservedObject var settings: IFSettings

    var body: some View {
        Form {
            Section("本机识别") {
                Text(settings.voice.message)
                    .accessibilityIdentifier("voice.preparation.status")
                switch settings.voice.action {
                case .authorize:
                    Button("允许使用麦克风") { Task { await settings.voice.prepare() } }
                        .accessibilityIdentifier("voice.prepare")
                case .retry:
                    Button("重试准备") { Task { await settings.voice.prepare(requestPermission: false) } }
                        .accessibilityIdentifier("voice.prepare")
                case .openSettings:
                    Link("打开麦克风设置", destination: URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone")!)
                case nil:
                    EmptyView()
                }
            }
            Section("快捷键") {
                Text("按住右 Shift 说话，松开结束。")
                Text("双击右 Shift 开始或结束连续听写；Esc 取消。")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.voice")
        .onAppear(perform: refreshPreparation)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshPreparation()
        }
    }

    private func refreshPreparation() { Task { await settings.voice.prepareIfAuthorized() } }
}
