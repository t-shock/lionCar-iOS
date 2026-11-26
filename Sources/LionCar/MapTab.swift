import SwiftUI
import MapKit
import LionCore

/// The Map tab: you, the car, and chargers (electric and plug-in hybrid cars) or fuel stations (other cars) from
/// OpenStreetMap. Port of LionFlow's map, on Apple Maps.
struct MapTab: View {
    @Environment(AppModel.self) private var model
    @State private var location = PhoneLocation()
    @State private var position: MapCameraPosition = .automatic
    @State private var center: CLLocationCoordinate2D?
    @State private var selected: Charger?
    @State private var fastOnly = false
    @State private var started = false

    private var car: CLLocationCoordinate2D? {
        guard let st = model.status, let la = st.lat, let lo = st.lon else { return nil }
        return CLLocationCoordinate2D(latitude: la, longitude: lo)
    }

    private var chargers: Bool { model.placesKind == .chargers }
    private var visible: [Charger] { model.places.filter { !fastOnly || !chargers || $0.isFast } }

    /// The map was moved well away from the last search.
    private var moved: Bool {
        guard let c = center, let s = model.placesCenter else { return false }
        return Geo.distanceM(c.latitude, c.longitude, s.latitude, s.longitude) > 2_000
    }

    var body: some View {
        NavigationStack {
            Map(position: $position) {
                UserAnnotation()
                if let car {
                    Annotation(L("My car"), coordinate: car) {
                        Image(systemName: "car.fill").font(.caption.bold()).foregroundStyle(.white)
                            .padding(7).background(Theme.accent, in: Circle()).overlay(Circle().stroke(.white, lineWidth: 2))
                    }
                }
                ForEach(visible) { c in
                    Annotation(c.name, coordinate: CLLocationCoordinate2D(latitude: c.lat, longitude: c.lon)) {
                        Button { selected = c } label: { PlaceMarker(place: c, fuel: !chargers) }
                    }
                    .annotationTitles(.hidden)
                }
            }
            .mapStyle(.standard(elevation: .realistic, pointsOfInterest: .excludingAll))
            .mapControls {
                MapUserLocationButton()
                MapPitchToggle()
                MapCompass()
                MapScaleView()
            }
            .onMapCameraChange(frequency: .onEnd) { ctx in center = ctx.region.center }
            .safeAreaInset(edge: .top) { topBar }
            .safeAreaInset(edge: .bottom) { bottomBar }
            .navigationTitle(chargers ? "Chargers" : "Fuel stations")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if let car {
                    ToolbarItem(placement: .topBarLeading) {
                        Button { withAnimation { position = .region(MKCoordinateRegion(center: car, latitudinalMeters: 4000, longitudinalMeters: 4000)) } } label: {
                            Label("My car", systemImage: "car")
                        }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { Task { await search(force: true) } } label: {
                        if model.placesLoading { ProgressView() } else { Image(systemName: "arrow.clockwise") }
                    }
                    .disabled(model.placesLoading)
                    .accessibilityLabel("Refresh")
                }
            }
            .sheet(item: $selected) { PlaceSheet(place: $0, fuel: !chargers, car: car, me: location.coordinate).presentationDetents([.medium, .large]) }
            .task {
                guard !started else { return }
                started = true
                location.start()
                // Give the phone a moment to find itself; otherwise start at the car.
                for _ in 0..<15 where location.coordinate == nil && !location.denied { try? await Task.sleep(nanoseconds: 200_000_000) }
                let start = location.coordinate ?? car
                if let start { position = .region(MKCoordinateRegion(center: start, latitudinalMeters: 8000, longitudinalMeters: 8000)) }
                await search(force: false, at: start)
            }
        }
    }

    private func search(force: Bool, at point: CLLocationCoordinate2D? = nil) async {
        guard let p = point ?? center ?? location.coordinate ?? car else { return }
        await model.loadPlaces(lat: p.latitude, lon: p.longitude, force: force)
    }

    @ViewBuilder
    private var topBar: some View {
        VStack(spacing: 8) {
            if chargers {
                Picker("Show", selection: $fastOnly) {
                    Text("All").tag(false)
                    Text("Fast 50 kW+").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 260)
            }
            if moved && !model.placesLoading {
                Button { Task { await search(force: false) } } label: {
                    Label("Search this area", systemImage: "magnifyingglass").font(.subheadline.bold())
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(.top, 6)
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            if model.placesLoading {
                HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Asking OpenStreetMap…") }
                    .font(.footnote.bold()).mapPill()
            } else if let e = model.placesError {
                Text(e).font(.footnote.bold()).mapPill()
            } else if !model.places.isEmpty {
                Text(chargers ? String(localized: "\(visible.count) chargers") : String(localized: "\(visible.count) fuel stations"))
                    .font(.footnote).mapPill()
            }
            Text(chargers ? "Chargers © OpenStreetMap contributors" : "Fuel stations © OpenStreetMap contributors")
                .font(.caption2).foregroundStyle(.secondary)
        }
        .padding(.bottom, 6)
    }
}

/// A small status capsule floating over the map, readable on any map colours.
private extension View {
    func mapPill() -> some View {
        padding(.horizontal, 12).padding(.vertical, 6).background(.regularMaterial, in: Capsule())
    }
}

struct PlaceMarker: View {
    let place: Charger
    let fuel: Bool

    var body: some View {
        let fast = place.isFast && !fuel
        Image(systemName: fuel ? "fuelpump.fill" : "bolt.fill")
            .font(.system(size: fast ? 13 : 11, weight: .bold))
            .foregroundStyle(fast ? .black : .white)
            .frame(width: fast ? 28 : 24, height: fast ? 28 : 24)
            .background(fast ? Theme.accent : Color(red: 0.12, green: 0.13, blue: 0.15), in: Circle())
            .overlay(Circle().stroke(.white, lineWidth: 2))
            .shadow(radius: 1.5)
    }
}

struct PlaceSheet: View {
    let place: Charger
    let fuel: Bool
    let car: CLLocationCoordinate2D?
    let me: CLLocationCoordinate2D?

    var body: some View {
        NavigationStack {
            List {
                Section {
                    if !fuel {
                        LabeledContent("Power", value: place.maxKw > 0 ? "\(place.maxKw.formatted(.number.precision(.fractionLength(0...1)))) kW" : L("not mapped"))
                        if place.points > 0 { LabeledContent("Charging points", value: "\(place.points)") }
                        if !place.sockets.isEmpty {
                            LabeledContent("Plugs", value: place.sockets.sorted { $0.key < $1.key }.map { "\($0.value)× \($0.key)" }.joined(separator: ", "))
                        }
                    }
                    if !place.operatorName.isEmpty && place.operatorName != place.name { LabeledContent("Operator", value: place.operatorName) }
                    if !place.address.isEmpty { LabeledContent("Address", value: place.address) }
                    if !place.openingHours.isEmpty { LabeledContent("Opening hours", value: place.openingHours) }
                    if place.fee == "no" { LabeledContent("Price", value: L("free")) }
                }
                Section {
                    if let me { LabeledContent("From you", value: distance(me)) }
                    if let car { LabeledContent("From the car", value: distance(car)) }
                }
                Section {
                    Button {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: CLLocationCoordinate2D(latitude: place.lat, longitude: place.lon)))
                        item.name = place.name
                        item.openInMaps(launchOptions: [MKLaunchOptionsDirectionsModeKey: MKLaunchOptionsDirectionsModeDriving])
                    } label: { Label("Directions", systemImage: "arrow.triangle.turn.up.right.circle.fill") }
                } footer: {
                    Text("From OpenStreetMap, made by volunteers: power, plugs and prices can be missing or out of date.")
                }
            }
            .navigationTitle(place.name)
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private func distance(_ from: CLLocationCoordinate2D) -> String {
        Fmt.km(Geo.distanceM(from.latitude, from.longitude, place.lat, place.lon) / 1000)
    }
}
