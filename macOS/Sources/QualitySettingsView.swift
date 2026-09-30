import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct QualitySettingsView: View {
    @ObservedObject var settings: IFSettings
    @State private var confirmClear = false
    @State private var exporting = false
    @State private var exportMessage: String?

    var body: some View {
        Section("输入质量记录") {
            Text("墨流在本机保存过去 28 天的文本输入记录和 90 天的学习效果事件，最多保存 4096 条，用于评估历史输入质量。你可以选择暂停记录，或者清除所有记录。")
            HStack {
                Button(settings.qualityRecordingPaused ? "恢复记录" : "暂停记录", action: changeRecording)
                    .accessibilityIdentifier("settings.quality.toggle")
                Button("清除记录", role: .destructive) { confirmClear = true }
                    .accessibilityIdentifier("settings.quality.clear")
            }
            Text("导出本机仍保留的记录，用于跨设备分析。文件可能包含输入内容、候选、选择结果和前文；不包含个人词库、完整设置或凭据。你选择保存位置并自行传递，不自动上传。本机清理不会删除已导出的副本。")
            Button("导出质量数据", action: exportRecords)
                .accessibilityIdentifier("settings.quality.export")
                .disabled(exporting)
            if exporting { ProgressView("正在导出质量数据…") }
            if let exportMessage { Text(exportMessage).textSelection(.enabled) }
            if settings.qualityCommandPending { ProgressView("正在处理…") }
            if let message = settings.qualityControlMessage { Text(message).accessibilityIdentifier("settings.quality.result") }
            if settings.qualityStore == nil { Text("质量记录服务尚未启动。") }
        }
        .disabled(settings.qualityCommandPending || settings.qualityStore == nil)
        .confirmationDialog("清除全部质量记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive, action: clearRecords)
            Button("取消", role: .cancel) { }
        } message: {
            Text("此操作无法撤销。正在输入及等待写入的质量记录也会丢弃，个人学习和词库不受影响。")
        }
    }

    private func exportRecords() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "InkFlow-quality-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).json"
        panel.message = "文件可能包含输入内容、候选及前文，请选择保存位置。"
        panel.begin { response in
            guard response == .OK, let destination = panel.url else { return }
            exporting = true
            exportMessage = nil
            Task { @MainActor in
                defer { exporting = false }
                do {
                    exportMessage = try await Task.detached(priority: .utility) {
                        let database = URL(fileURLWithPath: NSHomeDirectory())
                            .appendingPathComponent("Library/Application Support/InkFlow/quality.sqlite3")
                        return try QualityExport.write(database: database, destination: destination)
                    }.value
                } catch { exportMessage = "导出未完成：\(error.localizedDescription)" }
            }
        }
    }

    private func changeRecording() { Task { await settings.setQualityRecordingPaused(!settings.qualityRecordingPaused) } }
    private func clearRecords() { Task { await settings.clearQualityRecords() } }
}
