import Foundation
#if SWIFT_PACKAGE
@testable import InkFlowCore
import InkFlowTestSupport
#endif

@MainActor enum DiagnosticFeedbackModelTests {
    static func run() async {
        var clock = Date(timeIntervalSince1970: 1_800_000_000)
        var exports = 0, saves = 0
        var selected: DiagnosticExportSelection?
        var capturedClick: Date?
        var capturedOccurrence: Date?
        var destination: URL?
        var partial = false, failure = false
        let id = UUID()
        let dependencies = DiagnosticFeedbackDependencies(
            save: { occurred, clicked, _ in
                saves += 1; capturedOccurrence = occurred; capturedClick = clicked
                if failure { throw NSError(domain: "secret-provider-error", code: 9) }
                return .init(id: id, occurredAt: occurred, savedAt: clicked, eventCount: 2, isPartial: partial)
            },
            incidents: { .init(incidents: [], invalidIncidentCount: 1) },
            export: { selection, clicked, url in
                exports += 1; selected = selection; capturedClick = clicked
                if failure { throw NSError(domain: "secret-provider-error", code: 9) }
                return .init(url: url, incidentID: nil, eventCount: 2, isPartial: partial)
            },
            chooseDestination: { clock.addTimeInterval(20); return destination }, now: { clock })
        let model = DiagnosticFeedbackModel(dependencies: dependencies)
        clock.addTimeInterval(600)
        let clicked = clock
        await model.save()
        check(saves == 1 && capturedOccurrence == clicked && capturedClick == clicked,
              "Default incident time is the save click, not view construction")
        check(model.status?.kind == .success && model.selectedIncident == id && model.scope == .incident)
        await model.export()
        check(exports == 0 && model.status?.kind == .cancelled, "Cancelling the panel must never call export")
        destination = URL(fileURLWithPath: "/tmp/diagnostic-model-only.zip")
        model.scope = .incident; model.selectedIncident = id
        let exportClicked = clock
        partial = true
        await model.export()
        check(exports == 1 && capturedClick == exportClicked && model.status?.kind == .partial)
        if case .incident(let actual) = selected { check(actual == id) } else { check(false) }
        model.earlier = true; model.occurredAt = clock.addingTimeInterval(-60)
        await model.save()
        check(capturedOccurrence == model.occurredAt && model.status?.kind == .partial)
        let beforeInvalid = saves
        model.note = String(repeating: "x", count: 2_001)
        await model.save()
        check(saves == beforeInvalid && model.status?.kind == .failure)
        model.note = ""; failure = true
        await model.save()
        check(model.status?.kind == .failure && !model.status!.message.contains("secret-provider-error"))
        await model.export()
        check(model.status?.kind == .failure && !model.status!.message.contains("secret-provider-error"))
        failure = false
        await model.reload()
        check(model.listNotice?.contains("1") == true && model.incidents.isEmpty)
        await duplicateActions()
        print("PASS diagnostic feedback model: click times, panel cancellation, partial/success/failure, notes, selected incident and duplicate suppression")
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
        await model.export(); await model.save()
        check(chooserCalls == 1 && model.isBusy)
        release?.resume(returning: nil)
        await first.value
        check(!model.isBusy)
    }
}
