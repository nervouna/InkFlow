import Dispatch
import Foundation
import InkFlowEngine

public struct EngineConfiguration: Sendable {
    public let sharedDataURL: URL
    public let userDataURL: URL
    public let prebuiltDataURL: URL
    public let stagingDataURL: URL
    public let distributionName: String
    public let distributionCodeName: String
    public let distributionVersion: String
    public let applicationName: String

    public init(
        sharedDataURL: URL,
        userDataURL: URL,
        prebuiltDataURL: URL,
        stagingDataURL: URL,
        distributionName: String = "InkFlow",
        distributionCodeName: String,
        distributionVersion: String = "0.1.0",
        applicationName: String
    ) {
        self.sharedDataURL = sharedDataURL
        self.userDataURL = userDataURL
        self.prebuiltDataURL = prebuiltDataURL
        self.stagingDataURL = stagingDataURL
        self.distributionName = distributionName
        self.distributionCodeName = distributionCodeName
        self.distributionVersion = distributionVersion
        self.applicationName = applicationName
    }
}

public enum EngineError: Error, Equatable, Sendable, CustomStringConvertible {
    case status(code: UInt32, message: String)
    case malformedUTF8(field: String)
    case invalidUTF8Offsets(field: String)
    case runtimeUnavailable
    case sessionClosed

    public var description: String {
        switch self {
        case let .status(code, message):
            return "Engine operation failed with status \(code): \(message)"
        case let .malformedUTF8(field):
            return "Engine returned malformed UTF-8 for \(field)"
        case let .invalidUTF8Offsets(field):
            return "Engine returned invalid UTF-8 byte offsets for \(field)"
        case .runtimeUnavailable:
            return "Engine runtime is unavailable"
        case .sessionClosed:
            return "Engine session is closed"
        }
    }
}

public final class EngineRuntime: @unchecked Sendable {
    fileprivate let queue = DispatchQueue(label: "io.inkflow.local.apple.engine")
    private let queueKey = DispatchSpecificKey<UInt8>()
    fileprivate var pointer: OpaquePointer?

    public init(configuration: EngineConfiguration) throws {
        queue.setSpecific(key: queueKey, value: 1)
        pointer = try onQueue {
            try Self.withBorrowedRuntimeConfig(configuration) { config in
                var runtime: OpaquePointer?
                try Self.check(inkflow_runtime_create(&config, &runtime))
                guard let runtime else { throw EngineError.runtimeUnavailable }
                return runtime
            }
        }
    }

    static func withBorrowedRuntimeConfig<T>(
        _ configuration: EngineConfiguration,
        _ body: (inout InkFlowRuntimeConfig) throws -> T
    ) rethrows -> T {
        let sharedDataPath = configuration.sharedDataURL.path
        let userDataPath = configuration.userDataURL.path
        let prebuiltDataPath = configuration.prebuiltDataURL.path
        let stagingDataPath = configuration.stagingDataURL.path
        return try sharedDataPath.withCString { sharedData in
            try userDataPath.withCString { userData in
                try prebuiltDataPath.withCString { prebuiltData in
                    try stagingDataPath.withCString { stagingData in
                        try configuration.distributionName.withCString { name in
                            try configuration.distributionCodeName.withCString { codeName in
                                try configuration.distributionVersion.withCString { version in
                                    try configuration.applicationName.withCString { application in
                                        var config = InkFlowRuntimeConfig(
                                            struct_size: MemoryLayout<InkFlowRuntimeConfig>.size,
                                            shared_data_dir: sharedData,
                                            user_data_dir: userData,
                                            prebuilt_data_dir: prebuiltData,
                                            staging_data_dir: stagingData,
                                            distribution_name: name,
                                            distribution_code_name: codeName,
                                            distribution_version: version,
                                            application_name: application,
                                            minimum_log_level: 3
                                        )
                                        return try body(&config)
                                    }
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    deinit {
        let runtime = pointer
        pointer = nil
        guard let runtime else { return }
        onQueueWithoutThrow {
            _ = inkflow_runtime_destroy(runtime)
        }
    }

    public func makeSession(schemaID: String) throws -> EngineSession {
        try onQueue {
            guard let pointer else { throw EngineError.runtimeUnavailable }
            var session: OpaquePointer?
            try schemaID.withCString { schema in
                try Self.check(inkflow_session_create(pointer, schema, &session))
            }
            guard let session else { throw EngineError.sessionClosed }
            return EngineSession(runtime: self, pointer: session)
        }
    }

    fileprivate func onQueue<T>(_ body: () throws -> T) rethrows -> T {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            return try body()
        }
        return try queue.sync(execute: body)
    }

    fileprivate func onQueueWithoutThrow(_ body: () -> Void) {
        if DispatchQueue.getSpecific(key: queueKey) != nil {
            body()
        } else {
            queue.sync(execute: body)
        }
    }

    fileprivate static func check(_ status: InkFlowStatus) throws {
        guard status == INKFLOW_STATUS_OK else {
            let message = String(cString: inkflow_status_message(status))
            throw EngineError.status(code: status.rawValue, message: message)
        }
    }
}

public final class EngineSession: @unchecked Sendable {
    private let runtime: EngineRuntime
    private var pointer: OpaquePointer?

    fileprivate init(runtime: EngineRuntime, pointer: OpaquePointer) {
        self.runtime = runtime
        self.pointer = pointer
    }

    deinit {
        close()
    }

    public func close() {
        let session = runtime.onQueue { () -> OpaquePointer? in
            defer { pointer = nil }
            return pointer
        }
        guard let session else { return }
        runtime.onQueueWithoutThrow {
            _ = inkflow_session_destroy(session)
        }
    }

    public func process(_ event: EngineKeyEvent) throws -> EngineUpdate {
        try operation { session, snapshot in
            let nativeEvent = InkFlowKeyEvent(key: event.key, modifiers: event.modifiers)
            return inkflow_session_process_key(session, nativeEvent, snapshot)
        }
    }

    public func commit() throws -> EngineUpdate {
        try operation(inkflow_session_commit)
    }

    public func selectCandidate(at index: Int) throws -> EngineUpdate {
        guard index >= 0 else {
            throw EngineError.status(
                code: INKFLOW_STATUS_INVALID_CANDIDATE_INDEX.rawValue,
                message: String(cString: inkflow_status_message(
                    INKFLOW_STATUS_INVALID_CANDIDATE_INDEX
                ))
            )
        }
        return try operation { session, snapshot in
            inkflow_session_select_candidate(session, index, snapshot)
        }
    }

    public func changePage(backward: Bool) throws -> EngineUpdate {
        try operation { session, snapshot in
            inkflow_session_change_page(session, backward ? 1 : 0, snapshot)
        }
    }

    public func reset() throws -> EngineUpdate {
        try operation(inkflow_session_reset)
    }

    public func currentSnapshot() throws -> EngineUpdate {
        try operation(inkflow_session_snapshot)
    }

    private func operation(
        _ call: (OpaquePointer?, UnsafeMutablePointer<OpaquePointer?>?) -> InkFlowStatus
    ) throws -> EngineUpdate {
        try runtime.onQueue {
            guard let pointer else { throw EngineError.sessionClosed }
            var snapshot: OpaquePointer?
            try EngineRuntime.check(call(pointer, &snapshot))
            guard let snapshot else {
                throw EngineError.status(
                    code: INKFLOW_STATUS_INTERNAL_ERROR.rawValue,
                    message: "missing owned snapshot"
                )
            }
            defer { inkflow_snapshot_destroy(snapshot) }
            return try Self.decode(snapshot)
        }
    }

    private static func decode(_ snapshot: OpaquePointer) throws -> EngineUpdate {
        let preedit = try decodeRequired(
            inkflow_snapshot_preedit(snapshot),
            field: "preedit"
        )
        let cursorByteOffset = Int(
            inkflow_snapshot_preedit_cursor_byte_offset(snapshot)
        )
        let selectionStart = Int(
            inkflow_snapshot_preedit_selection_start_byte_offset(snapshot)
        )
        let selectionEnd = Int(
            inkflow_snapshot_preedit_selection_end_byte_offset(snapshot)
        )
        guard let cursor = UTF8RangeConverter.utf16Offset(
            in: preedit,
            utf8ByteOffset: cursorByteOffset
        ), let selection = UTF8RangeConverter.utf16Range(
            in: preedit,
            utf8Start: selectionStart,
            utf8End: selectionEnd
        ) else {
            throw EngineError.invalidUTF8Offsets(field: "preedit")
        }

        let count = Int(inkflow_snapshot_candidate_count(snapshot))
        var candidates: [EngineCandidate] = []
        candidates.reserveCapacity(count)
        for index in 0..<count {
            let text = try decodeRequired(
                inkflow_snapshot_candidate_text(snapshot, index),
                field: "candidate[\(index)].text"
            )
            let comment = try decodeOptional(
                inkflow_snapshot_candidate_comment(snapshot, index),
                field: "candidate[\(index)].comment"
            )
            candidates.append(EngineCandidate(text: text, comment: comment))
        }

        let rawHighlight = inkflow_snapshot_highlighted_candidate_index(snapshot)
        let highlight = rawHighlight == INKFLOW_NO_CANDIDATE
            ? nil
            : Int(rawHighlight)
        if let highlight, highlight >= candidates.count {
            throw EngineError.invalidUTF8Offsets(field: "candidate highlight")
        }

        return EngineUpdate(
            handled: inkflow_snapshot_handled(snapshot) != 0,
            commitText: try decodeOptional(
                inkflow_snapshot_commit_text(snapshot),
                field: "commit"
            ),
            preedit: preedit,
            cursorUTF16Offset: cursor,
            selectionUTF16Range: selection,
            candidates: candidates,
            highlightedCandidateIndex: highlight,
            hasPreviousPage: inkflow_snapshot_has_previous_page(snapshot) != 0,
            hasNextPage: inkflow_snapshot_has_next_page(snapshot) != 0
        )
    }

    private static func decodeRequired(
        _ pointer: UnsafePointer<CChar>?,
        field: String
    ) throws -> String {
        guard let pointer else { throw EngineError.malformedUTF8(field: field) }
        guard let value = String(validatingCString: pointer) else {
            throw EngineError.malformedUTF8(field: field)
        }
        return value
    }

    private static func decodeOptional(
        _ pointer: UnsafePointer<CChar>?,
        field: String
    ) throws -> String? {
        guard let pointer else { return nil }
        guard let value = String(validatingCString: pointer) else {
            throw EngineError.malformedUTF8(field: field)
        }
        return value
    }
}
