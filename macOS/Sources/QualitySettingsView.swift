import SwiftUI

struct QualitySettingsView: View {
    @ObservedObject var settings: IFSettings
    @State private var confirmClear = false

    var body: some View {
        Form {
            Section("本机输入质量记录") {
                Text("用于回顾输入质量，可能包含输入文本、候选词、上下文、自定义短语及应用标识。记录只保存在本机。")
                LabeledContent("记录状态", value: settings.qualityRecordingStatus)
                Button(settings.qualityRecordingPaused ? "恢复记录" : "暂停记录", action: changeRecording)
                    .accessibilityIdentifier("settings.quality.toggle")
                Text("暂停立即停止新记录，未完成的输入和等待写入的记录会丢弃；恢复后从下一段新输入开始。暂停不影响输入、个人学习和候选排序。")
                    .foregroundStyle(.secondary)
            }
            Section("保留与清除") {
                Text("含文本的输入记录保留 28 天；不含文本的学习效果事件保留 90 天，最多 4,096 条。墨流启动时及运行期间每小时清理过期记录，暂停时仍会清理。")
                Button("清除全部质量记录", role: .destructive) { confirmClear = true }
                    .accessibilityIdentifier("settings.quality.clear")
                Text("清除包含上述文本记录及学习效果事件，不包含个人词库、自定义短语、AI 用量统计或诊断日志。清除后记录开关保持不变。")
                    .foregroundStyle(.secondary)
                Text("清除是从墨流数据库移除记录，不保证擦除系统备份或文件系统快照中的副本。")
                    .foregroundStyle(.secondary)
            }
            if settings.qualityCommandPending { ProgressView("正在处理…") }
            if let message = settings.qualityControlMessage { Text(message).accessibilityIdentifier("settings.quality.result") }
            if settings.qualityStore == nil { Text("质量记录服务尚未启动。") }
        }
        .formStyle(.grouped)
        .disabled(settings.qualityCommandPending || settings.qualityStore == nil)
        .confirmationDialog("清除全部质量记录？", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("清除", role: .destructive, action: clearRecords)
            Button("取消", role: .cancel) { }
        } message: {
            Text("此操作无法撤销。正在输入及等待写入的质量记录也会丢弃，个人学习和词库不受影响。")
        }
    }

    private func changeRecording() { Task { await settings.setQualityRecordingPaused(!settings.qualityRecordingPaused) } }
    private func clearRecords() { Task { await settings.clearQualityRecords() } }
}
