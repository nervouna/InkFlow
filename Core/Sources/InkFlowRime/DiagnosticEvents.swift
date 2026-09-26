import Foundation

/// Only finite, source-defined diagnostic enums conform. Never conform a wrapper around user text.
package protocol DiagnosticLabel: RawRepresentable, Sendable where RawValue == String {}

package struct DiagnosticContext: Codable, Sendable {
    package var startupRun: UUID?
    package var session: UUID?
    package var attempt: UUID?
    package var controller: UUID?
    package var activation: UUID?
    package var key: UUID?
    package var composition: UUID?
    package var inputStage: InputDiagnosticStage?
    package var sequence: Int?
    package var source: IFStartupDiagnostics.Source?
    package var enabled: Bool?
    package var baseURLPresent: Bool?
    package var keyPresent: Bool?
    package var modelPresent: Bool?
    package var precedingAvailable: Bool?
    package var followingAvailable: Bool?
    package var engineAvailable: Bool?
    package var clientPresent: Bool?
    package var commitInsertion: Bool?
    package var markedTextUpdate: Bool?
    package var markedTextClear: Bool?
    package init(startupRun: UUID? = nil,
        session: UUID? = nil,
        attempt: UUID? = nil,
        controller: UUID? = nil,
        activation: UUID? = nil,
        key: UUID? = nil,
        composition: UUID? = nil,
        inputStage: InputDiagnosticStage? = nil,
        sequence: Int? = nil,
        source: IFStartupDiagnostics.Source? = nil,
        enabled: Bool? = nil,
        baseURLPresent: Bool? = nil,
        keyPresent: Bool? = nil,
        modelPresent: Bool? = nil,
        precedingAvailable: Bool? = nil,
        followingAvailable: Bool? = nil,
        engineAvailable: Bool? = nil,
        clientPresent: Bool? = nil,
        commitInsertion: Bool? = nil,
        markedTextUpdate: Bool? = nil,
        markedTextClear: Bool? = nil) {
        self.startupRun = startupRun
        self.session = session
        self.attempt = attempt
        self.controller = controller
        self.activation = activation
        self.key = key
        self.composition = composition
        self.inputStage = inputStage
        self.sequence = sequence
        self.source = source
        self.enabled = enabled
        self.baseURLPresent = baseURLPresent
        self.keyPresent = keyPresent
        self.modelPresent = modelPresent
        self.precedingAvailable = precedingAvailable
        self.followingAvailable = followingAvailable
        self.engineAvailable = engineAvailable
        self.clientPresent = clientPresent
        self.commitInsertion = commitInsertion
        self.markedTextUpdate = markedTextUpdate
        self.markedTextClear = markedTextClear
    }

}

/// Automatic records accept compile-time labels, UUIDs and numbers only. Never pass error descriptions,
/// URLs, application identifiers, document text or configuration values into this channel.
package struct LocalDiagnosticEvent: Sendable {
    package enum Module: String, Codable, Sendable { case startup, input, ai, voice, dictionary, update, termination, statistics, diagnostics }
    package enum Outcome: String, Codable, Sendable { case begin, ready, completed, failed, skipped, cancelled, timeout, unavailable, handled, passThrough }
    package enum ErrorDomain: String, Codable, Sendable { case cocoa, posix, url, speech, audio, sqlite, unknown }
    package let module: Module
    package let event: String
    package let outcome: Outcome
    package let reason: String?
    package let correlation: UUID?
    package let elapsedMilliseconds: Double?
    package let errorDomain: ErrorDomain?
    package let errorCode: Int?
    package let httpStatus: Int?
    package var context: DiagnosticContext?

    package init(module: Module, event: StaticString, outcome: Outcome, reason: StaticString? = nil,
         correlation: UUID? = nil, elapsedMilliseconds: Double? = nil,
         errorDomain: ErrorDomain? = nil, errorCode: Int? = nil, httpStatus: Int? = nil) {
        self.module = module; self.event = event.description; self.outcome = outcome
        self.reason = reason?.description; self.correlation = correlation
        self.elapsedMilliseconds = elapsedMilliseconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.errorDomain = errorDomain; self.errorCode = errorCode
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }
    }

    package init<E: DiagnosticLabel, R: DiagnosticLabel>(module: Module, event: E, outcome: Outcome,
         reason: R, correlation: UUID? = nil, elapsedMilliseconds: Double? = nil,
         errorDomain: ErrorDomain? = nil, errorCode: Int? = nil, httpStatus: Int? = nil,
         context: DiagnosticContext? = nil) {
        self.module = module; self.event = event.rawValue; self.outcome = outcome; self.reason = reason.rawValue
        self.correlation = correlation
        self.elapsedMilliseconds = elapsedMilliseconds.flatMap { $0.isFinite && $0 >= 0 ? $0 : nil }
        self.errorDomain = errorDomain; self.errorCode = errorCode
        self.httpStatus = httpStatus.flatMap { (100...599).contains($0) ? $0 : nil }; self.context = context
    }

    package static func safeError(_ error: any Error) -> (ErrorDomain, Int) {
        let value = error as NSError
        let domain: ErrorDomain = switch value.domain {
        case NSCocoaErrorDomain: .cocoa
        case NSPOSIXErrorDomain: .posix
        case NSURLErrorDomain: .url
        case "kAFAssistantErrorDomain", "SFSpeechErrorDomain": .speech
        case "com.apple.coreaudio.avfaudio", NSOSStatusErrorDomain: .audio
        default: .unknown
        }
        return (domain, value.code)
    }
}

/// Platform storage is explicitly injected; importing the engine never creates persistent diagnostics.
package final class LocalDiagnostics: @unchecked Sendable {
    package static let shared = LocalDiagnostics()
    private let lock = NSLock()
    private var sink: (@Sendable (LocalDiagnosticEvent) -> Void)?
    @TaskLocal static var observe: (@Sendable (LocalDiagnosticEvent) -> Void)?
    package func configure(_ sink: @escaping @Sendable (LocalDiagnosticEvent) -> Void) {
        lock.withLock { self.sink = sink }
    }
    package func submit(_ event: LocalDiagnosticEvent) {
        Self.observe?(event)
        let receive = lock.withLock { sink }
        receive?(event)
    }
}
