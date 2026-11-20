import InkFlowPortable
import Foundation

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
    package func call(_ op: String, _ fields: [String] = [], capacity: Int = 512) -> IFRimeChannel.Reply? {
        guard available, !op.utf8.contains(0), !fields.contains(where: { $0.utf8.contains(0) }) else { return nil }
        var reply: OpaquePointer?
        let status = withCStrings(fields) { ifr_session_call(session, op, $0, fields.count, capacity, &reply) }
        guard status == ifrOK, let reply else { return nil }
        return portableReply(reply)
    }
}
