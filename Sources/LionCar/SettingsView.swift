import SwiftUI
import LionCore

struct SettingsView: View {
    @Environment(AppModel.self) private var model
    @State private var confirmSignOut = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Car") {
                    if model.vehicles.count > 1 {
                        Picker("Car", selection: Binding(get: { model.vehicle?.vin ?? "" }, set: { vin in
                            if let v = model.vehicles.first(where: { $0.vin == vin }) { model.select(v) }
                        })) {
                            ForEach(model.vehicles) { v in Text("\(v.brand) · …\(v.vin.suffix(4))").tag(v.vin) }
                        }
                    }
                    LabeledContent("Type", value: L(model.kind))
                    if model.vehicle?.mildHybridUncertain == true || model.mildHybridOverride != nil {
                        Picker("48 V mild hybrid", selection: Binding(get: { model.mildHybridOverride }, set: { model.mildHybridOverride = $0 })) {
                            Text("Detect automatically").tag(Bool?.none)
                            Text("Yes").tag(Bool?.some(true))
                            Text("No").tag(Bool?.some(false))
                        }
                    }
                }
                RemoteSettingsSection()
                FuelSettingsSection()
                AlertSettingsSection()
                Section {
                    NavigationLink { TagsView() } label: { Label("Trip tags", systemImage: "tag") }
                }
                Section("Account") {
                    LabeledContent("Brand", value: model.brand.app)
                    LabeledContent("Country", value: Locale.current.localizedString(forRegionCode: model.country) ?? model.country)
                    Button("Sign out", role: .destructive) { confirmSignOut = true }
                }
                Section {
                    Text(model.brand.subscriptionNotice()).font(.footnote)
                }
                Section("About") {
                    LabeledContent("Version", value: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "dev")
                    Text("LionCar is a free, open-source (GPL-3.0) iPhone port of LionFlow by thocubeat. It is not made, endorsed or supported by Stellantis or its brands. Sign-in and API flow from homeassistant-stellantis-vehicles (MIT); the remote-control code generator from psa_car_controller (GPL-3.0).")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .confirmationDialog("Sign out of \(model.brand.app)?", isPresented: $confirmSignOut, titleVisibility: .visible) {
                Button("Sign out", role: .destructive) { model.signOut() }
            }
        }
    }
}
