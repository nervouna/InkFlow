import Foundation
import Observation

@MainActor @Observable final class DiagnosticFeedbackModel {
    enum Scope: String, CaseIterable, Identifiable {
        case lastThirtyMinutes = "最近 30 分钟", lastDay = "最近 24 小时", retainedHistory = "仍保留的全部历史", incident = "已保存的现场"
        var id: Self { self }
    }
    struct Status {
        enum Kind { case success, partial, failure, cancelled }
        let kind: Kind
        let message: String
    }

    var earlier = false
    var occurredAt: Date
    var note = ""
    var scope = Scope.lastThirtyMinutes
    var selectedIncident: UUID?
    private(set) var incidents: [DiagnosticIncidentSummary] = []
    private(set) var listNotice: String?
    private(set) var isBusy = false
    private(set) var progress = ""
    private(set) var status: Status?
    @ObservationIgnored private let dependencies: DiagnosticFeedbackDependencies

    init(dependencies: DiagnosticFeedbackDependencies) {
        self.dependencies = dependencies
        occurredAt = dependencies.now()
    }
    var canExport: Bool { !isBusy && (scope != .incident || selectedIncident != nil) }

    func reload() async {
        guard !isBusy else { return }
        isBusy = true; progress = "正在读取已保存现场…"
        defer { isBusy = false }
        do {
            let result = try await dependencies.incidents()
            incidents = result.incidents.sorted { $0.savedAt > $1.savedAt }
            listNotice = result.invalidIncidentCount == 0 ? nil : "有 \(result.invalidIncidentCount) 个现场无法读取，未列出。"
            if result.storageStatus?.availability == .unavailable {
                listNotice = [listNotice, "已有现场仍可读取，但诊断存储维护失败，后续记录可能缺失。"].compactMap { $0 }.joined(separator: " ")
            }
            if !incidents.contains(where: { $0.id == selectedIncident }) { selectedIncident = incidents.first?.id }
        } catch {
            incidents = []; selectedIncident = nil
            listNotice = "无法读取现场列表；可尝试直接导出最近的诊断记录。"
        }
    }

    func save() async {
        guard !isBusy else { return }
        let clickedAt = dependencies.now()
        let occurrence = earlier ? occurredAt : clickedAt
        let text = note.trimmingCharacters(in: .whitespacesAndNewlines)
        isBusy = true; progress = "正在保存问题现场…"; status = nil
        defer { isBusy = false }
        do {
            try DiagnosticIncident.validate(note: text)
            let saved = try await dependencies.save(occurrence, clickedAt, text.isEmpty ? nil : text)
            incidents.removeAll { $0.id == saved.id }
            incidents.insert(saved, at: 0); selectedIncident = saved.id
            scope = .incident
            status = .init(kind: saved.isPartial ? .partial : .success,
                message: saved.isPartial ? "已保存部分现场（\(saved.eventCount) 条记录），存在缺失或清理记录。"
                    : "已保存现场（\(saved.eventCount) 条记录）。历史完整性仍需结合诊断包判断。")
        } catch { show(error) }
    }

    func export() async {
        guard !isBusy else { return }
        let clickedAt = dependencies.now()
        let selection: DiagnosticExportSelection
        switch scope {
        case .lastThirtyMinutes: selection = .lastThirtyMinutes
        case .lastDay: selection = .lastDay
        case .retainedHistory: selection = .retainedHistory
        case .incident:
            guard let selectedIncident else { show(DiagnosticFeedbackError.missingIncident); return }
            selection = .incident(selectedIncident)
        }
        isBusy = true; progress = "请选择诊断包保存位置…"; status = nil
        defer { isBusy = false }
        guard let destination = await dependencies.chooseDestination() else {
            status = .init(kind: .cancelled, message: "已取消导出，未生成诊断包。")
            return
        }
        progress = "正在导出诊断包…"
        do {
            let result = try await dependencies.export(selection, clickedAt, destination)
            status = .init(kind: result.isPartial ? .partial : .success,
                message: result.isPartial ? "已导出部分诊断资料（\(result.eventCount) 条记录），请查看包内的缺失说明。未自动上传。"
                    : "已导出诊断包（\(result.eventCount) 条记录），可自行传回开发电脑。未自动上传。")
        } catch { show(error) }
    }

    private func show(_ error: any Error) {
        if error is CancellationError { status = .init(kind: .cancelled, message: "操作已取消。") }
        else {
            let message = (error as? DiagnosticFeedbackError)?.errorDescription ?? "诊断操作未完成，请稍后重试。"
            status = .init(kind: .failure, message: message)
        }
    }
}
