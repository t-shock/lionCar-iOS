import Foundation

/// After a command (lock, pre-heating…) the app shows the new state straight away and "holds" it, because the car's
/// own report lags behind. The hold ends once the car reports something newer than the command — or after 5 minutes
/// in any case, also when a report has no time at all (then the shown state never got stuck).
public enum CommandHold {
    public static let maxAge: TimeInterval = 5 * 60

    public static func isOver(since: Date, reportedAt: Date?, now: Date = Date()) -> Bool {
        if now.timeIntervalSince(since) > maxAge { return true }
        guard let reportedAt else { return false }
        return reportedAt > since
    }
}
