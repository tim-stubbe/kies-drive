import Foundation
import CoreLocation

struct FuelStation: Codable, Identifiable, Hashable {
    let id: String
    let name: String
    let brand: String
    let street: String
    let place: String
    let lat: Double
    let lon: Double
    let price: Double
    let open: Bool?
    let distanceKm: Double

    enum CodingKeys: String, CodingKey {
        case id, name, brand, street, place, lat, lon, price, open
        case distanceKm = "distance_km"
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: lat, longitude: lon) }
    var subtitle: String { String(format: "%.3f € · %.1f km", price, distanceKm) }
}

struct FuelStationEnvelope: Decodable { let stations: [FuelStation] }

enum FuelKind: String, CaseIterable, Identifiable {
    case diesel, e5, e10, superplus
    var id: String { rawValue }
    var label: String {
        switch self {
        case .diesel: "Diesel"
        case .superplus: "Super Plus*"
        default: rawValue.uppercased()
        }
    }
    /// Tankerkönig (die von Kies genutzte Preisquelle) kennt keinen eigenen
    /// SuperPlus-Preis - nur Diesel/E5/E10. Als Näherung wird für SuperPlus
    /// der Super-(E5)-Preis abgefragt (Stern im Label weist darauf hin).
    var apiValue: String { self == .superplus ? "e5" : rawValue }
}

enum DriveMapAppearance: String, CaseIterable, Identifiable {
    case standard, hybrid
    var id: String { rawValue }
    var label: String {
        switch self {
        case .standard: "Standard"
        case .hybrid: "Hybrid"
        }
    }
}

struct DriveChatResponse: Decodable { let reply: String? }

struct SpeedLimitResult: Decodable {
    let maxspeed: Int?
    let unlimited: Bool
}

struct SpeedLimitEnvelope: Decodable { let limits: [SpeedLimitResult] }

struct RecentDestination: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double
    let lastUsedAt: Date

    init(id: UUID = UUID(), name: String, subtitle: String, latitude: Double,
         longitude: Double, lastUsedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
        self.lastUsedAt = lastUsedAt
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

enum RecentDestinationStore {
    private static let key = "drive.recentDestinations.v1"
    static let maximumCount = 8

    static func load(defaults: UserDefaults = .standard) -> [RecentDestination] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return ((try? JSONDecoder().decode([RecentDestination].self, from: data)) ?? [])
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    @discardableResult
    static func record(_ destination: RecentDestination, defaults: UserDefaults = .standard) -> [RecentDestination] {
        var values = load(defaults: defaults)
        values.removeAll {
            abs($0.latitude - destination.latitude) < 0.00001 &&
            abs($0.longitude - destination.longitude) < 0.00001
        }
        values.insert(destination, at: 0)
        values = Array(values.prefix(maximumCount))
        if let data = try? JSONEncoder().encode(values) { defaults.set(data, forKey: key) }
        return values
    }

    static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}

struct DriveFavorite: Codable, Identifiable, Equatable {
    let id: UUID
    let name: String
    let subtitle: String
    let latitude: Double
    let longitude: Double

    init(id: UUID = UUID(), name: String, subtitle: String, latitude: Double, longitude: Double) {
        self.id = id
        self.name = name
        self.subtitle = subtitle
        self.latitude = latitude
        self.longitude = longitude
    }

    var coordinate: CLLocationCoordinate2D { .init(latitude: latitude, longitude: longitude) }
}

enum DriveFavoriteStore {
    private static let key = "drive.favoriteDestinations"

    static func load(defaults: UserDefaults = .standard) -> [DriveFavorite] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DriveFavorite].self, from: data)) ?? []
    }

    static func save(_ favorites: [DriveFavorite], defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(favorites) else { return }
        defaults.set(data, forKey: key)
    }
}

enum DriveDiagnosticKind: String, Codable {
    case routeCalculated, navigationStarted, rerouteRequested, rerouteSucceeded, rerouteFailed
    case arrivalReached, locationRejected, maneuverAnnounced, maneuverFinalCueMissed
}

struct DriveDiagnosticEvent: Codable, Identifiable, Equatable {
    let id: UUID
    let kind: DriveDiagnosticKind
    let date: Date
    let detail: String

    init(id: UUID = UUID(), kind: DriveDiagnosticKind, date: Date = Date(), detail: String) {
        self.id = id
        self.kind = kind
        self.date = date
        self.detail = detail
    }
}

enum DriveDiagnosticStore {
    private static let key = "drive.diagnostics.v1"
    private static let maximumCount = 100

    static func load(defaults: UserDefaults = .standard) -> [DriveDiagnosticEvent] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DriveDiagnosticEvent].self, from: data)) ?? []
    }

    static func append(_ kind: DriveDiagnosticKind, detail: String, defaults: UserDefaults = .standard) {
        var events = load(defaults: defaults)
        events.append(.init(kind: kind, detail: detail))
        events = Array(events.suffix(maximumCount))
        if let data = try? JSONEncoder().encode(events) { defaults.set(data, forKey: key) }
    }

    static func clear(defaults: UserDefaults = .standard) { defaults.removeObject(forKey: key) }
}
