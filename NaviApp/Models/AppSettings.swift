import Foundation
import NaviCore

/// User preferences, persisted in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    private let defaults = UserDefaults.standard

    @Published var units: UnitSystem { didSet { defaults.set(units.rawValue, forKey: "units") } }
    @Published var etaBasis: ETABasis { didSet { defaults.set(etaBasis.rawValue, forKey: "etaBasis") } }
    @Published var includeVillages: Bool { didSet { defaults.set(includeVillages, forKey: "includeVillages") } }
    @Published var includeAbeamTowns: Bool { didSet { defaults.set(includeAbeamTowns, forKey: "includeAbeamTowns") } }
    @Published var keepScreenOn: Bool { didSet { defaults.set(keepScreenOn, forKey: "keepScreenOn") } }
    /// Simulator cruise speed, m/s.
    @Published var simulatorSpeed: Double { didSet { defaults.set(simulatorSpeed, forKey: "simulatorSpeed") } }

    private init() {
        units = UnitSystem(rawValue: defaults.string(forKey: "units") ?? "") ?? .imperial
        etaBasis = ETABasis(rawValue: defaults.string(forKey: "etaBasis") ?? "") ?? .average
        includeVillages = defaults.object(forKey: "includeVillages") as? Bool ?? false
        includeAbeamTowns = defaults.object(forKey: "includeAbeamTowns") as? Bool ?? true
        keepScreenOn = defaults.object(forKey: "keepScreenOn") as? Bool ?? true
        simulatorSpeed = defaults.object(forKey: "simulatorSpeed") as? Double ?? 29 // ~65 mph
    }
}
