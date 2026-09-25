import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

@MainActor enum DiagnosticFeedbackModelTests {
    static func run() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var exports = 0
        var selected: DiagnosticExportSelection?
        var capturedClick: Date?
        var destination: URL?
        var partial = false, failure = false
        let dependencies = DiagnosticFeedbackDependencies(
            save: { _, _, _ in preconditionFailure("The simplified model must not save incidents") },
            incidents: { .init(incidents: [], invalidIncidentCount: 0) },
            export: { selection, clicked, url in
                exports += 1; selected = selection; capturedClick = clicked
                if failure { throw NSError(domain: "secret-provider-error", code: 9) }
                return .init(url: url, incidentID: nil, eventCount: 2, isPartial: partial)
            },
            chooseDestination: { clock.addTimeInterval(20); return destination }, now: { clock })
        let model = DiagnosticFeedbackModel(dependencies: dependencies)
        await model.export()
        check(exports == 0 && model.status?.kind == .cancelled, "Cancelling the panel must never call export")
        destination = URL(fileURLWithPath: "/tmp/diagnostic-model-only.zip")

        model.scope = .lastThirtyMinutes
        let exportClicked = clock
        await model.export()
        check(exports == 1 && capturedClick == exportClicked && model.status?.kind == .success)
        if case .lastThirtyMinutes = selected {} else { check(false) }

        model.scope = .lastDay
        partial = true
        await model.export()
        check(exports == 2 && model.status?.kind == .partial)
        if case .lastDay = selected {} else { check(false) }

        model.scope = .lastSevenDays
        partial = false
        await model.export()
        check(exports == 3 && model.status?.kind == .success)
        if case .retainedHistory = selected {} else { check(false) }

        failure = true
        await model.export()
        check(model.status?.kind == .failure && !model.status!.message.contains("secret-provider-error"))
        await duplicateActions()
        print("PASS diagnostic feedback model: three log ranges, panel cancellation, partial/success/failure and duplicate suppression")
    }

    private static func duplicateActions() async {
        var release: CheckedContinuation<URL?, Never>?
        var chooserCalls = 0
        let dependencies = DiagnosticFeedbackDependencies(save: { _, _, _ in throw DiagnosticFeedbackError.unavailable },
            incidents: { .init(incidents: [], invalidIncidentCount: 0) },
            export: { _, _, _ in preconditionFailure("Cancelled panel must not export") },
            chooseDestination: { chooserCalls += 1; return await withCheckedContinuation { release = $0 } })
        let model = DiagnosticFeedbackModel(dependencies: dependencies)
        let first = Task { await model.export() }
        while release == nil { await Task.yield() }
        await model.export()
        check(chooserCalls == 1 && model.isBusy)
        release?.resume(returning: nil)
        await first.value
        check(!model.isBusy)
    }
}
