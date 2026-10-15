import InkFlowPortable
import Foundation

/// The only Swift–Lua bridge, owned by the core (`InputSession::call`): one request property that the
/// Lua modules observe synchronously, answered in one result property, with the framing and its
/// version checks done there. The reply is the module's status word (ok, failed, unknown or
/// conflict) and body.
package enum IFRimeChannel {
    package struct Reply: Equatable {
        package let status: String
        package let body: String
        package init(status: String, body: String = "") {
            self.status = status
            self.body = body
        }
    }
}

@MainActor
extension IFEngine {
    /// One synchronous round trip through the Lua modules of this session. The reply is nil when the
    /// session is unavailable, no module answers the operation, the reply does not fit `capacity`
    /// bytes or a field would break the framing. Never from a key callback.
    package func call(_ op: String, _ fields: [String] = [], capacity: Int = 512) -> IFRimeChannel.Reply? {
        guard available, !op.utf8.contains(0), !fields.contains(where: { $0.utf8.contains(0) }) else { return nil }
        var reply: OpaquePointer?
        let status = withCStrings(fields) { ifr_session_call(session, op, $0, fields.count, capacity, &reply) }
        guard status == ifrOK, let reply else { return nil }
        return portableReply(reply)
    }
}
