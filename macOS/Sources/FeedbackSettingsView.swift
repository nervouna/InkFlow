import SwiftUI

struct FeedbackSettingsView: View {
    let reporter: FeedbackReporter
    var diagnosticDependencies: DiagnosticFeedbackDependencies = .live

    @State private var includesLogs = false
    @State private var isPreparing = false
    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 12) {
            Button("在 GitHub 提交反馈", systemImage: "exclamationmark.bubble", action: submitFeedback)
                .buttonStyle(.borderedProminent)
                .disabled(isPreparing)
                .accessibilityIdentifier("settings.feedback.submitFeedback")
            Toggle("附上最近 10 分钟运行日志", isOn: $includesLogs)
                .accessibilityIdentifier("settings.feedback.includeLogs")
            if isPreparing {
                ProgressView("正在准备反馈…")
                    .controlSize(.small)
                    .accessibilityIdentifier("settings.feedback.progress")
            }
            if let statusMessage {
                Text(statusMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("settings.feedback.status")
            }
            Divider().padding(.vertical, 4)
            DiagnosticFeedbackView(dependencies: diagnosticDependencies)
        }
        .padding(20)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        }
    }

    private func submitFeedback() {
        guard !isPreparing else { return }
        isPreparing = true
        statusMessage = nil
        Task {
            let report = await reporter.prepare(includeLogs: includesLogs)
            isPreparing = false
            if reporter.open(report) {
                statusMessage = report.notice
            } else {
                statusMessage = "无法打开 GitHub，请检查默认浏览器设置后重试。"
            }
        }
    }
}
