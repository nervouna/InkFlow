import Foundation

struct IFUpdateCheckSchedule: Sendable {
    static let interval: TimeInterval = 24 * 60 * 60

    static func delay(lastCheck: Date?, now: Date) -> TimeInterval {
        guard let lastCheck, lastCheck <= now else { return 0 }
        return max(0, interval - now.timeIntervalSince(lastCheck))
    }
}
