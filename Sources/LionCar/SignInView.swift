import SwiftUI
import AuthenticationServices
import LionCore

struct SignInView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.webAuthenticationSession) private var webAuth
    @State private var brand: Brand = .peugeot
    @State private var country = "GB"
    @State private var showNotice = false
    @State private var choosingDemo = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    VStack(spacing: 8) {
                        Image(systemName: "car.side.fill").font(.system(size: 52)).foregroundStyle(Theme.accent)
                        Text("LionCar").font(.largeTitle.bold())
                        Text("Your connected \(brand.display), without the wait.").foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity).padding(.vertical, 12)
                }
                Section("Your car's brand and country") {
                    Picker("Brand", selection: $brand) {
                        ForEach(Brand.allCases) { Text($0.display).tag($0) }
                    }
                    Picker("Country", selection: $country) {
                        ForEach(StellantisConfig.countries(brand), id: \.self) { cc in
                            Text(Locale.current.localizedString(forRegionCode: cc) ?? cc).tag(cc)
                        }
                    }
                }
                Section {
                    Button {
                        Task { await signIn() }
                    } label: {
                        HStack {
                            Spacer()
                            if model.signingIn { ProgressView() } else { Text("Sign in with \(brand.app)").bold() }
                            Spacer()
                        }
                    }
                    .disabled(model.signingIn)
                } footer: {
                    Text("You sign in on \(brand.display)'s own page with the same e-mail and password as the \(brand.app) app. LionCar never sees your password.")
                }
                Section {
                    Button("Try with a sample car (no account)") { choosingDemo = true }
                }
                Section {
                    DisclosureGroup("What needs a subscription?", isExpanded: $showNotice) {
                        Text(brand.subscriptionNotice()).font(.footnote)
                    }
                }
            }
            .navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $choosingDemo) { DemoSetupView() }
        }
        .onAppear {
            brand = model.brand
            let list = StellantisConfig.countries(brand)
            country = list.contains(model.country.uppercased()) ? model.country.uppercased() : Self.fallbackCountry(list)
        }
        .onChange(of: brand) { _, b in
            let list = StellantisConfig.countries(b)
            if !list.contains(country) { country = Self.fallbackCountry(list) }
        }
    }

    /// When the current country isn't offered for the brand: the UK if it is, else the first one.
    private static func fallbackCountry(_ list: [String]) -> String { list.contains("GB") ? "GB" : list.first ?? "GB" }

    private func signIn() async {
        model.setAccount(brand: brand, country: country)
        do {
            // The sign-in page ends on <scheme>://oauth2redirect/…?code=…; this session catches it even when the
            // brand's own app is installed and claims the same address.
            let url = try await webAuth.authenticate(using: model.authorizeURL, callbackURLScheme: model.callbackScheme,
                                                     preferredBrowserSession: .shared)
            await model.finishSignIn(redirect: url)
        } catch let e as ASWebAuthenticationSessionError where e.code == .canceledLogin {
            // closed by the user
        } catch {
            model.message = "Sign-in failed — \(error.localizedDescription)"
        }
    }
}
