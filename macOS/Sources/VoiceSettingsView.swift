import SwiftUI

struct VoiceSettingsView: View {
    @ObservedObject var settings: IFSettings
    @ObservedObject var shortcuts: KeyboardShortcuts

    var showShortcuts: () -> Void = {}
    var showAIService: () -> Void = {}

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
                LabeledContent("按住说话", value: shortcuts.title(for: .voiceHold))
                LabeledContent("连续听写", value: shortcuts.title(for: .voiceToggle))
                Text("松开结束按住说话；Esc 取消听写。")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("查看快捷键", action: showShortcuts)
                    .accessibilityIdentifier("voice.shortcuts")
            }
            Section("语音润色") {
                Toggle("润色语音转写", isOn: $settings.voicePolishEnabled)
                    .accessibilityIdentifier("voice.polish")
                Button("配置 AI 服务", action: showAIService)
                    .accessibilityIdentifier("voice.aiService")
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
