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
