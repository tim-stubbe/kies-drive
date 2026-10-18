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
    static func segment(previous: CLLocation?, current: CLLocation) ->
        (distanceMetres: CLLocationDistance, movingTime: TimeInterval)? {
        guard let previous else { return nil }
        let elapsed = current.timestamp.timeIntervalSince(previous.timestamp)
        guard elapsed > 0, elapsed <= 120 else { return nil }

        let distance = current.distance(from: previous)
        let inferredSpeed = distance / elapsed
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
    case navigationStopped, arrivalReached, locationRejected, locationGapRecovered
    case maneuverAnnounced, maneuverFinalCueMissed
    case offlineRouteDeparture, offlineRouteRejoined, speechDeliveryFailed
    case breakReminderShown, breakReminderAnnounced, fuelReminderShown, fuelReminderAnnounced
    case routeSearchCompleted, routeSearchDiscarded, routeStopAdded, routeStopFailed
}

/// Produces useful driving diagnostics without ever recording coordinates or
/// a location trail. Accuracy and speed are enough to distinguish a guidance
/// bug from a weak GPS fix when a real drive is reviewed later.
enum DriveDiagnosticDetail {
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
    static let didChange = Notification.Name("KiesDriveDiagnosticStoreDidChange")
    private static let key = "drive.diagnostics.v1"
    private static let maximumCount = 100
    private static let maximumPriorityCount = 30

    private static let priorityKinds: Set<DriveDiagnosticKind> = [
        .rerouteRequested, .rerouteSucceeded, .rerouteFailed, .routeRejoined,
        .maneuverFinalCueMissed, .speechDeliveryFailed,
        .offlineRouteDeparture, .offlineRouteRejoined,
    ]

    static func load(defaults: UserDefaults = .standard) -> [DriveDiagnosticEvent] {
        guard let data = defaults.data(forKey: key) else { return [] }
        return (try? JSONDecoder().decode([DriveDiagnosticEvent].self, from: data)) ?? []
    }

    static func append(_ kind: DriveDiagnosticKind, detail: String, defaults: UserDefaults = .standard) {
        var events = load(defaults: defaults)
        events.append(.init(kind: kind, detail: detail))
        if events.count > maximumCount {
            events = bounded(events)
        }
        if let data = try? JSONEncoder().encode(events) {
            defaults.set(data, forKey: key)
            NotificationCenter.default.post(name: didChange, object: nil)
        }
    }

    static func bounded(_ events: [DriveDiagnosticEvent]) -> [DriveDiagnosticEvent] {
        guard events.count > maximumCount else { return events }
        let latestStartIndex = events.lastIndex { $0.kind == .navigationStarted }
        let session = latestStartIndex.map { events[$0...] } ?? events[...]
        let priority = session.filter { priorityKinds.contains($0.kind) }
            .suffix(maximumPriorityCount)
        var retained = Set(priority.map(\.id))
        if let latestStartIndex { retained.insert(events[latestStartIndex].id) }
        for event in events.reversed() where retained.count < maximumCount {
            retained.insert(event.id)
        }
        // Filtering the original array retains chronological order even for
        // events sharing the same timestamp.
        return events.filter { retained.contains($0.id) }
    }

    static func clear(defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key)
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
    let fuelRemindersShown: Int
    let fuelRemindersAnnounced: Int
    let missedFinalCues: Int
    let speechDeliveryFailures: Int
    let offlineRouteDepartures: Int
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
        let parts = event.detail.split(separator: "·").map {
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
            guard let instruction = speechInstruction(in: failure) else { return true }
            return !indexed.indices.dropFirst(index + 1).contains { laterIndex in
                let later = indexed[laterIndex]
                return (later.kind == .maneuverAnnounced ||
                        later.kind == .breakReminderAnnounced ||
                        later.kind == .fuelReminderAnnounced) &&
                    speechInstruction(in: later) == instruction
            }
        }.count
    }

    static func latestSession(in events: [DriveDiagnosticEvent]) -> Self? {
        guard let start = events.lastIndex(where: { $0.kind == .navigationStarted }) else { return nil }
        let afterStart = events.index(after: start)..<events.endIndex
        let terminal = afterStart.first(where: {
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
        let offlineDepartures = unresolvedOffline.filter { $0.kind == .offlineRouteDeparture }.count
        let resolved = max(0, totalFailures - failures) +
            max(0, totalOfflineDepartures - offlineDepartures) +
            max(0, totalSpeechFailures - speechFailures)
        let reroutes = session.filter { $0.kind == .rerouteRequested }.count
        let quality: Quality
        let recommendation: String
        if failures > 0 || missed > 0 || offlineDepartures > 0 || speechFailures > 0 {
            quality = .critical
            if missed > 0 {
                recommendation = "Fahrhinweise prüfen; mindestens eine letzte Abbiegeansage fehlte."
            } else if speechFailures > 0 {
                recommendation = "Die letzte Fahransage wurde vom Audiosystem nicht beendet; Bluetooth- und Lautstärkeeinstellungen prüfen."
            } else if offlineDepartures > 0 {
                recommendation = "Die gespeicherte Route wurde verlassen und noch nicht online ersetzt."
            } else {
                recommendation = "Die letzte Neuberechnung ist noch fehlgeschlagen; die alte Route blieb aktiv."
            }
        } else if rejectedBurst >= 3 || recoveredLocationGaps >= 3 || reroutes >= 3 {
            quality = .attention
            if rejectedBurst >= 3 {
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
        let shownFuel = session.filter { $0.kind == .fuelReminderShown }.count
        let spokenFuel = session.filter { $0.kind == .fuelReminderAnnounced }.count
        return .init(quality: quality, eventCount: session.count,
                     rerouteRequests: reroutes,
                     rerouteFailures: failures, rejectedLocations: rejected,
                     recoveredLocationGaps: recoveredLocationGaps,
                     arrivals: arrivals, maneuverAnnouncements: maneuvers,
                     breakRemindersShown: shownBreaks,
                     breakRemindersAnnounced: spokenBreaks,
                     fuelRemindersShown: shownFuel,
                     fuelRemindersAnnounced: spokenFuel,
                     missedFinalCues: missed, speechDeliveryFailures: speechFailures,
                     offlineRouteDepartures: offlineDepartures,
                     resolvedRouteIssues: resolved, recommendation: recommendation)
    }
}

enum DriveDiagnosticReport {
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
            "\(formatter.string(from: $0.date)) | \($0.kind.rawValue) | \($0.detail.replacingOccurrences(of: "\n", with: " "))"
        }
        return lines.joined(separator: "\n")
    }
}
