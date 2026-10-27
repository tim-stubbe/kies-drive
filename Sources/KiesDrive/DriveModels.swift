import Foundation
import CoreLocation
import CryptoKit

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

enum DriveSavedDestinationPolicy {
    static func isValid(name: String, latitude: Double, longitude: Double) -> Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            latitude.isFinite && longitude.isFinite &&
            (-90...90).contains(latitude) && (-180...180).contains(longitude)
    }
}

enum RecentDestinationStore {
    private static let key = "drive.recentDestinations.v1"
    static let maximumCount = 8

    static func load(defaults: UserDefaults = .standard) -> [RecentDestination] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return ((try? JSONDecoder().decode([RecentDestination].self, from: data)) ?? [])
            .filter {
                DriveSavedDestinationPolicy.isValid(
                    name: $0.name, latitude: $0.latitude, longitude: $0.longitude
                )
            }
            .sorted { $0.lastUsedAt > $1.lastUsedAt }
    }

    @discardableResult
    static func record(_ destination: RecentDestination, defaults: UserDefaults = .standard) -> [RecentDestination] {
        var values = load(defaults: defaults)
        guard DriveSavedDestinationPolicy.isValid(
            name: destination.name,
            latitude: destination.latitude,
            longitude: destination.longitude
        ) else { return values }
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
        return ((try? JSONDecoder().decode([DriveFavorite].self, from: data)) ?? []).filter {
            DriveSavedDestinationPolicy.isValid(
                name: $0.name, latitude: $0.latitude, longitude: $0.longitude
            )
        }
    }

    static func save(_ favorites: [DriveFavorite], defaults: UserDefaults = .standard) {
        let valid = favorites.filter {
            DriveSavedDestinationPolicy.isValid(
                name: $0.name, latitude: $0.latitude, longitude: $0.longitude
            )
        }
        guard let data = try? JSONEncoder().encode(valid) else { return }
        defaults.set(data, forKey: key)
    }
}

struct DriveUsageStatistics: Codable, Equatable {
    var totalDistanceMetres: CLLocationDistance = 0
    var totalMovingTime: TimeInterval = 0
    var completedNavigations = 0
    var lastTripDistanceMetres: CLLocationDistance = 0
    var lastTripMovingTime: TimeInterval = 0
    var lastTripEndedAt: Date?

    mutating func recordTrip(distanceMetres: CLLocationDistance,
                             movingTime: TimeInterval,
                             endedAt: Date = Date()) {
        guard distanceMetres > 0 || movingTime > 0 else { return }
        totalDistanceMetres += max(0, distanceMetres)
        totalMovingTime += max(0, movingTime)
        completedNavigations += 1
        lastTripDistanceMetres = max(0, distanceMetres)
        lastTripMovingTime = max(0, movingTime)
        lastTripEndedAt = endedAt
    }
}

enum DriveUsageStatisticsStore {
    private static let key = "drive.usageStatistics.v1"

    static func load(defaults: UserDefaults = .standard) -> DriveUsageStatistics {
        guard let data = defaults.data(forKey: key) else { return .init() }
        return (try? JSONDecoder().decode(DriveUsageStatistics.self, from: data)) ?? .init()
    }

    static func save(_ statistics: DriveUsageStatistics, defaults: UserDefaults = .standard) {
        guard let data = try? JSONEncoder().encode(statistics) else { return }
        defaults.set(data, forKey: key)
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
    }
}

struct DriveUsageSessionState: Codable, Equatable {
    var tripID: UUID?
    var distanceMetres: CLLocationDistance = 0
    var movingTime: TimeInterval = 0
}

enum DriveUsageTripTransitionPolicy {
    static func shouldFinalize(sessionTripID: UUID?, previousTripID: UUID?, nextTripID: UUID?) -> Bool {
        guard let sessionTripID, let previousTripID, let nextTripID else { return false }
        return sessionTripID == previousTripID && previousTripID != nextTripID
    }
}

struct DriveUsageSessionStore {
    let defaults: UserDefaults
    var key = "drive.usageSession.v1"

    static let live = DriveUsageSessionStore(defaults: .standard)

    func load() -> DriveUsageSessionState {
        guard let data = defaults.data(forKey: key) else { return .init() }
        return (try? JSONDecoder().decode(DriveUsageSessionState.self, from: data)) ?? .init()
    }

    func save(_ state: DriveUsageSessionState) {
        guard let data = try? JSONEncoder().encode(state) else { return }
        defaults.set(data, forKey: key)
    }

    func clear() { defaults.removeObject(forKey: key) }
}

/// Counts only plausible movement samples received while guidance is active.
/// Coordinates are deliberately never persisted.
enum DriveUsageSegmentPolicy {
    static let maximumPlausibleSpeedMetresPerSecond = 90.0

    static func segment(previous: CLLocation?, current: CLLocation) ->
        (distanceMetres: CLLocationDistance, movingTime: TimeInterval)? {
        guard let previous else { return nil }
        guard previous.horizontalAccuracy >= 0, previous.horizontalAccuracy <= 65,
              current.horizontalAccuracy >= 0, current.horizontalAccuracy <= 65 else { return nil }
        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0, elapsed <= 120 else { return nil }

        let distance = current.distance(from: previous)
        let inferredSpeed = distance / elapsed
        // Navigation can tolerate one coarse 350 m GPS jump to keep route
        // matching alive. Trip statistics must be stricter: counting that
        // fallback as real distance would inflate a short drive substantially.
        guard distance.isFinite, inferredSpeed.isFinite,
              inferredSpeed <= maximumPlausibleSpeedMetresPerSecond else { return nil }
        let measuredSpeed = [previous.speed, current.speed]
            .filter { $0.isFinite && $0 >= 0 }
            .max() ?? -1
        guard max(inferredSpeed, measuredSpeed) >= 1.5 else { return nil }

        let accuracyAllowance = max(0, previous.horizontalAccuracy) + max(0, current.horizontalAccuracy)
        guard distance <= max(350, elapsed * 80 + accuracyAllowance) else { return nil }
        // If geometry says the vehicle was effectively stationary but the
        // newest fix already reports driving speed, the movement began near
        // the end of this sample interval (for example after a red light or
        // foreground resume). Counting the whole gap inflates driving hours.
        let movingTime: TimeInterval
        if inferredSpeed < 1.5, measuredSpeed >= 1.5 {
            movingTime = min(elapsed, max(1, distance / measuredSpeed))
        } else {
            movingTime = elapsed
        }
        return (distance, movingTime)
    }
}

enum DriveDiagnosticKind: String, Codable, Hashable {
    case routeCalculated, navigationStarted, rerouteRequested, rerouteSucceeded, rerouteFailed, routeRejoined
    case routeRestoreSucceeded, routeRestoreFailed
    case navigationStopped, arrivalReached, locationRejected, locationGapRecovered
    case maneuverAnnounced, maneuverFinalCueMissed
    case offlineRouteDeparture, offlineRouteRejoined, speechDeliveryFailed
    case breakReminderShown, breakReminderAnnounced, fuelReminderShown, fuelReminderAnnounced
    case restBreakCompleted
    case routeSearchCompleted, routeSearchDiscarded, routeStopAdded, routeStopFailed
}

/// Produces useful driving diagnostics without ever recording coordinates or
/// a location trail. Accuracy and speed are enough to distinguish a guidance
/// bug from a weak GPS fix when a real drive is reviewed later.
enum DriveDiagnosticDetail {
    private static let maneuverIdentityPrefix = "Manöver-ID "
    static let maximumStoredLength = 500

    /// Diagnostics are a compact local quality journal, not a transport log.
    /// Collapse multiline/provider text and cap every event so one verbose
    /// network or audio error cannot bloat UserDefaults or an exported report.
    static func storageSafe(_ detail: String,
                            maximumLength: Int = maximumStoredLength) -> String {
        guard maximumLength > 0 else { return "" }
        let collapsed = detail.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return String(collapsed.prefix(maximumLength))
    }

    static func navigationSample(_ description: String, location: CLLocation?) -> String {
        guard let location else { return description }
        let accuracy = location.horizontalAccuracy >= 0
            ? "GPS ±\(Int(location.horizontalAccuracy.rounded())) m"
            : "GPS-Genauigkeit unbekannt"
        let speed = location.speed >= 0 && location.speed.isFinite
            ? "\(Int((location.speed * 3.6).rounded())) km/h"
            : "Geschwindigkeit unbekannt"
        return "\(description) · \(accuracy) · \(speed)"
    }

    static func maneuver(_ description: String, key: String,
                         location: CLLocation? = nil) -> String {
        let identity = fingerprint(key)
        return navigationSample(
            "\(maneuverIdentityPrefix)\(identity) · \(description)",
            location: location
        )
    }

    static func maneuverIdentity(in detail: String) -> String? {
        guard let first = detail.split(separator: "·").first else { return nil }
        let component = first.trimmingCharacters(in: .whitespacesAndNewlines)
        guard component.hasPrefix(maneuverIdentityPrefix) else { return nil }
        let value = String(component.dropFirst(maneuverIdentityPrefix.count))
        return value.isEmpty ? nil : value
    }

    static func removingManeuverIdentity(from detail: String) -> String {
        guard maneuverIdentity(in: detail) != nil,
              let separator = detail.range(of: "·") else { return detail }
        return String(detail[separator.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// A stable one-way identifier lets the quality summary match a failed
    /// utterance with its later retry without embedding the reversible route
    /// key (which can contain a street name) in the local archive or export.
    static func fingerprint(_ value: String) -> String {
        SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

struct DriveDiagnosticEvent: Codable, Identifiable, Equatable {
    let id: UUID
    /// Persists across an app restart while the same navigation is still
    /// active. Older diagnostic archives decode with a nil session ID.
    let sessionID: UUID?
    let kind: DriveDiagnosticKind
    let date: Date
    let detail: String

    init(id: UUID = UUID(), sessionID: UUID? = nil,
         kind: DriveDiagnosticKind, date: Date = Date(), detail: String) {
        self.id = id
        self.sessionID = sessionID
        self.kind = kind
        self.date = date
        self.detail = detail
    }
}

enum DriveDiagnosticStore {
    static let didChange = Notification.Name("KiesDriveDiagnosticStoreDidChange")
    private static let key = "drive.diagnostics.v1"
    private static let activeSessionKey = "drive.diagnostics.active-session.v1"
    private static let maximumCount = 100
    private static let maximumPriorityCount = 30

    private static let priorityKinds: Set<DriveDiagnosticKind> = [
        .rerouteRequested, .rerouteSucceeded, .rerouteFailed, .routeRejoined,
        .routeRestoreFailed,
        .maneuverFinalCueMissed, .speechDeliveryFailed,
        .offlineRouteDeparture, .offlineRouteRejoined,
    ]

    static func load(defaults: UserDefaults = .standard) -> [DriveDiagnosticEvent] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DriveDiagnosticEvent].self, from: data)) ?? []
    }

    /// Binds diagnostics to the persistent trip rather than to one foreground
    /// navigation run. Pausing and restoring the same trip therefore keeps a
    /// continuous quality history, including across process restarts.
    static func activateSession(_ id: UUID, defaults: UserDefaults = .standard) {
        defaults.set(id.uuidString, forKey: activeSessionKey)
    }

    static func finishActiveSession(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: activeSessionKey)
    }

    static func append(_ kind: DriveDiagnosticKind, detail: String, defaults: UserDefaults = .standard) {
        var events = load(defaults: defaults)
        let sessionID: UUID?
        if kind == .navigationStarted {
            if let stored = defaults.string(forKey: activeSessionKey).flatMap(UUID.init(uuidString:)) {
                sessionID = stored
            } else {
                let created = UUID()
                defaults.set(created.uuidString, forKey: activeSessionKey)
                sessionID = created
            }
        } else {
            sessionID = defaults.string(forKey: activeSessionKey).flatMap(UUID.init(uuidString:))
        }
        events.append(.init(
            sessionID: sessionID, kind: kind,
            detail: DriveDiagnosticDetail.storageSafe(detail)
        ))
        if events.count > maximumCount {
            events = bounded(events)
        }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: key)
            if kind == .arrivalReached {
                defaults.removeObject(forKey: activeSessionKey)
            }
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func bounded(_ events: [DriveDiagnosticEvent]) -> [DriveDiagnosticEvent] {
        guard events.count > maximumCount else { return events }
        let latestStartIndex = events.lastIndex { $0.kind == .navigationStarted }
        let latestSessionID = latestStartIndex.flatMap { events[$0].sessionID }
        let sessionStartIndex = latestSessionID.flatMap { id in
            events.firstIndex { $0.kind == .navigationStarted && $0.sessionID == id }
        } ?? latestStartIndex
        let session = sessionStartIndex.map { events[$0...] } ?? events[...]
        let priority = session.filter { priorityKinds.contains($0.kind) }
            .suffix(maximumPriorityCount)
        var retained = Set(priority.map(\.id))
        if let sessionStartIndex { retained.insert(events[sessionStartIndex].id) }
        for event in events.reversed() where retained.count < maximumCount {
            retained.insert(event.id)
        }
        // Filtering the original array retains chronological order even for
        // events sharing the same timestamp.
        return events.filter { retained.contains($0.id) }
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
        defaults.removeObject(forKey: activeSessionKey)
        NotificationCenter.default.post(name: didChange, object: nil)
    }
}

struct DriveDiagnosticSummary: Equatable {
    enum Quality: String {
        case good = "Unauffällig"
        case attention = "Prüfen"
        case critical = "Fehler erkannt"
    }

    let quality: Quality
    let eventCount: Int
    let rerouteRequests: Int
    let rerouteFailures: Int
    let rejectedLocations: Int
    let recoveredLocationGaps: Int
    let arrivals: Int
    let maneuverAnnouncements: Int
    let breakRemindersShown: Int
    let breakRemindersAnnounced: Int
    let restBreaksCompleted: Int
    let fuelRemindersShown: Int
    let fuelRemindersAnnounced: Int
    let missedFinalCues: Int
    let speechDeliveryFailures: Int
    let offlineRouteDepartures: Int
    let routeStopFailures: Int
    let routeRestoreFailures: Int
    let resolvedRouteIssues: Int
    let recommendation: String

    private static func maximumBurst(of kind: DriveDiagnosticKind,
                                     in events: ArraySlice<DriveDiagnosticEvent>,
                                     window: TimeInterval = 60) -> Int {
        let dates = events.filter { $0.kind == kind }.map(\.date).sorted()
        var start = 0
        var maximum = 0
        for end in dates.indices {
            while start < end, dates[end].timeIntervalSince(dates[start]) > window {
                start += 1
            }
            maximum = max(maximum, end - start + 1)
        }
        return maximum
    }

    private static func speechInstruction(in event: DriveDiagnosticEvent) -> String? {
        let detail = DriveDiagnosticDetail.removingManeuverIdentity(from: event.detail)
        let parts = detail.split(separator: "·").map {
            $0.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let value: String?
        switch event.kind {
        case .speechDeliveryFailed:
            value = parts.indices.contains(1) ? parts[1] : parts.first
        case .maneuverAnnounced, .breakReminderAnnounced, .fuelReminderAnnounced:
            value = parts.indices.contains(2) ? parts[2] : parts.last
        default:
            value = nil
        }
        guard let value, !value.isEmpty else { return nil }
        return value.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current
        )
    }

    private static func unresolvedSpeechFailures(
        in session: ArraySlice<DriveDiagnosticEvent>
    ) -> Int {
        let indexed = Array(session)
        return indexed.indices.filter { index in
            let failure = indexed[index]
            guard failure.kind == .speechDeliveryFailed else { return false }
            let failedManeuverID = DriveDiagnosticDetail.maneuverIdentity(in: failure.detail)
            guard let instruction = speechInstruction(in: failure) else { return true }
            return !indexed.indices.dropFirst(index + 1).contains { laterIndex in
                let later = indexed[laterIndex]
                if let failedManeuverID {
                    return later.kind == .maneuverAnnounced &&
                        DriveDiagnosticDetail.maneuverIdentity(in: later.detail) == failedManeuverID
                }
                return (later.kind == .maneuverAnnounced ||
                        later.kind == .breakReminderAnnounced ||
                        later.kind == .fuelReminderAnnounced) &&
                    speechInstruction(in: later) == instruction
            }
        }.count
    }

    private static func normalizedRouteStopName(in event: DriveDiagnosticEvent) -> String? {
        let raw: String
        switch event.kind {
        case .routeStopFailed:
            raw = event.detail.components(separatedBy: "·").last ?? event.detail
        case .routeStopAdded:
            raw = event.detail
        default:
            return nil
        }
        let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
        return normalized.isEmpty ? nil : normalized
    }

    private static func unresolvedRouteStopFailures(
        in session: ArraySlice<DriveDiagnosticEvent>
    ) -> Int {
        let indexed = Array(session)
        return indexed.indices.filter { index in
            let failure = indexed[index]
            guard failure.kind == .routeStopFailed else { return false }
            guard let stop = normalizedRouteStopName(in: failure) else { return true }
            return !indexed.indices.dropFirst(index + 1).contains { laterIndex in
                let later = indexed[laterIndex]
                return later.kind == .routeStopAdded &&
                    normalizedRouteStopName(in: later) == stop
            }
        }.count
    }

    static func latestSession(in events: [DriveDiagnosticEvent]) -> Self? {
        guard let latestStart = events.lastIndex(where: { $0.kind == .navigationStarted }) else { return nil }
        let sessionID = events[latestStart].sessionID
        // A restored route emits another navigationStarted marker. When it
        // carries the same persisted ID, include the whole drive instead of
        // hiding problems that occurred before the app restart or long pause.
        let start = sessionID.flatMap { id in
            events.firstIndex { $0.kind == .navigationStarted && $0.sessionID == id }
        } ?? latestStart
        // A navigationStopped event is only a pause while the persistent trip
        // remains active. Search for a terminal only after the latest resume;
        // this keeps the whole trip visible while excluding late async work
        // once its final run actually stops or arrives.
        let afterLatestStart = events.index(after: latestStart)..<events.endIndex
        let terminal = afterLatestStart.first(where: {
            events[$0].kind == .navigationStopped || events[$0].kind == .arrivalReached
        })
        // A completed drive ends at its first terminal event. Async network
        // work from that drive may finish later, but must not retroactively
        // turn a clean session into a warning or critical result.
        let session = terminal.map { events[start...$0] } ?? events[start...]
        let lastRerouteRecovery = session.lastIndex(where: {
            $0.kind == .rerouteSucceeded || $0.kind == .routeRejoined
        })
        let unresolvedReroutes = lastRerouteRecovery.map {
            session[session.index(after: $0)...]
        } ?? session[session.startIndex...]
        let lastOfflineRecovery = session.lastIndex(where: {
            $0.kind == .rerouteSucceeded || $0.kind == .offlineRouteRejoined
        })
        let unresolvedOffline = lastOfflineRecovery.map {
            session[session.index(after: $0)...]
        } ?? session[session.startIndex...]
        let totalFailures = session.filter { $0.kind == .rerouteFailed }.count
        let totalOfflineDepartures = session.filter { $0.kind == .offlineRouteDeparture }.count
        let failures = unresolvedReroutes.filter { $0.kind == .rerouteFailed }.count
        let rejected = session.filter { $0.kind == .locationRejected }.count
        let recoveredLocationGaps = session.filter { $0.kind == .locationGapRecovered }.count
        let rejectedBurst = maximumBurst(of: .locationRejected, in: session)
        let missed = session.filter { $0.kind == .maneuverFinalCueMissed }.count
        let totalSpeechFailures = session.filter { $0.kind == .speechDeliveryFailed }.count
        let speechFailures = unresolvedSpeechFailures(in: session)
        let totalRouteStopFailures = session.filter { $0.kind == .routeStopFailed }.count
        let routeStopFailures = unresolvedRouteStopFailures(in: session)
        let restoreTimeline: [DriveDiagnosticEvent]
        let mayRestoreAfterTerminal = terminal.map {
            events[$0].kind == .navigationStopped
        } ?? true
        if let sessionID, mayRestoreAfterTerminal {
            restoreTimeline = events[start...].filter {
                $0.sessionID == sessionID &&
                    ($0.kind == .routeRestoreFailed || $0.kind == .routeRestoreSucceeded)
            }
        } else {
            restoreTimeline = session.filter {
                $0.kind == .routeRestoreFailed || $0.kind == .routeRestoreSucceeded
            }
        }
        let totalRestoreFailures = restoreTimeline.filter {
            $0.kind == .routeRestoreFailed
        }.count
        let lastRestoreSuccess = restoreTimeline.lastIndex {
            $0.kind == .routeRestoreSucceeded
        }
        let unresolvedRestoreTimeline = lastRestoreSuccess.map {
            restoreTimeline.dropFirst($0 + 1)
        } ?? restoreTimeline[...]
        let routeRestoreFailures = unresolvedRestoreTimeline.filter {
            $0.kind == .routeRestoreFailed
        }.count
        let diagnosticEventCount = Set(session.map(\.id) + restoreTimeline.map(\.id)).count
        let offlineDepartures = unresolvedOffline.filter { $0.kind == .offlineRouteDeparture }.count
        let resolved = max(0, totalFailures - failures) +
            max(0, totalOfflineDepartures - offlineDepartures) +
            max(0, totalSpeechFailures - speechFailures) +
            max(0, totalRouteStopFailures - routeStopFailures) +
            max(0, totalRestoreFailures - routeRestoreFailures)
        let reroutes = session.filter { $0.kind == .rerouteRequested }.count
        let quality: Quality
        let recommendation: String
        if failures > 0 || routeRestoreFailures > 0 || missed > 0 ||
            offlineDepartures > 0 || speechFailures > 0 {
            quality = .critical
            if missed > 0 {
                recommendation = "Fahrhinweise prüfen; mindestens eine letzte Abbiegeansage fehlte."
            } else if speechFailures > 0 {
                recommendation = "Die letzte Fahransage wurde vom Audiosystem nicht beendet; Bluetooth- und Lautstärkeeinstellungen prüfen."
            } else if offlineDepartures > 0 {
                recommendation = "Die gespeicherte Route wurde verlassen und noch nicht online ersetzt."
            } else if routeRestoreFailures > 0 {
                recommendation = "Die gespeicherte Reise konnte noch nicht fortgesetzt werden; Verbindung und Offlinekarte prüfen."
            } else {
                recommendation = "Die letzte Neuberechnung ist noch fehlgeschlagen; die alte Route blieb aktiv."
            }
        } else if routeStopFailures > 0 || rejectedBurst >= 3 ||
                    recoveredLocationGaps >= 3 || reroutes >= 3 {
            quality = .attention
            if routeStopFailures > 0 {
                recommendation = "Mindestens ein gewünschter Zwischenstopp konnte nicht berechnet werden; Verbindung und Erreichbarkeit des Stopps prüfen."
            } else if rejectedBurst >= 3 {
                recommendation = "Mehrere GPS-Messungen waren unzuverlässig; freie Sicht zum Himmel verbessert die Führung."
            } else if recoveredLocationGaps >= 3 {
                recommendation = "Die Standortübertragung war mehrfach unterbrochen; Hintergrundfreigabe und Energiesparmodus prüfen."
            } else {
                recommendation = "Die Route wurde mehrfach neu berechnet; den Diagnosebericht nach der Fahrt prüfen."
            }
        } else {
            quality = .good
            recommendation = resolved > 0
                ? "Ein vorübergehendes Routenproblem wurde automatisch behoben."
                : "Keine auffälligen Navigationsprobleme erkannt."
        }
        let arrivals = session.filter { $0.kind == .arrivalReached }.count
        let maneuvers = session.filter { $0.kind == .maneuverAnnounced }.count
        let shownBreaks = session.filter { $0.kind == .breakReminderShown }.count
        let spokenBreaks = session.filter { $0.kind == .breakReminderAnnounced }.count
        let completedBreaks = session.filter { $0.kind == .restBreakCompleted }.count
        let shownFuel = session.filter { $0.kind == .fuelReminderShown }.count
        let spokenFuel = session.filter { $0.kind == .fuelReminderAnnounced }.count
        return .init(quality: quality, eventCount: diagnosticEventCount,
                     rerouteRequests: reroutes,
                     rerouteFailures: failures, rejectedLocations: rejected,
                     recoveredLocationGaps: recoveredLocationGaps,
                     arrivals: arrivals, maneuverAnnouncements: maneuvers,
                     breakRemindersShown: shownBreaks,
                     breakRemindersAnnounced: spokenBreaks,
                     restBreaksCompleted: completedBreaks,
                     fuelRemindersShown: shownFuel,
                     fuelRemindersAnnounced: spokenFuel,
                     missedFinalCues: missed, speechDeliveryFailures: speechFailures,
                     offlineRouteDepartures: offlineDepartures,
                     routeStopFailures: routeStopFailures,
                     routeRestoreFailures: routeRestoreFailures,
                     resolvedRouteIssues: resolved, recommendation: recommendation)
    }
}

enum DriveDiagnosticReport {
    /// Returns only the drive represented by the latest navigation start.
    /// Restarts of the same persisted trip keep their shared session ID, while
    /// unrelated older drives and late asynchronous callbacks are excluded.
    static func latestSessionEvents(in events: [DriveDiagnosticEvent]) -> [DriveDiagnosticEvent] {
        guard let latestStart = events.lastIndex(where: { $0.kind == .navigationStarted }) else {
            return []
        }
        let sessionID = events[latestStart].sessionID
        let start = sessionID.flatMap { id in
            events.firstIndex { $0.kind == .navigationStarted && $0.sessionID == id }
        } ?? latestStart
        let afterLatestStart = events.index(after: latestStart)..<events.endIndex
        let terminal = afterLatestStart.first(where: {
            events[$0].kind == .navigationStopped || events[$0].kind == .arrivalReached
        })
        let end = terminal ?? events.index(before: events.endIndex)
        var selected = Array(events[start...end])
        // A failed restore is emitted after navigation was deliberately
        // paused. Include only restore lifecycle events carrying the same
        // persistent trip ID; unrelated late network callbacks remain
        // excluded from the completed drive report.
        if let terminal, let sessionID,
           events[terminal].kind == .navigationStopped,
           terminal < events.index(before: events.endIndex) {
            selected.append(contentsOf: events[events.index(after: terminal)...].filter {
                $0.sessionID == sessionID &&
                    ($0.kind == .routeRestoreFailed || $0.kind == .routeRestoreSucceeded)
            })
        }
        return selected
    }

    static func text(events: [DriveDiagnosticEvent], appVersion: String) -> String {
        var lines = [
            "Kies Drive Fahrdiagnose",
            "App-Version: \(appVersion)",
            "Ereignisse: \(events.count)",
            "Hinweis: Keine vollständige Standortspur enthalten.",
            ""
        ]
        let formatter = ISO8601DateFormatter()
        lines += events.map {
            "\(formatter.string(from: $0.date)) | \($0.kind.rawValue) | \(exportSafeDetail(for: $0))"
        }
        return lines.joined(separator: "\n")
    }

    private static func exportSafeDetail(for event: DriveDiagnosticEvent) -> String {
        let redacted: String
        switch event.kind {
        case .navigationStarted:
            redacted = event.detail.hasPrefix("Offline")
                ? "Offline-Navigation gestartet · Ziel ausgeblendet"
                : "Navigation gestartet · Ziel ausgeblendet"
        case .navigationStopped:
            redacted = "Navigation pausiert · Ziel ausgeblendet"
        case .arrivalReached:
            redacted = "Ziel erreicht · Ziel ausgeblendet"
        case .routeStopAdded:
            redacted = "Zwischenstopp hinzugefügt · Name ausgeblendet"
        case .routeStopFailed:
            redacted = "Zwischenstopp nicht berechenbar · Name ausgeblendet"
        case .breakReminderShown, .breakReminderAnnounced:
            redacted = redactedReminderDetail(
                event.detail, label: "Pausenerinnerung"
            )
        case .fuelReminderShown, .fuelReminderAnnounced:
            redacted = redactedReminderDetail(
                event.detail, label: "Tankhinweis"
            )
        case .maneuverAnnounced, .maneuverFinalCueMissed, .speechDeliveryFailed:
            redacted = redactedManeuverDetail(event.detail)
        default:
            redacted = event.detail
        }
        return redacted.replacingOccurrences(of: "\n", with: " ")
    }

    private static func redactedManeuverDetail(_ detail: String) -> String {
        if detail.localizedCaseInsensitiveContains("Pausenerinnerung") {
            return redactedReminderDetail(detail, label: "Pausenerinnerung")
        }
        if detail.localizedCaseInsensitiveContains("Tankhinweis") {
            return redactedReminderDetail(detail, label: "Tankhinweis")
        }
        let identity = DriveDiagnosticDetail.maneuverIdentity(in: detail)
            .map { "Manöver-ID \(DriveDiagnosticDetail.fingerprint($0))" }
        let parts = DriveDiagnosticDetail.removingManeuverIdentity(from: detail)
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var safe = parts.filter {
            $0.hasPrefix("GPS ") || $0 == "GPS-Genauigkeit unbekannt" ||
                $0.hasSuffix("km/h") ||
                NavigationAnnouncementStageNamePolicy.isStageOrDistance($0)
        }
        safe.append("Fahranweisung ausgeblendet")
        if let identity { safe.insert(identity, at: 0) }
        return safe.joined(separator: " · ")
    }

    /// Reminder text may contain the selected rest area or fuel-station name.
    /// Keep only operational state useful for debugging delivery, never the
    /// place chosen by the driver or planner.
    private static func redactedReminderDetail(_ detail: String, label: String) -> String {
        let safeWords: Set<String> = ["plan", "soon", "due", "gesprochen"]
        let parts = DriveDiagnosticDetail.removingManeuverIdentity(from: detail)
            .split(separator: "·")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var safe = parts.filter {
            safeWords.contains($0.lowercased()) || $0.hasPrefix("GPS ") ||
                $0 == "GPS-Genauigkeit unbekannt" || $0.hasSuffix("km/h")
        }
        safe.insert("\(label) · Ort ausgeblendet", at: 0)
        return safe.joined(separator: " · ")
    }
}

private enum NavigationAnnouncementStageNamePolicy {
    static func isStageOrDistance(_ value: String) -> Bool {
        let stages = ["early", "prepare", "final", "now"]
        if stages.contains(value.lowercased()) { return true }
        let components = value.split(separator: " ")
        return components.count == 2 && Double(components[0]) != nil &&
            ["m", "km"].contains(String(components[1]).lowercased())
    }
}
