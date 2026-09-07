import SwiftUI

/// Presentation only: the process-owned coordinator retains all work across window closure.
struct DictionarySettingsView: View {
    var coordinator: IFDictionaryCoordinator?
    @State private var sourcesExpanded = false
    @State private var detailsExpanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    if coordinator?.engineAvailable == true, let active = coordinator?.active {
                        activeDictionary(active)
                        DisclosureGroup("词库来源", isExpanded: $sourcesExpanded) {
                            sources(active.manifest)
                        }
                        .accessibilityIdentifier("dictionaries.sources")
                    } else {
                        Text(coordinator == nil ? "词库服务尚未就绪" : "输入引擎暂不可用")
                            .font(.headline)
                            .accessibilityIdentifier("dictionaries.unavailable")
                        Text("恢复词库后可查看当前版本并检查更新。")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(1)
            }
            .accessibilityIdentifier("dictionaries.metadata")

            Divider()
            if let failure = coordinator?.failure {
                VStack(alignment: .leading, spacing: 6) {
                    Label(failure.stage.failureSummary, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                        .accessibilityIdentifier("dictionaries.failure")
                    Text("失败阶段：\(failure.stage.displayName)")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("dictionaries.failureStage")
                    Text(coordinator?.engineAvailable == true && coordinator?.active != nil
                         ? "仍在使用词库 \(coordinator!.active!.manifest.contentVersion.prefix(15))…"
                         : "输入引擎暂不可用")
                        .font(.caption).foregroundStyle(.secondary)
                        .accessibilityIdentifier("dictionaries.failureEngineStatus")
                    DisclosureGroup("错误详情", isExpanded: $detailsExpanded) {
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
                    .accessibilityIdentifier("dictionaries.details")
                }
            } else {
                HStack(spacing: 8) {
                    if coordinator?.isBusy == true {
                        ProgressView().controlSize(.small)
                            .accessibilityLabel("词库更新进行中")
                    }
                    Text(status).font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("dictionaries.status")
                }
            }
            HStack {
                Button("检查词库更新") { coordinator?.checkForUpdates() }
                    .disabled(coordinator?.canCheck != true)
                    .accessibilityIdentifier("dictionaries.check")
                if coordinator?.canUpdate == true {
                    Button("下载并更新") { coordinator?.downloadAndUpdate() }
                        .disabled(coordinator?.canUpdate != true)
                        .accessibilityIdentifier("dictionaries.update")
                }
                if coordinator?.canRetry == true {
                    Button("重试") { coordinator?.retry() }
                        .accessibilityIdentifier("dictionaries.retry")
                }
                Spacer(minLength: 0)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onChange(of: coordinator?.failure?.technicalDetails) { _, _ in detailsExpanded = false }
    }

    private func activeDictionary(_ active: IFDictionaryActiveInfo) -> some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("当前使用的词库").font(.headline)
            Text(active.manifest.contentVersion)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("当前词库版本")
                .accessibilityValue(active.manifest.contentVersion)
                .accessibilityIdentifier("dictionaries.version")
            Text("词条数：\(active.manifest.entryCount.formatted())（词语与读音组合）")
                .accessibilityIdentifier("dictionaries.count")
            Text("启用时间：\(active.activatedAt.formatted(date: .numeric, time: .shortened))")
                .accessibilityIdentifier("dictionaries.activatedAt")
            Text(active.isBundled ? "正在使用随应用提供的词库。" : "正在使用已下载并验证的词库。")
                .font(.caption).foregroundStyle(.secondary)
                .accessibilityIdentifier("dictionaries.engineStatus")
        }
    }

    private func sources(_ manifest: IFDictionaryManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            ForEach(manifest.sources, id: \.id) { receipt in
                // The catalog owns names and destinations; downloaded metadata cannot introduce links.
                if let spec = IFDictionaryCatalog.sources.first(where: { $0.id == receipt.id }),
                   IFDictionaryHash.isHex(receipt.commit, length: 40) {
                    VStack(alignment: .leading, spacing: 3) {
                        Link(spec.name, destination: spec.sourceURL(commit: receipt.commit))
                            .accessibilityIdentifier("dictionaries.source.\(spec.id)")
                        Text(receipt.commit)
                            .font(.system(.caption, design: .monospaced))
                            .textSelection(.enabled)
                            .accessibilityIdentifier("dictionaries.commit.\(spec.id)")
                        Text(spec.sourceURL(commit: receipt.commit).absoluteString)
                            .font(.caption).foregroundStyle(.secondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .accessibilityIdentifier("dictionaries.url.\(spec.id)")
                    }
                }
            }
        }
        .padding(.top, 8)
    }

    private var status: String {
        guard let coordinator else { return "仅在手动检查后下载更新。" }
        if !coordinator.engineAvailable && !coordinator.isBusy { return "输入引擎暂不可用，请重试恢复。" }
        let message: String
        switch coordinator.activity {
        case .idle: message = "仅在手动检查后下载更新。"
        case .checking: message = "正在检查词库更新…"
        case .upToDate: message = "词库已是最新，无需更新。"
        case .updateAvailable: message = "发现词库更新，可下载并更新。"
        case .downloading: message = "正在下载词库…"
        case .preparing: message = "正在准备词库…"
        case .verifying: message = "正在验证词库…"
        case .waitingForIdle: message = "词库已准备好，等待所有输入完成后启用。"
        case .applying: message = "正在启用词库…"
        case .updated: message = "词库已更新并启用。"
        }
        if let progress = coordinator.progress, progress.total > 0 {
            return "\(message)（\(progress.completed)/\(progress.total)）"
        }
        return message
    }
}

extension IFDictionaryStage {
    var displayName: String {
        switch self {
        case .check: "检查更新"
        case .download: "下载"
        case .prepare: "准备"
        case .verify: "验证"
        case .apply: "启用"
        case .rollback: "回退"
        case .recovery: "恢复"
        }
    }
}
