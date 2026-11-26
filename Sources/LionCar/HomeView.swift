import SwiftUI
import MapKit
import LionCore

struct HomeView: View {
    @Environment(AppModel.self) private var model
    @State private var customizing = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    if model.isDemo { DemoBanner() }
                    header
                    if let label = model.commandLabel { progressStrip(label) }
                    if let st = model.status { notices(st); QuietCarNote(st: st) }
                    if !model.alerts.isEmpty { alertsCard }
                    if let st = model.status {
                        // The user's order; some cards only apply to certain cars.
                        ForEach(model.visibleCards) { c in
                            switch c {
                            case .energy: energyCard(st)
                            case .charging: if st.energyType != "Fuel" && Caps.battery(st) { ChargingCard(st: st) }
                            case .climate: if st.energyType != "Fuel" && Caps.climate(st) { ClimateCard(st: st) }
                            case .doors: locksCard(st)
                            case .map: if Caps.position(st), let lat = st.lat, let lon = st.lon { mapCard(lat: lat, lon: lon) }
                            case .details: detailsGrid(st)
                            }
                        }
                    } else if model.statusMissing {
                        Card { Text("\(model.brand.display) has no live status for this car. Trips and service still work.").foregroundStyle(.secondary) }
                    } else {
                        ProgressView().padding(40)
                    }
                    if model.status != nil { allDataLink }
                }
                .padding(.horizontal, 16).padding(.bottom, 24)
            }
            .background(Color(.systemGroupedBackground))
            .refreshable { await model.refresh() }
            .navigationTitle(model.vehicle.map { "\($0.brand.isEmpty ? model.brand.display : $0.brand)" } ?? "LionCar")
            .sheet(isPresented: $customizing) { CustomizeHomeView() }
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { customizing = true } label: { Image(systemName: "slider.horizontal.3") }
                        .accessibilityLabel("Customize")
                }
                ToolbarItem(placement: .topBarTrailing) { refreshMenu }
            }
        }
    }

    // MARK: Pieces

    private var allDataLink: some View {
        NavigationLink { CarDataView() } label: {
            Label("All car data", systemImage: "list.bullet.rectangle").frame(maxWidth: .infinity).padding(12)
        }
        .cardBackground()
    }

    /// Tap refreshes; long-press opens the menu, which can also wake the car when remote control is set up.
    private var refreshMenu: some View {
        Menu {
            Button { Task { await model.refresh() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
            if model.remoteReady {
                Button { Task { await model.wakeAndRefresh() } } label: {
                    Label("Update now (wake the car)", systemImage: "antenna.radiowaves.left.and.right")
                }
            }
        } label: {
            if model.refreshing { ProgressView() } else { Image(systemName: "arrow.clockwise") }
        } primaryAction: {
            Task { await model.refresh() }
        }
        .disabled(model.refreshing)
    }

    private var header: some View {
        VStack(spacing: 6) {
            if let s = model.vehicle?.pictureURL, let url = URL(string: s) {
                AsyncImage(url: url) { img in img.resizable().scaledToFit() } placeholder: { Color.clear }
                    .frame(maxHeight: 150)
            }
            Text(L(model.kind)).font(.subheadline).foregroundStyle(.secondary)
            if let st = model.status {
                HStack(spacing: 10) {
                    Label("Car reported \(Fmt.ago(st.updatedAt))", systemImage: st.moving ? "car.rear.road.lane" : "clock")
                        .font(.footnote).foregroundStyle(.secondary)
                    if model.remoteReady, stale(st) {
                        Button("Update now") { Task { await model.wakeAndRefresh() } }
                            .font(.footnote.bold()).glassButton().controlSize(.small)
                            .disabled(model.commandLabel != nil)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity).padding(.top, 4)
    }

    /// Driving now, privacy mode, fog lights left on.
    @ViewBuilder
    private func notices(_ st: VehicleStatus) -> some View {
        if st.isDriving {
            notice(st.speedKmh.map { $0 > 0 ? "Driving now · \(Int($0)) km/h" : "Engine on" } ?? "Driving now",
                   icon: "car.rear.road.lane", color: Theme.accent)
        }
        if st.privacyOn {
            notice("Privacy mode is on in the car (\(st.privacyState ?? "")). It blocks remote commands and may hide the position.",
                   icon: "eye.slash", color: .orange)
        }
        if !st.fogLightsOn.isEmpty && !st.isDriving {
            notice("Fog lights are on", icon: "light.beacon.max", color: .orange)
        }
    }

    private func notice(_ text: LocalizedStringKey, icon: String, color: Color) -> some View {
        Label(text, systemImage: icon).font(.subheadline.bold()).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading).padding(12)
            .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: Corners.banner, style: .continuous))
    }

    /// The car's report is older than 15 minutes: worth offering to wake it.
    private func stale(_ st: VehicleStatus) -> Bool { st.updatedAt.map { Date().timeIntervalSince($0) > 15 * 60 } ?? true }

    private func progressStrip(_ label: String) -> some View {
        HStack(spacing: 10) {
            ProgressView()
            VStack(alignment: .leading) {
                Text(L(label)).font(.headline)
                Text(L(model.commandProgress ?? "")).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
        .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: Corners.banner, style: .continuous))
    }

    private var alertsCard: some View {
        Card {
            Label(model.alerts.count == 1 ? String(localized: "1 warning from the car") : String(localized: "\(model.alerts.count) warnings from the car"),
                  systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.headline)
            ForEach(Array(model.alerts.enumerated()), id: \.offset) { _, a in
                Text(a.str("label") ?? a.str("type") ?? a.str("code") ?? "Alert").font(.subheadline)
            }
        }
    }

    private func energyCard(_ st: VehicleStatus) -> some View {
        Card {
            HStack(alignment: .center, spacing: 18) {
                Gauge(value: (st.batteryPct ?? 0) / 100) {
                    EmptyView()
                } currentValueLabel: {
                    Text(Fmt.pct(st.batteryPct)).font(.title3.bold())
                }
                .gaugeStyle(.accessoryCircularCapacity)
                .tint(levelColor(st.batteryPct))
                .scaleEffect(1.5).frame(width: 90, height: 90)

                VStack(alignment: .leading, spacing: 4) {
                    Text(st.energyType == "Fuel" ? "Fuel" : "Battery").font(.subheadline).foregroundStyle(.secondary)
                    Text(Fmt.km(st.rangeKm)).font(.system(size: 34, weight: .bold, design: .rounded))
                    Text(st.rangeEstimated ? "range (estimated)" : "range").font(.footnote).foregroundStyle(.secondary)
                }
                Spacer()
            }
            if st.energyType == "Hybrid" {
                Divider()
                row("Fuel", "\(Fmt.pct(st.fuelPct)) · \(Fmt.km(st.fuelRangeKm))", icon: "fuelpump.fill")
            }
            if st.energyType != "Fuel" {
                Divider()
                row("Charging", chargingText(st), icon: st.isCharging ? "bolt.fill" : "powerplug")
            }
            if st.energyType != "Electric", let avg = model.lifetimeLPer100 {
                Divider()
                row("Average since new", "\(avg.formatted(.number.precision(.fractionLength(1)))) l/100 km", icon: "fuelpump")
            }
        }
    }

    private func chargingText(_ st: VehicleStatus) -> String {
        if st.isCharging {
            var s = L("Charging")
            if let r = st.chargingRateKmh, r > 0 { s += " · \(Int(r)) km/h" }
            if let m = st.remainingMinutes { s += " · " + String(localized: "\(Fmt.duration(Double(m) * 60)) left") }
            return s
        }
        switch st.chargingStatus {
        case "Finished": return L("Finished")
        case "Stopped": return st.plugged ? L("Plugged in, waiting") : L("Stopped")
        case "Failure": return L("Charging failed")
        default: return st.plugged ? L("Plugged in") : L("Not plugged in")
        }
    }

    private func locksCard(_ st: VehicleStatus) -> some View {
        Card {
            if Caps.lockState(st) {
                HStack {
                    Image(systemName: st.locked == false ? "lock.open.fill" : "lock.fill")
                        .font(.title2).foregroundStyle(st.locked == false ? .orange : Theme.accent)
                    VStack(alignment: .leading) {
                        Text(st.locked == false ? "Unlocked" : "Locked").font(.headline)
                        Text(st.openDoors.isEmpty ? L("All doors closed") : L("Open:") + " " + st.openDoors.map(doorName).joined(separator: ", "))
                            .font(.footnote).foregroundStyle(st.openDoors.isEmpty ? Color.secondary : Color.orange)
                    }
                    Spacer()
                    if st.alarmActive == true { Label("Alarm on", systemImage: "shield.lefthalf.filled").font(.caption).foregroundStyle(.secondary) }
                }
            }
            RemoteCard()
        }
    }

    private func doorName(_ id: String) -> String {
        ["Driver": L("driver's door"), "Passenger": L("passenger door"), "RearLeft": L("rear left"), "RearRight": L("rear right"),
         "Trunk": L("boot"), "RearWindow": L("rear window"), "Roof": L("roof")][id] ?? id
    }

    private func mapCard(lat: Double, lon: Double) -> some View {
        let c = CLLocationCoordinate2D(latitude: lat, longitude: lon)
        return VStack(spacing: 0) {
            Map(initialPosition: .region(MKCoordinateRegion(center: c, latitudinalMeters: 600, longitudinalMeters: 600))) {
                Marker(model.vehicle?.brand ?? L("Car"), systemImage: "car.fill", coordinate: c).tint(Theme.accent)
            }
            .frame(height: 190)
            .allowsHitTesting(false)
            Button {
                let item = MKMapItem(placemark: MKPlacemark(coordinate: c))
                item.name = L("My car")
                item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeWalking])
            } label: {
                Label("Directions to the car", systemImage: "figure.walk").frame(maxWidth: .infinity).padding(12)
            }
            .background(Color(.secondarySystemGroupedBackground))
        }
        .clipShape(RoundedRectangle(cornerRadius: Corners.card, style: .continuous))
    }

    private func detailsGrid(_ st: VehicleStatus) -> some View {
        let cols = [GridItem(.flexible()), GridItem(.flexible())]
        return LazyVGrid(columns: cols, spacing: 12) {
            tile("Odometer", Fmt.km(st.odometerKm), icon: "speedometer")
            tile("Outside", Fmt.temp(st.outsideTempC), icon: "thermometer.medium")
            if st.kmToService != nil || st.daysToService != nil {
                tile("Next service", [st.kmToService.map { Fmt.km($0) }, st.daysToService.map { String(localized: "\(Int($0)) days") }]
                    .compactMap { $0 }.joined(separator: " · "), icon: "wrench.and.screwdriver")
            }
            if st.isMildHybrid || st.smallBatteryWh != nil, let wh = st.smallBatteryWh {
                tile("48 V battery", "\(Int(wh)) Wh" + (st.smallBatteryHealthPct.map { " · health \(Int($0)) %" } ?? ""), icon: "minus.plus.batteryblock")
            }
            if let c = st.coolantTempC, st.energyType != "Electric" {
                tile("Engine", c >= 60 ? String(localized: "Warm · \(Int(c)) °C") : String(localized: "Cold · \(Int(c)) °C"),
                     icon: "engine.combustion")
            }
            if let mode = st.driveMode {
                tile("Drive mode", [mode, st.gearboxMode.map { String(localized: "gearbox \($0)") }].compactMap { $0 }.joined(separator: " · "),
                     icon: "steeringwheel")
            }
            if let h = st.heading, !st.isDriving, Caps.position(st) {
                tile("Parked facing", Geo.compass(h) + " · \(Int(h))°", icon: "location.north.line")
            }
            if st.energyType != "Electric", let l = model.lifetimeLiters {
                tile("Fuel since new", "≈ \(Int(l.rounded())) l", icon: "drop")
            }
            if st.energyType != "Fuel", let h = st.batteryHealthPct {
                tile("Battery health", Fmt.pct(h), icon: "heart.text.square")
            }
            if let cap = st.capacityKwh {
                tile("Battery", (st.residualKwh.map { "\($0.formatted(.number.precision(.fractionLength(1)))) / " } ?? "") +
                     "\(cap.formatted(.number.precision(.fractionLength(0)))) kWh", icon: "battery.75percent")
            }
        }
    }

    // MARK: Building blocks

    private func levelColor(_ pct: Double?) -> Color {
        guard let p = pct else { return .gray }
        return p < 15 ? .red : (p < 30 ? .orange : Theme.accent)
    }

    private func row(_ title: LocalizedStringKey, _ value: String, icon: String) -> some View {
        HStack {
            Label(title, systemImage: icon).foregroundStyle(.secondary)
            Spacer()
            Text(value).bold()
        }
        .font(.subheadline)
    }

    private func tile(_ title: LocalizedStringKey, _ value: String, icon: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(.caption).foregroundStyle(.secondary)
            Text(value).font(.headline).lineLimit(2).minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, minHeight: 64, alignment: .leading)
        .padding(12)
        .cardBackground()
    }
}

/// Reorder and hide the Car tab's cards.
struct CustomizeHomeView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    ForEach(model.homeOrder.filter { c in
                        // Charging and pre-heating only for electric and plug-in hybrid cars
                        (c != .charging && c != .climate) || model.status.map { $0.energyType != "Fuel" } ?? false
                    }) { c in
                        Toggle(isOn: Binding(get: { !model.hiddenCards.contains(c) }, set: { on in
                            if on { model.hiddenCards.remove(c) } else { model.hiddenCards.insert(c) }
                        })) {
                            Label(L(c.title), systemImage: c.icon)
                        }
                    }
                    .onMove { from, to in model.homeOrder.move(fromOffsets: from, toOffset: to) }
                } footer: {
                    Text("Drag ≡ to change the order. Switch a card off to hide it.")
                }
                Section {
                    Button("Reset to default") { model.resetLayout() }
                }
            }
            .environment(\.editMode, .constant(.active))
            .navigationTitle("Car tab")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

/// The car itself hasn't sent anything new for hours. Nothing an app can force: say so plainly, with what usually
/// helps, so it doesn't look like LionCar is stuck (ported from LionFlow).
struct QuietCarNote: View {
    @Environment(AppModel.self) private var model
    let st: VehicleStatus
    @State private var settled = false
    @State private var hiddenFor: Date?

    var body: some View {
        Group {
            if let at = st.updatedAt, show(at) {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(alignment: .top) {
                        Label("The car hasn't sent new data", systemImage: "antenna.radiowaves.left.and.right.slash").font(.headline)
                        Spacer()
                        Button("OK") { hiddenFor = at }.font(.subheadline.bold())
                    }
                    Text("Last report \(Fmt.ago(at)). LionCar shows what the car last sent to the carmaker's server. If the official app has no new data either, the car's connection is asleep or the carmaker's service has a problem, and no app can fix that from the phone.")
                        .font(.caption).foregroundStyle(.secondary)
                    Text("A short drive, or locking and unlocking with the key, usually wakes it up. If it lasts for days, ask your dealer to check the car's connected services.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                .padding(14)
                .cardBackground()
            }
        }
        // Give a refresh or "Update now" a moment before saying anything.
        .task { try? await Task.sleep(nanoseconds: 20_000_000_000); settled = true }
    }

    private func show(_ at: Date) -> Bool {
        guard settled, !model.isDemo, !model.statusMissing, !st.moving, !model.refreshing, model.commandLabel == nil,
              hiddenFor != at else { return false }
        // With remote control the car can be woken, so 6 h means it didn't answer; without it, a parked car can be quiet overnight.
        return Date().timeIntervalSince(at) >= (model.remoteReady ? 6 : 24) * 3600
    }
}
