import Foundation

/// The Stellantis brands whose connected-car account LionCar can sign in to. All use the same backend;
/// only the sign-in settings, names and subscription packs differ.
public enum Brand: String, CaseIterable, Identifiable, Sendable {
    case peugeot, citroen, ds, opel, vauxhall

    public var id: String { rawValue }

    /// Key in the sign-in configs.
    public var configKey: String {
        switch self {
        case .peugeot: "MyPeugeot"
        case .citroen: "MyCitroen"
        case .ds: "MyDS"
        case .opel: "MyOpel"
        case .vauxhall: "MyVauxhall"
        }
    }

    public var display: String {
        switch self {
        case .peugeot: "Peugeot"
        case .citroen: "Citroën"
        case .ds: "DS"
        case .opel: "Opel"
        case .vauxhall: "Vauxhall"
        }
    }

    /// The brand's own app.
    public var app: String {
        switch self {
        case .peugeot: "MyPeugeot"
        case .citroen: "MyCitroën"
        case .ds: "MyDS"
        case .opel: "myOpel"
        case .vauxhall: "MyVauxhall"
        }
    }

    /// The subscription that gives remote charging and pre-conditioning (electric / plug-in cars).
    public var eRemotePack: String {
        switch self {
        case .peugeot: "Remote e-Controls (in the Connect ONE pack on new electric and plug-in hybrid cars; older cars need the e-Remote Control or Connect PLUS subscription)"
        case .citroen: "e-Remote Control (in the Connect ONE pack on new electric and plug-in hybrid cars; older cars need the e-Remote Control or Connect PLUS subscription)"
        case .ds: "e-Remote Control (in the Connect ONE pack on new electric and plug-in hybrid cars; older cars need the E-TENSE Remote Control or Connect PLUS subscription)"
        case .opel, .vauxhall: "e-Remote Control (Connect PLUS pack)"
        }
    }

    /// The subscription that gives lock/unlock, lights and horn.
    public var doorsPack: String { "Remote Control (Connect PLUS pack)" }

    public static func of(_ id: String?) -> Brand { Brand(rawValue: id ?? "") ?? .peugeot }

    public func subscriptionNotice() -> String {
        "What needs a subscription (decided by \(display), not by LionCar):\n" +
        "• Status, battery, range, trips and service: your \(app) account.\n" +
        "• Charging control and pre-heating (electric and plug-in hybrid cars): \(eRemotePack).\n" +
        "• Lock, unlock, lights and horn: \(doorsPack).\n" +
        "Which pack is included, and for how long, depends on the model, country and order date. Check and activate it in \(app); LionCar can't activate it for you."
    }
}

/// One brand + country's sign-in settings.
public struct BrandConfig: Sendable, Equatable {
    public let oauthURL: String
    public let realm: String
    public let scheme: String
    public let locale: String
    public let clientID: String
    public let clientSecret: String
    /// Lower-case country code used in the redirect address.
    public let culture: String

    public var basicToken: String { Data("\(clientID):\(clientSecret)".utf8).base64EncodedString() }
    public var redirectURI: String { "\(scheme)://oauth2redirect/\(culture)" }
}

public enum StellantisConfig {
    nonisolated(unsafe) private static var cache: JSON?

    private static func root() -> JSON {
        if let c = cache { return c }
        let j = JSONValue.parse(stellantisConfigsJSON) as? JSON ?? [:]
        cache = j
        return j
    }

    /// Countries the brand's sign-in is set up for, sorted.
    public static func countries(_ brand: Brand) -> [String] {
        (root().obj(brand.configKey, "configs") ?? [:]).keys.sorted()
    }

    /// Not every brand is available in every country: falls back to Norway, then Britain, then the first one listed.
    public static func load(_ brand: Brand, country: String) -> BrandConfig {
        let app = root().obj(brand.configKey) ?? [:]
        let cfgs = app.obj("configs") ?? [:]
        let cc = [country.uppercased(), "NO", "GB"].first { cfgs[$0] != nil } ?? cfgs.keys.sorted().first ?? "GB"
        let c = cfgs.obj(cc) ?? [:]
        return BrandConfig(
            oauthURL: app.optString("oauth_url"), realm: app.optString("realm"), scheme: app.optString("scheme"),
            locale: c.optString("locale"), clientID: c.optString("client_id"), clientSecret: c.optString("client_secret"),
            culture: cc.lowercased())
    }

    /// The custom URL schemes the sign-in pages redirect to (mymap, mymacsdk, …).
    public static var schemes: [String] { Brand.allCases.map { root().obj($0.configKey)?.optString("scheme") ?? "" } }
}
