import Foundation
#if SWIFT_PACKAGE
import CRime
#endif

/// The only Swift–Lua bridge: one request property that the Lua modules observe
/// synchronously, answered in one result property. Protocol version 1:
///
///     request = "1\t<op>\t<field>\t<field>..."   fields carry no tab, CR or LF
///     result  = "1\t<op>\t<status>\n<body>"       status: ok, failed, unknown or conflict
package enum IFRimeChannel {
    package static let version = 1
    package static let requestProperty = "inkflow_request"
    package static let resultProperty = "inkflow_result"

    package struct Reply: Equatable {
        package let status: String
        package let body: String
        package init(status: String, body: String = "") {
            self.status = status
            self.body = body
        }
    }

    /// nil when a field would break the line-oriented framing.
    package static func request(_ op: String, _ fields: [String]) -> String? {
        guard !op.isEmpty, op.utf8.allSatisfy({ (97...122).contains($0) || $0 == 95 }),
              fields.allSatisfy({ !$0.utf8.contains { $0 == 9 || $0 == 10 || $0 == 13 } }) else { return nil }
        return ([String(version), op] + fields).joined(separator: "\t")
    }

    /// nil for another protocol version, another operation or a malformed header.
    package static func reply(_ result: String, op: String) -> Reply? {
        let bytes = Array(result.utf8)
        let end = bytes.firstIndex(of: 10) ?? bytes.count
        let header = String(decoding: bytes[..<end], as: UTF8.self).split(separator: "\t", omittingEmptySubsequences: false)
        guard header.count == 3, header[0] == String(version), header[1] == op,
              !header[2].isEmpty, header[2].utf8.allSatisfy({ (97...122).contains($0) }) else { return nil }
        let body = end < bytes.count ? String(decoding: bytes[(end + 1)...], as: UTF8.self) : ""
        return Reply(status: String(header[2]), body: body)
    }
}

@MainActor
extension IFEngine {
    /// One synchronous round trip through the Lua modules of this session.
    /// Properties are transport only: no request or result stays in the live context.
    package func call(_ op: String, _ fields: [String] = [], capacity: Int = 512) -> IFRimeChannel.Reply? {
        guard available, let request = IFRimeChannel.request(op, fields) else { return nil }
        let api = Self.api.pointee
        api.set_property(session, IFRimeChannel.resultProperty, "")
        request.withCString { api.set_property(session, IFRimeChannel.requestProperty, $0) }
        api.set_property(session, IFRimeChannel.requestProperty, "")
        var buffer = [CChar](repeating: 0, count: capacity + 1)
        let read = api.get_property(session, IFRimeChannel.resultProperty, &buffer, buffer.count - 1)
        api.set_property(session, IFRimeChannel.resultProperty, "")
        // A result that fills the buffer may be truncated; fail closed.
        guard read != 0, let end = buffer.firstIndex(of: 0), end < buffer.count - 1 else { return nil }
        return IFRimeChannel.reply(String(decoding: buffer[..<end].map { UInt8(bitPattern: $0) }, as: UTF8.self), op: op)
    }
}
