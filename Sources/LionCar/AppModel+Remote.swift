import Foundation
import LocalAuthentication
import LionCore

/// Remote control: the one-time setup (SMS and PIN) and sending commands to the car.
extension AppModel {
    // MARK: Setup

    var remoteReady: Bool { isDemo || remote.isSetUp }
    /// False when the brand has no remote-services link for this account: then don't offer setup at all.
    var remotePossible: Bool { isDemo || api.customerID != nil || remote.isSetUp }

    func requestSMS() async {
        guard !isDemo else { return }
        setupBusy = true
        defer { setupBusy = false }
        do {
            try await remote.requestSMS()
            smsSent = true
        } catch is AuthExpiredError { expired() } catch {
            message = String(localized: "Couldn't send the SMS — \(HTTP.describe(error))")
        }
    }

    func activateRemote(sms: String, pin: String) async -> Bool {
        guard !isDemo else { return false }
        setupBusy = true
        defer { setupBusy = false }
        do {
            try await remote.activate(sms: sms, pin: pin)
            smsSent = false
            showToast(String(localized: "Remote control is ready"))
            return true
        } catch is AuthExpiredError {
            expired(); return false
        } catch {
            message = String(localized: "Activation failed — \(HTTP.describe(error))")
            return false
        }
    }

    func forgetRemote() {
        guard !isDemo else { return }
        let r = remote
        Task { await r.forget() }
    }

    func loadCommandLog() async { commandLog = await remote.log }

    /// Opens the remote-control connection early, so a command goes out faster.
    func warmUpRemote() {
        guard !isDemo, remote.isSetUp else { return }
        let r = remote
        Task { await r.warmUp() }
    }

    // MARK: Sending commands

    /// Face ID / Touch ID, or the phone's passcode, before acting on the real car.
    func confirm(_ reason: String) async -> Bool {
        let ctx = LAContext()
        var err: NSError?
        // A phone without a passcode can't ask: let the command through rather than block it for good.
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return true }
        return (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
    }

    /// Sends one command at a time and shows its progress. `optimistic` changes the shown status straight away, as the
    /// car's own report lags behind; `quiet` leaves out the "done" toast (and, for the real car, the refresh after it).
    /// In demo mode nothing is sent: `demoCommand` is applied to the sample car. Returns nil when nothing was sent.
    @discardableResult
    func runCommand(_ label: String, confirmWith reason: String?, optimistic: ((inout VehicleStatus) -> Void)? = nil,
                    quiet: Bool = false, demoCommand: String? = nil, demoPrograms: [Program]? = nil,
                    _ block: @escaping (RemoteControl, Tracker) async -> CommandResult) async -> CommandResult? {
        if let demo {
            guard commandLabel == nil else { return nil }
            commandLabel = label
            commandProgress = "Sending…"
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            if let demoCommand { demo.apply(demoCommand, programs: demoPrograms) }
            commandLabel = nil; commandProgress = nil
            await refresh()
            if !quiet { showToast(String(localized: "\(L(label)) — done (demo)")) }
            return .success
        }
        guard remote.isSetUp else { message = String(localized: "Set up remote control first (Settings › Remote control)"); return nil }
        guard commandLabel == nil else { return nil }
        if let reason, !(await confirm(reason)) { return nil }
        commandLabel = label
        commandProgress = "Sending…"
        let tracker = Tracker(
            onProgress: { p in Task { @MainActor in self.commandProgress = p } },
            // Arrives later only when we stopped waiting at "delivered".
            onFinal: { r in Task { @MainActor in
                if case .failed(let why) = r {
                    self.dropHeldState()
                    self.message = String(localized: "\(L(label)) didn't go through: \(why)")
                }
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                await self.refresh()
            } })
        let result = await block(remote, tracker)
        commandLabel = nil
        commandProgress = nil
        switch result {
        case .success, .delivered:
            optimistic.map { f in if var st = status { f(&st); status = st } }
            if !quiet {
                showToast(result == .delivered ? String(localized: "\(L(label)) — the car got it") : String(localized: "\(L(label)) — done"))
                // Give the car time to act and report, then show its real state.
                Task {
                    try? await Task.sleep(nanoseconds: 15_000_000_000)
                    await self.refresh()
                }
            }
        case .failed(let why):
            dropHeldState()
            message = String(localized: "\(L(label)): \(why)")
        }
        return result
    }

    /// A command failed: stop showing the value it sent and go back to what the car reports.
    private func dropHeldState() {
        holdLock = nil
        holdPrecond = nil
        reparse()
    }

    func lockCar(_ lock: Bool) async {
        await runCommand(lock ? "Lock" : "Unlock", confirmWith: lock ? nil : "Unlock your car",
                         optimistic: { [weak self] st in st.locked = lock; self?.holdLock = (lock, Date()) },
                         demoCommand: lock ? "lock" : "unlock") { r, t in await r.lock(lock, t) }
    }

    func horn() async { await runCommand("Horn", confirmWith: "Sound the horn") { r, t in await r.horn(t) } }
    func lights() async { await runCommand("Flash lights", confirmWith: nil) { r, t in await r.lights(t) } }

    /// Wakes the car so it reports now, then checks every 10 s (up to 2 minutes) until a newer report arrives.
    func wakeAndRefresh() async {
        if isDemo { await refresh(); showToast(String(localized: "Updated — the car just reported")); return }
        guard !updatingFromCar else { return }
        updatingFromCar = true
        defer { updatingFromCar = false }
        let before = status?.updatedAt
        guard let r = await runCommand("Updating from the car", confirmWith: nil, quiet: true, { r, t in await r.wakeUp(t) })
        else { return }
        if case .failed = r { return }
        commandLabel = "Updating from the car"
        commandProgress = "Waiting for the car to report…"
        defer { commandLabel = nil; commandProgress = nil }
        for _ in 0..<12 {
            try? await Task.sleep(nanoseconds: 10_000_000_000)
            await refresh()
            if let now = status?.updatedAt, before.map({ now > $0 }) ?? true {
                showToast(String(localized: "Updated — the car just reported"))
                await loadTrips(recentOnly: true)
                return
            }
        }
        message = String(localized: "The car didn't send a new report yet. It may be out of mobile coverage (for example in a garage); try again later.")
    }
}
