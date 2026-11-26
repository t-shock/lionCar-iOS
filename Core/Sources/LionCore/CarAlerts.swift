import Foundation

/// When to warn about the car: left unlocked, fuel or battery low, service due, fog lights left on.
/// Each warning is sent once and re-armed when the situation clears (state kept by the app between checks).
public enum CarAlerts {
    public enum Kind: String, Codable, CaseIterable, Sendable { case unlocked, lowEnergy, service, lightsOn }

    public struct Settings: Sendable {
        public var unlocked = true, lowEnergy = true, service = true, lightsOn = true
        public var lowPct = 15.0
        public init() {}
    }

    public struct Alert: Equatable, Sendable {
        public let kind: Kind
        public let title: String
        public let body: String
    }

    /// Which warnings are currently "sent and not yet cleared".
    public struct State: Codable, Equatable, Sendable {
        public var active: Set<Kind> = []
        public init() {}
    }

    /// Unlocked only counts when the car is parked and has stayed so for a while after its last report.
    public static let unlockedGrace: TimeInterval = 10 * 60

    public static func check(_ st: VehicleStatus, carName: String, settings: Settings, state: inout State, now: Date = Date()) -> [Alert] {
        var out: [Alert] = []
        func evaluate(_ kind: Kind, on: Bool, enabled: Bool, clear: Bool, _ alert: () -> Alert) {
            if enabled && on && !state.active.contains(kind) { out.append(alert()); state.active.insert(kind) }
            else if clear { state.active.remove(kind) }
        }
        let parked = !st.isDriving
        let reportAge = st.updatedAt.map { now.timeIntervalSince($0) } ?? 0

        evaluate(.unlocked, on: st.locked == false && parked && reportAge >= unlockedGrace, enabled: settings.unlocked,
                 clear: st.locked == true || st.isDriving) {
            Alert(kind: .unlocked, title: "\(carName) is unlocked", body: "It has been parked unlocked since \(timeText(st.updatedAt)).")
        }

        // A hybrid warns about its tank. On a petrol / diesel car batteryPct already is the tank.
        let level = st.energyType == "Hybrid" ? st.fuelPct : st.batteryPct
        let isFuel = st.energyType != "Electric"
        evaluate(.lowEnergy, on: (level ?? 100) <= settings.lowPct && !st.isCharging, enabled: settings.lowEnergy,
                 clear: (level ?? 0) >= settings.lowPct + 10) {
            let range = st.rangeKm.map { " — about \(Int($0)) km left" } ?? ""
            return Alert(kind: .lowEnergy, title: isFuel ? "Fuel is low" : "Battery is low",
                         body: "\(carName): \(Int(level ?? 0)) %\(range).")
        }

        let dueKm = st.kmToService.map { $0 <= 1000 } ?? false
        let dueDays = st.daysToService.map { $0 <= 30 } ?? false
        evaluate(.service, on: dueKm || dueDays, enabled: settings.service,
                 clear: (st.kmToService ?? 0) > 1500 && (st.daysToService ?? 0) > 45) {
            let parts = [st.kmToService.map { "\(Int($0)) km" }, st.daysToService.map { "\(Int($0)) days" }].compactMap { $0 }
            return Alert(kind: .service, title: "Service due soon", body: "\(carName): next service in \(parts.joined(separator: " or ")).")
        }

        evaluate(.lightsOn, on: !st.fogLightsOn.isEmpty && parked, enabled: settings.lightsOn, clear: st.fogLightsOn.isEmpty) {
            Alert(kind: .lightsOn, title: "Fog lights left on", body: "\(carName) is parked with its fog lights on.")
        }
        return out
    }

    private static func timeText(_ d: Date?) -> String {
        guard let d else { return "a while" }
        let f = DateFormatter(); f.timeStyle = .short; f.dateStyle = Calendar.current.isDateInToday(d) ? .none : .short
        return f.string(from: d)
    }
}
