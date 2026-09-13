import SwiftUI

/// Presentation only: the process-owned coordinator retains all work across window closure.
struct DictionarySettingsView: View {
    var coordinator: IFDictionaryCoordinator?
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let failure = coordinator?.failure {
                Label(coordinator?.engineAvailable == true ? "更新失败" : "词库暂不可用",
                      systemImage: "exclamationmark.triangle")
                    .font(.headline)
                    .foregroundStyle(.red)
                    .accessibilityIdentifier("dictionaries.failure")
                Text(coordinator?.engineAvailable == true
                     ? "当前词库仍可正常使用。"
                     : "请恢复后继续输入。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictionaries.failureMessage")
                DisclosureGroup("查看错误详情", isExpanded: $detailsExpanded) {
                    ScrollView([.horizontal, .vertical]) {
                        Text(failure.technicalDetails)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .fixedSize(horizontal: true, vertical: true)
                            .accessibilityIdentifier("dictionaries.errorDetails")
                            .padding(4)
                    }
                    .frame(height: 100)
                    .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 5))
                }
            } else if coordinator?.engineAvailable == true, let active = coordinator?.active {
                Label("词库已启用", systemImage: "checkmark.circle")
                    .font(.headline)
                    .accessibilityIdentifier("dictionaries.state")
                Text("\(active.manifest.entryCount.formatted()) 个中文词条")
                    .accessibilityIdentifier("dictionaries.count")
                Text(active.isBundled ? "正在使用随 InkFlow 提供的词库。" : "正在使用已更新的词库。")
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("dictionaries.engineStatus")
            } else {
                Label(coordinator == nil ? "正在准备词库…" : "词库暂不可用",
                      systemImage: coordinator == nil ? "hourglass" : "exclamationmark.triangle")
                    .font(.headline)
                    .accessibilityIdentifier("dictionaries.state")
                if coordinator != nil {
                    Text("恢复后即可继续输入。")
                        .foregroundStyle(.secondary)
                }
            }

            if let status {
                HStack(spacing: 8) {
                    if coordinator?.isBusy == true {
                        ProgressView()
                            .controlSize(.small)
                            .accessibilityLabel("词库更新进行中")
                    }
                    Text(status)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("dictionaries.status")
                }
            }

            if coordinator?.canRetry == true {
                Button(coordinator?.engineAvailable == true ? "重试" : "恢复词库", action: retry)
                    .accessibilityIdentifier("dictionaries.retry")
            } else if coordinator?.canUpdate == true {
                Button("更新词库", action: downloadAndUpdate)
                    .accessibilityIdentifier("dictionaries.update")
            } else if coordinator?.canCheck == true {
                Button("检查词库更新", action: checkForUpdates)
                    .accessibilityIdentifier("dictionaries.check")
            }

            Spacer(minLength: 0)
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: coordinator?.failure?.technicalDetails) { _, _ in detailsExpanded = false }
    }

    private var status: String? {
        guard let coordinator, coordinator.failure == nil else { return nil }
        let message: String?
        switch coordinator.activity {
        case .idle: message = nil
        case .checking: message = "正在检查词库更新…"
        case .upToDate: message = "词库已是最新。"
        case .updateAvailable: message = "发现词库更新。"
        case .downloading, .preparing, .verifying, .applying: message = "正在更新词库…"
        case .waitingForIdle: message = "更新已准备好，将在当前输入结束后启用。"
        case .updated: message = "词库已更新并启用。"
        }
        guard let message else { return nil }
        if let progress = coordinator.progress, progress.total > 0,
           [.downloading, .preparing, .verifying, .applying].contains(coordinator.activity) {
            return "\(message)（\(progress.completed)/\(progress.total)）"
        }
        return message
    }

    private func checkForUpdates() { coordinator?.checkForUpdates() }
    private func downloadAndUpdate() { coordinator?.downloadAndUpdate() }
    private func retry() { coordinator?.retry() }
}
