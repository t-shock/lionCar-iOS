import SwiftUI
import LionCore

/// Everything the car reported in its last status, in plain words, plus the raw answer for the curious.
struct CarDataView: View {
    @Environment(AppModel.self) private var model
    @State private var showRaw = false

    var body: some View {
        List {
            if let st = model.status {
                Section("Report") {
                    LabeledContent("Car reported", value: st.updatedAt?.formatted(date: .abbreviated, time: .shortened) ?? "—")
                    LabeledContent("Type", value: L(model.kind))
                    LabeledContent("Odometer", value: Fmt.km(st.odometerKm))
                }
                Section("Energy") {
                    if st.energyType != "Electric" {
                        LabeledContent("Fuel level", value: Fmt.pct(st.energyType == "Hybrid" ? st.fuelPct : st.batteryPct))
                        LabeledContent("Fuel range", value: Fmt.km(st.energyType == "Hybrid" ? st.fuelRangeKm : st.rangeKm))
                        value("Car's consumption figure", st.carConsumption.map { "\($0.formatted(.number.precision(.fractionLength(1)))) l/100 km" })
                        value("Average since new", model.lifetimeLPer100.map { "\($0.formatted(.number.precision(.fractionLength(1)))) l/100 km" })
                        value("Fuel since new", model.lifetimeLiters.map { "≈ \(Int($0.rounded())) l" })
                        value("Tank size", model.tankLiters.map { "\(Int($0.rounded())) l" + (model.tankIsEstimated ? String(localized: " (estimated)") : "") })
                    }
                    if st.energyType != "Fuel" {
                        LabeledContent("Battery", value: Fmt.pct(st.batteryPct))
                        LabeledContent("Range", value: Fmt.km(st.rangeKm))
                        value("Charging", st.chargingStatus)
                        value("Plugged in", st.plugged ? String(localized: "Yes") : String(localized: "No"))
                        value("Battery health", st.batteryHealthPct.map { Fmt.pct($0) })
                        value("Battery capacity", st.capacityKwh.map { "\(Int($0)) kWh" })
                    }
                    value("48 V battery", st.smallBatteryWh.map { "\(Int($0)) Wh" })
                    value("48 V battery health", st.smallBatteryHealthPct.map { Fmt.pct($0) })
                    value("Battery voltage (as reported)", st.batteryVoltage.map { "\($0.formatted()) V" })
                }
                Section("Car") {
                    value("Locked", st.locked.map { $0 ? String(localized: "Yes") : String(localized: "No") })
                    LabeledContent("Open", value: st.openDoors.isEmpty ? String(localized: "Nothing") : st.openDoors.joined(separator: ", "))
                    value("Alarm (as reported by the car)", st.alarmActive.map { $0 ? String(localized: "On") : String(localized: "Off") })
                    value("Ignition", st.ignition)
                    value("Engine", st.powertrainStatus)
                    value("Coolant temperature", st.coolantTempC.map { "\(Int($0)) °C" })
                    value("Speed", st.speedKmh.map { "\(Int($0)) km/h" })
                    value("Drive mode", st.driveMode)
                    value("Gearbox", st.gearboxMode)
                    LabeledContent("Fog lights on", value: st.fogLightsOn.isEmpty ? String(localized: "None") : st.fogLightsOn.joined(separator: ", "))
                    LabeledContent("Indicators on", value: st.indicatorsOn.isEmpty ? String(localized: "None") : st.indicatorsOn.joined(separator: ", "))
                    value("Seatbelts", st.seatbelts.isEmpty ? nil : st.seatbelts.joined(separator: ", "))
                    value("Outside temperature", st.outsideTempC.map { Fmt.temp($0) })
                    value("Privacy mode", st.privacyState)
                }
                Section("Position") {
                    value("Latitude, longitude", st.lat.flatMap { la in st.lon.map { "\(la.formatted(.number.precision(.fractionLength(5)))), \($0.formatted(.number.precision(.fractionLength(5))))" } })
                    value("Facing", st.heading.map { "\(Geo.compass($0)) · \(Int($0))°" })
                    value("GPS signal", st.gpsSignalQuality.map { "\(Int($0)) / 9" })
                }
                Section("Service") {
                    value("Distance to service", st.kmToService.map { Fmt.km($0) })
                    value("Days to service", st.daysToService.map { "\(Int($0))" })
                }
                Section {
                    DisclosureGroup("Raw data from \(model.brand.display)", isExpanded: $showRaw) {
                        Text(rawText(st.raw)).font(.caption2.monospaced()).textSelection(.enabled)
                    }
                }
            }
        }
        .navigationTitle("All car data")
        .navigationBarTitleDisplayMode(.inline)
    }

    @ViewBuilder
    private func value(_ title: LocalizedStringKey, _ v: String?) -> some View {
        if let v { LabeledContent(title, value: v) }
    }

    private func rawText(_ j: JSON) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: j, options: [.prettyPrinted, .sortedKeys]) else { return "" }
        return String(decoding: d, as: UTF8.self)
    }
}
