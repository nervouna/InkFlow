import Foundation
import Observation

@MainActor @Observable final class DiagnosticFeedbackModel {
    enum Scope: String, CaseIterable, Identifiable {
        case lastThirtyMinutes = "最近半小时"
        case lastDay = "最近24小时"
        case lastSevenDays = "最近七天"
        var id: Self { self }
    }
    struct Status {
        enum Kind { case success, partial, failure, cancelled }
        let kind: Kind
        let message: String
    }

    var scope = Scope.lastThirtyMinutes
    private(set) var isBusy = false
    private(set) var progress = ""
    private(set) var status: Status?
    @ObservationIgnored private let dependencies: DiagnosticFeedbackDependencies

    init(dependencies: DiagnosticFeedbackDependencies) {
        self.dependencies = dependencies
    }
    var canExport: Bool { !isBusy }

    func export() async {
        let selection: DiagnosticExportSelection
        switch scope {
        case .lastThirtyMinutes: selection = .lastThirtyMinutes
        case .lastDay: selection = .lastDay
        case .lastSevenDays: selection = .retainedHistory
        }
        await export(selection)
    }

    private func export(_ selection: DiagnosticExportSelection) async {
        guard !isBusy else { return }
        let clickedAt = dependencies.now()
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
