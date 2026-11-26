import SwiftUI
import UserNotifications
import LionCore

@main
struct LionCarApp: App {
    @State private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() { UNUserNotificationCenter.current().delegate = NotificationDelegate.shared }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environment(model)
                .tint(Theme.accent)
        }
        // iOS wakes the app now and then to check the car (it decides how often).
        .backgroundTask(.appRefresh(AppModel.refreshTaskID)) { await model.backgroundRefresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .background { AppModel.scheduleBackgroundRefresh() }
            if phase == .active, model.phase == .ready {
                // Connect early, so a command sent right after opening the app goes out faster.
                model.warmUpRemote()
                // Fresh data when the app comes back, unless it updated in the last 5 minutes (as LionFlow does).
                if model.lastRefresh.map({ Date().timeIntervalSince($0) > 300 }) ?? true {
                    Task { await model.refresh() }
                }
            }
        }
    }
}

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            switch model.phase {
            case .signedOut: SignInView()
            case .loading: ProgressView("Loading your car…").controlSize(.large)
            case .ready: MainTabs().task { model.requestNotificationPermission() }
            }
        }
        .overlay(alignment: .bottom) {
            if let t = model.toast {
                Text(t).font(.subheadline.bold()).padding(.horizontal, 16).padding(.vertical, 10)
                    .glassPill()
                    // Above the tab bar when there is one (at the top it sat on the glass navigation bar).
                    .padding(.bottom, model.phase == .ready ? 64 : 16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .onTapGesture { model.toast = nil }
            }
        }
        .animation(.spring(duration: 0.3), value: model.toast)
        .alert("LionCar", isPresented: Binding(get: { model.message != nil }, set: { if !$0 { model.message = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.message ?? "")
        }
    }
}

struct MainTabs: View {
    var body: some View {
        TabView {
            HomeView().tabItem { Label("Car", systemImage: "car.fill") }
            TripsView().tabItem { Label("Trips", systemImage: "point.topleft.down.to.point.bottomright.curvepath") }
            MapTab().tabItem { Label("Map", systemImage: "map") }
            StatsView().tabItem { Label("Stats", systemImage: "chart.bar.xaxis") }
            SettingsView().tabItem { Label("Settings", systemImage: "gearshape") }
        }
        .minimizingTabBar()
    }
}

enum Theme {
    static let accent = Color(red: 0.04, green: 0.48, blue: 0.46)
}

/// Looks up a text that is only known at run time (car type, progress from the core, …) in the app's translations.
func L(_ s: String) -> String { NSLocalizedString(s, comment: "") }

enum Fmt {
    static func km(_ v: Double?) -> String {
        guard let v else { return "—" }
        return v.formatted(.number.precision(.fractionLength(v < 100 ? 1 : 0))) + " km"
    }
    static func pct(_ v: Double?) -> String { v.map { "\(Int($0.rounded())) %" } ?? "—" }
    static func temp(_ v: Double?) -> String { v.map { $0.formatted(.number.precision(.fractionLength(1))) + " °C" } ?? "—" }
    static func ago(_ d: Date?) -> String {
        guard let d else { return L("unknown") }
        return d.formatted(.relative(presentation: .named))
    }
    static func money(_ v: Double, _ symbol: String) -> String {
        v.formatted(.number.precision(.fractionLength(2))) + " " + symbol
    }
    static func duration(_ sec: Double?) -> String {
        guard let sec else { return "—" }
        let m = Int((sec / 60).rounded())
        return m >= 60 ? String(localized: "\(m / 60) h \(m % 60) min") : String(localized: "\(m) min")
    }
}
