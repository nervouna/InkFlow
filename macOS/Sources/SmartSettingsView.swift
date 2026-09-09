import SwiftUI

struct SmartSettingsView: View {
    @ObservedObject var smart: IFSmartSettings
    @State private var baseURL: String
    @State private var apiKey: String
    @State private var model: String
    @State private var saveError: String?
    @State private var saved = false

    init(smart: IFSmartSettings) {
        self.smart = smart
        _baseURL = State(initialValue: smart.configuration.baseURL)
        _apiKey = State(initialValue: smart.configuration.apiKey)
        _model = State(initialValue: smart.configuration.model)
    }

    var body: some View {
        Form {
            Toggle("智能预测", isOn: $smart.isEnabled)
                .disabled(!smart.isAvailable)
                .accessibilityIdentifier("smart.enabled")
            TextField("Base URL", text: $baseURL, prompt: Text("服务的 API 基础地址"))
                .accessibilityIdentifier("smart.baseURL")
            SecureField("API Key", text: $apiKey, prompt: Text("粘贴 API Key"))
                .accessibilityIdentifier("smart.apiKey")
            TextField("模型名称", text: $model, prompt: Text("服务中的模型名称"))
                .accessibilityIdentifier("smart.model")
            HStack {
                if saved { Text("已保存").font(.caption).foregroundStyle(.secondary) }
                Spacer()
                Button("保存配置", action: save)
                    .accessibilityIdentifier("smart.save")
            }
            Text("开启后，输入停顿时会将光标前后文本和拼音发送至所配置的服务。按 Tab 采纳建议。API Key 保存在本机钥匙串。")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("smart.notice")
            if let error = saveError ?? smart.credentialError ?? smart.requestError {
                Text(error).font(.caption).foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("smart.error")
            }
        }
        .formStyle(.grouped)
        .accessibilityIdentifier("settings.smart")
        .onChange(of: baseURL) { saved = false }
        .onChange(of: apiKey) { saved = false }
        .onChange(of: model) { saved = false }
    }

    private func save() {
        do {
            try smart.save(baseURL: baseURL, apiKey: apiKey, model: model)
            baseURL = smart.configuration.baseURL
            apiKey = smart.configuration.apiKey
            model = smart.configuration.model
            saveError = nil
            saved = true
        } catch {
            saveError = AICredentialError.unavailable.localizedDescription
            saved = false
        }
    }
}
