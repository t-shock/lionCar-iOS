import SwiftUI
import LionCore

/// Settings › Fuel and costs.
struct FuelSettingsSection: View {
    @Environment(AppModel.self) private var model
    @State private var priceText = ""
    @State private var tankText = ""

    var body: some View {
        Section {
            HStack {
                Text("Fuel price")
                Spacer()
                TextField("e.g. 1.85", text: $priceText).keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    .onChange(of: priceText) { _, v in model.fuelPrice = Self.number(v) }
                Text("\(model.currencySymbol)/l").foregroundStyle(.secondary)
            }
            HStack {
                Text("Tank size")
                Spacer()
                TextField(model.tankIsEstimated ? (model.tankLiters.map { "≈ \(Int($0.rounded()))" } ?? "—") : "", text: $tankText)
                    .keyboardType(.decimalPad).multilineTextAlignment(.trailing).frame(width: 90)
                    .onChange(of: tankText) { _, v in model.tankLiters = Self.number(v) }
                Text("l").foregroundStyle(.secondary)
            }
        } header: {
            Text("Fuel and costs")
        } footer: {
            Text("The price is used for trip and monthly costs. Leave the tank size empty to let LionCar estimate it from the fuel gauge.")
        }
        .onAppear {
            priceText = model.fuelPrice.map { $0.formatted(.number.precision(.fractionLength(0...3))) } ?? ""
            tankText = model.tankIsEstimated ? "" : (model.tankLiters.map { $0.formatted(.number.precision(.fractionLength(0...1))) } ?? "")
        }
    }

    static func number(_ s: String) -> Double? {
        let t = s.replacingOccurrences(of: ",", with: ".").trimmingCharacters(in: .whitespaces)
        return Double(t).flatMap { $0 > 0 ? $0 : nil }
    }
}

/// Settings › Notifications.
struct AlertSettingsSection: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        Section {
            Toggle("Car left unlocked", isOn: $model.alertSettings.unlocked)
            Toggle("Low fuel / battery", isOn: $model.alertSettings.lowEnergy)
            if model.alertSettings.lowEnergy {
                Stepper("Warn at \(Int(model.alertSettings.lowPct)) %", value: $model.alertSettings.lowPct, in: 5...40, step: 5)
            }
            Toggle("Service due soon", isOn: $model.alertSettings.service)
            Toggle("Fog lights left on", isOn: $model.alertSettings.lightsOn)
        } header: {
            Text("Notifications")
        } footer: {
            Text("LionCar checks the car when you open it, and in the background when iOS allows it — often every hour or two, not on a fixed schedule. So a warning can come late. Background App Refresh must be on for LionCar in the iPhone's Settings.")
        }
    }
}

/// Settings › Trip tags.
struct TagsView: View {
    @Environment(AppModel.self) private var model
    @State private var newName = ""

    var body: some View {
        @Bindable var model = model
        List {
            Section {
                Toggle("Tag trips automatically by place", isOn: $model.tagBook.autoTag)
            } footer: {
                Text("A tag with a place is given to every trip that starts or ends within its radius. You can always change a trip's tag by hand.")
            }
            Section("Tags") {
                ForEach(model.tagBook.tags) { tag in
                    NavigationLink { TagEditor(tag: tag) } label: {
                        HStack {
                            Image(systemName: "tag.fill").foregroundStyle(TagColor.of(tag))
                            Text(tag.name)
                            Spacer()
                            if tag.hasPlace { Image(systemName: "mappin.and.ellipse").foregroundStyle(.secondary) }
                        }
                    }
                }
                .onDelete { idx in for i in idx { model.removeTag(model.tagBook.tags[i]) } }
                HStack {
                    TextField("New tag (e.g. Work)", text: $newName)
                    Button("Add") {
                        if !trimmedName.isEmpty { model.addTag(name: trimmedName); newName = "" }
                    }
                    .disabled(trimmedName.isEmpty)
                }
            }
        }
        .navigationTitle("Trip tags")
    }

    private var trimmedName: String { newName.trimmingCharacters(in: .whitespaces) }
}

struct TagEditor: View {
    @Environment(AppModel.self) private var model
    @State var tag: TripTag

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $tag.name)
                Picker("Colour", selection: $tag.color) {
                    ForEach(0..<TagColor.all.count, id: \.self) { i in
                        Image(systemName: "circle.fill").foregroundStyle(TagColor.all[i]).tag(i)
                    }
                }
                .pickerStyle(.palette)
            }
            Section {
                if let lat = tag.lat, let lon = tag.lon {
                    LabeledContent("Place", value: "\(lat.formatted(.number.precision(.fractionLength(4)))), \(lon.formatted(.number.precision(.fractionLength(4))))")
                    Stepper("Radius \(Int(tag.radius)) m", value: $tag.radius, in: 50...1000, step: 50)
                    Button("Remove place", role: .destructive) { tag.lat = nil; tag.lon = nil }
                }
                if let st = model.status, let lat = st.lat, let lon = st.lon {
                    Button(tag.hasPlace ? "Move to where the car is now" : "Use where the car is now") { tag.lat = lat; tag.lon = lon }
                }
                if let t = model.trips.first, let lat = t.stopLat, let lon = t.stopLon {
                    Button("Use the end of the last trip") { tag.lat = lat; tag.lon = lon }
                }
            } header: {
                Text("Place")
            } footer: {
                Text("Park at the place (home, work…) and use the car's position, or take the end of your last trip.")
            }
        }
        .navigationTitle(tag.name.isEmpty ? String(localized: "Tag") : tag.name)
        .onChange(of: tag) { _, t in model.updateTag(t) }
    }
}
