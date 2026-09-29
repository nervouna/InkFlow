import SwiftUI
import AppKit
import UniformTypeIdentifiers
import InkFlowRime

struct PersonalDataSettingsView: View {
    @ObservedObject var settings: IFSettings
    let coordinator: IFDictionaryCoordinator?
    @State private var busy = false
    @State private var message: String?
    @State private var pending: PersonalBackupDocument?
    @State private var confirming = false
    @State private var preview = ""
    var body: some View {
        Form {
            Section("备份与恢复") {
                Text("备份输入与外观设置、快捷键、自定义短语、语音润色规则，以及中文、英文和语音词条的完整学习数据。")
                HStack {
                    Button("导出备份", action: export)
                    Button("恢复备份", action: chooseRestore)
                }.disabled(busy || coordinator == nil || coordinator?.isBusy == true)
                if busy { ProgressView("正在处理个人数据…") }
                if let message { Text(message).textSelection(.enabled) }
            }
            QualitySettingsView(settings: settings)
        }
        .formStyle(.grouped)
        .confirmationDialog("替换当前个人数据？", isPresented: $confirming, titleVisibility: .visible) {
            Button("替换并恢复", role: .destructive) {
                guard let pending else { return }
                self.pending = nil
                perform { try await $0.restore(pending) }
            }
            Button("取消", role: .cancel) { pending = nil }
        } message: {
            if let pending { Text("\(pending.settings.phrases.count) 条自定义短语、\(pending.settings.voiceRules.count) 条语音规则。\n\(preview)\n当前范围内的数据将被替换。") }
        }
    }
    private func controller() -> PersonalDataController? {
        guard let coordinator else { return nil }
        return .init(user: URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support/InkFlow"),
            helper: Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/InkFlowDictionaryWorker"), settings: settings, coordinator: coordinator)
    }
    private func perform(_ operation: @escaping @MainActor (PersonalDataController) async throws -> Void) {
        guard let controller = controller() else { return }
        busy = true; message = nil
        Task { @MainActor in
            defer { busy = false }
            do { try await operation(controller); message = "操作已完成。" }
            catch { message = PersonalDataError.report(error) }
        }
    }
    private func export() {
        let panel = NSSavePanel(); panel.allowedContentTypes = [.json]; panel.nameFieldStringValue = "InkFlow-personal-backup.json"
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            perform { try await $0.export(to: url) }
        }
    }
    private func chooseRestore() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.json]; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            busy = true; message = nil
            Task { @MainActor in
                defer { busy = false }
                do {
                    let loaded = try await Task.detached {
                        let document = try PersonalBackupDocument.read(url)
                        return (document, document.preview())
                    }.value
                    pending = loaded.0; preview = loaded.1
                    confirming = true
                } catch { message = "无法读取此备份。文件可能不兼容、损坏或超过大小限制。" }
            }
        }
    }
}
