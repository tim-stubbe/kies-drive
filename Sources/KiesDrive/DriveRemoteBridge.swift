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
    /// Public trip-lock view for MCP. The dense corridor polyline remains
    /// local because it is navigation implementation data, not useful remote
    /// context. Omitting it keeps holiday-route updates small and reliable on
    /// mobile connections while retaining every mandatory stop and rule.
    struct RouteLock: Encodable {
        let id: UUID
        let title: String
        let destinationName: String
        let destination: DriveCoordinate
        let waypoints: [LockedWaypoint]
        let defaultOptions: LockedRouteOptions
        let visitedWaypointIDs: [String]
        let lastRouteProgress: Double?
        let status: ActiveRouteLock.Status
        let createdAt: Date
        let updatedAt: Date

        init(_ lock: ActiveRouteLock) {
            id = lock.id
            title = lock.title
            destinationName = lock.destinationName
            destination = lock.destination
            waypoints = lock.waypoints
            defaultOptions = lock.defaultOptions
            visitedWaypointIDs = lock.visitedWaypointIDs ?? []
            lastRouteProgress = lock.lastRouteProgress
            status = lock.status
            createdAt = lock.createdAt
            updatedAt = lock.updatedAt
        }
    }

    let location: Position?
    let headingDegrees: Double?
    let speedKmh: Double?
    let activeRoute: Route?
    let nextManeuver: Maneuver?
    let routeLock: RouteLock?
    let navigationActive: Bool
    let onRoute: Bool?
    let rerouting: Bool
    let offlineGuidanceActive: Bool
    let recordedAt: Date

    enum CodingKeys: String, CodingKey {
        case location
        case headingDegrees = "heading_degrees"
        case speedKmh = "speed_kmh"
        case activeRoute = "active_route"
        case nextManeuver = "next_maneuver"
        case routeLock = "route_lock"
        case navigationActive = "navigation_active"
        case onRoute = "on_route"
        case rerouting
        case offlineGuidanceActive = "offline_guidance_active"
        case recordedAt = "recorded_at"
    }
}

struct DriveRemoteCommand: Decodable {
    let id: Int
    let command: String
    let arguments: [String: JSONValue]
    let expiresAt: String?

    enum CodingKeys: String, CodingKey {
        case id, command, arguments
        case expiresAt = "expires_at"
    }
}

struct DriveRemoteCommandEnvelope: Decodable { let commands: [DriveRemoteCommand] }

struct DriveRemoteCommandResult: Codable, Equatable {
    let ok: Bool
    let message: String
}

struct DriveRemoteCommandJournal {
    let defaults: UserDefaults
    var key = "drive.remoteCommandJournal.v1"
    var maximumCount = 128

    static let live = DriveRemoteCommandJournal(defaults: .standard)

    func load() -> [Int: DriveRemoteCommandResult] {
        guard let data = defaults.data(forKey: key) else { return [:] }
        return (try? JSONDecoder().decode([Int: DriveRemoteCommandResult].self, from: data)) ?? [:]
    }

    func save(_ values: [Int: DriveRemoteCommandResult]) {
        var retained: [Int: DriveRemoteCommandResult] = [:]
        for commandID in values.keys.sorted().suffix(max(0, maximumCount)) {
            retained[commandID] = values[commandID]
        }
        guard let data = try? JSONEncoder().encode(retained) else { return }
        defaults.set(data, forKey: key)
    }
}

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

enum DriveRemoteLocationRefreshPolicy {
    static let minimumCheckInterval: TimeInterval = 15

    static func mayCheck(lastCheck: Date?, now: Date = Date()) -> Bool {
        guard let lastCheck else { return true }
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed >= minimumCheckInterval
    }
}

enum DriveRemoteRouteVisibilityPolicy {
    static func hasRoute(liveLegCount: Int, offlineGuidanceActive: Bool) -> Bool {
        liveLegCount > 0 || offlineGuidanceActive
    }
}

enum DriveRemoteCommandExpiryPolicy {
    static func isExpired(_ expiresAt: String?, now: Date = Date()) -> Bool {
        guard let expiresAt,
              let date = ISO8601DateFormatter.remoteCommand.date(from: expiresAt) else {
            // Preserve compatibility with an older standalone server. New
            // servers still expire pending commands before returning them.
            return false
        }
        return now >= date
    }
}

enum DriveRemoteCoordinatePolicy {
    static func isValid(latitude: Double, longitude: Double) -> Bool {
        latitude.isFinite && longitude.isFinite &&
            (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

enum DriveRemoteArgumentPolicy {
    static func validOptionalBool(_ arguments: [String: JSONValue], key: String) -> Bool {
        arguments[key] == nil || arguments[key]?.bool != nil
    }

    static func validOptionalString(_ arguments: [String: JSONValue], key: String) -> Bool {
        arguments[key] == nil || arguments[key]?.string != nil
    }

    static func validOptionalArray(_ arguments: [String: JSONValue], key: String) -> Bool {
        arguments[key] == nil || arguments[key]?.array != nil
    }
}

@MainActor
final class DriveRemoteBridge {
    static let shared = DriveRemoteBridge()
    private var lastSync = Date.distantPast
    private let commandJournal = DriveRemoteCommandJournal.live
    private var commandResults = DriveRemoteCommandJournal.live.load()
    private var syncing = false
    private var checkingForRemoteWork = false
    private var lastRemoteWorkCheck: Date?
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
                } else if DriveSettings.shared.isReady {
                    await self.requestFreshLocationIfRemoteWorkIsPending()
                }
                let interval = DriveRemoteSyncPolicy.interval(navigationActive: planner.isNavigating)
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    private func requestFreshLocationIfRemoteWorkIsPending() async {
        guard !checkingForRemoteWork,
              DriveRemoteLocationRefreshPolicy.mayCheck(lastCheck: lastRemoteWorkCheck) else {
            return
        }
        checkingForRemoteWork = true
        lastRemoteWorkCheck = Date()
        defer { checkingForRemoteWork = false }
        do {
            if !(try await DriveAPI.remoteCommands()).isEmpty {
                LocationService.shared.requestFreshLocationForRemoteCommand()
            }
        } catch {
            // Remote availability never changes local navigation behaviour.
        }
    }

    func sync(location: CLLocation) async {
        let interval = DriveRemoteSyncPolicy.interval(navigationActive: RoutePlanner.shared.isNavigating)
        guard DriveSettings.shared.isReady, DriveRemoteSyncPolicy.accepts(location), !syncing,
              Date().timeIntervalSince(lastSync) >= interval else { return }
        syncing = true
        defer { syncing = false; lastSync = Date() }
        let planner = RoutePlanner.shared
        let hasRemoteRoute = DriveRemoteRouteVisibilityPolicy.hasRoute(
            liveLegCount: planner.legs.count,
            offlineGuidanceActive: planner.isUsingOfflineGuidance
        )
        let state = DriveRemoteState(
            location: .init(latitude: location.coordinate.latitude,
                            longitude: location.coordinate.longitude,
                            accuracyMetres: location.horizontalAccuracy),
            headingDegrees: NavigationMotionPolicy.reliableCourse(for: location),
            speedKmh: NavigationMotionPolicy.reliableSpeed(for: location).map { $0 * 3.6 },
            activeRoute: hasRemoteRoute ? .init(
                destination: planner.destination?.name ?? planner.destinationText,
                distanceMetres: planner.remainingDistanceMetres > 0 ? planner.remainingDistanceMetres : planner.totalDistance,
                travelTimeSeconds: planner.remainingTravelTime > 0 ? planner.remainingTravelTime : planner.totalTravelTime
            ) : nil,
            nextManeuver: planner.isManeuverGuidanceReliable
                ? (planner.nextManeuverInstruction ?? planner.nextInstruction).map {
                    .init(instruction: $0, distanceMetres: planner.nextManeuverDistance)
                } : nil,
            routeLock: planner.activeRouteLock.map(DriveRemoteState.RouteLock.init),
            navigationActive: planner.isNavigating,
            onRoute: planner.isNavigating ? planner.isManeuverGuidanceReliable : nil,
            rerouting: planner.isRecalculating,
            offlineGuidanceActive: planner.isUsingOfflineGuidance,
            recordedAt: Date()
        )
        do {
            try await DriveAPI.publishRemoteState(state)
            for command in try await DriveAPI.remoteCommands() {
                let result: DriveRemoteCommandResult
                if let recorded = commandResults[command.id] {
                    // The local side effect already happened. Only retry the
                    // lost server acknowledgement; never execute navigation
                    // mutations twice after a radio drop or app restart.
                    result = recorded
                } else if DriveRemoteCommandExpiryPolicy.isExpired(command.expiresAt) {
                    result = .init(
                        ok: false,
                        message: "Der Remote-Befehl ist abgelaufen und wurde nicht ausgeführt."
                    )
                    commandResults[command.id] = result
                    commandJournal.save(commandResults)
                } else {
                    do {
                        try await execute(command, at: location.coordinate)
                        result = .init(ok: true, message: "In Kies Drive ausgeführt")
                    } catch {
                        result = .init(ok: false, message: error.localizedDescription)
                    }
                    commandResults[command.id] = result
                    commandJournal.save(commandResults)
                }
                try await DriveAPI.completeRemoteCommand(
                    command.id, ok: result.ok, message: result.message
                )
                commandResults.removeValue(forKey: command.id)
                commandJournal.save(commandResults)
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
            guard await planner.restoreActiveTrip(from: current, settings: settings) else {
                throw DriveRemoteError.routeUnavailable
            }
        case "set_route_options":
            guard DriveRemoteArgumentPolicy.validOptionalString(
                    command.arguments, key: "waypoint_id"
                  ), DriveRemoteArgumentPolicy.validOptionalBool(
                    command.arguments, key: "avoid_tolls"
                  ), DriveRemoteArgumentPolicy.validOptionalBool(
                    command.arguments, key: "avoid_highways"
                  ), command.arguments["avoid_tolls"] != nil ||
                    command.arguments["avoid_highways"] != nil else {
                throw DriveRemoteError.invalidCommandArguments
            }
            guard await planner.updateRouteOptionsAndRecalculate(
                waypointID: command.arguments["waypoint_id"]?.string,
                avoidTolls: command.arguments["avoid_tolls"]?.bool,
                avoidHighways: command.arguments["avoid_highways"]?.bool,
                from: current, settings: settings
            ) else {
                throw DriveRemoteError.routeUnavailable
            }
        case "set_destination":
            let item: MKMapItem
            if command.arguments["latitude"] != nil || command.arguments["longitude"] != nil {
                guard let lat = command.arguments["latitude"]?.number,
                      let lon = command.arguments["longitude"]?.number,
                      DriveRemoteCoordinatePolicy.isValid(
                        latitude: lat, longitude: lon
                      ) else { throw DriveRemoteError.invalidCommandArguments }
                item = MKMapItem(placemark: MKPlacemark(coordinate: .init(latitude: lat, longitude: lon)))
                item.name = command.arguments["query"]?.string ?? "Remote-Ziel"
            } else if let query = command.arguments["query"]?.string {
                planner.destinationText = query
                await planner.searchDestination(near: current)
                guard let found = planner.suggestions.first else { throw DriveRemoteError.destinationNotFound }
                item = found
            } else { throw DriveRemoteError.destinationNotFound }
            guard DriveRemoteArgumentPolicy.validOptionalArray(
                command.arguments, key: "required_waypoints"
            ) else { throw DriveRemoteError.invalidCommandArguments }
            var waypoints: [LockedWaypoint] = []
            for value in command.arguments["required_waypoints"]?.array ?? [] {
                guard let waypoint = value.object,
                      let latitude = waypoint["latitude"]?.number,
                      let longitude = waypoint["longitude"]?.number,
                      DriveRemoteCoordinatePolicy.isValid(
                        latitude: latitude, longitude: longitude
                      ) else {
                    // Required means required: never silently drop a malformed
                    // remote stop and calculate a materially different trip.
                    throw DriveRemoteError.invalidCommandArguments
                }
                let options: LockedRouteOptions?
                if let rawOptions = waypoint["options_after"] {
                    guard let segment = rawOptions.object,
                          DriveRemoteArgumentPolicy.validOptionalBool(
                            segment, key: "avoid_tolls"
                          ), DriveRemoteArgumentPolicy.validOptionalBool(
                            segment, key: "avoid_highways"
                          ) else { throw DriveRemoteError.invalidCommandArguments }
                    options = LockedRouteOptions(
                        avoidTolls: segment["avoid_tolls"]?.bool ?? settings.avoidTolls,
                        avoidHighways: segment["avoid_highways"]?.bool ?? settings.avoidHighways
                    )
                } else {
                    options = nil
                }
                waypoints.append(LockedWaypoint(
                    id: waypoint["id"]?.string ?? UUID().uuidString,
                    name: waypoint["name"]?.string ?? "Pflicht-Zwischenpunkt",
                    coordinate: .init(latitude: latitude, longitude: longitude),
                    required: true, optionsAfter: options
                ))
            }
            guard await planner.activateDestination(item, from: current, settings: settings,
                                                    requiredWaypoints: waypoints) else {
                throw DriveRemoteError.routeUnavailable
            }
        case "add_route_stop":
            guard let query = command.arguments["query"]?.string else { throw DriveRemoteError.destinationNotFound }
            await planner.searchAlongRoute(query)
            guard let result = planner.routeSearchResults.first else { throw DriveRemoteError.destinationNotFound }
            guard await planner.addRouteStop(
                result.mapItem, from: current, settings: settings,
                knownRouteProgress: result.routeProgress,
                expectedRouteGeneration: result.routeGeneration
            ) else {
                throw DriveRemoteError.routeUnavailable
            }
        default:
            throw DriveRemoteError.unknownCommand
        }
    }
}

enum DriveRemoteError: LocalizedError {
    case destinationNotFound, invalidCommandArguments, routeUnavailable, unknownCommand
    var errorDescription: String? {
        switch self {
        case .destinationNotFound: "Ziel konnte nicht gefunden werden."
        case .invalidCommandArguments: "Der Remote-Befehl enthält ungültige Pflichtpunkte."
        case .routeUnavailable: "Für dieses Ziel konnte keine gültige Route berechnet werden."
        case .unknownCommand: "Unbekannter Remote-Befehl."
        }
    }
}

private extension ISO8601DateFormatter {
    static let remoteCommand: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
