import SwiftUI
import Charts
import LionCore

/// Monthly totals, fill-ups, records and lifetime figures, from up to a year of trips.
struct StatsView: View {
    @Environment(AppModel.self) private var model
    @State private var metric: Metric = .km

    enum Metric: String, CaseIterable, Identifiable {
        case km, fuel, cost
        var id: String { rawValue }
        var title: LocalizedStringKey { self == .km ? "Distance" : self == .fuel ? "Fuel" : "Cost" }
    }

    private var yearTrips: [Trip] {
        let from = Date().addingTimeInterval(-365 * 86_400)
        return model.trips.filter { ($0.start ?? .distantPast) >= from }
    }

    var body: some View {
        let months = Stats.monthly(yearTrips)
        let electric = model.status?.energyType == "Electric"
        NavigationStack {
            List {
                if model.loadedTripDays < 365 || model.tripsLoading {
                    HStack { ProgressView(); Text("Loading a year of trips…").foregroundStyle(.secondary) }
                }
                lifetime
                if !months.isEmpty {
                    Section("Per month") {
                        if !electric {
                            Picker("Show", selection: $metric) {
                                ForEach(Metric.allCases.filter { $0 != .cost || model.fuelPrice != nil }) { Text($0.title).tag($0) }
                            }
                            .pickerStyle(.segmented)
                        }
                        Chart(months.reversed()) { m in
                            BarMark(x: .value("Month", m.start, unit: .month), y: .value("Value", value(m)))
                                .foregroundStyle(Theme.accent.gradient)
                                .cornerRadius(4)
                        }
                        .chartXAxis { AxisMarks(values: .stride(by: .month)) { _ in AxisValueLabel(format: .dateTime.month(.narrow)) } }
                        .frame(height: 180)
                        ForEach(months) { m in monthRow(m, electric: electric) }
                    }
                }
                fillUps(electric: electric)
                records
                if model.fuelPrice == nil && !electric {
                    Section {
                        Text("Set your fuel price in Settings › Fuel and costs to see what your driving costs.")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Stats")
            .task { if model.loadedTripDays < 365 { await model.loadTrips(days: 365) } }
            .refreshable { await model.loadTrips(recentOnly: true) }
        }
    }

    private func value(_ m: Stats.Month) -> Double {
        switch metric {
        case .km: m.km
        case .fuel: m.liters
        case .cost: m.cost(pricePerLiter: model.fuelPrice) ?? 0
        }
    }

    private func monthRow(_ m: Stats.Month, electric: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(m.start.formatted(.dateTime.month(.wide).year())).font(.headline)
                Spacer()
                Text(Fmt.km(m.km)).font(.headline)
            }
            HStack(spacing: 12) {
                Text("\(m.trips) trips")
                Text(Fmt.duration(m.seconds))
                if !electric, let l = m.lPer100 { Text("\(l.formatted(.number.precision(.fractionLength(1)))) l/100") }
                if !electric, m.liters > 0 { Text("\(m.liters.formatted(.number.precision(.fractionLength(1)))) l") }
                if electric, m.kwh > 0 { Text("\(Int(m.kwh)) kWh") }
                if let c = m.cost(pricePerLiter: model.fuelPrice) { Text(Fmt.money(c, model.currencySymbol)) }
            }
            .font(.caption).foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var lifetime: some View {
        if let st = model.status {
            Section("Since new") {
                LabeledContent("Odometer", value: Fmt.km(st.odometerKm))
                if let a = model.lifetimeLPer100 {
                    LabeledContent("Average consumption", value: "\(a.formatted(.number.precision(.fractionLength(1)))) l/100 km")
                }
                if let l = model.lifetimeLiters {
                    LabeledContent("Fuel used", value: "≈ \(Int(l.rounded())) l")
                    if let p = model.fuelPrice { LabeledContent("Fuel cost", value: "≈ " + Fmt.money(l * p, model.currencySymbol)) }
                }
            }
        }
    }

    @ViewBuilder
    private func fillUps(electric: Bool) -> some View {
        let fills = Stats.fillUps(yearTrips, tankLiters: electric ? nil : model.tankLiters)
        if !fills.isEmpty {
            Section {
                ForEach(fills) { f in
                    HStack {
                        VStack(alignment: .leading) {
                            Text(f.date.formatted(date: .abbreviated, time: .shortened)).font(.subheadline)
                            if let k = f.kmSincePrevious { Text("\(Fmt.km(k)) since the one before").font(.caption).foregroundStyle(.secondary) }
                        }
                        Spacer()
                        VStack(alignment: .trailing) {
                            Text("\(Int(f.fromPct)) → \(Int(f.toPct)) %").font(.subheadline.bold())
                            if let l = f.liters {
                                Text("≈ \(Int(l.rounded())) l" + (model.fuelPrice.map { " · " + Fmt.money(l * $0, model.currencySymbol) } ?? ""))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            } header: {
                Text(electric ? "Charges" : "Fill-ups")
            } footer: {
                if !electric {
                    let tank = model.tankLiters.map { "\(Int($0.rounded())) l" } ?? L("unknown")
                    Text("Found from the fuel gauge between trips. Litres are estimated from the tank size (\(tank)); the gauge stays at 100 % for the first kilometres, so small top-ups may be missed.")
                }
            }
        }
    }

    @ViewBuilder
    private var records: some View {
        let r = Stats.records(yearTrips)
        if r.longest != nil {
            Section("Records (last year)") {
                if let t = r.longest { record("Longest trip", Fmt.km(t.distanceKm), t) }
                if let t = r.longestTime { record("Longest time at the wheel", Fmt.duration(t.durationSec), t) }
                if let d = r.bestDay { LabeledContent("Most in one day", value: "\(Fmt.km(d.km)) · \(d.day.formatted(date: .abbreviated, time: .omitted))") }
                if let t = r.mostEfficient, let l = t.avgLPer100 { record("Most economical (10 km+)", "\(l.formatted(.number.precision(.fractionLength(1)))) l/100", t) }
                if let t = r.leastEfficient, let l = t.avgLPer100 { record("Thirstiest (10 km+)", "\(l.formatted(.number.precision(.fractionLength(1)))) l/100", t) }
            }
        }
    }

    private func record(_ title: LocalizedStringKey, _ value: String, _ t: Trip) -> some View {
        LabeledContent {
            VStack(alignment: .trailing) {
                Text(value)
                Text(t.start?.formatted(date: .abbreviated, time: .omitted) ?? "").font(.caption).foregroundStyle(.secondary)
            }
        } label: { Text(title) }
    }
}
