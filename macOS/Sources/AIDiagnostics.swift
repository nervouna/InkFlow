import Foundation
import OSLog

/// Only allowlisted labels and scalar metadata cross this privacy boundary. Never pass
/// document text, configuration values, provider bodies or arbitrary error descriptions.
enum AIDiagnosticEvent: String, Sendable {
    case settingsLoaded, settingsSaved, settingsToggled, credentialFailed
    case eligibility, anchorRejected, contextRejected, contextCaptured
    case scheduled, dispatched, invalidated, cancelled, discarded, failed, shown, accepted
    case transportStarted, httpResponse, transportSucceeded, transportFailed, transportCancelled
    case presentationFailed, deactivateEntered, deactivateCommitted, deactivateSuperReturned, deactivateFinished
}

enum AIDiagnosticReason: String, Sendable {
    case none, ready, disabled, incompleteConfiguration, credentialRead, credentialWrite
    case accepting, secureInput, missingPanel, panelHidden, emptyCandidates, missingEngine, inputUnavailable
    case missingClient, unownedMark, invalidMark, emptyMark, invalidSelection, selectionOutsideMark
    case anchorChanged, documentShorterThanMark, contextUnavailable, staleState
    case inputChanged, configurationChanged, stateChanged, presentation, accepted, acceptanceUnavailable
    case commit, deactivate, hidePalettes, workspaceChanged, engineChanged, settingsChanged, teardown, explicit
    case invalidConfiguration, network, httpStatus, invalidResponse, emptySuggestion, incompleteSuggestion
    case invalidCandidateFrame, noCandidateWindow, ambiguousCandidateWindow, suggestionHidden
}

struct AIDiagnosticRecord: Sendable {
    let event: AIDiagnosticEvent
    let reason: AIDiagnosticReason
    let attempt: UUID?
    var session: UUID?
    var status: Int?
    var elapsedMS: Int?
    var networkCode: Int?
    var enabled: Bool?
    var baseURLPresent: Bool?
    var keyPresent: Bool?
    var modelPresent: Bool?
    var precedingAvailable: Bool?
    var followingAvailable: Bool?
    var reportedDocumentLength: Int?
    var markedEnd: Int?

    var message: String {
        var fields = ["event=\(event.rawValue)", "reason=\(reason.rawValue)"]
        if let attempt { fields.append("attempt=\(attempt.uuidString)") }
        if let session { fields.append("session=\(session.uuidString)") }
        if let status { fields.append("status=\(status)") }
        if let elapsedMS { fields.append("elapsed_ms=\(elapsedMS)") }
        if let networkCode { fields.append("network_code=\(networkCode)") }
        if let enabled { fields.append("enabled=\(enabled)") }
        if let baseURLPresent { fields.append("base_url_present=\(baseURLPresent)") }
        if let keyPresent { fields.append("key_present=\(keyPresent)") }
        if let modelPresent { fields.append("model_present=\(modelPresent)") }
        if let precedingAvailable { fields.append("preceding_available=\(precedingAvailable)") }
        if let followingAvailable { fields.append("following_available=\(followingAvailable)") }
        if let reportedDocumentLength { fields.append("reported_document_length=\(reportedDocumentLength)") }
        if let markedEnd { fields.append("marked_end=\(markedEnd)") }
        return fields.joined(separator: " ")
    }
}

enum AIDiagnostics {
    private static let logger = Logger(subsystem: "io.damao.inputmethod.inkflow", category: "ai")
    @TaskLocal static var attempt: UUID?
    @TaskLocal static var session: UUID?
    // Focused tests observe the exact records also emitted to the system log.
    @TaskLocal static var observe: (@Sendable (AIDiagnosticRecord) -> Void)?

    static func emit(_ event: AIDiagnosticEvent, reason: AIDiagnosticReason = .none,
                     attempt: UUID? = AIDiagnostics.attempt, status: Int? = nil,
                     elapsedMS: Int? = nil, networkCode: Int? = nil,
                     session: UUID? = AIDiagnostics.session) {
        write(AIDiagnosticRecord(event: event, reason: reason, attempt: attempt,
                                 session: session, status: status, elapsedMS: elapsedMS, networkCode: networkCode))
    }

    static func write(_ record: AIDiagnosticRecord) {
        let message = record.message
        switch record.event {
        case .credentialFailed, .failed, .transportFailed, .presentationFailed:
            logger.error("\(message, privacy: .public)")
        default:
            // Notice remains queryable after a user's attempt; debug/info do not reliably persist.
            logger.notice("\(message, privacy: .public)")
        }
        observe?(record)
    }

}
