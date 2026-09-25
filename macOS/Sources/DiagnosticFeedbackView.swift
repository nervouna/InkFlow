import SwiftUI

struct DiagnosticFeedbackView: View {
    @State private var model: DiagnosticFeedbackModel

    init(dependencies: DiagnosticFeedbackDependencies) {
        _model = State(initialValue: DiagnosticFeedbackModel(dependencies: dependencies))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("导出日志")
                .font(.headline)
            Picker("选择时间范围", selection: $model.scope) {
                ForEach(DiagnosticFeedbackModel.Scope.allCases) { scope in
                    Text(scope.rawValue).tag(scope)
                }
            }
            .pickerStyle(.menu)
            .disabled(model.isBusy)
            .accessibilityIdentifier("settings.feedback.exportScope")
            Button("导出", systemImage: "square.and.arrow.up", action: export)
                .disabled(!model.canExport)
                .accessibilityIdentifier("settings.feedback.exportDiagnostics")
            if model.isBusy {
                ProgressView(model.progress)
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.feedback.diagnosticProgress")
            }
            if let status = model.status {
                Text(status.message)
                    .font(.caption)
                    .foregroundStyle(status.kind == .failure ? Color.red : Color.secondary)
                    .accessibilityIdentifier("settings.feedback.diagnosticStatus")
            }
        }
    }

    private func export() { Task { await model.export() } }
}
