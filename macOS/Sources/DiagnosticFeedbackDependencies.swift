import AppKit
import UniformTypeIdentifiers

@MainActor struct DiagnosticFeedbackDependencies {
    var export: (DiagnosticExportSelection, Date, URL) async throws -> DiagnosticExportResult
    var chooseDestination: () async -> URL?
    var now: () -> Date = Date.init

    static var live: Self {
        let service = DiagnosticFeedbackService.live
        return .init(export: { try await service.export($0, clickedAt: $1, destination: $2) },
            chooseDestination: {
                let panel = NSSavePanel()
                panel.title = "导出墨流诊断包"
                panel.nameFieldStringValue = "墨流诊断.zip"
                panel.allowedContentTypes = [.zip]
                panel.canCreateDirectories = true
                return await withCheckedContinuation { continuation in
                    panel.begin { response in continuation.resume(returning: response == .OK ? panel.url : nil) }
                }
            })
    }

    static var unavailable: Self {
        .init(export: { _, _, _ in throw DiagnosticFeedbackError.unavailable }, chooseDestination: { nil })
    }
}
