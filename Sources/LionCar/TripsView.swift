import SwiftUI
import MapKit
import LionCore

enum TagColor {
    static let all: [Color] = [.teal, .orange, .purple, .pink, .blue, .green, .red, .brown]
    static func of(_ tag: TripTag) -> Color { all[abs(tag.color) % all.count] }
}

struct TripsView: View {
    @Environment(AppModel.self) private var model
    @State private var open: Trip?
    /// nil = all trips; "" = trips without a tag; otherwise a tag id.
    @State private var tagFilter: String?
    @State private var exportURL: URL?

    static let periods: [(days: Int, short: LocalizedStringKey, long: String)] = [
        (7, "7 days", String(localized: "the last 7 days")), (30, "30 days", String(localized: "the last 30 days")),
        (90, "3 months", String(localized: "the last 3 months")), (365, "1 year", String(localized: "the last year")),
    ]
    private var periodName: String { Self.periods.first { $0.days == model.tripDays }?.long ?? "" }

    private var trips: [Trip] {
        guard let f = tagFilter else { return model.shownTrips }
        return model.shownTrips.filter { (model.tag(for: $0)?.id ?? "") == f }
    }

    private var byDay: [(day: Date, trips: [Trip])] {
        let cal = Calendar.current
        let groups = Dictionary(grouping: trips) { cal.startOfDay(for: $0.start ?? .distantPast) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    private var usesKwh: Bool { model.status.map { $0.energyType == "Electric" } ?? false }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Picker("Period", selection: Binding(get: { model.tripDays }, set: { model.tripDays = $0 })) {
                        ForEach(Self.periods, id: \.days) { Text($0.short).tag($0.days) }
                    }
                    .pickerStyle(.segmented)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
                }
                if !trips.isEmpty { Section { summary } }
                if tagFilter == nil && !model.tagBook.tags.isEmpty && !model.shownTrips.isEmpty { Section("By tag") { tagTotals } }
                ForEach(byDay, id: \.day) { group in
                    Section(group.day.formatted(.dateTime.weekday(.wide).day().month())) {
                        ForEach(group.trips) { t in
                            Button { open = t } label: { TripRow(trip: t, electric: usesKwh) }.tint(.primary)
                        }
                    }
                }
                if trips.isEmpty && !model.tripsLoading {
                    Text("No trips in \(periodName).").foregroundStyle(.secondary)
                }
            }
            .overlay { if model.tripsLoading && model.shownTrips.isEmpty { ProgressView("Loading trips…") } }
            .refreshable { await model.loadTrips(recentOnly: true) }
            .navigationTitle("Trips")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { filterMenu }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { exportURL = model.exportCSV() } label: { Image(systemName: "square.and.arrow.up") }
                        .accessibilityLabel("Export CSV")
                        .disabled(model.shownTrips.isEmpty)
                }
            }
            .sheet(item: $open) { TripDetail(trip: $0, electric: usesKwh).presentationDetents([.medium, .large]) }
            .sheet(item: $exportURL) { ShareSheet(items: [$0]) }
        }
    }

    private var filterMenu: some View {
        Menu {
            Picker("Show", selection: $tagFilter) {
                Text("All trips").tag(String?.none)
                ForEach(model.tagBook.tags) { Label($0.name, systemImage: "tag.fill").tag(String?.some($0.id)) }
                Text("Without a tag").tag(String?.some(""))
            }
        } label: {
            Image(systemName: tagFilter == nil ? "line.3.horizontal.decrease.circle" : "line.3.horizontal.decrease.circle.fill")
        }
        .accessibilityLabel("Filter by tag")
    }

    private var summary: some View {
        let t = trips
        let km = t.reduce(0) { $0 + $1.distanceKm }
        let liters = t.compactMap(\.liters).reduce(0, +)
        let kmWithFuel = t.filter { $0.liters != nil }.reduce(0) { $0 + $1.distanceKm }
        let kwh = t.compactMap(\.kwh).reduce(0, +)
        let cost = model.fuelPrice.map { liters * $0 }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(periodName.prefix(1).uppercased() + periodName.dropFirst()).font(.caption).foregroundStyle(.secondary)
                if let f = tagFilter { Text("· \(model.tagBook.tags.first { $0.id == f }?.name ?? String(localized: "no tag"))").font(.caption).foregroundStyle(.secondary) }
                if model.tripsLoading { ProgressView().controlSize(.mini) }
            }
            HStack(alignment: .firstTextBaseline, spacing: 18) {
                stat(Fmt.km(km), String(localized: "\(t.count) trips"))
                if !usesKwh, kmWithFuel > 0 {
                    stat("\((liters / kmWithFuel * 100).formatted(.number.precision(.fractionLength(1)))) l/100",
                         String(localized: "\(liters.formatted(.number.precision(.fractionLength(1)))) l fuel"))
                }
                if usesKwh, kwh > 0, km > 0 {
                    stat("\((kwh / km * 100).formatted(.number.precision(.fractionLength(1)))) kWh/100", "\(Int(kwh)) kWh")
                }
                if let cost, cost > 0 { stat(Fmt.money(cost, model.currencySymbol), String(localized: "fuel cost")) }
            }
        }
    }

    private var tagTotals: some View {
        ForEach(model.tagBook.tags) { tag in
            let list = model.shownTrips.filter { model.tag(for: $0)?.id == tag.id }
            if !list.isEmpty {
                Button { tagFilter = tag.id } label: {
                    HStack {
                        Label(tag.name, systemImage: "tag.fill").foregroundStyle(TagColor.of(tag))
                        Spacer()
                        Text("\(list.count) · \(Fmt.km(list.reduce(0) { $0 + $1.distanceKm }))").foregroundStyle(.secondary)
                    }
                }
                .tint(.primary)
            }
        }
    }

    private func stat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading) {
            Text(value).font(.title3.bold())
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

extension URL: @retroactive Identifiable { public var id: String { absoluteString } }

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController { UIActivityViewController(activityItems: items, applicationActivities: nil) }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}

struct TripRow: View {
    @Environment(AppModel.self) private var model
    let trip: Trip
    let electric: Bool

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(trip.start.map { $0.formatted(date: .omitted, time: .shortened) } ?? "—").font(.headline)
                    if let tag = model.tag(for: trip) {
                        Text(tag.name).font(.caption2.bold()).padding(.horizontal, 6).padding(.vertical, 2)
                            .background(TagColor.of(tag).opacity(0.18), in: Capsule()).foregroundStyle(TagColor.of(tag))
                    }
                }
                Text(Fmt.duration(trip.durationSec)).font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(Fmt.km(trip.distanceKm)).font(.headline)
                Text(consumption).font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var consumption: String {
        var parts: [String] = []
        if electric, let k = trip.avgKwhPer100 { parts.append("\(k.formatted(.number.precision(.fractionLength(1)))) kWh/100") }
        else if let l = trip.avgLPer100 { parts.append("\(l.formatted(.number.precision(.fractionLength(1)))) l/100 km") }
        if let c = model.cost(trip) { parts.append(Fmt.money(c, model.currencySymbol)) }
        if parts.isEmpty && trip.dataLacking { return String(localized: "incomplete data") }
        return parts.joined(separator: " · ")
    }
}

struct TripDetail: View {
    @Environment(AppModel.self) private var model
    let trip: Trip
    let electric: Bool
    @State private var newTag = ""
    @State private var addingTag = false

    var body: some View {
        NavigationStack {
            List {
                if let a = coord(trip.startLat, trip.startLon), let b = coord(trip.stopLat, trip.stopLon) {
                    Map(initialPosition: .rect(rect(a, b))) {
                        Marker("Start", systemImage: "flag", coordinate: a).tint(.green)
                        Marker("End", systemImage: "flag.checkered", coordinate: b).tint(.red)
                    }
                    .frame(height: 220).listRowInsets(EdgeInsets())
                }
                Section {
                    tagPicker
                }
                Section {
                    LabeledContent("Distance", value: Fmt.km(trip.distanceKm))
                    LabeledContent("Duration", value: Fmt.duration(trip.durationSec))
                    if let s = trip.avgSpeedKmh { LabeledContent("Average speed", value: "\(Int(s.rounded())) km/h") }
                    if let s = trip.maxSpeedKmh { LabeledContent("Top speed", value: "\(Int(s.rounded())) km/h") }
                    if let l = trip.liters { LabeledContent("Fuel", value: "\(l.formatted(.number.precision(.fractionLength(2)))) l") }
                    if let l = trip.avgLPer100, !electric { LabeledContent("Consumption", value: "\(l.formatted(.number.precision(.fractionLength(1)))) l/100 km") }
                    if let k = trip.kwh, k > 0 { LabeledContent("Energy", value: "\(k.formatted(.number.precision(.fractionLength(1)))) kWh") }
                    if let c = model.cost(trip) { LabeledContent("Fuel cost", value: Fmt.money(c, model.currencySymbol)) }
                    if let a = trip.startLevel, let b = trip.endLevel {
                        LabeledContent(electric ? "Battery" : "Tank", value: "\(Int(a)) % → \(Int(b)) %")
                    }
                    if let a = trip.startRangeKm, let b = trip.endRangeKm {
                        LabeledContent("Range", value: "\(Int(a)) → \(Int(b)) km")
                    }
                    if let m = trip.startMileage { LabeledContent("Odometer at start", value: Fmt.km(m)) }
                }
                if trip.dataLacking {
                    Text("The car lost its connection during this trip, so some figures may be missing.").font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle(trip.start.map { $0.formatted(date: .abbreviated, time: .shortened) } ?? "Trip")
            .navigationBarTitleDisplayMode(.inline)
            .alert("New tag", isPresented: $addingTag) {
                TextField("Name", text: $newTag)
                Button("Add") {
                    let name = newTag.trimmingCharacters(in: .whitespaces)
                    if !name.isEmpty { model.setTag(model.addTag(name: name).id, for: trip) }
                    newTag = ""
                }
                Button("Cancel", role: .cancel) { newTag = "" }
            }
        }
    }

    private var tagPicker: some View {
        Menu {
            ForEach(model.tagBook.tags) { tag in
                Button { model.setTag(tag.id, for: trip) } label: { Label(tag.name, systemImage: "tag") }
            }
            Divider()
            Button { model.setTag(nil, for: trip) } label: { Label("No tag", systemImage: "tag.slash") }
            Button { model.resetTag(for: trip) } label: { Label("Automatic", systemImage: "wand.and.stars") }
            Button { addingTag = true } label: { Label("New tag…", systemImage: "plus") }
        } label: {
            HStack {
                Label("Tag", systemImage: "tag")
                Spacer()
                Text(model.tag(for: trip)?.name ?? String(localized: "None")).foregroundStyle(.secondary)
            }
        }
        .tint(.primary)
    }

    private func coord(_ lat: Double?, _ lon: Double?) -> CLLocationCoordinate2D? {
        guard let lat, let lon else { return nil }
        return CLLocationCoordinate2D(latitude: lat, longitude: lon)
    }

    private func rect(_ a: CLLocationCoordinate2D, _ b: CLLocationCoordinate2D) -> MKMapRect {
        let pa = MKMapPoint(a), pb = MKMapPoint(b)
        let r = MKMapRect(x: min(pa.x, pb.x), y: min(pa.y, pb.y), width: abs(pa.x - pb.x), height: abs(pa.y - pb.y))
        let pad = max(r.width, r.height, 2000) * 0.3
        return r.insetBy(dx: -pad, dy: -pad)
    }
}
