import SwiftUI

struct DiagnosticFeedbackView: View {
    @State private var model: DiagnosticFeedbackModel

    init(dependencies: DiagnosticFeedbackDependencies) {
        _model = State(initialValue: DiagnosticFeedbackModel(dependencies: dependencies))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("本地故障诊断").font(.headline)
            Text("运行记录和已保存现场合计最多保留 7 天、50 MiB，可能提前清理。诊断包仅保存到你选择的位置。")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.feedback.retention")
            Toggle("问题发生在更早时间", isOn: $model.earlier)
                .accessibilityIdentifier("settings.feedback.earlier")
                .disabled(model.isBusy)
            if model.earlier {
                DatePicker("发生时间", selection: $model.occurredAt, in: ...Date.now, displayedComponents: [.date, .hourAndMinute])
                    .accessibilityIdentifier("settings.feedback.occurredAt")
                    .disabled(model.isBusy)
            }
            TextField("现象说明（可选，最多 2,000 字）", text: $model.note, axis: .vertical)
                .lineLimit(2...4)
                .textFieldStyle(.roundedBorder)
                .accessibilityIdentifier("settings.feedback.note")
                .disabled(model.isBusy)
            Text("默认不附输入正文、录音或统计数据库。现象说明会写入附件，请勿填写密码或敏感正文。")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("settings.feedback.privacy")
            Button("保存问题现场", systemImage: "bookmark", action: save)
                .disabled(model.isBusy)
                .accessibilityIdentifier("settings.feedback.saveIncident")
            Divider()
            Picker("导出范围", selection: $model.scope) {
                ForEach(DiagnosticFeedbackModel.Scope.allCases) { Text($0.rawValue).tag($0) }
            }
            .disabled(model.isBusy)
            .accessibilityIdentifier("settings.feedback.exportScope")
            if model.scope == .incident {
                if model.incidents.isEmpty {
                    Text("没有可用的已保存现场，可能尚未保存或已被清理。")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    Picker("问题现场", selection: $model.selectedIncident) {
                        ForEach(model.incidents) { incident in
                            Text("\(incident.occurredAt.formatted(date: .abbreviated, time: .shortened)) · \(incident.id.uuidString.prefix(8))\(incident.isPartial ? "（部分）" : "")")
                                .tag(Optional(incident.id))
                        }
                    }
                    .disabled(model.isBusy)
                    .accessibilityIdentifier("settings.feedback.incident")
                }
            }
            if let notice = model.listNotice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.feedback.incidentNotice")
            }
            Button("导出诊断包…", systemImage: "square.and.arrow.up", action: export)
                .disabled(!model.canExport)
                .accessibilityIdentifier("settings.feedback.exportDiagnostics")
            if model.isBusy {
                ProgressView(model.progress).controlSize(.small)
                    .accessibilityIdentifier("settings.feedback.diagnosticProgress")
            }
            if let status = model.status {
                Text(status.message).font(.caption)
                    .foregroundStyle(status.kind == .failure ? Color.red : Color.secondary)
                    .accessibilityIdentifier("settings.feedback.diagnosticStatus")
            }
        }
        .task { await model.reload() }
    }

    private func save() { Task { await model.save() } }
    private func export() { Task { await model.export() } }
}
