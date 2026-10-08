import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct QualitySettingsView: View {
    @ObservedObject var settings: IFSettings
    @State private var confirmClear = false
    @State private var confirmTextCapture = false
    @State private var exporting = false
    @State private var exportMessage: String?

    var body: some View {
        Section("输入质量记录") {
            Text("墨流在本机保存过去 28 天的候选排名和操作时序，以及 90 天的学习效果事件（最多 4096 条），用于评估历史输入质量。默认不保存任何输入文本。你可以暂停记录，或者清除所有记录。")
            HStack {
                Button(settings.qualityRecordingPaused ? "恢复记录" : "暂停记录", action: changeRecording)
                    .accessibilityIdentifier("settings.quality.toggle")
                Button("清除记录", role: .destructive) { confirmClear = true }
                    .accessibilityIdentifier("settings.quality.clear")
            }
            Toggle("同时保存输入文本", isOn: textCapture)
                .accessibilityIdentifier("settings.quality.text")
            Text("开启后会在本机明文保存输入内容、候选、选中结果和光标前 16 个字，保留 28 天。关闭时会删除已保存的输入文本。")
            Text("导出本机仍保留的记录，用于跨设备分析。开启文本记录时文件包含输入内容、候选、选择结果和前文，否则只有排名、时序和学习效果事件；不包含个人词库、完整设置或凭据。你选择保存位置并自行传递，不自动上传。本机清理不会删除已导出的副本。")
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
        .confirmationDialog("开启文本记录？", isPresented: $confirmTextCapture, titleVisibility: .visible) {
            Button("开启文本记录") { Task { await settings.setQualityTextCapture(true) } }
            Button("取消", role: .cancel) { }
        } message: {
            Text("墨流会把你输入的拼音、候选、选中的文字和光标前文明文保存在本机质量数据库中，保留 28 天；导出的质量数据也会包含这些文本。随时可以关闭并删除。")
        }
    }

    private var textCapture: Binding<Bool> {
        Binding(get: { settings.qualityTextCapture }, set: { enabled in
            if enabled { confirmTextCapture = true } else { Task { await settings.setQualityTextCapture(false) } }
        })
    }

    private func exportRecords() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "InkFlow-quality-\(Date.now.formatted(.iso8601.year().month().day().dateSeparator(.dash))).json"
        panel.message = settings.qualityTextCapture ? "文件包含输入内容、候选及前文，请选择保存位置。" : "文件只含排名、时序和学习效果事件，请选择保存位置。"
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
