import SwiftUI
import LionCore

/// Shown under the electric-car cards: these features follow LionFlow but haven't been tried on a real electric car.
struct UntestedNote: View {
    var body: some View {
        Label("New and not yet tested on a real electric car — please report what works.", systemImage: "flask")
            .font(.caption2).foregroundStyle(.secondary)
    }
}

// MARK: Car tab cards

struct ChargingCard: View {
    @Environment(AppModel.self) private var model
    let st: VehicleStatus

    var body: some View {
        Card(spacing: 12) {
            HStack {
                Label(statusText, systemImage: st.isCharging ? "bolt.fill" : (st.plugged ? "powerplug.fill" : "powerplug"))
                    .font(.headline).foregroundStyle(st.isCharging ? Theme.accent : .primary)
                Spacer()
                if let r = model.chargeReading {
                    Text(r.kw < 10 ? "\(r.kw.formatted(.number.precision(.fractionLength(1)))) kW" : "\(Int(r.kw.rounded())) kW")
                        .font(.title3.bold()) + Text(r.measured ? "" : L(" (est.)")).font(.caption).foregroundColor(.secondary)
                }
            }
            if st.isCharging, let left = model.chargeTimeLeft {
                let at = (st.updatedAt ?? Date()).addingTimeInterval(Double(left.minutes) * 60)
                Text(left.pct.map { pct in String(localized: "About \(pct) % at \(at.formatted(date: .omitted, time: .shortened))") }
                     ?? String(localized: "Full at about \(at.formatted(date: .omitted, time: .shortened))"))
                    .font(.subheadline)
                Text(String(localized: "\(Fmt.duration(Double(left.minutes) * 60)) left")).font(.caption).foregroundStyle(.secondary)
            }
            if let h = st.nextDelayedHour {
                ScheduledStartRow(st: st, hour: h, minute: st.nextDelayedMinute ?? 0)
            }
            if model.remoteReady {
                HStack(spacing: 10) {
                    if st.isCharging {
                        action("Stop charging", "stop.fill") { await model.charging(startNow: false) }
                    } else {
                        action("Charge now", "bolt.fill") { await model.charging(startNow: true) }
                    }
                }
                Picker("Car's limit", selection: Binding(get: { st.chargeType == "Full" }, set: { full in
                    Task { await model.setCarChargeLimit(daily: !full) }
                })) {
                    Text("Daily limit").tag(false)
                    Text("Full (trip)").tag(true)
                }
                .pickerStyle(.segmented)
                .disabled(model.commandLabel != nil)
            }
            HStack {
                NavigationLink { ChargeSettingsView() } label: {
                    Label(model.chargeSettings.limitOn ? String(localized: "Limit \(model.chargeSettings.limitPct) %") : L("Charging settings"),
                          systemImage: "slider.horizontal.below.square.filled.and.square")
                }
                Spacer()
                NavigationLink { ChargeLogView() } label: { Label("Charging log", systemImage: "list.bullet.rectangle") }
            }
            .font(.subheadline)
            UntestedNote()
        }
    }

    private var statusText: String {
        if st.isCharging { return L("Charging") }
        switch st.chargingStatus {
        case "Finished": return L("Charging finished")
        case "Failure": return L("Charging failed")
        default: return st.plugged ? L("Plugged in, waiting") : L("Not plugged in")
        }
    }

    private func action(_ title: LocalizedStringKey, _ icon: String, _ run: @escaping () async -> Void) -> some View {
        Button { Task { await run() } } label: { Label(title, systemImage: icon).frame(maxWidth: .infinity).padding(.vertical, 6) }
            .buttonStyle(.borderedProminent)
            .disabled(model.commandLabel != nil)
    }
}

/// The car waits for this time before it charges. "Stop charging" works by setting it, so it can stay on afterwards;
/// Turn off lets the car charge as soon as it is plugged in (ported from LionFlow).
struct ScheduledStartRow: View {
    @Environment(AppModel.self) private var model
    let st: VehicleStatus
    let hour: Int
    let minute: Int
    @State private var confirming = false

    var body: some View {
        HStack {
            Label("Scheduled start", systemImage: "clock.badge")
            Spacer()
            Text(clockTime(hour, minute)).bold()
            // Not while LionCar's charging times use the scheduled start.
            if model.remoteReady && !model.chargeSettings.windowOn {
                Button("Turn off") { confirming = true }
                    .buttonStyle(.bordered).controlSize(.small)
                    .disabled(model.commandLabel != nil)
            }
        }
        .font(.subheadline)
        .confirmationDialog(st.plugged ? "Turn off scheduled start? Charging starts now." : "Turn off scheduled start?",
                            isPresented: $confirming, titleVisibility: .visible) {
            Button("Turn off") { Task { await model.clearScheduledStart() } }
        }
    }
}

struct ClimateCard: View {
    @Environment(AppModel.self) private var model
    let st: VehicleStatus

    var body: some View {
        Card(spacing: 12) {
            Label(st.preconditioningOn ? "Pre-heating is on" : "Pre-heating is off", systemImage: st.preconditioningOn ? "fan.fill" : "fan")
                .font(.headline).foregroundStyle(st.preconditioningOn ? Theme.accent : .primary)
            Text("Heats or cools the cabin for a limited time (about 10–30 minutes, depending on the car). Uses grid power when plugged in.")
                .font(.caption).foregroundStyle(.secondary)
            if model.remoteReady {
                Button {
                    Task { await model.preconditioning(!st.preconditioningOn) }
                } label: {
                    Label(st.preconditioningOn ? "Stop pre-heating" : "Pre-heat now", systemImage: st.preconditioningOn ? "stop.fill" : "flame")
                        .frame(maxWidth: .infinity).padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .disabled(model.commandLabel != nil)
            }
            NavigationLink { SchedulesView() } label: {
                HStack {
                    Label("Schedules", systemImage: "calendar.badge.clock")
                    Spacer()
                    Text(summary).foregroundStyle(.secondary).lineLimit(1)
                }
            }
            .font(.subheadline)
            UntestedNote()
        }
    }

    private var summary: String {
        let on = st.programs.filter(\.enabled)
        guard let p = on.first else { return L("None on") }
        return "\(clockTime(p.hour, p.minute)) · \(Days.short(p.days))" + (on.count > 1 ? " +\(on.count - 1)" : "")
    }
}

enum Days {
    static let all = ["Mon", "Tue", "Wed", "Thu", "Fri", "Sat", "Sun"]
    /// Weekday names in the phone's language, Monday first.
    static func name(_ d: String) -> String {
        let syms = Calendar.current.shortWeekdaySymbols   // Sunday first
        guard let i = all.firstIndex(of: d) else { return d }
        return syms[(i + 1) % 7]
    }
    static func short(_ days: [String]) -> String {
        if Set(days) == Set(all.prefix(5)) { return L("Mon–Fri") }
        if Set(days) == Set(all) { return L("Every day") }
        return all.filter(days.contains).map(name).joined(separator: " ")
    }
}

// MARK: Schedules

struct SchedulesView: View {
    @Environment(AppModel.self) private var model
    @State private var slots: [Program] = []
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                Text("The car has 4 schedule slots. Set when the car should be ready; it starts heating or cooling shortly before.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            ForEach($slots, id: \.slot) { $p in
                Section(String(localized: "Slot \(p.slot)")) {
                    Toggle("On", isOn: $p.enabled)
                    DatePicker("Ready at", selection: Binding(get: { time(p) }, set: { d in
                        let c = Calendar.current.dateComponents([.hour, .minute], from: d)
                        p.hour = c.hour ?? 7; p.minute = c.minute ?? 0
                    }), displayedComponents: .hourAndMinute)
                    HStack(spacing: 6) {
                        ForEach(Days.all, id: \.self) { d in
                            let on = p.days.contains(d)
                            Button(Days.name(d)) {
                                if on { p.days.removeAll { $0 == d } } else { p.days.append(d) }
                            }
                            .font(.caption.bold())
                            .buttonStyle(.bordered)
                            .tint(on ? Theme.accent : .gray)
                        }
                    }
                }
            }
            Section {
                Button {
                    Task { await model.savePrograms(slots.filter { $0.enabled || !$0.days.isEmpty }) }
                } label: {
                    HStack { Spacer(); Text("Send to the car").bold(); Spacer() }
                }
                .disabled(model.commandLabel != nil || !model.remoteReady)
            } footer: {
                VStack(alignment: .leading, spacing: 6) {
                    if !model.remoteReady { Text("Set up remote control first (Settings › Remote control)") }
                    UntestedNote()
                }
            }
        }
        .navigationTitle("Pre-heating schedules")
        .onAppear {
            guard !loaded else { return }
            loaded = true
            let have = model.status?.programs ?? []
            slots = (1...4).map { i in have.first { $0.slot == i } ?? Program(slot: i, days: [], hour: 7, minute: 0, enabled: false) }
        }
    }

    private func time(_ p: Program) -> Date {
        Calendar.current.date(bySettingHour: p.hour, minute: p.minute, second: 0, of: Date()) ?? Date()
    }
}

// MARK: Charging settings

struct ChargeSettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var batteryText = ""

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Toggle("Notify when the target is reached", isOn: $model.targetNotify)
            } footer: {
                Text("While charging, LionCar sets a notification for the time the car should reach your limit (or full). iOS delivers it on time even when LionCar isn't running — the most reliable way on iPhone to stop at a %: unplug when it rings.")
            }
            Section {
                Toggle("Stop at a limit", isOn: $model.chargeSettings.limitOn)
                if model.chargeSettings.limitOn {
                    Stepper("Stop at \(model.chargeSettings.limitPct) %", value: $model.chargeSettings.limitPct, in: 50...100, step: 5)
                }
            } header: {
                Text("LionCar's charge limit")
            } footer: {
                Text("LionCar asks the car to stop charging when it reaches this level. It only works while LionCar runs — when you open it, or when iOS lets it check in the background (often only every hour or two). So the car can charge past the limit. The car's own daily limit (set in the car or the brand app) is more reliable.")
            }
            Section {
                Toggle("Only charge between set times", isOn: $model.chargeSettings.windowOn)
                if model.chargeSettings.windowOn {
                    DatePicker("From", selection: minutes($model.chargeSettings.windowFrom), displayedComponents: .hourAndMinute)
                    DatePicker("To", selection: minutes($model.chargeSettings.windowTo), displayedComponents: .hourAndMinute)
                }
                if model.remoteReady && model.chargeSettings.windowOn {
                    Button("Send the start time to the car") { Task { await model.applyChargeWindow() } }
                        .disabled(model.commandLabel != nil)
                }
            } header: {
                Text("Charging times")
            } footer: {
                Text("For example when power is cheapest. The car's delayed start is set to the start time, so it begins by itself; LionCar stops charging after the end time and starts it if the car waits inside the window — but only while LionCar runs.")
            }
            Section {
                HStack {
                    Text("Usable battery")
                    Spacer()
                    TextField(model.usableKwh.map { "≈ \(Int($0.rounded()))" } ?? "—", text: $batteryText)
                        .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                        .onChange(of: batteryText) { _, v in model.batteryKwhSetting = FuelSettingsSection.number(v) }
                    Text("kWh").foregroundStyle(.secondary)
                }
            } footer: {
                Text("Used for the kW figures and the charging log. Leave empty to use what the car reports.")
            }
            Section { UntestedNote() }
        }
        .navigationTitle("Charging settings")
        .onAppear { batteryText = model.batteryKwhSetting.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "" }
    }

    private func minutes(_ b: Binding<Int>) -> Binding<Date> {
        Binding(get: { Calendar.current.date(bySettingHour: b.wrappedValue / 60, minute: b.wrappedValue % 60, second: 0, of: Date()) ?? Date() },
                set: { d in let c = Calendar.current.dateComponents([.hour, .minute], from: d); b.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0) })
    }
}

// MARK: Charging log

struct ChargeLogView: View {
    @Environment(AppModel.self) private var model

    private var month: [ChargeSession] {
        let from = Date().addingTimeInterval(-30 * 86_400).timeIntervalSince1970
        return model.chargeSessions.filter { $0.start >= from }
    }

    var body: some View {
        List {
            Section {
                Text("LionCar builds this log from the car's reports. It only notices a charge while it runs (app open, or a background check iOS allowed), so a charge that starts and ends meanwhile is missed. Everything stays on this iPhone.")
                    .font(.footnote).foregroundStyle(.secondary)
                UntestedNote()
            }
            if let a = model.activeSession {
                Section("Charging now") { SessionRow(s: a, live: true) }
            }
            if !month.isEmpty { Section("Last 30 days") { summary } }
            if let h = model.healthEstimate {
                Section {
                    LabeledContent("Battery health (estimate)", value: "\(Int(h.pct.rounded())) %")
                } footer: {
                    Text("From \(h.sessions) charging sessions: energy that went in per 100 %, compared with the battery's size. Not an official figure.")
                }
            }
            Section("Sessions") {
                if model.chargeSessions.isEmpty { Text("No charging sessions yet.").foregroundStyle(.secondary) }
                ForEach(model.chargeSessions) { s in SessionRow(s: s, live: false) }
                    .onDelete { idx in for i in idx { model.deleteSession(model.chargeSessions[i]) } }
            }
        }
        .navigationTitle("Charging log")
        .toolbar { NavigationLink { PlacesView() } label: { Label("Places and prices", systemImage: "mappin.and.ellipse") } }
    }

    private var summary: some View {
        let home = month.filter { model.placeMatch($0).kind == "home" }
        let kwh = month.reduce(0) { $0 + $1.kwh }
        let homeKwh = home.reduce(0) { $0 + $1.kwh }
        let cost = month.compactMap { model.sessionCost($0) }.reduce(0, +)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 18) {
                stat("\(Int(kwh.rounded())) kWh", String(localized: "\(month.count) sessions"))
                stat("\(Int(homeKwh.rounded())) kWh", L("at home"))
                stat("\(Int((kwh - homeKwh).rounded())) kWh", L("away"))
            }
            if cost > 0 { Text(String(localized: "Estimated cost \(Fmt.money(cost, model.currencySymbol))")).font(.subheadline) }
        }
    }

    private func stat(_ value: String, _ caption: String) -> some View { StatFigure(value: value, caption: caption) }
}

struct SessionRow: View {
    @Environment(AppModel.self) private var model
    let s: ChargeSession
    let live: Bool

    var body: some View {
        let m = model.placeMatch(s)
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(Date(timeIntervalSince1970: s.start).formatted(date: .abbreviated, time: .shortened)).font(.headline)
                Spacer()
                Text("\(s.kwh.formatted(.number.precision(.fractionLength(1)))) kWh").font(.headline)
            }
            HStack(spacing: 10) {
                Label(L(m.label), systemImage: m.kind == "home" ? "house" : (s.isFast ? "bolt.fill" : "powerplug"))
                Text("\(Int(s.startPct)) → \(Int(s.endPct)) %")
                Text(Fmt.duration(s.end - s.start))
            }
            .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                Text(s.isFast ? "DC" : "AC")
                if let a = s.avgKw { Text(String(localized: "avg \(a.formatted(.number.precision(.fractionLength(1)))) kW")) }
                if let p = s.peakKw { Text(String(localized: "peak \(p.formatted(.number.precision(.fractionLength(1)))) kW")) }
                if let c = model.sessionCost(s) { Text(c == 0 ? L("free") : Fmt.money(c, model.currencySymbol)) }
                if live { Text("so far") }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }
}

struct PlacesView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                if let h = model.chargePlaces.home {
                    price("Price per kWh", h.price) { v in model.updatePlaces { $0.home?.price = v } }
                    Button("Remove home", role: .destructive) { model.updatePlaces { $0.home = nil } }
                }
                if let lat = model.status?.lat, let lon = model.status?.lon {
                    Button(model.chargePlaces.home == nil ? "Set home to where the car is now" : "Move home to where the car is now") {
                        model.updatePlaces { p in
                            let price = p.home?.price ?? 0
                            p.home = ChargePlace(id: "home", name: "Home", lat: lat, lon: lon, price: price)
                        }
                    }
                }
            } header: {
                Text("Home")
            } footer: {
                Text("Sessions within 50 m count as home.")
            }
            Section {
                ForEach(model.chargePlaces.known) { k in
                    VStack(alignment: .leading) {
                        TextField("Name", text: Binding(get: { k.name }, set: { v in updateKnown(k.id) { $0.name = v } }))
                        price("Price per kWh", k.price) { v in updateKnown(k.id) { $0.price = v } }
                    }
                }
                .onDelete { idx in model.updatePlaces { p in p.known.remove(atOffsets: idx) } }
                if model.chargePlaces.known.count < 5, let lat = model.status?.lat, let lon = model.status?.lon {
                    Button("Add a charger where the car is now") {
                        model.updatePlaces { p in
                            p.known.append(ChargePlace(id: UUID().uuidString, name: String(localized: "Charger \(p.known.count + 1)"), lat: lat, lon: lon))
                        }
                    }
                }
            } header: {
                Text("Known chargers (up to 5)")
            } footer: {
                Text("Work, a cabin, a free charger… Sessions within 75 m use its price.")
            }
            Section {
                price("Other AC chargers", model.chargePlaces.publicAcPrice) { v in model.updatePlaces { $0.publicAcPrice = v } }
                price("Other fast chargers", model.chargePlaces.publicDcPrice) { v in model.updatePlaces { $0.publicDcPrice = v } }
            } header: {
                Text("Other chargers")
            } footer: {
                Text("Estimated prices per kWh for chargers you don't know. 0 = don't estimate.")
            }
        }
        .navigationTitle("Places and prices")
    }

    private func price(_ title: LocalizedStringKey, _ value: Double, _ set: @escaping (Double) -> Void) -> some View {
        PriceField(title: title, value: value, symbol: model.currencySymbol, set: set)
    }

    /// Changes the known charger with this id, if it still exists.
    private func updateKnown(_ id: String, _ change: (inout ChargePlace) -> Void) {
        model.updatePlaces { p in
            if let i = p.known.firstIndex(where: { $0.id == id }) { change(&p.known[i]) }
        }
    }
}

private struct PriceField: View {
    let title: LocalizedStringKey
    let value: Double
    let symbol: String
    let set: (Double) -> Void
    @State private var text = ""

    var body: some View {
        HStack {
            Text(title)
            Spacer()
            TextField("0", text: $text).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 80)
                .onChange(of: text) { _, v in set(FuelSettingsSection.number(v) ?? 0) }
            Text("\(symbol)/kWh").foregroundStyle(.secondary)
        }
        .onAppear { text = value > 0 ? value.formatted(.number.precision(.fractionLength(0...3))) : "" }
    }
}

// MARK: Demo

/// Which sample car to show: electric, plug-in hybrid or petrol / diesel, of any brand (ported from LionFlow).
struct DemoSetupView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var kind: DemoCar.Kind = .electric
    @State private var brand: Brand = .peugeot

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Sample car and made-up data. Nothing is sent to a real car.").font(.footnote).foregroundStyle(.secondary)
                }
                Section("Kind of car") {
                    ForEach(DemoCar.Kind.allCases) { k in
                        Button { kind = k } label: {
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(title(k)).foregroundStyle(.primary)
                                    Text(note(k)).font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                if kind == k { Image(systemName: "checkmark").foregroundStyle(Theme.accent) }
                            }
                        }
                    }
                }
                Section("Brand") {
                    Picker("Brand", selection: $brand) {
                        ForEach(Brand.allCases) { Text(verbatim: $0.display).tag($0) }
                    }
                }
                Section {
                    Button {
                        model.enterDemo(kind: kind, brand: brand)
                        dismiss()
                    } label: { HStack { Spacer(); Text("Start the demo").bold(); Spacer() } }
                }
            }
            .navigationTitle("Try a sample car")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
        }
        .onAppear { brand = model.brand }
    }

    private func title(_ k: DemoCar.Kind) -> LocalizedStringKey {
        switch k { case .electric: "Electric"; case .hybrid: "Plug-in hybrid"; case .fuel: "Petrol / diesel" }
    }

    private func note(_ k: DemoCar.Kind) -> LocalizedStringKey {
        switch k {
        case .electric: "Battery, charging and pre-heating"
        case .hybrid: "Battery for short trips, fuel for long ones"
        case .fuel: "Fuel level, fuel cost and statistics"
        }
    }
}

struct DemoBanner: View {
    @Environment(AppModel.self) private var model
    var body: some View {
        HStack {
            Label("Demo mode — a sample car. Nothing is sent to a real car.", systemImage: "play.rectangle")
                .font(.footnote.bold())
            Spacer()
            Button("Exit") { model.exitDemo() }.font(.footnote.bold())
        }
        .padding(12)
        .background(Color.purple.opacity(0.15), in: RoundedRectangle(cornerRadius: 12))
    }
}
