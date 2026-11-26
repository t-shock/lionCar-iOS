import Foundation

/// LionCar's own charge limit and charging window (port of LionFlow's ChargeLimit.kt and ChargeWindow.kt), as pure
/// decisions: given the car's state, they say what to send; the app sends it.
///
/// Untested on a real electric car. On iPhone these only act when LionCar runs (open, or a background check iOS
/// allowed), so the car can charge past the limit or outside the window. LionFlow's "charge past the car's limit",
/// its restore-when-unplugged and re-check steps are not ported: they need checks every few minutes.
public enum ChargeAutomation {
    public struct Settings: Equatable, Sendable {
        public var limitOn = false
        public var limitPct = 80
        public var windowOn = false
        /// Minutes after midnight.
        public var windowFrom = 22 * 60
        public var windowTo = 6 * 60
        public init() {}
    }

    public enum Action: Equatable, Sendable {
        /// Stop charging: the brand's "delayed" charge, which waits for the given start time.
        case stop(hour: Int, minute: Int)
        /// Start charging now ("immediate"); the time is the car's delayed-start time to keep.
        case start(hour: Int, minute: Int)
    }

    public struct Decision: Equatable, Sendable {
        public var action: Action?
        /// Something to tell the user, if any.
        public var note: String?
        public init(action: Action? = nil, note: String? = nil) { self.action = action; self.note = note }
    }

    static let maxTries = 3
    static let retry: TimeInterval = 5 * 60

    // MARK: Limit

    public struct LimitState: Codable, Equatable, Sendable {
        /// Start of the charging session this state belongs to (0 = unknown session, -1 = none yet).
        public var session: Double = -1
        public var tries = 0
        public var lastTry: Double = 0
        public var gaveUp = false
        public init() {}
    }

    /// Stop charging once the battery reaches the limit. The car reports every few minutes, so it stops a little
    /// early when charging fast (adds what it will gain in 5 minutes, at most 3 %). Tries 3 times, 5 minutes apart,
    /// then says the car ignored it.
    public static func limit(_ st: VehicleStatus, _ s: Settings, state: inout LimitState, sessionStart: Double?, kw: Double?,
                             usableKwh: Double, now: Date = Date(), calendar: Calendar = .current) -> Decision {
        let sess = sessionStart ?? 0
        let t = now.timeIntervalSince1970
        // A new charging session starts from scratch (unknown session: keep, but let tries expire after 12 h).
        if state.session != sess || (sess == 0 && t - state.lastTry > 12 * 3600) { state = LimitState(); state.session = sess }
        guard s.limitOn, st.isCharging, let pct = st.batteryPct else { return Decision() }
        let gain = min(3, max(0, (kw ?? 0) * (5.0 / 60) / usableKwh * 100))
        guard pct + gain >= Double(s.limitPct), !state.gaveUp else { return Decision() }
        guard state.tries >= maxTries || t - state.lastTry > retry else { return Decision() }
        if state.tries >= maxTries {
            state.gaveUp = true
            return Decision(action: nil, note: "The car kept charging (now \(Int(pct)) %) — it ignored the stop. Unplug it or stop it in the car.")
        }
        let (h, m) = delayTime(st, now: now, calendar: calendar)
        state.tries += 1
        state.lastTry = t
        return Decision(action: .stop(hour: h, minute: m),
                        note: state.tries == 1 ? "Asking the car to stop charging at \(Int(pct)) % (your limit is \(s.limitPct) %)" : nil)
    }

    /// Start time for the "delayed" charge: the car's own scheduled time, unless it's missing or within the next hour
    /// (charging would just start again) — then 12 hours from now.
    static func delayTime(_ st: VehicleStatus, now: Date, calendar: Calendar) -> (Int, Int) {
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let nowMin = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        if let h = st.nextDelayedHour, let m = st.nextDelayedMinute, (0...23).contains(h) {
            let until = ((h * 60 + m) - nowMin + 1440) % 1440
            if until >= 60 { return (h, m) }
        }
        let t = (nowMin + 12 * 60) % 1440
        return (t / 60, t % 60)
    }

    // MARK: Window

    public struct WindowState: Codable, Equatable, Sendable {
        public var what = ""
        public var lastTry: Double = 0
        public var tries = 0
        public init() {}
    }

    /// True when [min] (minutes after midnight) is inside the window; a window over midnight is fine.
    public static func inside(_ min: Int, from: Int, to: Int) -> Bool {
        if from == to { return true }
        return from < to ? (from..<to).contains(min) : (min >= from || min < to)
    }

    /// "Only charge between": stop a charge outside the window, start one when the car is plugged in and waiting
    /// inside it. (The car's own delayed start is set to the window's start when the window is switched on.)
    public static func window(_ st: VehicleStatus, _ s: Settings, state: inout WindowState, now: Date = Date(),
                              calendar: Calendar = .current) -> Decision {
        guard s.windowOn else { return Decision() }
        let c = calendar.dateComponents([.hour, .minute], from: now)
        let minNow = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let inWindow = inside(minNow, from: s.windowFrom, to: s.windowTo)
        let pct = st.batteryPct ?? 0
        let overLimit = s.limitOn && pct >= Double(s.limitPct) - 1
        let what: String
        if st.isCharging && !inWindow { what = "stop" }
        else if inWindow && st.plugged && !st.isCharging && st.chargingStatus != "Finished" && !overLimit && pct < 99 { what = "start" }
        else { state = WindowState(); return Decision() }
        let t = now.timeIntervalSince1970
        let tries = state.what == what ? state.tries : 0
        let last = state.what == what ? state.lastTry : 0
        guard tries < maxTries, t - last >= retry else { return Decision() }
        state = WindowState(what: what, lastTry: t, tries: tries + 1)
        let h = s.windowFrom / 60, m = s.windowFrom % 60
        let note: String? = tries > 0 ? nil : (what == "stop"
            ? "Charging stopped: outside your charging times. It starts again at \(String(format: "%02d:%02d", h, m))."
            : "Charging started: the car is plugged in during your charging times.")
        return Decision(action: what == "stop" ? .stop(hour: h, minute: m) : .start(hour: h, minute: m), note: note)
    }
}

extension ChargeAutomation.WindowState {
    init(what: String, lastTry: Double, tries: Int) { self.what = what; self.lastTry = lastTry; self.tries = tries }
}
