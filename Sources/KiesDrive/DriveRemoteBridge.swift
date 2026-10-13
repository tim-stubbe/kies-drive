import Foundation
import CoreLocation
import MapKit

struct DriveRemoteState: Encodable {
    struct Position: Encodable { let latitude: Double; let longitude: Double; let accuracyMetres: Double }
    struct Route: Encodable { let destination: String; let distanceMetres: Double; let travelTimeSeconds: Double }
    struct Maneuver: Encodable {
        let instruction: String
        let distanceMetres: Double?

        enum CodingKeys: String, CodingKey {
            case instruction
            case distanceMetres = "distance_metres"
        }
    }

    let location: Position?
    let headingDegrees: Double?
    let speedKmh: Double?
    let activeRoute: Route?
    let nextManeuver: Maneuver?
    let routeLock: ActiveRouteLock?
    let navigationActive: Bool
    let recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case location
        case headingDegrees = "heading_degrees"
        case speedKmh = "speed_kmh"
        case activeRoute = "active_route"
        case nextManeuver = "next_maneuver"
        case routeLock = "route_lock"
        case navigationActive = "navigation_active"
        case recordedAt = "recorded_at"
    }
}

struct DriveRemoteCommand: Decodable {
    let id: Int
    let command: String
    let arguments: [String: JSONValue]
}

struct DriveRemoteCommandEnvelope: Decodable { let commands: [DriveRemoteCommand] }

enum JSONValue: Codable {
    case string(String), number(Double), bool(Bool), array([JSONValue]), object([String: JSONValue]), null

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if c.decodeNil() { self = .null }
        else if let v = try? c.decode(Bool.self) { self = .bool(v) }
        else if let v = try? c.decode(Double.self) { self = .number(v) }
        else if let v = try? c.decode(String.self) { self = .string(v) }
        else if let v = try? c.decode([JSONValue].self) { self = .array(v) }
        else { self = .object(try c.decode([String: JSONValue].self)) }
    }
    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        switch self {
        case .string(let v): try c.encode(v); case .number(let v): try c.encode(v)
        case .bool(let v): try c.encode(v); case .array(let v): try c.encode(v)
        case .object(let v): try c.encode(v); case .null: try c.encodeNil()
        }
    }
    var string: String? { if case .string(let value) = self { value } else { nil } }
    var number: Double? { if case .number(let value) = self { value } else { nil } }
    var bool: Bool? { if case .bool(let value) = self { value } else { nil } }
    var array: [JSONValue]? { if case .array(let value) = self { value } else { nil } }
    var object: [String: JSONValue]? { if case .object(let value) = self { value } else { nil } }
}

enum DriveRemoteSyncPolicy {
    static func interval(navigationActive: Bool) -> TimeInterval { navigationActive ? 5 : 15 }

    static func accepts(_ location: CLLocation) -> Bool {
        location.horizontalAccuracy >= 0 && location.horizontalAccuracy <= 100 &&
        abs(location.timestamp.timeIntervalSinceNow) <= 30
    }
}

@MainActor
final class DriveRemoteBridge {
    static let shared = DriveRemoteBridge()
    private var lastSync = Date.distantPast
    private var handledCommandIDs: Set<Int> = []
    private var syncing = false
    private var pollingTask: Task<Void, Never>?

    func start() {
        guard pollingTask == nil else { return }
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                let planner = RoutePlanner.shared
                if DriveSettings.shared.isReady,
                   let location = LocationService.shared.location,
                   DriveRemoteSyncPolicy.accepts(location) {
                    await self.sync(location: location)
                }
                let interval = DriveRemoteSyncPolicy.interval(navigationActive: planner.isNavigating)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func sync(location: CLLocation) async {
        let interval = DriveRemoteSyncPolicy.interval(navigationActive: RoutePlanner.shared.isNavigating)
        guard DriveSettings.shared.isReady, DriveRemoteSyncPolicy.accepts(location), !syncing,
              Date().timeIntervalSince(lastSync) >= interval else { return }
        syncing = true
        defer { syncing = false; lastSync = Date() }
        let planner = RoutePlanner.shared
        let state = DriveRemoteState(
            location: .init(latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude,
                            accuracyMetres: location.horizontalAccuracy),
            headingDegrees: NavigationMotionPolicy.reliableCourse(for: location),
            speedKmh: NavigationMotionPolicy.reliableSpeed(for: location).map { $0 * 3.6 },
            activeRoute: planner.legs.isEmpty ? nil : .init(
                destination: planner.destination?.name ?? planner.destinationText,
                distanceMetres: planner.remainingDistanceMetres > 0 ? planner.remainingDistanceMetres : planner.totalDistance,
                travelTimeSeconds: planner.remainingTravelTime > 0 ? planner.remainingTravelTime : planner.totalTravelTime),
            nextManeuver: (planner.nextManeuverInstruction ?? planner.nextInstruction).map {
                .init(instruction: $0, distanceMetres: planner.nextManeuverDistance)
            },
            routeLock: planner.activeRouteLock,
            navigationActive: planner.isNavigating, recordedAt: Date()
        )
        do {
            try await DriveAPI.publishRemoteState(state)
            for command in try await DriveAPI.remoteCommands() where !handledCommandIDs.contains(command.id) {
                handledCommandIDs.insert(command.id)
                if handledCommandIDs.count > 256 {
                    handledCommandIDs = Set(handledCommandIDs.sorted().suffix(128))
                }
                do {
                    try await execute(command, at: location.coordinate)
                    try await DriveAPI.completeRemoteCommand(command.id, ok: true, message: "In Kies Drive ausgeführt")
                } catch {
                    try? await DriveAPI.completeRemoteCommand(command.id, ok: false, message: error.localizedDescription)
                }
            }
        } catch {
            // Navigation bleibt absichtlich unbeeinflusst, wenn die Remote-
            // Schnittstelle oder der TrueNAS nicht erreichbar ist.
        }
    }

    private func execute(_ command: DriveRemoteCommand, at current: CLLocationCoordinate2D) async throws {
        let planner = RoutePlanner.shared
        let settings = DriveSettings.shared
        switch command.command {
        case "restore_route":
            await planner.restoreActiveTrip(from: current, settings: settings)
        case "set_route_options":
            if let value = command.arguments["avoid_tolls"]?.bool { settings.avoidTolls = value }
            if let value = command.arguments["avoid_highways"]?.bool { settings.avoidHighways = value }
            planner.updateLockedRouteOptions(
                waypointID: command.arguments["waypoint_id"]?.string,
                avoidTolls: command.arguments["avoid_tolls"]?.bool,
                avoidHighways: command.arguments["avoid_highways"]?.bool)
            await planner.calculate(from: current, settings: settings)
        case "set_destination":
            let item: MKMapItem
            if let lat = command.arguments["latitude"]?.number,
               let lon = command.arguments["longitude"]?.number {
                item = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: lat, longitude: lon)))
                item.name = command.arguments["query"]?.string ?? "Remote-Ziel"
            } else if let query = command.arguments["query"]?.string {
                planner.destinationText = query
                await planner.searchDestination(near: current)
                guard let found = planner.suggestions.first else { throw DriveRemoteError.destinationNotFound }
                item = found
            } else { throw DriveRemoteError.destinationNotFound }
            let waypoints = command.arguments["required_waypoints"]?.array?.compactMap { value -> LockedWaypoint? in
                guard let item = value.object,
                      let latitude = item["latitude"]?.number,
                      let longitude = item["longitude"]?.number else { return nil }
                let segment = item["options_after"]?.object
                let options = segment.map {
                    LockedRouteOptions(avoidTolls: $0["avoid_tolls"]?.bool ?? settings.avoidTolls,
                                       avoidHighways: $0["avoid_highways"]?.bool ?? settings.avoidHighways)
                }
                return LockedWaypoint(
                    id: item["id"]?.string ?? UUID().uuidString,
                    name: item["name"]?.string ?? "Pflicht-Zwischenpunkt",
                    coordinate: .init(latitude: latitude, longitude: longitude),
                    required: true, optionsAfter: options)
            } ?? []
            guard await planner.activateDestination(item, from: current, settings: settings,
                                                    requiredWaypoints: waypoints) else {
                throw DriveRemoteError.routeUnavailable
            }
        case "add_route_stop":
            guard let query = command.arguments["query"]?.string else { throw DriveRemoteError.destinationNotFound }
            await planner.searchAlongRoute(query)
            guard let item = planner.routeSearchResults.first else { throw DriveRemoteError.destinationNotFound }
            await planner.addRouteStop(item, from: current, settings: settings)
        default:
            throw DriveRemoteError.unknownCommand
        }
    }
}

enum DriveRemoteError: LocalizedError {
    case destinationNotFound, routeUnavailable, unknownCommand
    var errorDescription: String? {
        switch self {
        case .destinationNotFound: "Ziel konnte nicht gefunden werden."
        case .routeUnavailable: "Für dieses Ziel konnte keine gültige Route berechnet werden."
        case .unknownCommand: "Unbekannter Remote-Befehl."
        }
    }
}
