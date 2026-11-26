import Foundation

enum MildHybridDetection: Equatable {
    case vehicleMetadata, modelName, otherPowertrain, insufficientMetadata
    var detected: Bool { self == .vehicleMetadata || self == .modelName }
}

/// A car on the account. Port of LionFlow's `Vehicle` (StellantisApi.kt), including its powertrain detection.
public struct Vehicle: Equatable, Identifiable, Sendable {
    public let id: String
    public let vin: String
    public var motorization: String
    public var brand: String
    public var pictureURL: String?
    public var maintenanceHref: String?
    public var modelLabel: String?
    var legacyLabel: String?

    public init(id: String, vin: String, motorization: String, brand: String, pictureURL: String? = nil,
                maintenanceHref: String? = nil, modelLabel: String? = nil, legacyLabel: String? = nil) {
        self.id = id; self.vin = vin; self.motorization = motorization; self.brand = brand
        self.pictureURL = pictureURL; self.maintenanceHref = maintenanceHref
        self.modelLabel = modelLabel; self.legacyLabel = legacyLabel
    }

    private var powertrain: String { motorization.filter { $0.isLetter || $0.isNumber }.lowercased() }

    private var labels: [String] {
        [modelLabel, legacyLabel].compactMap { $0 }.map {
            $0.lowercased().replacingOccurrences(of: #"[^\p{L}\p{N}]+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespaces)
        }
    }

    private var reportsPlugInHybrid: Bool {
        Self.plugIn.contains(powertrain) ||
            (Self.ambiguous.contains(powertrain) && labels.contains { Self.matches(Self.plugInModel, $0) })
    }

    var needsBranding: Bool {
        (brand.isEmpty || brand.caseInsensitiveCompare("Peugeot") == .orderedSame) && mildHybridDetection == .insufficientMetadata
    }

    public var reportsMildHybrid: Bool { mildHybridDetection.detected }

    public func isMildHybrid(override: Bool?) -> Bool { override ?? reportsMildHybrid }

    /// True when the server's data can't tell whether this hybrid is a 48 V mild hybrid (the user can say so).
    public var mildHybridUncertain: Bool { mildHybridDetection == .insufficientMetadata && Self.genericHybrid.contains(powertrain) }

    public func kind(override: Bool?) -> String {
        if isMildHybrid(override: override) { return "48 V mild hybrid" }
        if reportsPlugInHybrid { return "Plug-in hybrid" }
        if Self.genericHybrid.contains(powertrain) || reportsMildHybrid { return "Hybrid (type unknown)" }
        if ["electric", "bev", "batteryelectricvehicle"].contains(powertrain) { return "Electric" }
        if ["thermal", "thermic", "fuel", "petrol", "gasoline", "diesel", "ice"].contains(powertrain) { return "Petrol / diesel" }
        return motorization.isEmpty ? "Car" : motorization
    }

    public func parseStatus(_ status: JSON, maintenance: JSON?, override: Bool?) -> VehicleStatus {
        // Off (override false) opts out of mild-hybrid handling and restores the standard status parser.
        let hasFuel = status.objects("energies").contains { $0.optString("type") == "Fuel" }
        let needsEvidence = override == nil && !reportsPlugInHybrid &&
            (Self.genericHybrid.contains(powertrain) || (Self.ambiguous.contains(powertrain) && hasFuel))
        return VehicleStatus.parse(status, maintenance: maintenance, mildHybrid: isMildHybrid(override: override),
                                   requireChargingEvidence: needsEvidence)
    }

    var mildHybridDetection: MildHybridDetection {
        let p = powertrain
        if Self.mildHybrid.contains(p) { return .vehicleMetadata }
        if Self.other.contains(p) || Self.plugIn.contains(p) { return .otherPowertrain }
        let labels = labels
        if labels.contains(where: { Self.matches(Self.otherModel, $0) }) { return .otherPowertrain }
        // The complete Peugeot model and transmission distinguish this version from a generic Hybrid.
        if Self.ambiguous.contains(p) && brand.caseInsensitiveCompare("Peugeot") == .orderedSame &&
            labels.contains(where: { Self.matches(Self.hybrid208, $0) }) { return .modelName }
        return .insufficientMetadata
    }

    public func toJSON() -> JSON {
        var j: JSON = ["id": id, "vin": vin, "motorization": motorization, "brand": brand,
                       "picture": pictureURL ?? "", "maintenance": maintenanceHref ?? ""]
        if let modelLabel { j["modelLabel"] = modelLabel }
        if let legacyLabel { j["legacyLabel"] = legacyLabel }
        return j
    }

    public static func fromJSON(_ j: JSON) -> Vehicle? {
        guard let id = j.str("id"), let vin = j.str("vin") else { return nil }
        return Vehicle(id: id, vin: vin, motorization: metadata(j, "motorization") ?? "", brand: metadata(j, "brand") ?? "",
                       pictureURL: j.str("picture").flatMap { $0.isEmpty ? nil : $0 },
                       maintenanceHref: j.str("maintenance").flatMap { $0.isEmpty ? nil : $0 },
                       modelLabel: metadata(j, "modelLabel"), legacyLabel: metadata(j, "legacyLabel"))
    }

    /// A car from the vehicles list.
    public static func fromAPI(_ j: JSON, defaultBrand: String) -> Vehicle? {
        guard let id = j.str("id"), let vin = j.str("vin") else { return nil }
        let pics = (j["pictures"] as? [Any])?.compactMap { $0 as? String } ?? []
        return Vehicle(id: id, vin: vin, motorization: "", brand: defaultBrand,
                       pictureURL: pics.first.flatMap { $0.isEmpty ? nil : $0 },
                       maintenanceHref: j.obj("_links", "maintenance")?.str("href")).withBranding(j)
    }

    /// Adds details from the single-car answer, if it is for this car.
    public func withBrandingDetail(_ j: JSON?) -> Vehicle {
        guard let j else { return self }
        if let i = Self.metadata(j, "id"), i != id { return self }
        if let v = Self.metadata(j, "vin"), v != vin { return self }
        return withBranding(j)
    }

    private func withBranding(_ j: JSON) -> Vehicle {
        let branding = j.obj("_embedded", "extension", "branding")
        let brandingLabel = branding.flatMap { Self.metadata($0, "label") }
        let label = Self.metadata(j, "label")
        var v = self
        v.motorization = Self.metadata(j, "motorization") ?? motorization
        v.brand = branding.flatMap { Self.metadata($0, "brand") } ?? Self.metadata(j, "brand") ?? brand
        v.modelLabel = brandingLabel ?? label ?? modelLabel
        // The plain label is kept as a second name when the branding label differs from it; with no label at all,
        // the old one stays.
        v.legacyLabel = (brandingLabel == nil && label == nil) ? legacyLabel : (brandingLabel != nil && label != brandingLabel ? label : nil)
        return v
    }

    private static func metadata(_ j: JSON, _ key: String) -> String? {
        guard let s = (j[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty else { return nil }
        return s
    }

    private static func matches(_ pattern: String, _ s: String) -> Bool { s.range(of: pattern, options: .regularExpression) != nil }

    private static let mildHybrid: Set<String> = ["mhev", "mhev48v", "48vmhev", "mildhybrid", "mildhybridelectricvehicle",
                                                  "48vmildhybrid", "mildhybrid48v", "48vhybrid", "hybrid48v"]
    private static let plugIn: Set<String> = ["phev", "pluginhybrid", "pluginhybridelectricvehicle"]
    private static let other: Set<String> = ["bev", "electric", "batteryelectricvehicle", "thermic", "thermal", "fuel",
                                             "petrol", "gasoline", "diesel", "ice", "hydrogen"]
    private static let genericHybrid: Set<String> = ["hybrid", "hev", "hybridelectricvehicle", "fullhybrid"]
    private static let ambiguous: Set<String> = genericHybrid.union(["", "unknown"])
    private static let otherModel = #"\b(?:phev|bev|plug ?in|electric|e ?208)\b"#
    private static let plugInModel = #"\b(?:phev|plug ?in hybrid|hybrid plug ?in)\b"#
    private static let hybrid208 = #"\b208(?: (?![0-9]{3,4}\b)[\p{L}\p{N}]+)*? hybrid 100 e ?dcs ?6\b"#
}
