import Foundation
import CoreLocation

struct DriveCoordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

extension DriveCoordinate {
    var clLocationCoordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
}

struct LockedRouteOptions: Codable, Equatable, Sendable {
    var avoidTolls: Bool
    var avoidHighways: Bool
}

struct LockedWaypoint: Codable, Equatable, Identifiable, Sendable {
    let id: String
    var name: String
    var coordinate: DriveCoordinate
    var required: Bool
    /// Vorgaben fuer die Strecke, die an diesem Punkt beginnt. `nil` erbt die
    /// allgemeinen Trip-Vorgaben.
    var optionsAfter: LockedRouteOptions?
}

struct ActiveRouteLock: Codable, Equatable, Identifiable, Sendable {
    enum Status: String, Codable, Sendable { case active, completed, cancelled }

    let id: UUID
    var title: String
    var destinationName: String
    var destination: DriveCoordinate
    var waypoints: [LockedWaypoint]
    var defaultOptions: LockedRouteOptions
    var corridorWidthMetres: Double
    var corridorPoints: [DriveCoordinate]?
    var visitedWaypointIDs: [String]?
    var status: Status
    var createdAt: Date
    var updatedAt: Date

    var isActive: Bool { status == .active }
}

extension ActiveRouteLock {
    /// Determines mandatory points already passed along the persisted route
    /// corridor. This prevents a restored trip from routing back to Croatia or
    /// Slovenia after a longer break farther north. The result is intentionally
    /// empty when the current position is not plausibly inside the corridor.
    func passedWaypointIDs(at current: DriveCoordinate) -> [String] {
        guard let corridorPoints, corridorPoints.count > 2 else { return [] }
        let currentLocation = CLLocation(latitude: current.latitude, longitude: current.longitude)
        guard let currentMatch = corridorPoints.enumerated().min(by: {
            currentLocation.distance(from: CLLocation(latitude: $0.element.latitude, longitude: $0.element.longitude)) <
            currentLocation.distance(from: CLLocation(latitude: $1.element.latitude, longitude: $1.element.longitude))
        }) else { return [] }
        let corridorDistance = currentLocation.distance(from: CLLocation(
            latitude: currentMatch.element.latitude, longitude: currentMatch.element.longitude))
        guard corridorDistance <= max(corridorWidthMetres * 2, 5_000) else { return [] }

        return waypoints.compactMap { waypoint in
            let point = CLLocation(latitude: waypoint.coordinate.latitude, longitude: waypoint.coordinate.longitude)
            guard let match = corridorPoints.enumerated().min(by: {
                point.distance(from: CLLocation(latitude: $0.element.latitude, longitude: $0.element.longitude)) <
                point.distance(from: CLLocation(latitude: $1.element.latitude, longitude: $1.element.longitude))
            }) else { return nil }
            // Keep the next corridor point active. A small index margin avoids
            // skipping a mandatory pass when GPS lies just beyond its sample.
            return match.offset < currentMatch.offset ? waypoint.id : nil
        }
    }

    /// Heimfahrt nach Hochheim am Main. Der Punkt liegt direkt auf der B109
    /// auf der Wurzenpasshoehe und erzwingt damit die Umfahrung des
    /// Karawankentunnels, ohne eine Ortsmitte als Zwischenziel anzufahren.
    static func hochheimViaWurzenpass(now: Date = Date()) -> ActiveRouteLock {
        ActiveRouteLock(
            id: UUID(), title: "Heimfahrt über Wurzenpass", destinationName: "Hochheim am Main",
            destination: .init(latitude: 50.0147, longitude: 8.3522),
            waypoints: [
                .init(id: "a1-dugopolje", name: "A1 Auffahrt Dugopolje",
                      coordinate: .init(latitude: 43.59603, longitude: 16.57081), required: true,
                      optionsAfter: .init(avoidTolls: false, avoidHighways: false)),
                .init(id: "wurzenpass-road", name: "Wurzenpass (B109)",
                      coordinate: .init(latitude: 46.521944, longitude: 13.7525), required: true,
                      optionsAfter: .init(avoidTolls: false, avoidHighways: false)),
                .init(id: "katschberg-b99", name: "Katschbergpass (B99)",
                      coordinate: .init(latitude: 47.0583, longitude: 13.6153), required: true,
                      optionsAfter: .init(avoidTolls: false, avoidHighways: true)),
                .init(id: "obertauern-b99", name: "Radstädter Tauernpass / Obertauern (B99)",
                      coordinate: .init(latitude: 47.2494, longitude: 13.5592), required: true,
                      optionsAfter: .init(avoidTolls: false, avoidHighways: false))
            ],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 8_000, corridorPoints: nil, visitedWaypointIDs: [],
            status: .active, createdAt: now, updatedAt: now
        )
    }

    /// Persistenter Urlaubskorridor nach Split: Slowenien ohne Autobahn,
    /// ab der kroatischen Grenze wieder mit Autobahn.
    static func croatiaSplit(now: Date = Date()) -> ActiveRouteLock {
        ActiveRouteLock(
            id: UUID(), title: "Kroatien", destinationName: "Split, Kroatien",
            destination: .init(latitude: 43.5081, longitude: 16.4402),
            waypoints: [
                .init(id: "sentilj", name: "Šentilj / Spielfeld",
                      coordinate: .init(latitude: 46.7006, longitude: 15.6350), required: true,
                      optionsAfter: .init(avoidTolls: true, avoidHighways: true)),
                .init(id: "macelj", name: "Macelj (kroatische Grenze)",
                      coordinate: .init(latitude: 46.1955, longitude: 15.6908), required: true,
                      optionsAfter: .init(avoidTolls: false, avoidHighways: false))
            ],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 8_000, corridorPoints: nil, visitedWaypointIDs: [],
            status: .active, createdAt: now, updatedAt: now
        )
    }
}

@MainActor
final class RouteLockStore: ObservableObject {
    static let shared = RouteLockStore()
    @Published private(set) var activeLock: ActiveRouteLock?

    private let defaults: UserDefaults
    private let key = "drive.activeRouteLock.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        activeLock = Self.decode(defaults.data(forKey: key))
    }

    func save(_ lock: ActiveRouteLock) {
        activeLock = lock
        if let data = try? JSONEncoder().encode(lock) { defaults.set(data, forKey: key) }
    }

    func update(_ change: (inout ActiveRouteLock) -> Void) {
        guard var lock = activeLock else { return }
        change(&lock)
        lock.updatedAt = Date()
        save(lock)
    }

    func finish(cancelled: Bool = false) {
        update { $0.status = cancelled ? .cancelled : .completed }
    }

    func clearFinished() {
        guard activeLock?.isActive != true else { return }
        activeLock = nil
        defaults.removeObject(forKey: key)
    }

    private static func decode(_ data: Data?) -> ActiveRouteLock? {
        guard let data, let lock = try? JSONDecoder().decode(ActiveRouteLock.self, from: data), lock.isActive else {
            return nil
        }
        return lock
    }
}
