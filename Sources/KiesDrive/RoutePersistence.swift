import Foundation
import CoreLocation
import MapKit

struct DriveCoordinate: Codable, Equatable, Sendable {
    let latitude: Double
    let longitude: Double
}

extension DriveCoordinate {
    var clLocationCoordinate: CLLocationCoordinate2D {
        .init(latitude: latitude, longitude: longitude)
    }
}

enum RouteWaypointVisitPolicy {
    /// Only the first remaining mandatory point can be completed. This keeps a
    /// nearby later overpass or parallel road from silently skipping the route
    /// rules attached to an earlier border crossing or mountain pass.
    static func reachedWaypointID(waypoints: [LockedWaypoint], visitedIDs: Set<String>,
                                  location: CLLocation,
                                  expectedCourseDegrees: CLLocationDirection? = nil) -> String? {
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 100,
              let next = waypoints.first(where: { $0.required && !visitedIDs.contains($0.id) })
        else { return nil }
        let radius = min(120, max(45, location.horizontalAccuracy * 2))
        let target = CLLocation(latitude: next.coordinate.latitude,
                                longitude: next.coordinate.longitude)
        guard location.distance(from: target) <= radius else { return nil }
        if let expectedCourseDegrees {
            let vehicleCourse = NavigationMotionPolicy.reliableCourse(for: location)
            // A drive-through constraint at a bridge or motorway interchange
            // needs directional evidence. Real comfort stops intentionally
            // remain confirmable while parked, when Core Location has no
            // useful course.
            if next.mayAutoCompleteWhenPassed, vehicleCourse == nil { return nil }
            if let vehicleCourse,
               let difference = NavigationCourseMatchingPolicy.angularDifference(
                   courseDegrees: vehicleCourse,
                   routeCourseDegrees: expectedCourseDegrees
               ), !NavigationCourseMatchingPolicy.isPlausible(difference) {
                return nil
            }
        }
        return next.id
    }
}

enum RouteCorridorPolicy {
    /// Accepts a reroute when almost all of its sampled geometry remains near
    /// the persisted corridor polyline. Measuring against line segments is
    /// essential: stored corridor anchors can be many kilometres apart on a
    /// long holiday route, so endpoint-only checks reject the road between
    /// two perfectly valid anchors.
    static func contains(route: [CLLocationCoordinate2D], corridor: [DriveCoordinate],
                         widthMetres: CLLocationDistance,
                         requiredFraction: Double = 0.9) -> Bool {
        guard !route.isEmpty, corridor.count >= 2, widthMetres > 0 else { return false }
        let corridorPoints = corridor.map { MKMapPoint($0.clLocationCoordinate) }
        let allowedFraction = min(1, max(0, requiredFraction))
        let insideCount = route.reduce(into: 0) { count, coordinate in
            let point = MKMapPoint(coordinate)
            var nearest = CLLocationDistance.greatestFiniteMagnitude
            for index in 0..<(corridorPoints.count - 1) {
                nearest = min(nearest, distance(point, toSegmentFrom: corridorPoints[index],
                                                to: corridorPoints[index + 1]))
            }
            if nearest <= widthMetres { count += 1 }
        }
        return Double(insideCount) / Double(route.count) >= allowedFraction
    }

    private static func distance(_ point: MKMapPoint, toSegmentFrom start: MKMapPoint,
                                 to end: MKMapPoint) -> CLLocationDistance {
        let dx = end.x - start.x
        let dy = end.y - start.y
        let lengthSquared = dx * dx + dy * dy
        let fraction = lengthSquared == 0 ? 0 : max(0, min(1,
            ((point.x - start.x) * dx + (point.y - start.y) * dy) / lengthSquared))
        let projection = MKMapPoint(x: start.x + fraction * dx, y: start.y + fraction * dy)
        return point.distance(to: projection)
    }
}

enum RouteCorridorRestorePolicy {
    /// At a crossing several corridor samples can be virtually equally close.
    /// Choosing the absolute nearest one is unstable with metre-level GPS
    /// noise, so restoration deliberately chooses the earliest near-best
    /// match and never skips a locked section on ambiguous evidence.
    static func earliestNearBestMatch(for coordinate: DriveCoordinate,
                                      in corridor: [DriveCoordinate],
                                      toleranceMetres: CLLocationDistance = 75)
        -> (index: Int, distance: CLLocationDistance)? {
        guard !corridor.isEmpty else { return nil }
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let distances = corridor.map {
            location.distance(from: CLLocation(latitude: $0.latitude, longitude: $0.longitude))
        }
        guard let minimum = distances.min(), minimum.isFinite,
              let index = distances.firstIndex(where: { $0 <= minimum + max(0, toleranceMetres) })
        else { return nil }
        return (index, minimum)
    }

    /// Uses persisted forward progress to disambiguate a corridor crossing.
    /// A small backwards allowance tolerates sparse corridor samples and GPS
    /// drift, but a restart can no longer jump back to an earlier visit of the
    /// same physical junction.
    static func forwardNearBestMatch(for coordinate: DriveCoordinate,
                                     in corridor: [DriveCoordinate],
                                     previousProgress: Double?,
                                     backwardsAllowance: Double = 0.02,
                                     toleranceMetres: CLLocationDistance = 75)
        -> (index: Int, distance: CLLocationDistance)? {
        guard !corridor.isEmpty else { return nil }
        let lowerProgress = max(0, min(1, previousProgress ?? 0) - max(0, backwardsAllowance))
        let start = min(corridor.count - 1,
                        Int((lowerProgress * Double(max(0, corridor.count - 1))).rounded(.down)))
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let matches = corridor.indices.dropFirst(start).map { index in
            (index, location.distance(from: CLLocation(latitude: corridor[index].latitude,
                                                       longitude: corridor[index].longitude)))
        }
        guard let minimum = matches.map(\.1).min(), minimum.isFinite,
              let match = matches.first(where: { $0.1 <= minimum + max(0, toleranceMetres) })
        else { return nil }
        return match
    }
}

struct LockedRouteOptions: Codable, Equatable, Sendable {
    var avoidTolls: Bool
    var avoidHighways: Bool
}

struct LockedWaypoint: Codable, Equatable, Identifiable, Sendable {
    enum Kind: String, Codable, Sendable {
        case routeConstraint
        case userStop
        case fuelStop
    }

    let id: String
    var name: String
    var coordinate: DriveCoordinate
    var required: Bool
    /// Vorgaben fuer die Strecke, die an diesem Punkt beginnt. `nil` erbt die
    /// allgemeinen Trip-Vorgaben.
    var optionsAfter: LockedRouteOptions?
    /// Optional keeps route locks written by earlier releases decodable. Old
    /// waypoints were route constraints, so `nil` intentionally retains that
    /// meaning while all newly inserted comfort stops set an explicit kind.
    var kind: Kind? = nil

    var isTollEvidenceAnchor: Bool {
        mayAutoCompleteWhenPassed
    }

    var isRemovableComfortStop: Bool {
        kind == .userStop || kind == .fuelStop
    }

    /// Historic waypoints and explicit route constraints describe a road the
    /// driver must use, so a trustworthy forward corridor match may complete
    /// them after an app restart. Real user, food and fuel stops must instead
    /// be reached locally and can never disappear merely because the driver is
    /// already farther along the route.
    var mayAutoCompleteWhenPassed: Bool {
        kind == nil || kind == .routeConstraint
    }
}

enum RouteStopSelectionPolicy {
    static func contains(stopID: String, transientStationIDs: [String],
                         lockedWaypoints: [LockedWaypoint]) -> Bool {
        transientStationIDs.contains(stopID) || lockedWaypoints.contains {
            $0.id == stopID && $0.isRemovableComfortStop
        }
    }
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
    /// Monotonic progress on the original locked corridor. Optional so route
    /// locks written by older app versions continue to decode.
    var lastRouteProgress: Double? = nil
    var status: Status
    var createdAt: Date
    var updatedAt: Date

    var isActive: Bool { status == .active }
}

enum OfflineRouteConstraintIdentityPolicy {
    /// Stable identity of every instruction that can materially change route
    /// geometry. Progress and timestamps are deliberately excluded: passing a
    /// waypoint must not invalidate the same cached road, while adding,
    /// removing, reordering or changing a constraint must.
    static func identity(for lock: ActiveRouteLock) -> String {
        let defaultOptions = options(lock.defaultOptions)
        let destination = coordinate(lock.destination)
        let waypoints = lock.waypoints.map { waypoint in
            [
                waypoint.id,
                coordinate(waypoint.coordinate),
                waypoint.required ? "required" : "optional",
                waypoint.kind?.rawValue ?? "legacy-constraint",
                waypoint.optionsAfter.map(options) ?? "inherit",
            ].joined(separator: ":")
        }.joined(separator: "|")
        return [destination, defaultOptions, waypoints].joined(separator: "#")
    }

    static func matches(_ cachedIdentity: String?, lock: ActiveRouteLock) -> Bool {
        cachedIdentity == identity(for: lock)
    }

    private static func coordinate(_ value: DriveCoordinate) -> String {
        "\(value.latitude.bitPattern),\(value.longitude.bitPattern)"
    }

    private static func options(_ value: LockedRouteOptions) -> String {
        "\(value.avoidTolls ? 1 : 0)\(value.avoidHighways ? 1 : 0)"
    }
}

enum ActiveRouteLockValidationPolicy {
    static func isValid(_ lock: ActiveRouteLock) -> Bool {
        guard isValid(lock.destination),
              lock.corridorWidthMetres.isFinite, lock.corridorWidthMetres > 0,
              lock.createdAt.timeIntervalSinceReferenceDate.isFinite,
              lock.updatedAt.timeIntervalSinceReferenceDate.isFinite,
              lock.lastRouteProgress.map({ $0.isFinite && (0...1).contains($0) }) ?? true
        else { return false }

        let waypointIDs = lock.waypoints.map(\.id)
        guard waypointIDs.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(waypointIDs).count == waypointIDs.count,
              lock.waypoints.allSatisfy({ isValid($0.coordinate) }),
              lock.corridorPoints?.allSatisfy(isValid) ?? true
        else { return false }
        return true
    }

    private static func isValid(_ coordinate: DriveCoordinate) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }
}

/// Identity of the route constraints used by one asynchronous MapKit request.
/// Live corridor progress and timestamps are intentionally excluded: they can
/// change on every GPS checkpoint without changing the route to calculate.
/// Waypoints, visited state and scoped options are authoritative and must still
/// match before a delayed result is allowed to publish.
struct RouteCalculationConstraintSnapshot: Equatable {
    let tripID: UUID
    let destination: DriveCoordinate
    let waypoints: [LockedWaypoint]
    let defaultOptions: LockedRouteOptions
    let visitedWaypointIDs: [String]
    let status: ActiveRouteLock.Status

    init?(_ lock: ActiveRouteLock?) {
        guard let lock else { return nil }
        tripID = lock.id
        destination = lock.destination
        waypoints = lock.waypoints
        defaultOptions = lock.defaultOptions
        visitedWaypointIDs = lock.visitedWaypointIDs ?? []
        status = lock.status
    }
}

extension ActiveRouteLock {
    /// Prevents the same real-world stop from being added repeatedly through
    /// slightly different MapKit search results. An exact coordinate match is
    /// always a duplicate; for ordinary search-result drift the names must
    /// also match so a fuel station beside a mandatory road anchor remains a
    /// valid, distinct stop.
    func containsEquivalentStop(name: String, coordinate: CLLocationCoordinate2D) -> Bool {
        let normalizedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        let candidate = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        return waypoints.contains { waypoint in
            let existing = CLLocation(latitude: waypoint.coordinate.latitude,
                                      longitude: waypoint.coordinate.longitude)
            let distance = candidate.distance(from: existing)
            if distance <= 15 { return true }
            let existingName = waypoint.name.trimmingCharacters(in: .whitespacesAndNewlines)
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            return distance <= 100 && !normalizedName.isEmpty && existingName == normalizedName
        }
    }

    /// Inserts a stop in driven-route order while preserving the routing rules
    /// of the segment it splits. Fuel, food and arbitrary POIs therefore cannot
    /// silently bypass a locked Slovenia or mountain-pass constraint.
    mutating func insertWaypoint(_ waypoint: LockedWaypoint,
                                 knownProgress: Double? = nil,
                                 progress: (DriveCoordinate) -> Double) {
        guard !waypoints.contains(where: { $0.id == waypoint.id }) else { return }
        let insertionProgress = knownProgress ?? progress(waypoint.coordinate)
        let index = waypoints.firstIndex { progress($0.coordinate) > insertionProgress }
            ?? waypoints.endIndex
        let inheritedOptions = index == 0
            ? defaultOptions
            : (waypoints[index - 1].optionsAfter ?? defaultOptions)
        var inserted = waypoint
        inserted.optionsAfter = inheritedOptions
        waypoints.insert(inserted, at: index)
        visitedWaypointIDs?.removeAll { $0 == waypoint.id }
        updatedAt = Date()
    }

    mutating func removeWaypoint(id: String) {
        waypoints.removeAll { $0.id == id }
        visitedWaypointIDs?.removeAll { $0 == id }
        updatedAt = Date()
    }

    /// Determines mandatory points already passed along the persisted route
    /// corridor. This prevents a restored trip from routing back to Croatia or
    /// Slovenia after a longer break farther north. The result is intentionally
    /// empty when the current position is not plausibly inside the corridor.
    func passedWaypointIDs(at current: DriveCoordinate) -> [String] {
        guard let corridorPoints, corridorPoints.count > 2 else { return [] }
        guard let currentMatch = RouteCorridorRestorePolicy.forwardNearBestMatch(
            for: current, in: corridorPoints, previousProgress: lastRouteProgress
        ), currentMatch.distance <= max(corridorWidthMetres * 2, 5_000) else { return [] }

        let visited = Set(visitedWaypointIDs ?? [])
        var passed: [String] = []
        for waypoint in waypoints where waypoint.required {
            if visited.contains(waypoint.id) { continue }
            // A real fuel/food/user stop is a hard ordering boundary. If it
            // was missed, restoration must route back to it and then enforce
            // every later road constraint again; marking those later anchors
            // complete here could silently bypass a required pass or country
            // rule on the return leg.
            guard waypoint.mayAutoCompleteWhenPassed else { break }
            guard let match = RouteCorridorRestorePolicy.earliestNearBestMatch(
                for: waypoint.coordinate, in: corridorPoints
            ), match.index < currentMatch.index else { break }
            // Keep the next corridor point active. A small index margin avoids
            // skipping a mandatory pass when GPS lies just beyond its sample.
            passed.append(waypoint.id)
        }
        return passed
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
    private let backupKey = "drive.activeRouteLock.v1.backup"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let primary = defaults.data(forKey: key)
        if let decoded = Self.decodeAny(primary) {
            // A valid completed/cancelled primary is authoritative. Never
            // revive its older active backup after an intentional finish.
            activeLock = decoded.isActive ? decoded : nil
        } else {
            activeLock = Self.decodeActive(defaults.data(forKey: backupKey))
        }
    }

    func save(_ lock: ActiveRouteLock) {
        guard let data = try? JSONEncoder().encode(lock) else { return }
        if lock.isActive {
            if let previousData = defaults.data(forKey: key),
               let previous = Self.decodeAny(previousData),
               previous.isActive, previous.id == lock.id {
                defaults.set(previousData, forKey: backupKey)
            } else {
                // A backup from another journey must never replace this one.
                defaults.removeObject(forKey: backupKey)
            }
            defaults.set(data, forKey: key)
        } else {
            // Commit the terminal state first, then remove recovery data.
            defaults.set(data, forKey: key)
            defaults.removeObject(forKey: backupKey)
        }
        activeLock = lock
    }

    /// Restores a transaction snapshot. Used when adding/removing a stop made
    /// the route impossible, so persisted constraints and visible UI agree.
    func replace(with lock: ActiveRouteLock?) {
        guard let lock else {
            activeLock = nil
            defaults.removeObject(forKey: key)
            defaults.removeObject(forKey: backupKey)
            return
        }
        save(lock)
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
        defaults.removeObject(forKey: backupKey)
    }

    private static func decodeAny(_ data: Data?) -> ActiveRouteLock? {
        guard let data else { return nil }
        guard let lock = try? JSONDecoder().decode(ActiveRouteLock.self, from: data),
              ActiveRouteLockValidationPolicy.isValid(lock) else { return nil }
        return lock
    }

    private static func decodeActive(_ data: Data?) -> ActiveRouteLock? {
        guard let lock = decodeAny(data), lock.isActive else { return nil }
        return lock
    }
}

enum RouteWaypointProgressPolicy {
    /// Keeps persisted visit order stable and appends newly passed mandatory
    /// points exactly once when a route calculation is committed.
    static func merging(existing: [String]?, newlyPassed: Set<String>) -> [String] {
        var result = existing ?? []
        let known = Set(result)
        result.append(contentsOf: newlyPassed.subtracting(known).sorted())
        return result
    }
}

enum RouteWaypointRoutingPolicy {
    enum Source: Equatable {
        case direct
        case persistedLock
        case transientStations
    }

    /// Once a trip lock exists it is the authoritative waypoint source. A
    /// station retained in transient UI state must never reappear after its
    /// locked waypoint was completed.
    static func source(hasActiveLock: Bool, remainingLockedWaypointCount: Int,
                       transientStationCount: Int) -> Source {
        if hasActiveLock {
            return remainingLockedWaypointCount > 0 ? .persistedLock : .direct
        }
        return transientStationCount > 0 ? .transientStations : .direct
    }
}

enum RouteWaypointOptionsPolicy {
    /// Returns the rules for the segment that starts at the current trip
    /// position. A visited route constraint changes the active rules until a
    /// later visited constraint changes them again. Only a contiguous visited
    /// prefix is considered, so an accidentally persisted later waypoint can
    /// never skip the restrictions of an earlier mandatory point.
    static func currentOptions(defaultOptions: LockedRouteOptions,
                               waypoints: [LockedWaypoint],
                               visitedIDs: Set<String>) -> LockedRouteOptions {
        var options = defaultOptions
        for waypoint in waypoints where waypoint.required {
            guard visitedIDs.contains(waypoint.id) else { break }
            if let optionsAfter = waypoint.optionsAfter {
                options = optionsAfter
            }
        }
        return options
    }
}
