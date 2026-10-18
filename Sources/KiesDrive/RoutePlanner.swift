import Foundation
import MapKit
import AVFoundation

private enum FuelStationLoadOutcome {
    case batch([FuelStation])
    case superseded
}

private enum SpeedLimitLoadOutcome {
    case main([SpeedLimitResult])
    case comparison([SpeedLimitResult])
    case superseded
}

private enum BreakDetourLoadOutcome {
    case measurement(String, CLLocationDistance?)
    case superseded
}

private extension Array {
    subscript(safe index: Int) -> Element? { indices.contains(index) ? self[index] : nil }
}

/// Für den Offline-Fallback zwischengespeicherte Routen- und Tankstellendaten -
/// bewusst schlank (kein `MKRoute`, das ist nicht `Codable`), damit die letzte
/// berechnete Route auch ohne Netzverbindung als Text/Liste angezeigt werden kann.
/// Eine echte Offline-Kartendarstellung bietet MapKit über keine öffentliche API an.
struct CachedRoute: Codable {
    struct Step: Codable {
        let instructions: String
        let distance: Double
        /// Optional keeps caches from earlier releases decodable. New caches
        /// store per-maneuver geometry so guidance can continue without a
        /// fresh MapKit route after a restart or network outage.
        let coordinates: [DriveCoordinate]?

        init(instructions: String, distance: Double, coordinates: [DriveCoordinate]? = nil) {
            self.instructions = instructions
            self.distance = distance
            self.coordinates = coordinates
        }
    }
    struct Leg: Codable {
        let distance: Double
        let travelTime: TimeInterval
        let steps: [Step]
        /// Simplified route geometry. Optional keeps caches written by older
        /// versions decodable after an app update.
        let coordinates: [DriveCoordinate]?
    }
    let destinationName: String
    /// Identifies the exact persisted trip that produced this geometry. It is
    /// optional so caches written by older app versions still decode, but an
    /// untagged cache never receives extended active-trip retention.
    let tripID: UUID?
    /// Optional for backwards compatibility with caches written before the
    /// destination identity was anchored geographically.
    let destinationCoordinate: DriveCoordinate?
    /// Fingerprint of required waypoints and per-segment route rules. Optional
    /// keeps old files decodable, but an untagged cache cannot restore a
    /// locked trip whose constraints it cannot prove it represents.
    let routeConstraintIdentity: String?
    let legs: [Leg]
    let stations: [FuelStation]
    let savedAt: Date
    /// Progress on this exact cached geometry. The trip lock's progress refers
    /// to the original corridor and can differ substantially after a reroute.
    let navigationProgress: Double?

    init(destinationName: String, tripID: UUID? = nil,
         destinationCoordinate: DriveCoordinate?, routeConstraintIdentity: String? = nil,
         legs: [Leg],
         stations: [FuelStation], savedAt: Date,
         navigationProgress: Double? = nil) {
        self.destinationName = destinationName
        self.tripID = tripID
        self.destinationCoordinate = destinationCoordinate
        self.routeConstraintIdentity = routeConstraintIdentity
        self.legs = legs
        self.stations = stations
        self.savedAt = savedAt
        self.navigationProgress = navigationProgress
    }

    func updatingNavigationProgress(_ progress: Double) -> CachedRoute {
        guard progress.isFinite else { return self }
        return .init(
            destinationName: destinationName, tripID: tripID,
            destinationCoordinate: destinationCoordinate,
            routeConstraintIdentity: routeConstraintIdentity, legs: legs,
            stations: stations, savedAt: savedAt,
            navigationProgress: min(1, max(navigationProgress ?? 0, progress))
        )
    }
}

enum OfflineRouteCacheValidationPolicy {
    static func isValid(_ route: CachedRoute) -> Bool {
        guard !route.destinationName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              route.savedAt.timeIntervalSinceReferenceDate.isFinite,
              route.destinationCoordinate.map(isValid) ?? true,
              route.navigationProgress.map({ $0.isFinite && (0...1).contains($0) }) ?? true,
              !route.legs.isEmpty,
              route.legs.allSatisfy(isValid),
              route.legs.contains(where: { $0.distance > 0 }),
              route.stations.allSatisfy(isValid)
        else { return false }
        return true
    }

    private static func isValid(_ leg: CachedRoute.Leg) -> Bool {
        guard leg.distance.isFinite, leg.distance >= 0,
              leg.travelTime.isFinite, leg.travelTime >= 0,
              leg.coordinates?.allSatisfy(isValid) ?? true,
              leg.steps.allSatisfy({ step in
                step.distance.isFinite && step.distance >= 0
                    && (step.coordinates?.allSatisfy(isValid) ?? true)
              }) else { return false }
        // Legacy text-only caches remain decodable but cannot start offline
        // guidance. Once a leg contains guidance geometry, however, every
        // material step must have a usable line; accepting a partial mixture
        // could silently jump over the missing maneuver after a restart.
        let containsGuidanceGeometry = leg.steps.contains {
            ($0.coordinates?.count ?? 0) > 1
        }
        guard !containsGuidanceGeometry || leg.steps.allSatisfy({ step in
            step.distance <= 1 || (step.coordinates?.count ?? 0) > 1
        }) else { return false }
        return true
    }

    private static func isValid(_ station: FuelStation) -> Bool {
        isValid(.init(latitude: station.lat, longitude: station.lon))
            && station.price.isFinite && station.price >= 0
            && station.distanceKm.isFinite && station.distanceKm >= 0
    }

    private static func isValid(_ coordinate: DriveCoordinate) -> Bool {
        coordinate.latitude.isFinite && coordinate.longitude.isFinite
            && (-90...90).contains(coordinate.latitude)
            && (-180...180).contains(coordinate.longitude)
    }
}

enum OfflineRouteCacheWritePolicy {
    static func progressForWrite(existing: CachedRoute?, currentTripID: UUID?,
                                 preservingProgress: Bool) -> Double? {
        if preservingProgress, existing?.tripID == currentTripID,
           let progress = existing?.navigationProgress {
            return progress
        }
        // Every newly installed geometry starts at its own 0%, even if the
        // original locked holiday corridor is already mostly complete.
        return currentTripID == nil ? nil : 0
    }

    static func progressForResume(cacheProgress: Double?,
                                  hasConstraintIdentity: Bool,
                                  legacyTripProgress: Double?) -> Double? {
        if let cacheProgress { return cacheProgress }
        // A constraint-bound cache owns an independent geometry cursor.
        // Never borrow progress from the differently shaped trip corridor.
        return hasConstraintIdentity ? 0 : legacyTripProgress
    }
}

struct OfflineRouteCacheStore {
    let fileURL: URL
    private var backupURL: URL { fileURL.appendingPathExtension("backup") }

    static func live(fileManager: FileManager = .default) -> Self {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return .init(fileURL: base.appendingPathComponent("KiesDrive", isDirectory: true)
            .appendingPathComponent("offline-route.json"))
    }

    func load() -> CachedRoute? {
        decode(at: fileURL) ?? decode(at: backupURL)
    }

    @discardableResult
    func save(_ route: CachedRoute, fileManager: FileManager = .default) -> Bool {
        guard OfflineRouteCacheValidationPolicy.isValid(route) else { return false }
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(route)
            if let previousData = try? Data(contentsOf: fileURL),
               let previous = decode(previousData), sameJourney(previous, route) {
                // Keep the exact previous valid geometry until the new atomic
                // replacement has completed. A checkpoint from another trip
                // must never be eligible for this destination.
                try previousData.write(to: backupURL, options: .atomic)
            } else if decode(at: backupURL).map({ sameJourney($0, route) }) != true {
                try? fileManager.removeItem(at: backupURL)
            }
            // The app sandbox protects the file. Atomic replacement prevents a
            // crash or full disk from leaving a half-written route that cannot
            // be restored on the next launch.
            try data.write(to: fileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    func clear(fileManager: FileManager = .default) {
        if fileManager.fileExists(atPath: fileURL.path) {
            try? fileManager.removeItem(at: fileURL)
        }
        if fileManager.fileExists(atPath: backupURL.path) {
            try? fileManager.removeItem(at: backupURL)
        }
    }

    private func decode(at url: URL) -> CachedRoute? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return decode(data)
    }

    private func decode(_ data: Data) -> CachedRoute? {
        guard let route = try? JSONDecoder().decode(CachedRoute.self, from: data),
              OfflineRouteCacheValidationPolicy.isValid(route) else { return nil }
        return route
    }

    private func sameJourney(_ lhs: CachedRoute, _ rhs: CachedRoute) -> Bool {
        if let lhsID = lhs.tripID, let rhsID = rhs.tripID { return lhsID == rhsID }
        guard lhs.tripID == nil, rhs.tripID == nil else { return false }
        return OfflineRouteCachePolicy.matches(
            cacheName: lhs.destinationName,
            cacheCoordinate: lhs.destinationCoordinate?.clLocationCoordinate,
            destinationName: rhs.destinationName,
            destinationCoordinate: rhs.destinationCoordinate?.clLocationCoordinate
        )
    }
}

struct RouteSearchResult: Identifiable {
    let id: String
    let mapItem: MKMapItem
    let detourMetres: CLLocationDistance
    let detourIsEstimated: Bool
    let queryRelevance: Double
    let routeProgress: Double
    let routeGeneration: UUID
}

@MainActor
final class RoutePlanner: NSObject, ObservableObject, @preconcurrency AVSpeechSynthesizerDelegate {
    /// Shared by the phone UI and CarPlay so both surfaces operate on the
    /// same route, stops and long-trip plan.
    static let shared = RoutePlanner()
    @Published var destinationText = "" {
        didSet {
            guard destinationText != oldValue else { return }
            // Text-field edits happen independently of the explicit search
            // button. Invalidate and cancel immediately so results for the
            // old address neither consume MapKit work nor remain tappable
            // under the new query while it is still being entered.
            destinationSearchGeneration = UUID()
            activeDestinationSearches.forEach { $0.cancel() }
            activeDestinationSearches = []
            suggestions = []
        }
    }
    @Published var suggestions: [MKMapItem] = []
    @Published var destination: MKMapItem?
    @Published var viaStations: [FuelStation] = []
    @Published var legs: [MKRoute] = []
    @Published var alternatives: [MKRoute] = []
    @Published var stations: [FuelStation] = []
    @Published var isLoading = false
    @Published var errorMessage: String?
    @Published var isRecalculating = false
    @Published var lastAnnouncement: String?
    @Published var speedWarning: Bool = false
    @Published var offlineRoute: CachedRoute?
    @Published var longTripPlan: LongTripPlan?
    @Published var isNavigating = false {
        didSet {
            guard isNavigating != oldValue else { return }
            // Navigation may begin through the phone UI, CarPlay, offline
            // restore or MCP. Core Location must follow the authoritative
            // planner state instead of relying on a particular view being
            // alive to forward this transition.
            LocationService.shared.setNavigationActive(isNavigating)
        }
    }
    @Published var activeRouteLock: ActiveRouteLock?
    @Published var routeSearchQuery = ""
    @Published var routeSearchResults: [RouteSearchResult] = []
    @Published var routeSearchMessage: String?
    @Published var isSearchingAlongRoute = false
    @Published private(set) var nextManeuverIdentity: String?
    @Published var nextManeuverInstruction: String?
    @Published var nextManeuverDistance: CLLocationDistance?
    @Published var upcomingManeuverInstructions: [String] = []
    @Published var remainingDistanceMetres: CLLocationDistance = 0
    @Published var remainingTravelTime: TimeInterval = 0
    @Published var hasArrived = false
    @Published var breakReminderText: String?
    @Published var fuelReminderText: String?
    @Published private(set) var usageStatistics = DriveUsageStatisticsStore.load()
    @Published private(set) var isUsingOfflineGuidance = false
    @Published private(set) var isManeuverGuidanceReliable = true
    var isMatchingOfflinePosition: Bool {
        isUsingOfflineGuidance && offlineNeedsInitialPositionMatch
    }
    private var comparisonRoute: MKRoute?
    private var researchedStandardToll: TollCost = .unknown(reason: "Mautrecherche läuft noch.")
    private var researchedAvoidingToll: TollCost = .unknown(reason: "Mautfreie Route wird geprüft.")
    private var tollLookupSnapshots: [Bool: TollLookupSnapshot] = [:]
    private var amenityBreakCandidates: [BreakCandidate] = []
    private var measuredBreakDetours: [String: CLLocationDistance] = [:]

    /// Tempolimits entlang der Route, parallel zu `speedLimitPoints` indiziert.
    private var speedLimitPoints: [CLLocationCoordinate2D] = []
    private var speedLimits: [SpeedLimitResult] = []
    private var comparisonSpeedLimitPoints: [CLLocationCoordinate2D] = []
    private var comparisonSpeedLimits: [SpeedLimitResult] = []

    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var activeSpeechPriority: NavigationSpeechPriority?
    private var audioSessionInterrupted = false
    private var navigationStepCursor = 0
    private var announcedManeuverStages: [String: Set<NavigationAnnouncementStage>] = [:]
    private struct ManeuverSpeechClaim {
        let key: String
        let stage: NavigationAnnouncementStage
        let instruction: String
        let distance: CLLocationDistance
        let issuedAt: Date
    }
    private var pendingManeuverSpeech: [ObjectIdentifier: [ManeuverSpeechClaim]] = [:]
    private var activeManeuverSpeech: [ObjectIdentifier: [ManeuverSpeechClaim]] = [:]
    private struct BreakReminderSpeechClaim {
        let stage: NavigationBreakReminderPolicy.Stage
        let issuedAt: Date
    }
    private var pendingBreakReminderSpeech: [ObjectIdentifier: BreakReminderSpeechClaim] = [:]
    private var activeBreakReminderSpeech: [ObjectIdentifier: BreakReminderSpeechClaim] = [:]
    private struct FuelReminderSpeechClaim {
        let key: String
        let text: String
        let issuedAt: Date
    }
    private var pendingFuelReminderSpeech: [ObjectIdentifier: FuelReminderSpeechClaim] = [:]
    private var activeFuelReminderSpeech: [ObjectIdentifier: FuelReminderSpeechClaim] = [:]
    private var diagnosticManeuverKey: String?
    private var diagnosticManeuverInstruction: String?
    private var diagnosticManeuverDistance: CLLocationDistance?
    private var offRouteSince: Date?
    private var offRouteFixCount = 0
    private var onRouteRecoveryFixCount = 0
    private var previousOffRouteDistance: CLLocationDistance?
    private var lastRerouteAt: Date?
    private var consecutiveRerouteFailures = 0
    private var navigationSessionGeneration = UUID()
    private var rerouteGeneration = UUID()
    /// Owns the actual MapKit work behind an automatic reroute. Generation
    /// checks protect publication, while cancellation also stops obsolete
    /// network work after a timeout or navigation stop.
    private var activeAutomaticRerouteTask: Task<Void, Never>?
    private var lastAcceptedNavigationLocation: CLLocation?
    private let usageSessionStore = DriveUsageSessionStore.live
    @Published private(set) var usageSessionState = DriveUsageSessionStore.live.load()
    private var usageSessionLastLocation: CLLocation?
    private var lastReliableGuidanceSpeedMps: Double?
    private var lastReliableGuidanceSpeedAt: Date?
    private var lastLocationRejectionLoggedAt: Date?
    private var lastOfflineRecoveryAttempt: Date?
    private var offlineNeedsInitialPositionMatch = false
    private var offlineInitialMatchStepIndex: Int?
    private var offlineDeviationWarningActive = false
    private var arrivalStrikes = 0
    private var arrivalCandidateSince: Date?
    private var stationLoadGeneration = UUID()
    private var breakCandidateLoadGeneration = UUID()
    private var breakDetourLoadGeneration = UUID()
    private var stopPlanningGeneration = UUID()
    private var speedLimitLoadGeneration = UUID()
    private var comparisonSpeedLimitLoadGeneration = UUID()
    private var tollLoadGeneration = UUID()
    private var routeCalculationGeneration = UUID()
    private var routeOptionMutationGeneration = UUID()
    private struct RouteOptionMutationSnapshot {
        let lock: ActiveRouteLock?
        let avoidTolls: Bool
        let avoidHighways: Bool
    }
    private var routeOptionMutationSnapshot: RouteOptionMutationSnapshot?
    private struct RouteStopMutationSnapshot {
        let lock: ActiveRouteLock?
        let stations: [FuelStation]
        let searchResults: [RouteSearchResult]
        let searchQuery: String
    }
    private var routeStopMutationGeneration = UUID()
    private var routeStopMutationSnapshot: RouteStopMutationSnapshot?
    /// Volatile identity for MapKit route objects. Unlike the offline cache,
    /// live `MKRoute` values cannot be persisted, but they still must never be
    /// resumed for a different destination after a failed recalculation.
    private var liveRouteDestinationCoordinate: CLLocationCoordinate2D?
    /// Global options that produced the currently installed `legs`. Route
    /// previews do not have a trip lock yet, so this is their authoritative
    /// rollback baseline when a settings toggle cannot be recalculated.
    private var installedDefaultRouteOptions: LockedRouteOptions?
    private var destinationSearchGeneration = UUID()
    private var destinationActivationGeneration = UUID()
    private struct DestinationActivationSnapshot {
        let destination: MKMapItem?
        let destinationText: String
        let lock: ActiveRouteLock?
    }
    private var destinationActivationSnapshot: DestinationActivationSnapshot?
    private var routeSearchGeneration = UUID()
    private var activeDestinationSearches: [MKLocalSearch] = []
    private var activeRouteSearches: [MKLocalSearch] = []
    private var activeAmenitySearches: [MKLocalSearch] = []
    private var automaticRestoreInProgress = false
    private var lastAutomaticRestoreAttempt: Date?
    private var lastRouteProgressPersistedAt: Date?
    private var lastOfflineProgressPersistedAt: Date?
    private var lastUsageSessionPersistedAt: Date?
    private var lastDrivingStatePersistedAt: Date?
    private var lastLongTripPlanRefreshAt: Date?
    /// A waypoint is only persisted after the replacement route has been
    /// committed. Keeping the in-flight identity here prevents every GPS fix
    /// near the same point from starting another MapKit calculation.
    private var pendingReachedWaypointID: String?
    private var deliveredBreakReminderStages: Set<NavigationBreakReminderPolicy.Stage> {
        get {
            Set(drivingRestState.deliveredReminderRawValues.compactMap(
                NavigationBreakReminderPolicy.Stage.init(rawValue:)
            ))
        }
        set {
            guard let updated = DrivingRestReminderStatePolicy.changedRawValues(
                current: drivingRestState.deliveredReminderRawValues, stages: newValue
            ) else { return }
            drivingRestState.deliveredReminderRawValues = updated
            drivingRestStore.save(drivingRestState)
        }
    }

    private enum DestinationSearchOutcome {
        case results([MKMapItem])
        case noResults
        case failed(String)
        case timedOut
    }
    private enum RouteSearchDetourOutcome {
        case candidate(RouteSearchResult?)
        case superseded
    }
    private let drivingRestStore = DrivingRestStateStore.live
    private var drivingRestState = DrivingRestStateStore.live.load()
    private let drivingFuelStore = DrivingFuelStateStore.live
    private var drivingFuelState = DrivingFuelStateStore.live.load()
    private static let cacheKey = "drive.offlineRoute"
    private static let offlineCacheStore = OfflineRouteCacheStore.live()
    private let routeLockStore = RouteLockStore.shared

    override init() {
        super.init()
        synthesizer.delegate = self
        #if os(iOS)
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(handleAudioSessionInterruption(_:)),
            name: AVAudioSession.interruptionNotification,
            object: AVAudioSession.sharedInstance()
        )
        #endif
        offlineRoute = Self.loadCache()
        // Never install a personal preset on a fresh device. Public builds
        // restore only a trip the signed-in driver deliberately created.
        activeRouteLock = routeLockStore.activeLock
        if let lock = activeRouteLock {
            destinationText = lock.destinationName
            let item = MKMapItem(placemark: MKPlacemark(coordinate: lock.destination.clLocationCoordinate))
            item.name = lock.destinationName
            destination = item
        }
    }

    /// Erste Teilstrecke - für Rückwärtskompatibilität und schnellen Zugriff
    /// auf die "Hauptroute" (ohne Zwischenstopp identisch mit der Gesamtroute).
    var route: MKRoute? { legs.first }
    var totalDistance: Double { legs.reduce(0) { $0 + $1.distance } }
    var totalTravelTime: TimeInterval { legs.reduce(0) { $0 + $1.expectedTravelTime } }
    var completeRouteMapRect: MKMapRect? {
        guard !legs.isEmpty else { return nil }
        return legs.reduce(MKMapRect.null) { $0.union($1.polyline.boundingMapRect) }
    }
    var usableOfflineRoute: CachedRoute? {
        guard let cache = offlineRoute,
              OfflineRouteAvailabilityPolicy.isUsable(
                savedAt: cache.savedAt,
                cacheName: cache.destinationName,
                cacheCoordinate: cache.destinationCoordinate?.clLocationCoordinate,
                destinationName: destination?.name ?? (destinationText.isEmpty ? nil : destinationText),
                destinationCoordinate: destination?.placemark.coordinate,
                belongsToActiveTrip: belongsToActiveTrip(cache)
              ) else { return nil }
        return cache
    }
    var offlinePolylines: [MKPolyline] {
        usableOfflineRoute?.legs.compactMap { leg in
            guard let values = leg.coordinates, values.count > 1 else { return nil }
            var coordinates = values.map(\.clLocationCoordinate)
            return MKPolyline(coordinates: &coordinates, count: coordinates.count)
        } ?? []
    }
    var completeDisplayMapRect: MKMapRect? {
        if let completeRouteMapRect { return completeRouteMapRect }
        guard !offlinePolylines.isEmpty else { return nil }
        return offlinePolylines.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
    }

    var selectedAlternativeIndex: Int? {
        guard let selected = legs.first else { return nil }
        return alternatives.firstIndex { $0 === selected }
    }

    func selectAlternative(at index: Int, settings: DriveSettings) {
        guard alternatives.indices.contains(index), !isNavigating,
              selectedAlternativeIndex != index else { return }
        // An alternative is a new authoritative geometry, even though origin
        // and destination stay the same. Invalidate every asynchronous
        // enrichment tied to the previously selected polyline before
        // publishing the replacement; otherwise a late station, speed-limit
        // or toll response can be rendered on the wrong road.
        let selectionGeneration = UUID()
        routeCalculationGeneration = selectionGeneration
        routeSearchGeneration = UUID()
        activeRouteSearches.forEach { $0.cancel() }
        activeRouteSearches = []
        activeAmenitySearches.forEach { $0.cancel() }
        activeAmenitySearches = []
        routeSearchResults = []
        routeSearchMessage = nil
        isSearchingAlongRoute = false
        let selectedRoute = alternatives[index]
        let selectedOrigin = RouteGeometryEndpointPolicy.origin(
            coordinates: sample(selectedRoute.polyline, maximum: 2),
            fallback: selectedRoute.polyline.coordinate
        )
        legs = [selectedRoute]
        resetLiveNavigationProgress()
        seedInitialNavigationPresentation()
        remainingDistanceMetres = totalDistance
        remainingTravelTime = totalTravelTime
        stations = []
        amenityBreakCandidates = []
        speedLimitPoints = []
        speedLimits = []
        comparisonSpeedLimitPoints = []
        comparisonSpeedLimits = []
        speedWarning = false
        researchedStandardToll = .unknown(reason: "Maut für die gewählte Route wird geprüft.")
        researchedAvoidingToll = .unknown(reason: "Mautfreie Alternative wird geprüft.")
        longTripPlan = nil
        stopPlanningGeneration = UUID()
        measuredBreakDetours = [:]
        cacheForOffline()
        buildLongTripPlan(settings: settings)
        Task { [weak self] in
            guard let self,
                  selectionGeneration == self.routeCalculationGeneration else { return }
            async let stopPlanning: Void = self.reloadStopPlanning(
                fuel: settings.fuel, settings: settings, reloadAmenities: true
            )
            async let speedLimits: Void = self.loadSpeedLimits()
            async let tollCost: Void = self.loadTollCost(from: selectedOrigin, settings: settings)
            _ = await (stopPlanning, speedLimits, tollCost)
            guard selectionGeneration == self.routeCalculationGeneration else { return }
            self.buildLongTripPlan(settings: settings)
            self.cacheForOffline(preservingProgress: true)
        }
    }

    func startNavigation(voiceGuidance: Bool? = nil) {
        guard !legs.isEmpty else { return }
        let shouldSpeak = voiceGuidance ?? DriveSettings.shared.voiceGuidance
        isUsingOfflineGuidance = false
        persistActiveTrip()
        // `calculate` may have written its first cache while a preview still
        // had no trip lock. Bind the exact same geometry to the now-persisted
        // trip before guidance starts, so an immediate network loss or app
        // termination cannot leave only an anonymous short-lived cache.
        cacheForOffline(preservingProgress: true)
        beginNavigationSession()
        isNavigating = true
        hasArrived = false
        resetLiveNavigationProgress()
        lastAnnouncement = nextInstruction ?? "Route gestartet"
        let opening = lastAnnouncement.map { "Route gestartet. \(NavigationSpeechFormatter.spokenText($0))" }
            ?? "Route gestartet."
        if shouldSpeak { speak(opening, priority: .status) }
        DriveDiagnosticStore.append(.navigationStarted, detail: destination?.name ?? destinationText)
    }

    func stopNavigation() {
        let wasNavigating = isNavigating
        if wasNavigating { closeOutstandingManeuverDiagnostic(reason: .userStopped) }
        if wasNavigating {
            // Pausing guidance is not the end of the persistent trip. Keep
            // aggregate distance/time for a later restore, but deliberately
            // drop the last coordinate so no location trail is persisted.
            usageSessionLastLocation = nil
            usageSessionStore.save(usageSessionState)
            if let tripID = activeRouteLock?.id ?? routeLockStore.activeLock?.id {
                drivingRestState = DrivingRestPolicy.paused(
                    drivingRestState, tripID: tripID, at: Date(),
                    speedMetresPerSecond: lastAcceptedNavigationLocation.flatMap(
                        NavigationMotionPolicy.reliableSpeed(for:)
                    )
                )
                drivingRestStore.save(drivingRestState)
            }
        }
        invalidateNavigationAsyncWork()
        isNavigating = false
        isUsingOfflineGuidance = false
        cancelCurrentSpeechWork()
        lastAnnouncement = nil
        speedWarning = false
        // A persistent trip remains resumable, but cancelling guidance must
        // not make the very next GPS fix restart it immediately.
        lastAutomaticRestoreAttempt = Date()
        if wasNavigating {
            DriveDiagnosticStore.append(.navigationStopped,
                                        detail: destination?.name ?? destinationText)
        }
    }

    func setVoiceGuidanceEnabled(_ enabled: Bool) {
        if !enabled {
            synthesizer.stopSpeaking(at: .immediate)
            pendingManeuverSpeech = [:]
            activeManeuverSpeech = [:]
            pendingBreakReminderSpeech = [:]
            activeBreakReminderSpeech = [:]
            pendingFuelReminderSpeech = [:]
            activeFuelReminderSpeech = [:]
            diagnosticManeuverKey = nil
            diagnosticManeuverInstruction = nil
            diagnosticManeuverDistance = nil
            activeUtterance = nil
            activeSpeechPriority = nil
            if drivingRestState.pendingSpokenReminderRawValue != nil {
                drivingRestState.pendingSpokenReminderRawValue = nil
                drivingRestStore.save(drivingRestState)
            }
            if drivingFuelState.pendingSpokenReminderKey != nil ||
                drivingFuelState.pendingSpokenReminderText != nil {
                drivingFuelState.clearPendingSpeech()
                drivingFuelStore.save(drivingFuelState)
            }
            #if os(iOS)
            // `didCancel` normally releases this session, but Bluetooth route
            // changes can delay or omit that callback. Muting is an immediate
            // user command and must restore music volume deterministically.
            try? AVAudioSession.sharedInstance().setActive(
                false, options: .notifyOthersOnDeactivation
            )
            #endif
        }
    }

    /// Plays a deliberate sample from settings without changing the normal
    /// guidance toggle. Never interrupts live driving instructions.
    @discardableResult
    func previewNavigationVoice() -> Bool {
        guard !isNavigating else { return false }
        return speak(
            "In 500 Metern rechts abbiegen auf die Autobahn A 66, Richtung Wiesbaden.",
            priority: .status
        )
    }

    /// Beendet den Trip bewusst. Ein normales Stoppen/Pausieren der Navigation
    /// loescht den Lock dagegen nicht, damit Rast und App-Neustart sicher sind.
    func completeActiveTrip() {
        stopNavigation()
        DriveDiagnosticStore.finishActiveSession()
        finishUsageSession()
        routeLockStore.finish()
        activeRouteLock = nil
        routeLockStore.clearFinished()
        clearCompletedTripPlanningState()
        clearCompletedRoutePresentation(preservingArrival: false)
    }

    private func clearCompletedTripPlanningState() {
        drivingRestState = DrivingRestState()
        drivingRestStore.clear()
        breakReminderText = nil
        fuelReminderText = nil
        drivingFuelState = DrivingFuelState()
        drivingFuelStore.clear()
    }

    private func clearCompletedRoutePresentation(preservingArrival: Bool) {
        // Invalidate every slow provider before clearing its published state;
        // otherwise a fuel/toll response finishing just after arrival can
        // repaint a completed journey on the phone, CarPlay or MCP.
        routeCalculationGeneration = UUID()
        stationLoadGeneration = UUID()
        breakCandidateLoadGeneration = UUID()
        breakDetourLoadGeneration = UUID()
        speedLimitLoadGeneration = UUID()
        comparisonSpeedLimitLoadGeneration = UUID()
        tollLoadGeneration = UUID()
        routeSearchGeneration = UUID()
        activeRouteSearches.forEach { $0.cancel() }
        activeRouteSearches = []
        activeAmenitySearches.forEach { $0.cancel() }
        activeAmenitySearches = []
        legs = []
        liveRouteDestinationCoordinate = nil
        alternatives = []
        comparisonRoute = nil
        stations = []
        viaStations = []
        amenityBreakCandidates = []
        measuredBreakDetours = [:]
        speedLimitPoints = []
        speedLimits = []
        comparisonSpeedLimitPoints = []
        comparisonSpeedLimits = []
        routeSearchResults = []
        routeSearchMessage = nil
        isSearchingAlongRoute = false
        longTripPlan = nil
        clearOfflineCache()
        remainingDistanceMetres = 0
        remainingTravelTime = 0
        if !preservingArrival {
            nextManeuverIdentity = nil
            nextManeuverInstruction = nil
            nextManeuverDistance = nil
            upcomingManeuverInstructions = []
            hasArrived = false
        }
    }

    private func persistActiveTrip() {
        guard let destination else { return }
        let coordinate = destination.placemark.coordinate
        let options = LockedRouteOptions(avoidTolls: DriveSettings.shared.avoidTolls,
                                         avoidHighways: DriveSettings.shared.avoidHighways)
        let existing = routeLockStore.activeLock
        let waypoints: [LockedWaypoint]
        if let existing, existing.isActive {
            waypoints = existing.waypoints
        } else {
            waypoints = viaStations.map {
                LockedWaypoint(id: $0.id, name: $0.brand.isEmpty ? $0.name : $0.brand,
                               coordinate: .init(latitude: $0.lat, longitude: $0.lon),
                               required: true, optionsAfter: nil)
            }
        }
        let lock = ActiveRouteLock(
            id: existing?.id ?? UUID(), title: existing?.title ?? (destination.name ?? destinationText),
            destinationName: destination.name ?? destinationText,
            destination: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
            waypoints: waypoints, defaultOptions: existing?.defaultOptions ?? options,
            corridorWidthMetres: existing?.corridorWidthMetres ?? 5_000,
            corridorPoints: existing?.corridorPoints ?? legs.flatMap { sample($0.polyline, maximum: 120) }
                .map { .init(latitude: $0.latitude, longitude: $0.longitude) },
            visitedWaypointIDs: existing?.visitedWaypointIDs ?? [],
            status: .active, createdAt: existing?.createdAt ?? Date(), updatedAt: Date()
        )
        routeLockStore.save(lock)
        activeRouteLock = lock
        if drivingRestState.tripID != lock.id {
            drivingRestState = DrivingRestState(tripID: lock.id)
            drivingRestStore.save(drivingRestState)
            deliveredBreakReminderStages = []
            breakReminderText = nil
            fuelReminderText = nil
        }
        if drivingFuelState.tripID != lock.id {
            drivingFuelState = DrivingFuelState(
                tripID: lock.id,
                observedFuelFraction: min(1, max(0, DriveSettings.shared.departureFuelPercent / 100))
            )
            drivingFuelStore.save(drivingFuelState)
        }
    }

    func confirmFullTank(settings: DriveSettings) {
        confirmFuelLevel(1, settings: settings)
    }

    @discardableResult
    func confirmRestBreak(settings: DriveSettings, at date: Date = Date()) -> Bool {
        guard let tripID = activeRouteLock?.id ?? routeLockStore.activeLock?.id else {
            errorMessage = "Es ist keine aktive Reise vorhanden."
            return false
        }
        let reliableSpeed = lastAcceptedNavigationLocation.flatMap(
            NavigationMotionPolicy.reliableSpeed(for:)
        )
        guard DrivingRestConfirmationPolicy.mayConfirm(
            sampleAt: lastAcceptedNavigationLocation?.timestamp,
            reliableSpeedMetresPerSecond: reliableSpeed,
            now: date
        ) else {
            errorMessage = "Die Pause kann erst bei einem aktuellen Stillstand bestätigt werden."
            return false
        }
        drivingRestState = DrivingRestPolicy.confirmedBreak(
            drivingRestState, tripID: tripID, at: date
        )
        drivingRestStore.save(drivingRestState)
        breakReminderText = nil
        lastLongTripPlanRefreshAt = date
        buildLongTripPlan(settings: settings)
        return true
    }

    func confirmFuelLevel(_ fraction: Double, settings: DriveSettings) {
        guard let tripID = activeRouteLock?.id ?? routeLockStore.activeLock?.id else { return }
        drivingFuelState = DrivingFuelPolicy.confirmed(
            drivingFuelState, tripID: tripID, fraction: min(1, max(0, fraction)),
            location: lastAcceptedNavigationLocation
        )
        drivingFuelStore.save(drivingFuelState)
        buildLongTripPlan(settings: settings)
    }

    /// Keeps the fatigue clock truthful while a persistent trip is paused or
    /// waiting for route restoration. This deliberately updates neither route
    /// progress nor driven-distance statistics: it only observes whether the
    /// vehicle is still moving or has completed a real restorative stop.
    func observePausedTripRest(at location: CLLocation) {
        guard !isNavigating,
              let tripID = activeRouteLock?.id ?? routeLockStore.activeLock?.id,
              let speed = NavigationMotionPolicy.reliableSpeed(for: location)
        else { return }
        let previousContinuousDriving = drivingRestState.continuousDriving
        drivingRestState = DrivingRestPolicy.updated(
            drivingRestState, tripID: tripID, at: location.timestamp,
            speedMetresPerSecond: speed
        )
        if NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: lastDrivingStatePersistedAt, now: location.timestamp
        ) || (previousContinuousDriving > 0 && drivingRestState.continuousDriving == 0) {
            drivingRestStore.save(drivingRestState)
            lastDrivingStatePersistedAt = location.timestamp
        }
        if previousContinuousDriving > 0 && drivingRestState.continuousDriving == 0 {
            deliveredBreakReminderStages = []
            breakReminderText = nil
            buildLongTripPlan(settings: .shared)
        }
    }

    func estimatedFuelFraction(settings: DriveSettings) -> Double {
        guard let tripID = activeRouteLock?.id ?? routeLockStore.activeLock?.id else {
            return min(1, max(0, settings.departureFuelPercent / 100))
        }
        return DrivingFuelPolicy.estimatedFraction(
            drivingFuelState,
            tripID: tripID,
            tankCapacityLitres: settings.tankCapacityL,
            consumptionLPer100km: settings.consumptionLPer100km,
            fallback: settings.departureFuelPercent / 100
        )
    }

    var currentInstalledRouteProgress: Double {
        let distanceProgress = RouteSearchPolicy.installedRouteProgress(
            totalDistance: totalDistance,
            remainingDistance: remainingDistanceMetres,
            navigationActive: isNavigating
        )
        return RouteSearchPolicy.currentProgress(
            projected: distanceProgress,
            persisted: activeRouteLock?.lastRouteProgress,
            navigationActive: isNavigating
        )
    }

    /// Einmaliger Wiederanlauf nach App-Start. Erst mit einer echten Position
    /// wird neu gerechnet; dadurch setzt MapKit am passenden aktuellen
    /// Routenabschnitt an, waehrend Pflichtpunkte und Segmentregeln erhalten bleiben.
    @discardableResult
    func restoreActiveTripIfNeeded(from current: CLLocationCoordinate2D,
                                   settings: DriveSettings) async -> Bool {
        guard NavigationDestinationCoordinatePolicy.isValid(current) else { return false }
        guard let lock = routeLockStore.activeLock, lock.isActive else { return false }
        guard let restoreConstraintSnapshot = RouteCalculationConstraintSnapshot(lock) else {
            return false
        }
        // Another surface (phone scene, CarPlay or remote bridge) may already
        // own the same restore. Treat that as accepted work instead of a
        // failure; its result will publish through the shared planner state.
        if isNavigating || automaticRestoreInProgress { return true }
        guard RouteLockRestorePolicy.shouldAttempt(
            navigationActive: isNavigating,
            attemptInProgress: automaticRestoreInProgress,
            lastAttempt: lastAutomaticRestoreAttempt
        ) else { return false }
        automaticRestoreInProgress = true
        lastAutomaticRestoreAttempt = Date()
        defer { automaticRestoreInProgress = false }
        activeRouteLock = lock
        destinationText = lock.destinationName
        let item = MKMapItem(placemark: MKPlacemark(coordinate: lock.destination.clLocationCoordinate))
        item.name = lock.destinationName
        destination = item
        let onlineCalculationSucceeded = await calculate(from: current, settings: settings)
        // Finishing, replacing or editing the trip while MapKit was awaiting
        // a response revokes this restore. Never let an old result restart a
        // route the driver has just ended or materially changed.
        guard RouteRestoreCommitPolicy.mayResume(
            expected: restoreConstraintSnapshot,
            current: RouteCalculationConstraintSnapshot(routeLockStore.activeLock)
        ) else { return false }
        let hasMatchingLiveRoute = !legs.isEmpty && NavigationDestinationIdentityPolicy.matches(
            liveRouteDestinationCoordinate, lock.destination.clLocationCoordinate
        )
        let hasMatchingOfflineRoute = offlineRoute.map {
            let exactTrip = belongsToActiveTrip($0)
            let available = OfflineRouteAvailabilityPolicy.isUsable(
                savedAt: $0.savedAt,
                cacheName: $0.destinationName,
                cacheCoordinate: $0.destinationCoordinate?.clLocationCoordinate,
                destinationName: destination?.name ?? (destinationText.isEmpty ? nil : destinationText),
                destinationCoordinate: destination?.placemark.coordinate,
                belongsToActiveTrip: exactTrip
            )
            return OfflineRouteGuidanceEligibilityPolicy.mayStart(
                available: available, belongsToExactActiveTrip: exactTrip
            ) && $0.legs.flatMap(\.steps).contains { ($0.coordinates?.count ?? 0) > 1 }
        } ?? false
        switch RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: onlineCalculationSucceeded,
            hasMatchingLiveRoute: hasMatchingLiveRoute,
            hasMatchingOfflineRoute: hasMatchingOfflineRoute
        ) {
        case .online, .staleLive:
            startNavigation(voiceGuidance: settings.voiceGuidance)
            return isNavigating
        case .offline:
            return startOfflineGuidanceIfAvailable(replacingLiveRoute: true)
        case .unavailable:
            return false
        }
    }

    @discardableResult
    func restoreActiveTrip(from current: CLLocationCoordinate2D,
                           settings: DriveSettings) async -> Bool {
        lastAutomaticRestoreAttempt = nil
        return await restoreActiveTripIfNeeded(from: current, settings: settings)
    }

    func installCroatiaSplitTripLock() {
        let lock = ActiveRouteLock.croatiaSplit()
        finishReplacedUsageTripIfNeeded(previousTripID: routeLockStore.activeLock?.id,
                                        nextTripID: lock.id)
        routeLockStore.save(lock)
        activeRouteLock = lock
        destinationText = lock.destinationName
        let item = MKMapItem(placemark: MKPlacemark(coordinate: lock.destination.clLocationCoordinate))
        item.name = lock.destinationName
        destination = item
        stopNavigation()
        lastAutomaticRestoreAttempt = nil
        legs = []
        liveRouteDestinationCoordinate = nil
        alternatives = []
    }

    func installHochheimViaWurzenpassTripLock() {
        let lock = ActiveRouteLock.hochheimViaWurzenpass()
        finishReplacedUsageTripIfNeeded(previousTripID: routeLockStore.activeLock?.id,
                                        nextTripID: lock.id)
        routeLockStore.save(lock)
        activeRouteLock = lock
        destinationText = lock.destinationName
        let item = MKMapItem(placemark: MKPlacemark(coordinate: lock.destination.clLocationCoordinate))
        item.name = lock.destinationName
        destination = item
        stopNavigation()
        lastAutomaticRestoreAttempt = nil
        legs = []
        liveRouteDestinationCoordinate = nil
        alternatives = []
    }

    func updateLockedRouteOptions(waypointID: String?, avoidTolls: Bool?, avoidHighways: Bool?) {
        routeOptionMutationGeneration = UUID()
        routeOptionMutationSnapshot = nil
        applyLockedRouteOptions(
            waypointID: waypointID, avoidTolls: avoidTolls, avoidHighways: avoidHighways
        )
    }

    private func applyLockedRouteOptions(
        waypointID: String?, avoidTolls: Bool?, avoidHighways: Bool?
    ) {
        routeLockStore.update { lock in
            if let waypointID, let index = lock.waypoints.firstIndex(where: { $0.id == waypointID }) {
                var options = lock.waypoints[index].optionsAfter ?? lock.defaultOptions
                if let avoidTolls { options.avoidTolls = avoidTolls }
                if let avoidHighways { options.avoidHighways = avoidHighways }
                lock.waypoints[index].optionsAfter = options
            } else {
                if let avoidTolls { lock.defaultOptions.avoidTolls = avoidTolls }
                if let avoidHighways { lock.defaultOptions.avoidHighways = avoidHighways }
            }
        }
        activeRouteLock = routeLockStore.activeLock
    }

    /// Applies remote/user route preferences as one transaction. A failed
    /// MapKit calculation restores the previous lock and global settings as
    /// long as no newer edit or waypoint progress has superseded this one.
    @discardableResult
    func updateRouteOptionsAndRecalculate(
        waypointID rawWaypointID: String?, avoidTolls: Bool?, avoidHighways: Bool?,
        from start: CLLocationCoordinate2D, settings: DriveSettings
    ) async -> Bool {
        let waypointID = RouteOptionScopePolicy.waypointID(rawWaypointID)
        if let waypointID,
           routeLockStore.activeLock?.waypoints.contains(where: { $0.id == waypointID }) != true {
            errorMessage = "Der angegebene Routenabschnitt wurde nicht gefunden."
            return false
        }
        let mutationGeneration = UUID()
        routeOptionMutationGeneration = mutationGeneration
        let settingsBaseline = RouteOptionSettingsBaselinePolicy.baseline(
            waypointID: waypointID,
            activeDefaults: routeLockStore.activeLock?.defaultOptions ??
                installedDefaultRouteOptions,
            currentAvoidTolls: settings.avoidTolls,
            currentAvoidHighways: settings.avoidHighways
        )
        let rollback = RouteMutationBaselinePolicy.choose(
            existing: routeOptionMutationSnapshot,
            current: RouteOptionMutationSnapshot(
                lock: routeLockStore.activeLock,
                avoidTolls: settingsBaseline.avoidTolls,
                avoidHighways: settingsBaseline.avoidHighways
            )
        )
        routeOptionMutationSnapshot = rollback
        defer {
            if mutationGeneration == routeOptionMutationGeneration {
                routeOptionMutationSnapshot = nil
            }
        }
        if RouteOptionScopePolicy.mutatesGlobalSettings(waypointID: waypointID) {
            if let avoidTolls { settings.avoidTolls = avoidTolls }
            if let avoidHighways { settings.avoidHighways = avoidHighways }
        }
        applyLockedRouteOptions(
            waypointID: waypointID, avoidTolls: avoidTolls, avoidHighways: avoidHighways
        )
        let mutatedLock = routeLockStore.activeLock
        let mutatedSettings = (avoidTolls: settings.avoidTolls,
                               avoidHighways: settings.avoidHighways)
        guard await recalculateCurrentRoute(from: start, settings: settings) else {
            guard mutationGeneration == routeOptionMutationGeneration else { return false }
            let didRestoreLock: Bool
            if let currentLock = routeLockStore.activeLock,
               let mutatedLock,
               let baselineLock = rollback.lock,
               let restored = RouteOptionRollbackPolicy.restoringOptions(
                   current: currentLock, mutated: mutatedLock, baseline: baselineLock
               ) {
                routeLockStore.replace(with: restored)
                activeRouteLock = restored
                didRestoreLock = true
            } else if RouteMutationRollbackPolicy.shouldRollback(
                current: routeLockStore.activeLock, mutated: mutatedLock
            ) {
                routeLockStore.replace(with: rollback.lock)
                activeRouteLock = rollback.lock
                didRestoreLock = true
            } else {
                didRestoreLock = false
            }
            if didRestoreLock,
               settings.avoidTolls == mutatedSettings.avoidTolls,
               settings.avoidHighways == mutatedSettings.avoidHighways {
                settings.avoidTolls = rollback.avoidTolls
                settings.avoidHighways = rollback.avoidHighways
            }
            return false
        }
        return true
    }

    /// Recalculates user- or remote-edited options without allowing a delayed
    /// MapKit result to outlive the navigation session that requested it.
    @discardableResult
    func recalculateCurrentRoute(from start: CLLocationCoordinate2D,
                                 settings: DriveSettings) async -> Bool {
        let navigationSession = isNavigating ? navigationSessionGeneration : nil
        return await calculate(
            from: start, settings: settings,
            navigationSession: navigationSession
        )
    }

    func replaceRouteLockForRemoteDestination(waypoints: [LockedWaypoint] = []) {
        guard let destination else { return }
        let coordinate = destination.placemark.coordinate
        let lock = ActiveRouteLock(
            id: UUID(), title: destination.name ?? destinationText,
            destinationName: destination.name ?? destinationText,
            destination: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
            waypoints: waypoints,
            defaultOptions: .init(avoidTolls: DriveSettings.shared.avoidTolls,
                                  avoidHighways: DriveSettings.shared.avoidHighways),
            corridorWidthMetres: 5_000, corridorPoints: nil, visitedWaypointIDs: [],
            status: .active, createdAt: Date(), updatedAt: Date())
        routeLockStore.save(lock)
        activeRouteLock = lock
    }

    /// Atomically switches to a completely new destination. A failed route
    /// request restores the previous destination and trip lock, preventing a
    /// new label from being shown on top of an old route.
    @discardableResult
    func activateDestination(_ item: MKMapItem, from start: CLLocationCoordinate2D,
                             settings: DriveSettings,
                             requiredWaypoints: [LockedWaypoint] = []) async -> Bool {
        guard NavigationDestinationCoordinatePolicy.isValid(start) else {
            errorMessage = "Der aktuelle Standort ist nicht gültig. Bitte warte auf ein neues GPS-Signal."
            return false
        }
        guard NavigationDestinationCoordinatePolicy.isValid(item.placemark.coordinate) else {
            errorMessage = "Das ausgewählte Ziel hat keinen gültigen Standort."
            return false
        }
        let activationGeneration = UUID()
        // A destination replacement started during guidance belongs to that
        // exact session. Stopping or arriving while MapKit is still working
        // must prevent its delayed result from restarting navigation.
        let navigationSession = isNavigating ? navigationSessionGeneration : nil
        destinationActivationGeneration = activationGeneration
        let rollback = DestinationActivationBaselinePolicy.choose(
            existing: destinationActivationSnapshot,
            current: DestinationActivationSnapshot(
                destination: destination,
                destinationText: destinationText,
                lock: routeLockStore.activeLock
            )
        )
        destinationActivationSnapshot = rollback
        defer {
            if activationGeneration == destinationActivationGeneration {
                destinationActivationSnapshot = nil
            }
        }
        destinationSearchGeneration = UUID()
        suggestions = []
        destination = item
        destinationText = item.name ?? item.placemark.title ?? "Ziel"
        replaceRouteLockForRemoteDestination(waypoints: requiredWaypoints)
        guard await calculate(
            from: start, settings: settings,
            navigationSession: navigationSession
        ) else {
            // A newer destination may already be calculating. The older
            // request is allowed to fail, but it must never restore its stale
            // destination and route-lock snapshot over the latest selection.
            guard DestinationActivationRollbackPolicy.shouldRollback(
                request: activationGeneration, current: destinationActivationGeneration
            ) else { return false }
            destination = rollback.destination
            destinationText = rollback.destinationText
            routeLockStore.replace(with: rollback.lock)
            activeRouteLock = rollback.lock
            return false
        }
        // `calculate` committed the route, but actor reentrancy allows a new
        // destination selection or an explicit navigation stop to occur
        // before this continuation resumes. Only the still-current selection
        // may finish the previous trip and start guidance.
        guard DestinationActivationRollbackPolicy.isCurrent(
            request: activationGeneration, current: destinationActivationGeneration
        ), NavigationAsyncWorkPolicy.mayCommitCalculation(
            navigationActive: isNavigating,
            session: navigationSession,
            currentSession: navigationSessionGeneration,
            work: nil,
            currentWork: rerouteGeneration
        ) else { return false }
        finishReplacedUsageTripIfNeeded(previousTripID: rollback.lock?.id,
                                        nextTripID: routeLockStore.activeLock?.id)
        startNavigation(voiceGuidance: settings.voiceGuidance)
        return true
    }

    var nextInstruction: String? {
        if let nextManeuverInstruction { return nextManeuverInstruction }
        return legs.lazy
            .flatMap(\.steps)
            .first(where: { !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .instructions
    }

    func searchDestination(near coordinate: CLLocationCoordinate2D?) async {
        let query = destinationText.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = UUID()
        destinationSearchGeneration = generation
        activeDestinationSearches.forEach { $0.cancel() }
        activeDestinationSearches = []
        suggestions = []
        errorMessage = nil
        guard query.count > 2 else { return }
        var requests: [MKLocalSearch.Request] = []
        if let coordinate {
            let local = MKLocalSearch.Request()
            local.naturalLanguageQuery = query
            local.region = .init(center: coordinate, latitudinalMeters: 100_000,
                                 longitudinalMeters: 100_000)
            requests.append(local)
        }
        // A region is a strong MapKit ranking hint. Pair it with an unbiased
        // request so a remote holiday destination such as Split cannot lose
        // to a similarly named nearby business or district.
        let global = MKLocalSearch.Request()
        global.naturalLanguageQuery = query
        requests.append(global)
        let searches = requests.map(MKLocalSearch.init(request:))
        activeDestinationSearches = searches
        let outcome = await withTaskGroup(of: DestinationSearchOutcome.self) {
            group -> DestinationSearchOutcome in
            for search in searches {
                group.addTask {
                    do { return .results(try await search.start().mapItems) }
                    catch { return .failed(error.localizedDescription) }
                }
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: NavigationSearchTimeoutPolicy.timeoutNanoseconds)
                return .timedOut
            }
            var results: [MKMapItem] = []
            var failures: [String] = []
            var completedSearches = 0
            while let next = await group.next() {
                switch next {
                case .results(let items):
                    results.append(contentsOf: items)
                    completedSearches += 1
                case .noResults:
                    completedSearches += 1
                case .failed(let detail):
                    failures.append(detail)
                    completedSearches += 1
                case .timedOut:
                    searches.forEach { $0.cancel() }
                    group.cancelAll()
                    return results.isEmpty
                        ? DestinationSearchOutcome.timedOut
                        : DestinationSearchOutcome.results(results)
                }
                if completedSearches == searches.count {
                    group.cancelAll()
                    switch DestinationSearchBatchCompletionPolicy.resolution(
                        resultCount: results.count,
                        failureCount: failures.count,
                        searchCount: searches.count
                    ) {
                    case .results:
                        return .results(results)
                    case .noResults:
                        return .noResults
                    case .failed:
                        return .failed(failures.first ?? "Unbekannter Suchfehler")
                    }
                }
            }
            return results.isEmpty
                ? DestinationSearchOutcome.timedOut
                : DestinationSearchOutcome.results(results)
        }
        searches.forEach { $0.cancel() }
        guard DestinationSearchCompletionPolicy.mayPublish(
            request: generation, currentRequest: destinationSearchGeneration,
            query: query, currentText: destinationText
        ) else { return }
        activeDestinationSearches = []
        switch outcome {
        case .results(let items):
            let origin = coordinate.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
            let ordered = items.sorted { lhs, rhs in
                let lhsRelevance = DestinationSearchRankingPolicy.relevanceScore(
                    query: query, name: lhs.name, title: lhs.placemark.title
                )
                let rhsRelevance = DestinationSearchRankingPolicy.relevanceScore(
                    query: query, name: rhs.name, title: rhs.placemark.title
                )
                if lhsRelevance != rhsRelevance { return lhsRelevance < rhsRelevance }
                guard let origin else { return (lhs.name ?? "") < (rhs.name ?? "") }
                return origin.distance(from: CLLocation(
                    latitude: lhs.placemark.coordinate.latitude,
                    longitude: lhs.placemark.coordinate.longitude
                )) < origin.distance(from: CLLocation(
                    latitude: rhs.placemark.coordinate.latitude,
                    longitude: rhs.placemark.coordinate.longitude
                ))
            }
            suggestions = ordered.reduce(into: [MKMapItem]()) { result, item in
                guard result.count < 12,
                      !result.contains(where: {
                          DestinationSearchRankingPolicy.isDuplicate(
                            name: item.name, coordinate: item.placemark.coordinate,
                            existingName: $0.name, existingCoordinate: $0.placemark.coordinate
                          )
                      }) else { return }
                result.append(item)
            }
        case .noResults:
            errorMessage = "Kein Ziel gefunden. Bitte Ort, Straße oder Hausnummer genauer eingeben."
        case .failed(let detail):
            errorMessage = "Zielsuche fehlgeschlagen: \(detail)"
        case .timedOut:
            errorMessage = "Zielsuche dauert zu lange. Bitte erneut versuchen."
        }
    }

    /// Sucht POIs entlang der bereits berechneten Route statt nur am aktuellen
    /// Standort. Wenige Suchregionen und ein enger Korridor vermeiden Umwege.
    func searchAlongRoute(_ query: String) async {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = UUID()
        routeSearchGeneration = generation
        activeRouteSearches.forEach { $0.cancel() }
        activeRouteSearches = []
        guard !legs.isEmpty, !cleanQuery.isEmpty else {
            routeSearchQuery = cleanQuery
            routeSearchResults = []
            routeSearchMessage = nil
            isSearchingAlongRoute = false
            return
        }
        // Results belong to the exact query that produced them. Leaving the
        // previous list visible while MapKit searches lets a fast tap add an
        // old petrol station after the user has already asked for a restaurant
        // (the route generation can legitimately still be identical). Clear
        // synchronously; the new request publishes its own complete list only
        // after both POI and detour validation finish.
        routeSearchResults = []
        routeSearchMessage = nil
        isSearchingAlongRoute = true
        let routeGeneration = routeCalculationGeneration
        routeSearchQuery = cleanQuery
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 180) }
        let projectedRouteProgress: Double? = {
            guard let location = LocationService.shared.location,
                  let projection = RouteGeometryProgress.nearestProgress(
                    of: location.coordinate, on: routeCoordinates,
                    progressRange: currentRouteProgressSearchRange
                  ), projection.distance <= 5_000 else { return nil }
            return projection.progress
        }()
        let installedRouteProgress = RouteSearchPolicy.installedRouteProgress(
            totalDistance: totalDistance,
            remainingDistance: remainingDistanceMetres,
            navigationActive: isNavigating
        )
        let currentRouteProgress = RouteSearchPolicy.currentProgress(
            projected: RouteSearchPolicy.installedProgress(
                projected: projectedRouteProgress,
                distanceEstimate: installedRouteProgress
            ),
            persisted: activeRouteLock?.lastRouteProgress ?? routeLockStore.activeLock?.lastRouteProgress,
            navigationActive: isNavigating
        )
        let remainingCoordinates = RouteSearchPolicy.remainingRouteCoordinates(
            routeCoordinates, currentProgress: currentRouteProgress
        )
        let searchPoints = evenlySpaced(
            remainingCoordinates,
            maximum: NavigationSearchBatchPolicy.maximumConcurrentRouteSearches
        )
        let searchRadius = RouteSearchPolicy.searchRadiusMetres(
            routeCoordinates: remainingCoordinates, searchPointCount: searchPoints.count
        )
        var matches: [String: MKMapItem] = [:]
        let searches = searchPoints.map { point -> MKLocalSearch in
            let request = MKLocalSearch.Request()
            request.naturalLanguageQuery = cleanQuery
            request.region = .init(center: point, latitudinalMeters: searchRadius,
                                   longitudinalMeters: searchRadius)
            return MKLocalSearch(request: request)
        }
        activeRouteSearches = searches
        for item in await boundedMapSearchResults(searches) {
            let c = item.placemark.coordinate
            // Overlapping search regions commonly return the same chain or
            // service-area POI with a few metres of coordinate drift. Merge
            // those before launching expensive driving-detour requests.
            guard !matches.values.contains(where: { existing in
                DestinationSearchRankingPolicy.isDuplicate(
                    name: item.name, coordinate: c,
                    existingName: existing.name,
                    existingCoordinate: existing.placemark.coordinate,
                    toleranceMetres: 80
                )
            }) else { continue }
            matches["\(item.name ?? ""):\(c.latitude):\(c.longitude)"] = item
        }
        switch RouteSearchCompletionPolicy.disposition(
            request: generation, currentRequest: routeSearchGeneration,
            routeGeneration: routeGeneration, currentRouteGeneration: routeCalculationGeneration,
            query: cleanQuery, currentQuery: routeSearchQuery
        ) {
        case .publish:
            break
        case .discardAndFinish:
            DriveDiagnosticStore.append(
                .routeSearchDiscarded,
                detail: "POI-Suche verworfen · Route oder Suchtext geändert"
            )
            finishRouteSearch(generation: generation, clearResults: true)
            return
        case .superseded:
            return
        }
        activeRouteSearches = []
        let candidates = matches.values.compactMap {
            item -> (item: MKMapItem, progress: Double, airDistance: Double,
                     anchors: RouteSearchPolicy.DetourAnchors)? in
            guard let projection = RouteGeometryProgress.nearestProgress(
                of: item.placemark.coordinate, on: routeCoordinates,
                progressRange: max(0, currentRouteProgress - 0.02)...1
            ) else { return nil }
            guard projection.distance <= 5_000,
                  RouteSearchPolicy.isAhead(candidateProgress: projection.progress,
                                            currentProgress: currentRouteProgress,
                                            totalRouteDistance: totalDistance),
                  let anchors = RouteSearchPolicy.detourAnchors(
                    routeCoordinates: routeCoordinates, progress: projection.progress
                  ) else { return nil }
            return (item, projection.progress, projection.distance, anchors)
        }
        .sorted {
            $0.progress == $1.progress ? $0.airDistance < $1.airDistance : $0.progress < $1.progress
        }
        // Route only a small shortlist. This is a user-triggered search, but
        // dozens of MKDirections requests would still make the screen lag and
        // can trigger provider throttling.
        let shortlist = RouteSearchPolicy.diverseShortlist(
            candidates, maximum: 6,
            progress: { $0.progress }, airDistance: { $0.airDistance },
            queryRelevance: {
                DestinationSearchRankingPolicy.relevanceScore(
                    query: cleanQuery,
                    name: $0.item.name,
                    title: $0.item.placemark.title
                )
            }
        )
        let remainingRouteDistance = isNavigating && remainingDistanceMetres > 0
            ? remainingDistanceMetres : totalDistance
        var routed: [RouteSearchResult] = []
        var detourSearchWasSuperseded = false
        await withTaskGroup(of: RouteSearchDetourOutcome.self) { group in
            for candidate in shortlist {
                group.addTask { [weak self] in
                    let driven = await self?.drivingDetour(
                        through: candidate.item, anchors: candidate.anchors
                    )
                    guard let detour = driven ?? RouteSearchPolicy.estimatedDetour(
                        airDistance: candidate.airDistance
                    ) else { return .candidate(nil) }
                    guard RouteSearchPolicy.acceptsDetour(
                        detour, remainingRouteDistance: remainingRouteDistance
                    ) else { return .candidate(nil) }
                    let coordinate = candidate.item.placemark.coordinate
                    return .candidate(RouteSearchResult(
                        id: "\(candidate.item.name ?? ""): \(coordinate.latitude):\(coordinate.longitude)",
                        mapItem: candidate.item,
                        detourMetres: detour,
                        detourIsEstimated: driven == nil,
                        queryRelevance: DestinationSearchRankingPolicy.relevanceScore(
                            query: cleanQuery,
                            name: candidate.item.name,
                            title: candidate.item.placemark.title
                        ),
                        routeProgress: candidate.progress,
                        routeGeneration: routeGeneration
                    ))
                }
            }
            // MKDirections requests used for detour measurement are more
            // expensive than the POI search itself. Observe route/query
            // ownership while they run so a new search cancels their entire
            // task tree instead of leaving up to six obsolete requests alive
            // until their individual network timeouts.
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { break }
                    guard let self else { return .superseded }
                    if !(await self.isCurrentRouteSearch(
                        generation: generation, routeGeneration: routeGeneration,
                        query: cleanQuery
                    )) { return .superseded }
                }
                return .superseded
            }
            var remainingCandidates = shortlist.count
            while remainingCandidates > 0, let outcome = await group.next() {
                switch outcome {
                case .candidate(let result):
                    remainingCandidates -= 1
                    if let result { routed.append(result) }
                case .superseded:
                    detourSearchWasSuperseded = true
                    group.cancelAll()
                    return
                }
            }
            group.cancelAll()
        }
        if detourSearchWasSuperseded { return }
        switch RouteSearchCompletionPolicy.disposition(
            request: generation, currentRequest: routeSearchGeneration,
            routeGeneration: routeGeneration, currentRouteGeneration: routeCalculationGeneration,
            query: cleanQuery, currentQuery: routeSearchQuery
        ) {
        case .publish:
            break
        case .discardAndFinish:
            DriveDiagnosticStore.append(
                .routeSearchDiscarded,
                detail: "Umwegprüfung verworfen · Route oder Suchtext geändert"
            )
            finishRouteSearch(generation: generation, clearResults: true)
            return
        case .superseded:
            return
        }
        routeSearchResults = routed.sorted {
            let lhs = RouteSearchPolicy.rankingScore(
                detourMetres: $0.detourMetres,
                candidateProgress: $0.routeProgress,
                currentProgress: currentRouteProgress,
                remainingRouteDistance: remainingRouteDistance,
                queryRelevance: $0.queryRelevance
            )
            let rhs = RouteSearchPolicy.rankingScore(
                detourMetres: $1.detourMetres,
                candidateProgress: $1.routeProgress,
                currentProgress: currentRouteProgress,
                remainingRouteDistance: remainingRouteDistance,
                queryRelevance: $1.queryRelevance
            )
            return lhs == rhs ? $0.detourMetres < $1.detourMetres : lhs < rhs
        }
        DriveDiagnosticStore.append(
            .routeSearchCompleted,
            detail: "POI \(matches.count) · Korridor \(candidates.count) · Umweg geprüft \(shortlist.count) · zulässig \(routeSearchResults.count)"
        )
        routeSearchMessage = RouteSearchEmptyResultPolicy.message(
            mapMatches: matches.count,
            corridorMatches: candidates.count,
            acceptableDetours: routeSearchResults.count
        )
        isSearchingAlongRoute = false
    }

    private func finishRouteSearch(generation: UUID, clearResults: Bool) {
        guard generation == routeSearchGeneration else { return }
        activeRouteSearches.forEach { $0.cancel() }
        activeRouteSearches = []
        if clearResults {
            routeSearchResults = []
            routeSearchMessage = nil
        }
        isSearchingAlongRoute = false
    }

    private func isCurrentRouteSearch(generation: UUID, routeGeneration: UUID,
                                      query: String) -> Bool {
        RouteSearchCompletionPolicy.disposition(
            request: generation, currentRequest: routeSearchGeneration,
            routeGeneration: routeGeneration,
            currentRouteGeneration: routeCalculationGeneration,
            query: query, currentQuery: routeSearchQuery
        ) == .publish
    }

    /// Constrains current-position matching around route progress already known
    /// from navigation. At a bridge, cloverleaf or route loop, pure geometric
    /// proximity can otherwise snap the driver to a much earlier/later visit of
    /// the same coordinate and hide useful stops that are still ahead.
    private var currentRouteProgressSearchRange: ClosedRange<Double>? {
        guard isNavigating, totalDistance > 0, remainingDistanceMetres > 0 else { return nil }
        let expected = min(1, max(0, 1 - remainingDistanceMetres / totalDistance))
        return max(0, expected - 0.08)...min(1, expected + 0.12)
    }

    private func drivingDetour(through item: MKMapItem,
                               anchors: RouteSearchPolicy.DetourAnchors) async
        -> CLLocationDistance? {
        let entry = MKMapItem(placemark: MKPlacemark(coordinate: anchors.entry))
        let exit = MKMapItem(placemark: MKPlacemark(coordinate: anchors.exit))
        do {
            async let outbound = Self.drivingDistance(from: entry, to: item)
            async let inbound = Self.drivingDistance(from: item, to: exit)
            let viaDistance = try await outbound + inbound
            return RouteSearchPolicy.additionalDistance(
                viaDistance: viaDistance, baselineDistance: anchors.baselineMetres
            )
        } catch {
            return nil
        }
    }

    private nonisolated static func drivingDistance(from source: MKMapItem,
                                                     to destination: MKMapItem) async throws
        -> CLLocationDistance {
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = false
        guard let route = try await calculateDirections(
            request, timeout: NavigationDirectionsTimeoutPolicy.detourCalculation
        ).first else {
            throw DriveAPIError.invalidData
        }
        return route.distance
    }

    /// Cancels the underlying MapKit object, not just the awaiting Swift task.
    /// That distinction matters in weak coverage: otherwise a timed-out
    /// request can keep radio/network work alive and delay later reroutes.
    private nonisolated static func calculateDirections(
        _ request: MKDirections.Request, timeout: TimeInterval
    ) async throws -> [MKRoute] {
        let directions = MKDirections(request: request)
        return try await withThrowingTaskGroup(of: [MKRoute].self) { group in
            group.addTask { try await directions.calculate().routes }
            group.addTask {
                try await Task.sleep(
                    nanoseconds: NavigationDirectionsTimeoutPolicy.nanoseconds(for: timeout)
                )
                directions.cancel()
                throw NavigationDirectionsTimeoutError()
            }
            defer {
                group.cancelAll()
                directions.cancel()
            }
            guard let first = try await group.next() else {
                throw DriveAPIError.invalidData
            }
            return first
        }
    }

    @discardableResult
    func addRouteStop(_ item: MKMapItem, from start: CLLocationCoordinate2D,
                      settings: DriveSettings,
                      knownRouteProgress: Double? = nil,
                      expectedRouteGeneration: UUID? = nil) async -> Bool {
        guard RouteSearchSelectionPolicy.accepts(
            resultRouteGeneration: expectedRouteGeneration,
            currentRouteGeneration: routeCalculationGeneration
        ) else {
            errorMessage = "Die Route wurde inzwischen neu berechnet. Bitte suche den Zwischenstopp erneut."
            return false
        }
        let navigationSession = isNavigating ? navigationSessionGeneration : nil
        let candidateRollback = RouteStopMutationSnapshot(
            lock: routeLockStore.activeLock,
            stations: viaStations,
            searchResults: routeSearchResults,
            searchQuery: routeSearchQuery
        )
        // A user may add a stop while merely previewing a calculated route,
        // before tapping Start. Materialise the lock here so the action never
        // appears to succeed while silently doing nothing.
        if routeLockStore.activeLock == nil { persistActiveTrip() }
        guard routeLockStore.activeLock != nil else {
            errorMessage = "Zwischenstopp konnte nicht gespeichert werden."
            return false
        }
        let coordinate = item.placemark.coordinate
        let stopName = item.name ?? "Zwischenstopp"
        guard mayInsertRouteStop(at: coordinate) else { return false }
        if routeLockStore.activeLock?.containsEquivalentStop(
            name: stopName, coordinate: coordinate
        ) == true {
            errorMessage = "Dieser Zwischenstopp ist bereits in der Route."
            return false
        }
        // A route-search result already has an unambiguous progress value.
        // Reuse it so a POI beside a later parallel carriageway or a route
        // crossing cannot be inserted into an earlier locked segment.
        let searchedProgress = routeSearchResults.first(where: { result in
            let resultCoordinate = result.mapItem.placemark.coordinate
            return CLLocation(latitude: resultCoordinate.latitude, longitude: resultCoordinate.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) <= 30
        })?.routeProgress
        let selectedProgress = knownRouteProgress ?? searchedProgress
        if isNavigating, let selectedProgress {
            let currentProgress = currentInstalledRouteProgress(from: start)
            guard RouteSearchPolicy.isAhead(
                candidateProgress: selectedProgress,
                currentProgress: currentProgress,
                totalRouteDistance: totalDistance
            ) else {
                errorMessage = "Dieser Zwischenstopp liegt inzwischen hinter dir."
                routeSearchResults.removeAll { result in
                    let resultCoordinate = result.mapItem.placemark.coordinate
                    return CLLocation(
                        latitude: resultCoordinate.latitude,
                        longitude: resultCoordinate.longitude
                    ).distance(from: CLLocation(
                        latitude: coordinate.latitude,
                        longitude: coordinate.longitude
                    )) <= 30
                }
                return false
            }
        }
        // Only a request that will actually mutate the route may supersede an
        // in-flight mutation. A duplicate/behind tap must not steal rollback
        // ownership from the calculation already running for the first tap.
        let mutationGeneration = UUID()
        routeStopMutationGeneration = mutationGeneration
        let rollback = RouteMutationBaselinePolicy.choose(
            existing: routeStopMutationSnapshot,
            current: candidateRollback
        )
        routeStopMutationSnapshot = rollback
        defer {
            if mutationGeneration == routeStopMutationGeneration {
                routeStopMutationSnapshot = nil
            }
        }
        insertLockedWaypoint(id: "poi-\(UUID().uuidString)", name: stopName,
                             coordinate: coordinate,
                             knownProgress: selectedProgress,
                             kind: .userStop)
        let mutatedLock = routeLockStore.activeLock
        routeSearchResults = []
        routeSearchMessage = nil
        isSearchingAlongRoute = false
        let succeeded = await calculate(
            from: start, settings: settings,
            navigationSession: navigationSession
        )
        guard succeeded else {
            guard mutationGeneration == routeStopMutationGeneration else { return false }
            guard RouteMutationRollbackPolicy.shouldRollback(
                current: routeLockStore.activeLock, mutated: mutatedLock
            ) else { return false }
            routeLockStore.replace(with: rollback.lock)
            activeRouteLock = rollback.lock
            viaStations = rollback.stations
            routeSearchQuery = rollback.searchQuery
            routeSearchResults = rollback.searchResults
            isSearchingAlongRoute = false
            DriveDiagnosticStore.append(
                .routeStopFailed,
                detail: "Zwischenstopp nicht berechenbar · \(stopName)"
            )
            return false
        }
        // `calculate` deliberately preserves `isNavigating`. A stop added to
        // a preview therefore stays a preview, while an active drive continues
        // seamlessly without a second "Route gestartet" announcement or an
        // unnecessary second navigation reset.
        DriveDiagnosticStore.append(.routeStopAdded, detail: stopName)
        return true
    }

    /// Reconciles map matching and distance remaining for every UI path that
    /// can insert a stop. Search results, station pins and planned breaks must
    /// all use the same forward-only cursor at motorway crossings.
    private func currentInstalledRouteProgress(from coordinate: CLLocationCoordinate2D) -> Double {
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 180) }
        let projectedProgress = RouteGeometryProgress.nearestProgress(
            of: coordinate, on: routeCoordinates,
            progressRange: currentRouteProgressSearchRange
        )?.progress
        let distanceProgress = RouteSearchPolicy.installedRouteProgress(
            totalDistance: totalDistance,
            remainingDistance: remainingDistanceMetres,
            navigationActive: isNavigating
        )
        return RouteSearchPolicy.currentProgress(
            projected: RouteSearchPolicy.installedProgress(
                projected: projectedProgress, distanceEstimate: distanceProgress
            ),
            persisted: activeRouteLock?.lastRouteProgress ??
                routeLockStore.activeLock?.lastRouteProgress,
            navigationActive: isNavigating
        )
    }

    var removableRouteStops: [LockedWaypoint] {
        activeRouteLock?.waypoints.filter(\.isRemovableComfortStop) ?? []
    }

    /// Compatibility-only station state that has not already been promoted
    /// into the persistent route lock. Locked fuel stops are shown through
    /// `removableRouteStops`; exposing both produced duplicate remove actions.
    var transientViaStations: [FuelStation] {
        let lockedIDs = Set(removableRouteStops.map(\.id))
        return viaStations.filter { !lockedIDs.contains($0.id) }
    }

    func isRouteStopSelected(id: String) -> Bool {
        RouteStopSelectionPolicy.contains(
            stopID: id,
            transientStationIDs: viaStations.map(\.id),
            lockedWaypoints: activeRouteLock?.waypoints ?? []
        )
    }

    @discardableResult
    func removeRouteStop(id: String, from start: CLLocationCoordinate2D,
                         settings: DriveSettings) async -> Bool {
        guard routeLockStore.activeLock?.waypoints.contains(where: {
            $0.id == id && $0.isRemovableComfortStop
        }) == true else {
            return false
        }
        let navigationSession = isNavigating ? navigationSessionGeneration : nil
        let mutationGeneration = UUID()
        routeStopMutationGeneration = mutationGeneration
        let rollback = RouteMutationBaselinePolicy.choose(
            existing: routeStopMutationSnapshot,
            current: RouteStopMutationSnapshot(
                lock: routeLockStore.activeLock,
                stations: viaStations,
                searchResults: routeSearchResults,
                searchQuery: routeSearchQuery
            )
        )
        routeStopMutationSnapshot = rollback
        defer {
            if mutationGeneration == routeStopMutationGeneration {
                routeStopMutationSnapshot = nil
            }
        }
        routeLockStore.update { $0.removeWaypoint(id: id) }
        viaStations.removeAll { $0.id == id }
        activeRouteLock = routeLockStore.activeLock
        let mutatedLock = routeLockStore.activeLock
        let mutatedStations = viaStations
        guard await calculate(
            from: start, settings: settings,
            navigationSession: navigationSession
        ) else {
            guard mutationGeneration == routeStopMutationGeneration else { return false }
            guard RouteMutationRollbackPolicy.shouldRollback(
                current: routeLockStore.activeLock, mutated: mutatedLock
            ), RouteMutationRollbackPolicy.shouldRollback(
                current: viaStations, mutated: mutatedStations
            ) else { return false }
            routeLockStore.replace(with: rollback.lock)
            viaStations = rollback.stations
            activeRouteLock = rollback.lock
            routeSearchResults = rollback.searchResults
            routeSearchQuery = rollback.searchQuery
            isSearchingAlongRoute = false
            return false
        }
        return true
    }

    /// Every user-selected stop is written into the persistent trip lock. This
    /// avoids the former split-brain state where fuel stops lived only in
    /// `viaStations` and disappeared whenever mandatory route points existed.
    private func insertLockedWaypoint(id: String, name: String, coordinate: CLLocationCoordinate2D,
                                      knownProgress: Double? = nil,
                                      kind: LockedWaypoint.Kind = .userStop) {
        guard var lock = routeLockStore.activeLock,
              !lock.waypoints.contains(where: { $0.id == id }) else { return }
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 240) }
        func progress(_ coordinate: CLLocationCoordinate2D) -> Double {
            RouteGeometryProgress.nearestProgress(of: coordinate, on: routeCoordinates)?.progress ?? 1
        }
        lock.insertWaypoint(.init(
            id: id, name: name,
            coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
            required: true, optionsAfter: nil, kind: kind
        ), knownProgress: knownProgress, progress: { progress($0.clLocationCoordinate) })
        routeLockStore.save(lock)
        activeRouteLock = lock
    }

    @discardableResult
    func calculate(from start: CLLocationCoordinate2D, settings: DriveSettings,
                   showLoading: Bool = true,
                   navigationSession: UUID? = nil,
                   navigationWork: UUID? = nil,
                   newlyReachedWaypointID: String? = nil) async -> Bool {
        guard let destination else { return false }
        if NavigationRerouteSupersessionPolicy.shouldInvalidateAutomaticReroute(
            isRecalculating: isRecalculating,
            navigationSession: navigationSession,
            navigationWork: navigationWork
        ) {
            activeAutomaticRerouteTask?.cancel()
            activeAutomaticRerouteTask = nil
            rerouteGeneration = UUID()
            isRecalculating = false
        }
        let calculationGeneration = UUID()
        routeCalculationGeneration = calculationGeneration
        destinationSearchGeneration = UUID()
        routeSearchGeneration = UUID()
        activeDestinationSearches.forEach { $0.cancel() }
        activeDestinationSearches = []
        activeRouteSearches.forEach { $0.cancel() }
        activeRouteSearches = []
        activeAmenitySearches.forEach { $0.cancel() }
        activeAmenitySearches = []
        routeSearchResults = []
        isSearchingAlongRoute = false
        // Keep the currently usable route enrichment visible until a complete
        // replacement route commits. In particular, a failed attempt to add
        // or remove a stop must not erase the fuel stations belonging to the
        // still-active route. The successful commit below clears every stale
        // enrichment atomically before loading data for the new geometry.
        if showLoading { isLoading = true }
        errorMessage = nil
        let startItem = MKMapItem(placemark: MKPlacemark(coordinate: start))
        do {
            let lock = routeLockStore.activeLock
            let constraintSnapshot = RouteCalculationConstraintSnapshot(lock)
            var newlyPassed = Set(lock?.passedWaypointIDs(at: .init(
                latitude: start.latitude, longitude: start.longitude
            )) ?? [])
            if let newlyReachedWaypointID {
                newlyPassed.insert(newlyReachedWaypointID)
            }
            let visited = Set(lock?.visitedWaypointIDs ?? []).union(newlyPassed)
            let lockedWaypoints = lock?.waypoints.filter { $0.required && !visited.contains($0.id) } ?? []
            let currentLockedOptions = lock.map {
                RouteWaypointOptionsPolicy.currentOptions(
                    defaultOptions: $0.defaultOptions,
                    waypoints: $0.waypoints,
                    visitedIDs: visited
                )
            }
            let computedLegs: [MKRoute]
            let computedAlternatives: [MKRoute]
            let computedComparison: MKRoute?
            let shouldLoadComparison: Bool
            let waypointSource = RouteWaypointRoutingPolicy.source(
                hasActiveLock: lock != nil,
                remainingLockedWaypointCount: lockedWaypoints.count,
                transientStationCount: viaStations.count
            )
            if waypointSource == .direct {
                let routes = try await computeRoutes(from: startItem, to: destination, settings: settings, alternates: true)
                guard calculationGeneration == routeCalculationGeneration else { return false }
                // A strict trip corridor may reject every MapKit alternative.
                // Never replace an active, still usable route with an empty
                // result; retaining it lets guidance continue and retry later.
                guard let firstRoute = routes.first else { throw DriveAPIError.invalidData }
                computedAlternatives = routes
                computedLegs = [firstRoute]
                // The opposite toll preference is useful enrichment, not a
                // prerequisite for driving. Publish the primary route first
                // and fetch the comparison below without holding the screen's
                // loading state for another network round trip.
                computedComparison = nil
                shouldLoadComparison = true
            } else {
                // MapKit kennt keine mehrgliedrigen Routen als ein einziges Objekt.
                // Daher Teilstrecken sequentiell (Start→wp1→wp2→…→Ziel) berechnen.
                let waypoints: [MKMapItem] = waypointSource == .transientStations
                    ? viaStations.map {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: $0.coordinate))
                        item.name = $0.brand.isEmpty ? $0.name : $0.brand
                        return item
                    }
                    : lockedWaypoints.map {
                        let item = MKMapItem(placemark: MKPlacemark(coordinate: $0.coordinate.clLocationCoordinate))
                        item.name = $0.name
                        return item
                    }
                let allStops = [startItem] + waypoints + [destination]

                var newLegs: [MKRoute] = []
                for i in 0..<(allStops.count - 1) {
                    let from = allStops[i]
                    let to = allStops[i + 1]
                    let lockedOptions = i == 0 ? currentLockedOptions
                        : lockedWaypoints[safe: i - 1]?.optionsAfter ?? lock?.defaultOptions
                    guard let leg = try await computeRoutes(from: from, to: to, settings: settings,
                                                            alternates: false, lockedOptions: lockedOptions).first else {
                        throw DriveAPIError.invalidData
                    }
                    guard calculationGeneration == routeCalculationGeneration else { return false }
                    newLegs.append(leg)
                }
                computedLegs = newLegs
                computedAlternatives = []
                computedComparison = nil
                shouldLoadComparison = false
            }
            guard calculationGeneration == routeCalculationGeneration,
                  constraintSnapshot == RouteCalculationConstraintSnapshot(
                    routeLockStore.activeLock
                  ),
                  NavigationAsyncWorkPolicy.mayCommitCalculation(
                    navigationActive: isNavigating,
                    session: navigationSession,
                    currentSession: navigationSessionGeneration,
                    work: navigationWork,
                    currentWork: rerouteGeneration
                  ) else { return false }
            // Commit route and trip progress together. A superseded request
            // therefore cannot flash an old route or permanently skip a
            // mandatory waypoint merely because it finished later.
            if !newlyPassed.isEmpty {
                routeLockStore.update { current in
                    current.visitedWaypointIDs = RouteWaypointProgressPolicy.merging(
                        existing: current.visitedWaypointIDs, newlyPassed: newlyPassed
                    )
                }
                activeRouteLock = routeLockStore.activeLock
                viaStations.removeAll { newlyPassed.contains($0.id) }
            }
            cancelSpeechForRouteReplacementIfNeeded()
            legs = computedLegs
            liveRouteDestinationCoordinate = destination.placemark.coordinate
            installedDefaultRouteOptions = lock?.defaultOptions ?? .init(
                avoidTolls: settings.avoidTolls,
                avoidHighways: settings.avoidHighways
            )
            alternatives = computedAlternatives
            comparisonRoute = computedComparison
            // Enrichment belongs to the geometry that produced it. Preserve
            // the old data while MapKit is still calculating, but discard it
            // at the same commit boundary as the replacement route. Otherwise
            // a successful reroute can briefly recommend a station, break,
            // speed limit or toll amount from the abandoned road.
            stations = []
            amenityBreakCandidates = []
            speedLimitPoints = []
            speedLimits = []
            comparisonSpeedLimitPoints = []
            comparisonSpeedLimits = []
            speedWarning = false
            researchedStandardToll = .unknown(reason: "Maut für die neue Route wird geprüft.")
            researchedAvoidingToll = .unknown(reason: "Mautfreie Alternative wird geprüft.")
            longTripPlan = nil
            stopPlanningGeneration = UUID()
            measuredBreakDetours = [:]
            resetLiveNavigationProgress()
            seedInitialNavigationPresentation()
            isUsingOfflineGuidance = false
            lastOfflineRecoveryAttempt = nil
            remainingDistanceMetres = totalDistance
            remainingTravelTime = totalTravelTime
            resetDeviationTracking()
            cacheForOffline()
            DriveDiagnosticStore.append(.routeCalculated, detail: "\(legs.count) Etappen · \(Int(totalDistance)) m")
            // Die sichtbare Route ist jetzt fertig. Langsame Server-Zusatzdaten
            // duerfen Navigation und UI nicht mehr blockieren.
            // This request owns the current generation. Clear a spinner even
            // when it was started by a now-superseded foreground request and
            // this replacement calculation intentionally ran in background.
            isLoading = false
            if shouldLoadComparison {
                Task { [weak self] in
                    guard let self else { return }
                    let comparison = try? await self.computeRoutes(
                        from: startItem, to: destination, settings: settings,
                        alternates: false, avoidTollsOverride: !settings.avoidTolls
                    ).first
                    let activeLock = self.routeLockStore.activeLock
                    let visited = Set(activeLock?.visitedWaypointIDs ?? [])
                    let hasOpenRequiredWaypoints = activeLock?.waypoints.contains {
                        $0.required && !visited.contains($0.id)
                    } ?? false
                    guard RouteComparisonPublicationPolicy.mayPublish(
                        requestRoute: calculationGeneration,
                        currentRoute: self.routeCalculationGeneration,
                        stillEligible: self.viaStations.isEmpty && !hasOpenRequiredWaypoints
                    ) else { return }
                    self.comparisonRoute = comparison
                    self.buildLongTripPlan(settings: settings)
                    await self.loadComparisonSpeedLimits()
                    guard calculationGeneration == self.routeCalculationGeneration else { return }
                    self.buildLongTripPlan(settings: settings)
                    // Even a failed comparison finishes ownership of this
                    // enrichment pass. Load once now so the standard route
                    // still receives evidence, without the earlier duplicate
                    // SearXNG batch before comparison geometry was known.
                    await self.loadTollCost(from: start, settings: settings)
                    guard calculationGeneration == self.routeCalculationGeneration else { return }
                    self.buildLongTripPlan(settings: settings)
                    self.cacheForOffline(preservingProgress: true)
                }
            }
            Task { [weak self] in
                guard let self else { return }
                // These providers are independent. Start them together so a
                // slow fuel endpoint cannot postpone speed limits and map
                // amenities needed by the driving screen.
                async let stationLoad: Void = self.loadStations(fuel: settings.fuel)
                async let amenityLoad: Void = self.loadBreakAmenities()
                async let speedLimitLoad: Void = self.loadSpeedLimits()
                await stationLoad
                await amenityLoad
                guard calculationGeneration == self.routeCalculationGeneration else { return }
                await self.measureBreakCandidateDetours()
                guard calculationGeneration == self.routeCalculationGeneration else { return }
                await speedLimitLoad
                guard calculationGeneration == self.routeCalculationGeneration else { return }
                if !shouldLoadComparison {
                    await self.loadTollCost(from: start, settings: settings)
                    guard calculationGeneration == self.routeCalculationGeneration else { return }
                }
                self.buildLongTripPlan(settings: settings)
                self.cacheForOffline(preservingProgress: true)
            }
            return true
        } catch {
            guard calculationGeneration == routeCalculationGeneration else { return false }
            isLoading = false
            if showLoading {
                errorMessage = "Route konnte nicht berechnet werden: \(error.localizedDescription)"
            } else {
                // Cached guidance remains usable. A background reconnect must
                // never cover the navigation UI with a transient network error.
                errorMessage = nil
            }
            return false
        }
    }

    /// Speichert die aktuell berechnete Route + Tankstellenliste lokal, damit
    /// sie bei fehlender Verbindung (z.B. Funkloch unterwegs) weiter als Text
    /// angezeigt werden kann - kein Kartenmaterial, nur Fahrhinweise und Preise.
    private func cacheForOffline(preservingProgress: Bool = false) {
        guard !legs.isEmpty else { return }
        let currentTripID = routeLockStore.activeLock?.id
        let routeConstraintIdentity = routeLockStore.activeLock.map {
            OfflineRouteConstraintIdentityPolicy.identity(for: $0)
        }
        let retainedProgress = OfflineRouteCacheWritePolicy.progressForWrite(
            existing: offlineRoute,
            currentTripID: currentTripID,
            preservingProgress: preservingProgress
        )
        let cached = CachedRoute(
            destinationName: destination?.name ?? destinationText,
            tripID: currentTripID,
            destinationCoordinate: destination.map {
                .init(latitude: $0.placemark.coordinate.latitude,
                      longitude: $0.placemark.coordinate.longitude)
            },
            routeConstraintIdentity: routeConstraintIdentity,
            legs: legs.map { leg in
                CachedRoute.Leg(distance: leg.distance, travelTime: leg.expectedTravelTime,
                                 steps: leg.steps.map { step in
                                     .init(instructions: step.instructions, distance: step.distance,
                                           coordinates: sample(step.polyline, maximum: 80).map {
                                               .init(latitude: $0.latitude, longitude: $0.longitude)
                                           })
                                 },
                                 coordinates: sample(leg.polyline, maximum: 600).map {
                                     .init(latitude: $0.latitude, longitude: $0.longitude)
                                 })
            },
            stations: stations,
            savedAt: Date(),
            navigationProgress: retainedProgress
        )
        offlineRoute = cached
        if Self.offlineCacheStore.save(cached) {
            UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        }
    }

    private static func loadCache() -> CachedRoute? {
        if let route = offlineCacheStore.load() { return route }
        // One-time migration from the legacy large UserDefaults value.
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey),
              let route = try? JSONDecoder().decode(CachedRoute.self, from: data),
              OfflineRouteCacheValidationPolicy.isValid(route) else { return nil }
        if offlineCacheStore.save(route) {
            UserDefaults.standard.removeObject(forKey: Self.cacheKey)
        }
        return route
    }

    /// Löscht die zwischengespeicherte Offline-Route (z.B. wenn sie veraltet ist).
    func clearOfflineCache() {
        offlineRoute = nil
        Self.offlineCacheStore.clear()
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    // MARK: - Navigation live: Ansagen, Tempowarnung, automatische Neuberechnung

    /// Wird laufend mit der aktuellen Position während der Fahrt aufgerufen.
    /// Kümmert sich um drei Dinge: nächste Fahranweisung ansagen, Tempolimit-
    /// Überschreitung erkennen und bei Abweichung von der Route automatisch
    /// neu berechnen.
    func updateProgress(at location: CLLocation, settings: DriveSettings,
                        evaluationDate: Date = Date(),
                        maximumLocationAge: TimeInterval = NavigationLocationPolicy.maximumLiveAge,
                        allowsAutomaticReroute: Bool = true) {
        guard isNavigating, !legs.isEmpty || isUsingOfflineGuidance else { return }
        let previousNavigationLocation = lastAcceptedNavigationLocation
        if let rejection = NavigationLocationPolicy.rejectionReason(
            for: location, after: previousNavigationLocation, now: evaluationDate,
            maximumAge: maximumLocationAge
        ) {
            if NavigationLocationDiagnosticPolicy.shouldLog(
                lastLoggedAt: lastLocationRejectionLoggedAt,
                now: evaluationDate
            ) {
                lastLocationRejectionLoggedAt = evaluationDate
                DriveDiagnosticStore.append(.locationRejected,
                                            detail: DriveDiagnosticDetail.navigationSample(
                                                rejection, location: location
                                            ))
            }
            return
        }
        updateUsageSession(at: location)
        lastAcceptedNavigationLocation = location
        let recoveredLocationGap = NavigationLocationGapPolicy.recoveredGap(
            previous: previousNavigationLocation, current: location
        )
        if let gap = recoveredLocationGap {
            DriveDiagnosticStore.append(
                .locationGapRecovered,
                detail: DriveDiagnosticDetail.navigationSample(
                    "Standort nach \(Int(gap.rounded())) Sekunden wieder verfügbar",
                    location: location
                )
            )
        }
        let allowsFullLiveRecovery = NavigationLiveRecoveryPolicy.allowsFullRouteMatch(
            previous: previousNavigationLocation, current: location
        )
        expireStaleManeuverSpeech(now: evaluationDate)
        let currentSpeed = NavigationMotionPolicy.reliableSpeed(for: location)
        let guidanceSpeed = NavigationGuidanceSpeedPolicy.effective(
            current: currentSpeed,
            previous: lastReliableGuidanceSpeedMps,
            previousAt: lastReliableGuidanceSpeedAt,
            now: location.timestamp
        )
        if let currentSpeed {
            lastReliableGuidanceSpeedMps = currentSpeed
            lastReliableGuidanceSpeedAt = location.timestamp
        }
        let previousContinuousDriving = drivingRestState.continuousDriving
        if let tripID = activeRouteLock?.id ?? routeLockStore.activeLock?.id {
            drivingRestState = DrivingRestPolicy.updated(
                drivingRestState, tripID: tripID, at: location.timestamp,
                speedMetresPerSecond: currentSpeed
            )
            drivingFuelState = DrivingFuelPolicy.updated(
                drivingFuelState, tripID: tripID,
                initialFuelFraction: settings.departureFuelPercent / 100,
                location: location
            )
            if NavigationPersistenceCheckpointPolicy.shouldPersist(
                last: lastDrivingStatePersistedAt, now: location.timestamp
            ) {
                drivingRestStore.save(drivingRestState)
                drivingFuelStore.save(drivingFuelState)
                lastDrivingStatePersistedAt = location.timestamp
            }
        }
        if detectArrival(at: location, settings: settings) { return }
        updateBreakReminder(settings: settings)
        updateFuelReminder()
        // Evaluate route safety before accepting another spoken maneuver from
        // the old geometry. The GPS fix that confirms a deviation must not
        // first announce the very turn the driver has already missed.
        if !isUsingOfflineGuidance {
            checkForDeviation(
                from: location, settings: settings,
                allowsAutomaticReroute: allowsAutomaticReroute
            )
        }
        if isUsingOfflineGuidance {
            updateOfflineProgress(
                at: location, guidanceSpeedMps: guidanceSpeed, settings: settings,
                recoveredAfterLocationGap: recoveredLocationGap != nil
            )
        } else if let progress = liveNavigationProgress(
            at: location, allowsFullRecovery: allowsFullLiveRecovery
        ) {
            updateNextManeuver(using: progress)
            if settings.voiceGuidance,
               NavigationManeuverSafetyPolicy.mayAnnounceLiveManeuver(
                    navigationActive: isNavigating,
                    rerouting: isRecalculating,
                    confirmedOffRoute: !isManeuverGuidanceReliable
               ) {
                announce(
                    progress, guidanceSpeedMps: guidanceSpeed,
                    recoveredAfterLocationGap: recoveredLocationGap != nil
                )
            }
        }
        persistRouteLockProgress(at: location)
        markReachedWaypoints(at: location, settings: settings)
        if !isUsingOfflineGuidance {
            checkSpeedLimit(at: location.coordinate,
                            speedMps: NavigationMotionPolicy.reliableSpeed(for: location))
        }
        let pauseJustCompleted = previousContinuousDriving > 0 && drivingRestState.continuousDriving == 0
        let passedPlannedStop = LongTripPlanRefreshPolicy.hasPassedConcreteStop(
            longTripPlan?.results.first,
            currentInstalledProgress: currentInstalledRouteProgress
        )
        if pauseJustCompleted || passedPlannedStop ||
            LongTripPlanRefreshPolicy.periodicRefreshIsDue(
                lastRefresh: lastLongTripPlanRefreshAt, now: evaluationDate
            ) {
            lastLongTripPlanRefreshAt = evaluationDate
            buildLongTripPlan(settings: settings)
        }
    }

    private func updateBreakReminder(settings: DriveSettings) {
        guard drivingRestState.continuousDriving > 0 else {
            let hadPendingSpeech = drivingRestState.pendingSpokenReminderRawValue != nil
            deliveredBreakReminderStages = []
            drivingRestState.pendingSpokenReminderRawValue = nil
            if hadPendingSpeech { drivingRestStore.save(drivingRestState) }
            breakReminderText = nil
            return
        }
        let distanceProgress = RouteSearchPolicy.installedRouteProgress(
            totalDistance: totalDistance,
            remainingDistance: remainingDistanceMetres,
            navigationActive: isNavigating
        )
        let currentProgress = RouteSearchPolicy.currentProgress(
            projected: distanceProgress,
            persisted: activeRouteLock?.lastRouteProgress ??
                routeLockStore.activeLock?.lastRouteProgress,
            navigationActive: isNavigating
        )
        let plannedName = NavigationBreakReminderPolicy.nextPlannedStopName(
            breaks: longTripPlan?.results.first?.breaks ?? [],
            currentRouteProgress: currentProgress
        )
        let remaining = remainingTravelTime > 0 ? remainingTravelTime : totalTravelTime
        let newlyDueStage = NavigationBreakReminderPolicy.stage(
            continuousDriving: drivingRestState.continuousDriving,
            remainingTravelTime: remaining,
            delivered: deliveredBreakReminderStages
        )
        let persistedPendingStage = drivingRestState.pendingSpokenReminderRawValue.flatMap(
            NavigationBreakReminderPolicy.Stage.init(rawValue:)
        )
        let stageToRetry = DrivingRestReminderStatePolicy.stageToRetry(
            pending: persistedPendingStage, newlyDue: newlyDueStage
        )

        if let newlyDueStage {
            deliveredBreakReminderStages.insert(newlyDueStage)
            let text = NavigationBreakReminderTextPolicy.text(
                stage: newlyDueStage, plannedName: plannedName
            )
            breakReminderText = text
            DriveDiagnosticStore.append(
                .breakReminderShown,
                detail: "Pausenerinnerung · \(newlyDueStage) · \(text)"
            )
        }

        guard settings.voiceGuidance else {
            if drivingRestState.pendingSpokenReminderRawValue != nil {
                drivingRestState.pendingSpokenReminderRawValue = nil
                drivingRestStore.save(drivingRestState)
            }
            return
        }
        guard let stageToRetry else { return }
        if drivingRestState.pendingSpokenReminderRawValue != stageToRetry.rawValue {
            drivingRestState.pendingSpokenReminderRawValue = stageToRetry.rawValue
            drivingRestStore.save(drivingRestState)
        }
        let text = NavigationBreakReminderTextPolicy.text(
            stage: stageToRetry, plannedName: plannedName
        )
        // Restore the visible reminder after an app/scene restart as well as
        // the pending spoken claim.
        breakReminderText = text
        let inFlight = pendingBreakReminderSpeech.values.contains { $0.stage == stageToRetry } ||
            activeBreakReminderSpeech.values.contains { $0.stage == stageToRetry }
        guard !inFlight else { return }
        _ = speak(text, priority: .status, breakReminderClaim: stageToRetry)
    }

    private func updateFuelReminder() {
        guard isNavigating, let result = longTripPlan?.results.first else {
            fuelReminderText = nil
            return
        }
        let currentProgress = currentInstalledRouteProgress
        guard let stop = result.fuelStops
            .filter({ PlannedRouteStopVisibilityPolicy.isAhead(
                $0.insertionRouteProgress, current: currentProgress
            ) })
            .min(by: { $0.insertionRouteProgress < $1.insertionRouteProgress }) else {
            if drivingFuelState.pendingSpokenReminderKey != nil ||
                drivingFuelState.pendingSpokenReminderText != nil {
                drivingFuelState.clearPendingSpeech()
                drivingFuelStore.save(drivingFuelState)
            }
            fuelReminderText = nil
            return
        }
        let distance = NavigationFuelReminderPolicy.remainingDistance(
            stop: stop, currentProgress: currentProgress,
            installedRouteDistance: totalDistance
        )
        let reminderID = NavigationFuelReminderPolicy.reminderID(for: stop)
        let newlyDueStage = NavigationFuelReminderPolicy.stage(
            distanceMetres: distance,
            deliveredKeys: drivingFuelState.deliveredReminderKeys,
            stopID: reminderID
        )
        let stageToRetry = NavigationFuelReminderSpeechDeliveryPolicy.stageToRetry(
            pendingKey: drivingFuelState.pendingSpokenReminderKey,
            stopID: reminderID,
            newlyDue: newlyDueStage
        )

        if let newlyDueStage {
            drivingFuelState.deliveredReminderKeys.formUnion(
                NavigationFuelReminderPolicy.keysThrough(
                    stopID: reminderID, stage: newlyDueStage
                )
            )
            drivingFuelStore.save(drivingFuelState)
            fuelReminderText = NavigationFuelReminderPolicy.text(
                stage: newlyDueStage, stationName: stop.candidate?.name
            )
            DriveDiagnosticStore.append(
                .fuelReminderShown,
                detail: "Tankhinweis · \(newlyDueStage) · \(fuelReminderText ?? "")"
            )
        }

        guard DriveSettings.shared.voiceGuidance else {
            if drivingFuelState.pendingSpokenReminderKey != nil ||
                drivingFuelState.pendingSpokenReminderText != nil {
                drivingFuelState.clearPendingSpeech()
                drivingFuelStore.save(drivingFuelState)
            }
            return
        }
        guard let stageToRetry else {
            // A pending reminder for a later/removed stop is intentionally not
            // relevant to the currently nearest stop.
            if drivingFuelState.pendingSpokenReminderKey != nil ||
                drivingFuelState.pendingSpokenReminderText != nil {
                drivingFuelState.clearPendingSpeech()
                drivingFuelStore.save(drivingFuelState)
            }
            return
        }
        let key = NavigationFuelReminderPolicy.key(
            stopID: reminderID, stage: stageToRetry
        )
        let text = NavigationFuelReminderPolicy.text(
            stage: stageToRetry, stationName: stop.candidate?.name
        )
        fuelReminderText = text
        if drivingFuelState.pendingSpokenReminderKey != key ||
            drivingFuelState.pendingSpokenReminderText != text {
            drivingFuelState.pendingSpokenReminderKey = key
            drivingFuelState.pendingSpokenReminderText = text
            drivingFuelStore.save(drivingFuelState)
        }
        let inFlight = pendingFuelReminderSpeech.values.contains { $0.key == key } ||
            activeFuelReminderSpeech.values.contains { $0.key == key }
        guard !inFlight else { return }
        _ = speak(text, priority: .status, fuelReminderClaim: (key, text))
    }

    @discardableResult
    private func startOfflineGuidanceIfAvailable(replacingLiveRoute: Bool = false) -> Bool {
        guard (legs.isEmpty || replacingLiveRoute), let cache = offlineRoute else { return false }
        let exactTrip = belongsToActiveTrip(cache)
        let available = OfflineRouteAvailabilityPolicy.isUsable(
                savedAt: cache.savedAt,
                cacheName: cache.destinationName,
                cacheCoordinate: cache.destinationCoordinate?.clLocationCoordinate,
                destinationName: destination?.name ?? (destinationText.isEmpty ? nil : destinationText),
                destinationCoordinate: destination?.placemark.coordinate,
                belongsToActiveTrip: exactTrip
              )
        guard OfflineRouteGuidanceEligibilityPolicy.mayStart(
            available: available, belongsToExactActiveTrip: exactTrip
        ), cache.legs.flatMap(\.steps).contains(where: { ($0.coordinates?.count ?? 0) > 1 }) else {
            return false
        }
        if replacingLiveRoute {
            legs = []
            liveRouteDestinationCoordinate = nil
            alternatives = []
            comparisonRoute = nil
        }
        resetLiveNavigationProgress()
        errorMessage = nil
        isUsingOfflineGuidance = true
        let cachedGuidanceSteps = cache.legs.flatMap(\.steps).compactMap { step -> OfflineGuidanceStep? in
            guard let coordinates = step.coordinates, coordinates.count > 1 else { return nil }
            return .init(instruction: step.instructions, distance: step.distance,
                         coordinates: coordinates.map(\.clLocationCoordinate))
        }
        navigationStepCursor = OfflineGuidanceResumePolicy.stepIndex(
            steps: cachedGuidanceSteps,
            persistedProgress: OfflineRouteCacheWritePolicy.progressForResume(
                cacheProgress: cache.navigationProgress,
                hasConstraintIdentity: cache.routeConstraintIdentity != nil,
                legacyTripProgress: activeRouteLock?.lastRouteProgress ??
                    routeLockStore.activeLock?.lastRouteProgress
            )
        )
        offlineNeedsInitialPositionMatch = true
        offlineInitialMatchStepIndex = nil
        lastOfflineRecoveryAttempt = Date()
        beginNavigationSession()
        // The persisted cursor is only an estimate until a fresh GPS fix
        // proves which cached road segment the car is actually on.
        isManeuverGuidanceReliable = false
        isNavigating = true
        hasArrived = false
        let resumeEstimate = OfflineGuidanceResumeEstimatePolicy.estimate(
            stepDistances: cachedGuidanceSteps.map(\.distance),
            currentIndex: navigationStepCursor,
            routeDistance: cache.legs.reduce(0) { $0 + $1.distance },
            routeTravelTime: cache.legs.reduce(0) { $0 + $1.travelTime }
        )
        remainingDistanceMetres = resumeEstimate.distance
        remainingTravelTime = resumeEstimate.travelTime
        let remainingGuidance = cachedGuidanceSteps.dropFirst(navigationStepCursor).map {
            (instruction: $0.instruction, distance: $0.distance)
        }
        if let seed = NavigationInitialManeuverPolicy.seed(steps: remainingGuidance) {
            nextManeuverIdentity = CarPlayManeuverIdentityPolicy.offline(
                stepIndex: navigationStepCursor + seed.stepIndex
            )
            nextManeuverInstruction = seed.instruction
            nextManeuverDistance = seed.distance
            upcomingManeuverInstructions = seed.upcomingInstructions
        } else {
            nextManeuverIdentity = "offline:final"
            nextManeuverInstruction = "Dem Straßenverlauf bis zum Ziel folgen"
            nextManeuverDistance = remainingDistanceMetres
            upcomingManeuverInstructions = ["Dem Straßenverlauf bis zum Ziel folgen"]
        }
        lastAnnouncement = "Offline-Route wiederhergestellt"
        DriveDiagnosticStore.append(.navigationStarted, detail: "Offline · \(cache.destinationName)")
        return true
    }

    /// Extended offline retention is granted only when the cache belongs to
    /// the exact destination of the still-active persisted trip. A manually
    /// selected destination with the same display state cannot accidentally
    /// revive an unrelated old cache.
    private func belongsToActiveTrip(_ cache: CachedRoute) -> Bool {
        guard let lock = routeLockStore.activeLock,
              OfflineRouteTripIdentityPolicy.belongs(
                cacheTripID: cache.tripID, activeTripID: lock.id, active: lock.isActive
              ),
              OfflineRouteConstraintIdentityPolicy.matches(
                cache.routeConstraintIdentity, lock: lock
              ) else { return false }
        return OfflineRouteCachePolicy.matches(
            cacheName: cache.destinationName,
            cacheCoordinate: cache.destinationCoordinate?.clLocationCoordinate,
            destinationName: lock.destinationName,
            destinationCoordinate: lock.destination.clLocationCoordinate
        )
    }

    private func updateOfflineProgress(at location: CLLocation, guidanceSpeedMps: Double,
                                       settings: DriveSettings,
                                       recoveredAfterLocationGap: Bool) {
        guard let cache = offlineRoute else { return }
        let guidanceEntries = cache.legs.enumerated().flatMap { legIndex, leg in
            leg.steps.compactMap { step -> (legIndex: Int, step: OfflineGuidanceStep)? in
                guard let coordinates = step.coordinates, coordinates.count > 1 else { return nil }
                return (legIndex, .init(
                    instruction: step.instructions, distance: step.distance,
                    coordinates: coordinates.map(\.clLocationCoordinate)
                ))
            }
        }
        let steps = guidanceEntries.map(\.step)
        guard let progress = OfflineGuidanceEngine.progress(
            at: location.coordinate, currentIndex: navigationStepCursor, steps: steps,
            transitionRadius: max(8, location.horizontalAccuracy * 1.5),
            allowsFullRecovery: offlineNeedsInitialPositionMatch,
            courseDegrees: NavigationMotionPolicy.reliableCourse(for: location)
        ) else { return }

        if OfflineRouteRecoveryPolicy.shouldAttempt(
            lastAttempt: lastOfflineRecoveryAttempt,
            urgent: offlineDeviationWarningActive
        ) {
            lastOfflineRecoveryAttempt = Date()
            let recoverySession = navigationSessionGeneration
            Task { [weak self] in
                guard let self, self.isUsingOfflineGuidance, self.isNavigating else { return }
                let succeeded = await self.calculate(
                    from: location.coordinate, settings: settings, showLoading: false,
                    navigationSession: recoverySession
                )
                guard OfflineRouteRecoveryPolicy.acceptsOnlineResult(
                    calculationSucceeded: succeeded,
                    navigationActive: self.isNavigating,
                    stillUsingOfflineGuidance: self.isUsingOfflineGuidance
                ) else { return }
                DriveDiagnosticStore.append(
                    .rerouteSucceeded, detail: "Online-Route nach Offline-Fahrt wiederhergestellt"
                )
                self.presentRecalculatedRoute(
                    at: NavigationReroutePresentationPolicy.location(
                        trigger: location, latest: self.lastAcceptedNavigationLocation
                    ),
                    voiceGuidance: settings.voiceGuidance
                )
            }
        }

        let reliableSpeed = NavigationMotionPolicy.reliableSpeed(for: location) ?? 0
        let isWrongWay = NavigationWrongWayPolicy.isOpposing(
            courseDifferenceDegrees: progress.courseDifferenceDegrees,
            distanceFromRoute: progress.distanceFromRoute,
            horizontalAccuracy: location.horizontalAccuracy,
            speedMetresPerSecond: reliableSpeed
        )
        let isOutsideCorridor = NavigationDeviationPolicy.isOutsideCorridor(
            distanceFromRoute: progress.distanceFromRoute,
            horizontalAccuracy: location.horizontalAccuracy,
            speedMetresPerSecond: reliableSpeed
        ) || isWrongWay
        if offlineNeedsInitialPositionMatch {
            let reliableInitialMatch = OfflineInitialPositionMatchPolicy.isReliable(
                distanceFromRoute: progress.distanceFromRoute,
                horizontalAccuracy: location.horizontalAccuracy,
                speedMetresPerSecond: reliableSpeed,
                wrongWay: isWrongWay
            )
            if reliableInitialMatch {
                if offlineInitialMatchStepIndex == progress.currentStepIndex {
                    onRouteRecoveryFixCount += 1
                } else {
                    offlineInitialMatchStepIndex = progress.currentStepIndex
                    onRouteRecoveryFixCount = 1
                }
                guard OfflineInitialPositionMatchPolicy.isConfirmed(
                    consecutiveMatches: onRouteRecoveryFixCount
                ) else {
                    // Keep every surface in the neutral "Position wird
                    // bestimmt" state until the same road segment is stable.
                    return
                }
                offlineNeedsInitialPositionMatch = false
                offlineInitialMatchStepIndex = nil
                onRouteRecoveryFixCount = 0
                isManeuverGuidanceReliable = true
            } else {
                offlineInitialMatchStepIndex = nil
                onRouteRecoveryFixCount = 0
            }
        }
        let isDeparting = NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: progress.distanceFromRoute,
            previousDistance: previousOffRouteDistance,
            horizontalAccuracy: location.horizontalAccuracy,
            speedMetresPerSecond: reliableSpeed,
            wrongWay: isWrongWay
        )
        previousOffRouteDistance = progress.distanceFromRoute
        if isOutsideCorridor {
            onRouteRecoveryFixCount = 0
            if isDeparting {
                if offRouteSince == nil {
                    offRouteSince = location.timestamp
                    offRouteFixCount = 1
                } else {
                    offRouteFixCount += 1
                }
                if let offRouteSince,
                   NavigationDeviationPolicy.isConfirmed(
                    elapsed: location.timestamp.timeIntervalSince(offRouteSince),
                    consecutiveFixes: offRouteFixCount,
                    speedMetresPerSecond: reliableSpeed
                   ), !offlineDeviationWarningActive {
                    offlineDeviationWarningActive = true
                    isManeuverGuidanceReliable = false
                    DriveDiagnosticStore.append(
                        .offlineRouteDeparture,
                        detail: DriveDiagnosticDetail.navigationSample(
                            isWrongWay
                                ? "Falsche Fahrtrichtung auf der Offline-Route"
                                : "Abstand zum Offline-Korridor \(Int(progress.distanceFromRoute.rounded())) m",
                            location: location
                        )
                    )
                    if settings.voiceGuidance {
                        _ = speak(
                            isWrongWay
                                ? "Du fährst entgegen der gespeicherten Route. Bitte sicher wenden. Sobald eine Verbindung verfügbar ist, wird neu berechnet."
                                : "Du hast die gespeicherte Route verlassen. Sobald eine Verbindung verfügbar ist, wird neu berechnet.",
                            priority: .critical
                        )
                    }
                }
            } else if !offlineDeviationWarningActive {
                resetDeviationTracking(keepingDistance: progress.distanceFromRoute)
            }
            // Freeze the last trustworthy instruction while outside the
            // cached corridor. Snapping to the nearest distant segment can
            // otherwise announce an unrelated junction or future crossing.
            return
        }
        if offlineDeviationWarningActive {
            onRouteRecoveryFixCount += 1
            guard NavigationRouteRejoinPolicy.isConfirmed(
                consecutiveInsideFixes: onRouteRecoveryFixCount
            ) else {
                // One optimistic snap onto a nearby or crossing road is not
                // enough evidence to revive a cached maneuver. Keep the last
                // trustworthy instruction frozen until the match is stable.
                return
            }
            offlineDeviationWarningActive = false
            isManeuverGuidanceReliable = true
            onRouteRecoveryFixCount = 0
            DriveDiagnosticStore.append(
                .offlineRouteRejoined,
                detail: DriveDiagnosticDetail.navigationSample(
                    "Offline-Routenkorridor wieder erreicht", location: location
                )
            )
            if settings.voiceGuidance {
                _ = speak("Du bist wieder auf der gespeicherten Route.", priority: .status)
            }
        }
        resetDeviationTracking(keepingDistance: progress.distanceFromRoute)
        navigationStepCursor = progress.currentStepIndex
        nextManeuverIdentity = CarPlayManeuverIdentityPolicy.offline(
            stepIndex: progress.maneuverStepIndex
        )
        nextManeuverInstruction = progress.instruction
        nextManeuverDistance = progress.distanceToManeuver
        upcomingManeuverInstructions = progress.upcomingInstructions
        remainingDistanceMetres = progress.remainingDistance
        if let entry = guidanceEntries[safe: progress.currentStepIndex],
           let estimate = OfflineRouteRemainingTimePolicy.estimate(
            totalRemainingDistance: progress.remainingDistance,
            currentLegIndex: entry.legIndex,
            legs: cache.legs.map { (distance: $0.distance, travelTime: $0.travelTime) }
           ) {
            remainingTravelTime = estimate
        } else {
            let cachedDistance = cache.legs.reduce(0) { $0 + $1.distance }
            let cachedTime = cache.legs.reduce(0) { $0 + $1.travelTime }
            remainingTravelTime = progress.remainingDistance / max(cachedDistance / max(cachedTime, 1), 1)
        }

        guard settings.voiceGuidance else { return }
        announceOfflineManeuver(
            progress, guidanceSpeedMps: guidanceSpeedMps,
            recoveredAfterLocationGap: recoveredAfterLocationGap
        )
    }

    private func announceOfflineManeuver(
        _ progress: OfflineGuidanceProgress,
        guidanceSpeedMps: Double,
        recoveredAfterLocationGap: Bool = false
    ) {
        let key = "offline:\(progress.maneuverStepIndex):\(progress.instruction)"
        if recordManeuverTransition(
            key: key,
            instruction: progress.instruction,
            distance: progress.distanceToManeuver,
            guidanceSpeedMps: guidanceSpeedMps,
            recoveredAfterLocationGap: recoveredAfterLocationGap
        ) { return }
        guard
              let stage = NavigationAnnouncementStage.stage(
                distance: progress.distanceToManeuver,
                speedKmh: guidanceSpeedMps * 3.6
              ) else { return }
        let completed = announcedManeuverStages[key] ?? []
        guard NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            stage, delivered: completed, pending: pendingStages(for: key)
        ) else { return }
        let following = progress.upcomingInstructions.dropFirst().first
        let speech = NavigationManeuverSpeechPolicy.text(
            instruction: progress.instruction,
            distance: progress.distanceToManeuver,
            stage: stage,
            followingInstruction: following,
            followingDistance: progress.followingManeuverDistance
        )
        _ = speak(
            speech, priority: .forAnnouncementStage(stage),
            maneuverClaim: .init(key: key, stage: stage, instruction: progress.instruction,
                                 distance: progress.distanceToManeuver, issuedAt: Date())
        )
    }

    private func currentOfflineGuidanceProgress(at location: CLLocation)
        -> OfflineGuidanceProgress? {
        guard let cache = offlineRoute else { return nil }
        let steps = cache.legs.flatMap(\.steps).compactMap { step -> OfflineGuidanceStep? in
            guard let coordinates = step.coordinates, coordinates.count > 1 else { return nil }
            return .init(
                instruction: step.instructions,
                distance: step.distance,
                coordinates: coordinates.map(\.clLocationCoordinate)
            )
        }
        return OfflineGuidanceEngine.progress(
            at: location.coordinate,
            currentIndex: navigationStepCursor,
            steps: steps,
            transitionRadius: max(8, location.horizontalAccuracy * 1.5),
            allowsFullRecovery: false,
            courseDegrees: NavigationMotionPolicy.reliableCourse(for: location)
        )
    }

    private struct LiveRouteStep {
        let legIndex: Int
        let stepIndex: Int
        let step: MKRoute.Step
    }

    private struct LiveNavigationProgress {
        let maneuver: LiveRouteStep
        let maneuverFlatIndex: Int
        let distance: CLLocationDistance
        let totalRemainingDistance: CLLocationDistance
        let totalRemainingTravelTime: TimeInterval
        let upcomingInstructions: [String]
        let followingManeuverDistance: CLLocationDistance?
    }

    private func resetLiveNavigationProgress() {
        navigationStepCursor = 0
        announcedManeuverStages = [:]
        pendingManeuverSpeech = [:]
        activeManeuverSpeech = [:]
        pendingBreakReminderSpeech = [:]
        activeBreakReminderSpeech = [:]
        pendingFuelReminderSpeech = [:]
        activeFuelReminderSpeech = [:]
        diagnosticManeuverKey = nil
        diagnosticManeuverInstruction = nil
        diagnosticManeuverDistance = nil
        resetDeviationTracking()
        arrivalStrikes = 0
        arrivalCandidateSince = nil
        lastAcceptedNavigationLocation = nil
        lastReliableGuidanceSpeedMps = nil
        lastReliableGuidanceSpeedAt = nil
        lastLocationRejectionLoggedAt = nil
        consecutiveRerouteFailures = 0
        onRouteRecoveryFixCount = 0
        offlineNeedsInitialPositionMatch = false
        offlineInitialMatchStepIndex = nil
        offlineDeviationWarningActive = false
        isManeuverGuidanceReliable = true
        lastLongTripPlanRefreshAt = nil
        lastOfflineProgressPersistedAt = nil
    }

    /// Publishes a maneuver belonging to the newly installed route before the
    /// next Core Location fix arrives. Phone, speech, MCP and CarPlay all read
    /// these same fields, so none of them can retain guidance from a previous
    /// destination during the route transition.
    private func seedInitialNavigationPresentation() {
        let values = legs.flatMap(\.steps).map {
            (instruction: $0.instructions, distance: $0.distance)
        }
        guard let seed = NavigationInitialManeuverPolicy.seed(steps: values) else {
            nextManeuverIdentity = legs.isEmpty ? nil : "live:\(routeCalculationGeneration):final"
            nextManeuverInstruction = legs.isEmpty ? nil : "Dem Straßenverlauf bis zum Ziel folgen"
            nextManeuverDistance = legs.isEmpty ? nil : totalDistance
            upcomingManeuverInstructions = nextManeuverInstruction.map { [$0] } ?? []
            return
        }
        nextManeuverIdentity = "live:\(routeCalculationGeneration):\(seed.stepIndex)"
        nextManeuverInstruction = seed.instruction
        nextManeuverDistance = seed.distance
        upcomingManeuverInstructions = seed.upcomingInstructions
    }

    @discardableResult
    private func detectArrival(at location: CLLocation, settings: DriveSettings) -> Bool {
        guard let coordinate = destination?.placemark.coordinate else { return false }
        let lock = activeRouteLock ?? routeLockStore.activeLock
        let visited = Set(lock?.visitedWaypointIDs ?? [])
        let hasOpenRequiredWaypoints = lock?.waypoints.contains {
            $0.required && !visited.contains($0.id)
        } ?? false
        guard NavigationArrivalPolicy.mayCompleteTrip(
            hasOpenRequiredWaypoints: hasOpenRequiredWaypoints
        ) else {
            arrivalStrikes = 0
            arrivalCandidateSince = nil
            return false
        }
        if NavigationArrivalPolicy.isArrivalFix(location, destination: coordinate) {
            if arrivalStrikes == 0 { arrivalCandidateSince = location.timestamp }
            arrivalStrikes += 1
        } else {
            arrivalStrikes = 0
            arrivalCandidateSince = nil
        }
        guard arrivalStrikes >= NavigationArrivalPolicy.requiredConsecutiveFixes,
              NavigationArrivalPolicy.hasSettled(
                since: arrivalCandidateSince, at: location.timestamp
              ) else { return false }

        arrivalStrikes = 0
        arrivalCandidateSince = nil
        closeOutstandingManeuverDiagnostic(reason: .arrival)
        finishUsageSession()
        invalidateNavigationAsyncWork()
        isNavigating = false
        isUsingOfflineGuidance = false
        isRecalculating = false
        speedWarning = false
        remainingDistanceMetres = 0
        remainingTravelTime = 0
        nextManeuverIdentity = "arrival"
        nextManeuverInstruction = "Ziel erreicht"
        nextManeuverDistance = 0
        upcomingManeuverInstructions = []
        lastAnnouncement = "Ziel erreicht"
        hasArrived = true
        resetDeviationTracking()
        if settings.voiceGuidance { speak("Du hast dein Ziel erreicht.", priority: .critical) }
        routeLockStore.finish()
        activeRouteLock = nil
        routeLockStore.clearFinished()
        clearCompletedTripPlanningState()
        clearCompletedRoutePresentation(preservingArrival: true)
        DriveDiagnosticStore.append(.arrivalReached, detail: destination?.name ?? destinationText)
        return true
    }

    private func routeSteps() -> [LiveRouteStep] {
        legs.enumerated().flatMap { legIndex, leg in
            leg.steps.enumerated().map { LiveRouteStep(legIndex: legIndex, stepIndex: $0.offset, step: $0.element) }
        }
    }

    private func liveNavigationProgress(at location: CLLocation,
                                        allowsFullRecovery: Bool = false)
        -> LiveNavigationProgress? {
        let steps = routeSteps()
        guard !steps.isEmpty else { return nil }

        let cursor = min(navigationStepCursor, steps.count - 1)
        var metrics = steps.map {
            NavigationStepMetric(
                distanceFromRoute: .greatestFiniteMagnitude,
                remainingOnStep: .greatestFiniteMagnitude,
                stepDistance: $0.step.distance,
                hasManeuverInstruction: !$0.step.instructions
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        let evaluationIndices: any Sequence<Int> = allowsFullRecovery
            ? AnySequence(steps.indices)
            : AnySequence(NavigationStepSelectionPolicy.metricEvaluationIndices(
                current: cursor, stepCount: steps.count
            ))
        let vehicleCourse = NavigationMotionPolicy.reliableCourse(for: location)
        for index in evaluationIndices {
            metrics[index] = Self.navigationMetric(
                from: location.coordinate, on: steps[index].step.polyline,
                stepDistance: steps[index].step.distance,
                vehicleCourse: vehicleCourse,
                hasManeuverInstruction: !steps[index].step.instructions
                    .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            )
        }
        let transitionRadius = max(8, location.horizontalAccuracy * 1.5)
        navigationStepCursor = NavigationStepSelectionPolicy.selectedIndex(
            current: cursor, metrics: metrics,
            transitionRadius: transitionRadius,
            allowsFullRecovery: allowsFullRecovery
        )
        let currentIndex = navigationStepCursor

        let currentStepRemaining = metrics[currentIndex].remainingOnStep
        let routeRemaining = max(0, currentStepRemaining
            + steps.dropFirst(currentIndex + 1).reduce(0) { $0 + $1.step.distance })
        let routeRemainingTime = estimatedRemainingTravelTime(
            currentIndex: currentIndex, currentStepRemaining: currentStepRemaining,
            steps: steps, totalRemainingDistance: routeRemaining
        )

        guard let maneuverIndex = steps.indices.dropFirst(currentIndex + 1).first(where: {
            !steps[$0].step.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            // Being on the final road is not the same as arriving. The
            // separate multi-fix arrival detector is the only authority that
            // may show and speak "Ziel erreicht".
            nextManeuverIdentity = "live:\(routeCalculationGeneration):final"
            nextManeuverInstruction = "Dem Straßenverlauf bis zum Ziel folgen"
            nextManeuverDistance = routeRemaining
            upcomingManeuverInstructions = ["Dem Straßenverlauf bis zum Ziel folgen"]
            remainingDistanceMetres = routeRemaining
            remainingTravelTime = routeRemainingTime
            return nil
        }

        var distance = metrics[currentIndex].remainingOnStep
        if maneuverIndex > currentIndex + 1 {
            for index in (currentIndex + 1)..<maneuverIndex { distance += steps[index].step.distance }
        }
        if !distance.isFinite {
            let coordinate = steps[maneuverIndex].step.polyline.coordinate
            distance = location.distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
        let upcoming = steps[maneuverIndex...].compactMap { item -> String? in
            let instruction = item.step.instructions.trimmingCharacters(in: .whitespacesAndNewlines)
            return instruction.isEmpty ? nil : instruction
        }
        let followingIndex = NavigationInstructionSequencePolicy.firstDistinctInstructionIndex(
            in: steps.map(\.step.instructions), after: maneuverIndex
        )
        let followingDistance = followingIndex.map { index in
            steps[maneuverIndex..<index].reduce(0) { $0 + $1.step.distance }
        }
        return LiveNavigationProgress(
            maneuver: steps[maneuverIndex], maneuverFlatIndex: maneuverIndex,
            distance: max(0, distance),
            totalRemainingDistance: routeRemaining,
            totalRemainingTravelTime: routeRemainingTime,
            upcomingInstructions: Array(NavigationInstructionSequencePolicy
                .removingConsecutiveDuplicates(upcoming).prefix(5)),
            followingManeuverDistance: followingDistance
        )
    }

    private func updateNextManeuver(using progress: LiveNavigationProgress) {
        guard !progress.upcomingInstructions.isEmpty else {
            nextManeuverIdentity = "live:\(routeCalculationGeneration):follow"
            nextManeuverInstruction = "Route folgen"
            nextManeuverDistance = nil
            upcomingManeuverInstructions = []
            return
        }
        nextManeuverIdentity = CarPlayManeuverIdentityPolicy.live(
            legIndex: progress.maneuver.legIndex,
            stepIndex: progress.maneuver.stepIndex
        )
        nextManeuverInstruction = progress.maneuver.step.instructions
        nextManeuverDistance = progress.distance
        upcomingManeuverInstructions = progress.upcomingInstructions
        remainingDistanceMetres = progress.totalRemainingDistance
        remainingTravelTime = progress.totalRemainingTravelTime
    }

    private func estimatedRemainingTravelTime(currentIndex: Int,
                                              currentStepRemaining: CLLocationDistance,
                                              steps: [LiveRouteStep],
                                              totalRemainingDistance: CLLocationDistance) -> TimeInterval {
        guard let current = steps[safe: currentIndex],
              let leg = legs[safe: current.legIndex] else {
            let average = totalDistance / max(totalTravelTime, 1)
            return totalRemainingDistance / max(average, 1)
        }
        let remainingInCurrentLeg = max(0, currentStepRemaining + steps.dropFirst(currentIndex + 1)
            .prefix { $0.legIndex == current.legIndex }
            .reduce(0) { $0 + $1.step.distance })
        let followingTimes = legs.dropFirst(current.legIndex + 1).map(\.expectedTravelTime)
        if let estimate = RouteRemainingTimePolicy.estimate(
            currentLegRemainingDistance: remainingInCurrentLeg,
            currentLegDistance: leg.distance,
            currentLegTravelTime: leg.expectedTravelTime,
            followingLegTravelTimes: followingTimes
        ) {
            return estimate
        }
        let average = totalDistance / max(totalTravelTime, 1)
        return totalRemainingDistance / max(average, 1)
    }

    private func markReachedWaypoints(at location: CLLocation, settings: DriveSettings) {
        guard pendingReachedWaypointID == nil,
              let lock = routeLockStore.activeLock else { return }
        let visited = Set(lock.visitedWaypointIDs ?? [])
        guard let reachedID = RouteWaypointVisitPolicy.reachedWaypointID(
            waypoints: lock.waypoints, visitedIDs: visited, location: location
        ) else { return }
        // At bridges and motorway junctions distance alone can match the road
        // below. Only after the cheap proximity check do we sample the route
        // and verify a trustworthy vehicle course against the intended road.
        if let waypoint = lock.waypoints.first(where: { $0.id == reachedID }) {
            let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 600) }
            let expectedCourse = NavigationCourseMatchingPolicy.routeCourse(
                near: waypoint.coordinate.clLocationCoordinate,
                coordinates: routeCoordinates
            )
            guard RouteWaypointVisitPolicy.reachedWaypointID(
                waypoints: lock.waypoints, visitedIDs: visited, location: location,
                expectedCourseDegrees: expectedCourse
            ) == reachedID else { return }
        }
        pendingReachedWaypointID = reachedID
        let session = navigationSessionGeneration
        Task {
            _ = await calculate(from: location.coordinate, settings: settings,
                                navigationSession: session,
                                newlyReachedWaypointID: reachedID)
            if pendingReachedWaypointID == reachedID {
                pendingReachedWaypointID = nil
            }
        }
    }

    private func persistRouteLockProgress(at location: CLLocation) {
        persistOfflineCacheProgress(at: location.timestamp)
        guard let lock = routeLockStore.activeLock,
              let corridor = lock.corridorPoints, corridor.count > 2,
              let match = RouteCorridorRestorePolicy.forwardNearBestMatch(
                for: .init(latitude: location.coordinate.latitude,
                           longitude: location.coordinate.longitude),
                in: corridor, previousProgress: lock.lastRouteProgress
              ),
              match.distance <= max(lock.corridorWidthMetres * 2, 5_000)
        else { return }
        let progress = Double(match.index) / Double(corridor.count - 1)
        let previous = lock.lastRouteProgress ?? 0
        guard progress >= previous else { return }
        let now = location.timestamp
        let enoughMovement = progress - previous >= 0.003
        let periodicCheckpoint = NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: lastRouteProgressPersistedAt, now: now, interval: 60
        )
        guard enoughMovement || periodicCheckpoint else { return }
        routeLockStore.update { current in
            current.lastRouteProgress = max(current.lastRouteProgress ?? 0, progress)
        }
        activeRouteLock = routeLockStore.activeLock
        lastRouteProgressPersistedAt = now
    }

    private func persistOfflineCacheProgress(at now: Date) {
        guard isNavigating, remainingDistanceMetres >= 0,
              var cache = offlineRoute else { return }
        let cachedDistance = cache.legs.reduce(0) { $0 + $1.distance }
        guard let progress = OfflineRouteProgressPolicy.progress(
            liveRouteDistance: totalDistance,
            cachedRouteDistance: cachedDistance,
            remainingDistance: remainingDistanceMetres
        ) else { return }
        let previous = cache.navigationProgress ?? 0
        let enoughMovement = progress - previous >= 0.003
        let periodicCheckpoint = NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: lastOfflineProgressPersistedAt, now: now, interval: 60
        )
        guard progress >= previous, enoughMovement || periodicCheckpoint else { return }
        cache = cache.updatingNavigationProgress(progress)
        guard Self.offlineCacheStore.save(cache) else { return }
        offlineRoute = cache
        lastOfflineProgressPersistedAt = now
    }

    private func checkSpeedLimit(at coordinate: CLLocationCoordinate2D, speedMps: Double?) {
        guard let speedMps,
              let limit = currentSpeedLimit(near: coordinate), let maxspeed = limit.maxspeed else {
            speedWarning = false
            return
        }
        let speedKmh = speedMps * 3.6
        // 5 km/h Toleranz für GPS-Ungenauigkeit / Tacho-Rundung.
        speedWarning = speedKmh > Double(maxspeed) + 5
    }

    private func announce(_ progress: LiveNavigationProgress, guidanceSpeedMps: Double,
                          recoveredAfterLocationGap: Bool = false) {
        let speedKmh = guidanceSpeedMps * 3.6
        let key = "\(progress.maneuver.legIndex):\(progress.maneuver.stepIndex):\(progress.maneuver.step.instructions)"
        if recordManeuverTransition(
            key: key,
            instruction: progress.maneuver.step.instructions,
            distance: progress.distance,
            guidanceSpeedMps: guidanceSpeedMps,
            recoveredAfterLocationGap: recoveredAfterLocationGap
        ) { return }
        guard let stage = NavigationAnnouncementStage.stage(distance: progress.distance, speedKmh: speedKmh) else { return }
        let completed = announcedManeuverStages[key] ?? []
        guard NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            stage, delivered: completed, pending: pendingStages(for: key)
        ) else { return }

        // If a sparse GPS update lands directly in the immediate zone, mark
        // earlier stages complete as well so they cannot be spoken afterwards.
        let following = progress.upcomingInstructions.dropFirst().first
        let speech = NavigationManeuverSpeechPolicy.text(
            instruction: progress.maneuver.step.instructions,
            distance: progress.distance,
            stage: stage,
            followingInstruction: following,
            followingDistance: progress.followingManeuverDistance
        )
        _ = speak(
            speech, priority: .forAnnouncementStage(stage),
            maneuverClaim: .init(
                key: key, stage: stage, instruction: progress.maneuver.step.instructions,
                distance: progress.distance, issuedAt: Date()
            )
        )
    }

    /// Returns true when a final cue for the maneuver just crossed was spoken.
    /// A close following maneuver is chained into the same utterance. Waiting
    /// for another GPS sample here can be too late at motorway interchanges.
    @discardableResult
    private func recordManeuverTransition(key: String, instruction: String,
                                          distance: CLLocationDistance,
                                          guidanceSpeedMps: Double,
                                          recoveredAfterLocationGap: Bool = false) -> Bool {
        guard diagnosticManeuverKey != key else {
            diagnosticManeuverDistance = distance
            return false
        }
        let previousKey = diagnosticManeuverKey
        let previousInstruction = diagnosticManeuverInstruction
        let previousDistance = diagnosticManeuverDistance
        let previousInFlightStages = previousKey.map { pendingStages(for: $0) } ?? []
        let shouldRecover = ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: previousKey, nextKey: key,
            stages: previousKey.map { announcedManeuverStages[$0] ?? [] } ?? [],
            inFlightStages: previousInFlightStages,
            previousDistance: previousDistance ?? .greatestFiniteMagnitude,
            speedMetresPerSecond: guidanceSpeedMps,
            recoveredAfterLocationGap: recoveredAfterLocationGap
        )
        var recovered = false
        if shouldRecover, let previousKey, let previousInstruction {
            var claims = [ManeuverSpeechClaim(
                key: previousKey, stage: .now, instruction: previousInstruction,
                distance: 0, issuedAt: Date()
            )]
            if distance <= NavigationChainedManeuverPolicy.maximumFollowingDistance,
               let currentStage = NavigationAnnouncementStage.stage(
                   distance: distance, speedKmh: guidanceSpeedMps * 3.6
               ) {
                claims.append(.init(
                    key: key, stage: currentStage, instruction: instruction,
                    distance: distance, issuedAt: Date()
                ))
            }
            recovered = speak(
                NavigationSpeechFormatter.spokenText(
                    previousInstruction,
                    distance: 0,
                    then: instruction,
                    followingDistance: distance
                ),
                priority: .critical,
                maneuverClaims: claims
            )
        }
        let decisiveCueAlreadyInFlight = ManeuverDiagnosticPolicy.deliveredDecisiveCue(
            stages: previousInFlightStages
        )
        closeOutstandingManeuverDiagnostic(reason:
            recovered || decisiveCueAlreadyInFlight ? .recoveryQueued : .routeTransition
        )
        diagnosticManeuverKey = key
        diagnosticManeuverInstruction = instruction
        diagnosticManeuverDistance = distance
        return recovered
    }

    private func closeOutstandingManeuverDiagnostic(
        reason: ManeuverDiagnosticPolicy.ClosureReason = .routeTransition
    ) {
        if let previous = diagnosticManeuverKey,
           ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: announcedManeuverStages[previous] ?? [], reason: reason
           ) {
            DriveDiagnosticStore.append(.maneuverFinalCueMissed,
                                        detail: DriveDiagnosticDetail.navigationSample(
                                            diagnosticManeuverInstruction ?? "Unbekanntes Manöver",
                                            location: lastAcceptedNavigationLocation
                                        ))
        }
        diagnosticManeuverKey = nil
        diagnosticManeuverInstruction = nil
        diagnosticManeuverDistance = nil
    }

    private func pendingStages(for key: String) -> Set<NavigationAnnouncementStage> {
        Set((Array(pendingManeuverSpeech.values) + Array(activeManeuverSpeech.values))
            .joined().lazy.filter { $0.key == key }.map(\.stage))
    }

    private func expireStaleManeuverSpeech(now: Date) {
        let expiredPending = pendingManeuverSpeech.filter {
            $0.value.contains { NavigationSpeechClaimTimeoutPolicy.isExpired(
                issuedAt: $0.issuedAt, now: now, active: false
            ) }
        }
        let expiredActive = activeManeuverSpeech.filter {
            $0.value.contains { NavigationSpeechClaimTimeoutPolicy.isExpired(
                issuedAt: $0.issuedAt, now: now, active: true
            ) }
        }
        let expiredPendingBreaks = pendingBreakReminderSpeech.filter {
            NavigationSpeechClaimTimeoutPolicy.isExpired(
                issuedAt: $0.value.issuedAt, now: now, active: false
            )
        }
        let expiredActiveBreaks = activeBreakReminderSpeech.filter {
            NavigationSpeechClaimTimeoutPolicy.isExpired(
                issuedAt: $0.value.issuedAt, now: now, active: true
            )
        }
        let expiredPendingFuel = pendingFuelReminderSpeech.filter {
            NavigationSpeechClaimTimeoutPolicy.isExpired(
                issuedAt: $0.value.issuedAt, now: now, active: false
            )
        }
        let expiredActiveFuel = activeFuelReminderSpeech.filter {
            NavigationSpeechClaimTimeoutPolicy.isExpired(
                issuedAt: $0.value.issuedAt, now: now, active: true
            )
        }
        guard !expiredPending.isEmpty || !expiredActive.isEmpty ||
                !expiredPendingBreaks.isEmpty || !expiredActiveBreaks.isEmpty ||
                !expiredPendingFuel.isEmpty || !expiredActiveFuel.isEmpty else { return }
        let claim = expiredActive.values.first?.first ?? expiredPending.values.first?.first
        // Remove the stale queued utterance from AVSpeechSynthesizer as well;
        // otherwise it could start after the retry and produce a duplicate.
        // Clean all local ownership synchronously because the exact failure
        // being handled here may also mean `didCancel` never arrives.
        cancelCurrentSpeechWork()
        let breakStage = expiredActiveBreaks.values.first?.stage ??
            expiredPendingBreaks.values.first?.stage
        let fuelText = expiredActiveFuel.values.first?.text ??
            expiredPendingFuel.values.first?.text
        DriveDiagnosticStore.append(
            .speechDeliveryFailed,
            detail: DriveDiagnosticDetail.navigationSample(
                claim.map { "\($0.stage) · \($0.instruction)" } ??
                    breakStage.map { "Pausenerinnerung · \($0)" } ??
                    fuelText.map { "Tankhinweis · \($0)" } ?? "Unbekannte Fahransage",
                location: lastAcceptedNavigationLocation
            )
        )
    }

    /// Route calculation is intentionally non-destructive until its complete
    /// result is ready. At that exact commit boundary, however, spoken work
    /// from the old route becomes unsafe and must not finish over the new map.
    private func cancelSpeechForRouteReplacementIfNeeded() {
        let currentlyHasSpeechWork = hasSpeechWork
        guard NavigationSpeechInterruptionPolicy.shouldCancelForRouteReplacement(
            navigationActive: isNavigating, hasSpeechWork: currentlyHasSpeechWork
        ) else { return }

        cancelCurrentSpeechWork()
    }

    private func cancelSpeechForConfirmedDeviationIfNeeded() {
        guard NavigationSpeechInterruptionPolicy.shouldCancelForConfirmedDeviation(
            confirmedOffRoute: !isManeuverGuidanceReliable,
            navigationActive: isNavigating,
            hasSpeechWork: hasSpeechWork
        ) else { return }

        cancelCurrentSpeechWork()
    }

    private var hasSpeechWork: Bool {
        synthesizer.isSpeaking || activeUtterance != nil ||
            !pendingManeuverSpeech.isEmpty || !activeManeuverSpeech.isEmpty ||
            !pendingBreakReminderSpeech.isEmpty || !activeBreakReminderSpeech.isEmpty ||
            !pendingFuelReminderSpeech.isEmpty || !activeFuelReminderSpeech.isEmpty
    }

    private func cancelCurrentSpeechWork() {
        let replacedUtterance = activeUtterance
        // Remove ownership before asking AVSpeechSynthesizer to stop. Its
        // delegate callback is normally asynchronous, but treating that as a
        // guarantee could make a synchronous callback look like an unexpected
        // Bluetooth failure and immediately speak the cancelled turn again.
        pendingManeuverSpeech = [:]
        activeManeuverSpeech = [:]
        pendingBreakReminderSpeech = [:]
        activeBreakReminderSpeech = [:]
        pendingFuelReminderSpeech = [:]
        activeFuelReminderSpeech = [:]
        synthesizer.stopSpeaking(at: .immediate)
        if let replacedUtterance {
            finishAudioSession(for: replacedUtterance)
        } else {
            activeSpeechPriority = nil
        }
    }

    @discardableResult
    private func speak(_ text: String, priority: NavigationSpeechPriority,
                       maneuverClaim: ManeuverSpeechClaim? = nil,
                       maneuverClaims: [ManeuverSpeechClaim] = [],
                       breakReminderClaim: NavigationBreakReminderPolicy.Stage? = nil,
                       fuelReminderClaim: (key: String, text: String)? = nil) -> Bool {
        // Do not queue a maneuver under an active call, Siri session or other
        // system interruption. Returning false leaves its claim retryable on
        // the next GPS fix after audio becomes available again.
        guard !text.isEmpty, !audioSessionInterrupted else { return false }
        let hasActiveSpeechWork = NavigationSpeechInterruptionPolicy.hasActiveWork(
            isSpeaking: synthesizer.isSpeaking,
            hasQueuedUtterance: activeUtterance != nil
        )
        let requestedManeuverClaims = maneuverClaims + (maneuverClaim.map { [$0] } ?? [])
        if hasActiveSpeechWork, !requestedManeuverClaims.isEmpty {
            let activeKeys = Set(
                (Array(pendingManeuverSpeech.values) + Array(activeManeuverSpeech.values))
                    .joined().map(\.key)
            )
            let incomingKeys = Set(requestedManeuverClaims.map(\.key))
            if NavigationSpeechInterruptionPolicy.shouldDeferForSameManeuver(
                activeKeys: activeKeys,
                incomingKeys: incomingKeys,
                incomingPriority: priority
            ) {
                // Do not claim this stage. A following location fix retries it
                // once the current complete sentence has finished.
                return false
            }
        }
        if hasActiveSpeechWork, let activeSpeechPriority,
           !NavigationSpeechInterruptionPolicy.shouldInterrupt(
               active: activeSpeechPriority, incoming: priority
           ) {
            return false
        }
        // Supersede the old utterance before activating the new audio session.
        // AVSpeechSynthesizer can omit or delay `didCancel` across Bluetooth,
        // Siri and phone-call route changes; retaining its old claim would
        // later cancel the new instruction when the timeout audit runs.
        if hasActiveSpeechWork { cancelCurrentSpeechWork() }
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = Self.preferredGermanVoice()
        utterance.rate = 0.48
        utterance.pitchMultiplier = 0.98
        utterance.volume = 1
        utterance.preUtteranceDelay = 0.08
        utterance.postUtteranceDelay = 0.12
        utterance.prefersAssistiveTechnologySettings = false
        activeUtterance = utterance
        activeSpeechPriority = priority
        if !requestedManeuverClaims.isEmpty {
            pendingManeuverSpeech[ObjectIdentifier(utterance)] = requestedManeuverClaims
        }
        if let breakReminderClaim {
            pendingBreakReminderSpeech[ObjectIdentifier(utterance)] = .init(
                stage: breakReminderClaim, issuedAt: Date()
            )
        }
        if let fuelReminderClaim {
            pendingFuelReminderSpeech[ObjectIdentifier(utterance)] = .init(
                key: fuelReminderClaim.key, text: fuelReminderClaim.text, issuedAt: Date()
            )
        }
        synthesizer.speak(utterance)
        return true
    }

    #if os(iOS)
    @objc private func handleAudioSessionInterruption(_ notification: Notification) {
        guard let rawValue = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawValue) else { return }
        switch type {
        case .began:
            audioSessionInterrupted = true
            // A turn instruction partially spoken before a call is unsafe to
            // resume later. Cancel it without claiming delivery; a current GPS
            // fix can issue the appropriate stage again after the interruption.
            cancelCurrentSpeechWork()
        case .ended:
            audioSessionInterrupted = false
            retryCurrentManeuverAfterSpeechBecomesAvailable()
        @unknown default:
            audioSessionInterrupted = true
            cancelCurrentSpeechWork()
        }
    }
    #endif

    /// Re-evaluates guidance whenever the speech channel becomes free. This is
    /// needed not only after calls or Siri: at a tight interchange a second
    /// critical cue deliberately cannot cut the first cue in half. Waiting
    /// for another GPS callback after that first sentence can be too late, so
    /// use the latest accepted fix immediately.
    private func retryCurrentManeuverAfterSpeechBecomesAvailable() {
        let settings = DriveSettings.shared
        guard NavigationSpeechInterruptionPolicy.shouldRetryManeuverAfterInterruption(
            navigationActive: isNavigating,
            voiceGuidance: settings.voiceGuidance,
            guidanceReliable: isManeuverGuidanceReliable,
            hasUsableLocation: lastAcceptedNavigationLocation != nil
        ), let location = lastAcceptedNavigationLocation else { return }
        let speed = NavigationGuidanceSpeedPolicy.effective(
            current: NavigationMotionPolicy.reliableSpeed(for: location),
            previous: lastReliableGuidanceSpeedMps,
            previousAt: lastReliableGuidanceSpeedAt,
            now: location.timestamp
        )
        if isUsingOfflineGuidance {
            guard let progress = currentOfflineGuidanceProgress(at: location) else { return }
            announceOfflineManeuver(progress, guidanceSpeedMps: speed)
            return
        }
        guard let progress = liveNavigationProgress(at: location) else { return }
        updateNextManeuver(using: progress)
        announce(progress, guidanceSpeedMps: speed)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didStart utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        if let claims = pendingManeuverSpeech.removeValue(forKey: identifier) {
            activeManeuverSpeech[identifier] = claims
        }
        if let claim = pendingBreakReminderSpeech.removeValue(forKey: identifier) {
            activeBreakReminderSpeech[identifier] = claim
        }
        if let claim = pendingFuelReminderSpeech.removeValue(forKey: identifier) {
            activeFuelReminderSpeech[identifier] = claim
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        let claims = NavigationAnnouncementDeliveryPolicy.completedClaims(
            active: activeManeuverSpeech.removeValue(forKey: identifier),
            queued: pendingManeuverSpeech.removeValue(forKey: identifier)
        )
        let breakClaim = NavigationAnnouncementDeliveryPolicy.completedClaims(
            active: activeBreakReminderSpeech.removeValue(forKey: identifier),
            queued: pendingBreakReminderSpeech.removeValue(forKey: identifier)
        )
        let fuelClaim = NavigationAnnouncementDeliveryPolicy.completedClaims(
            active: activeFuelReminderSpeech.removeValue(forKey: identifier),
            queued: pendingFuelReminderSpeech.removeValue(forKey: identifier)
        )
        if let claims,
           NavigationAnnouncementDeliveryPolicy.shouldCommitDelivery(didFinish: true) {
            for claim in claims {
                let delivered = announcedManeuverStages[claim.key] ?? []
                let isNewCompletion = !delivered.contains(claim.stage)
                announcedManeuverStages[claim.key] =
                    NavigationAnnouncementDeliveryPolicy.committedStages(
                        delivered: delivered, completing: claim.stage
                    )
                guard isNewCompletion else { continue }
                lastAnnouncement = claim.instruction
                DriveDiagnosticStore.append(
                    .maneuverAnnounced,
                    detail: "\(claim.stage) · \(Int(claim.distance)) m · \(claim.instruction)"
                )
            }
        }
        if NavigationBreakReminderSpeechDeliveryPolicy.shouldClearPending(
            pendingRawValue: drivingRestState.pendingSpokenReminderRawValue,
            completed: breakClaim?.stage
        ) {
            if let breakClaim {
                DriveDiagnosticStore.append(
                    .breakReminderAnnounced,
                    detail: "Pausenerinnerung · \(breakClaim.stage)"
                )
            }
            drivingRestState.pendingSpokenReminderRawValue = nil
            drivingRestStore.save(drivingRestState)
        }
        if let fuelClaim,
           NavigationFuelReminderSpeechDeliveryPolicy.shouldClearPending(
                pendingKey: drivingFuelState.pendingSpokenReminderKey,
                completedKey: fuelClaim.key
           ) {
            DriveDiagnosticStore.append(
                .fuelReminderAnnounced,
                detail: "Tankhinweis · gesprochen · \(fuelClaim.text)"
            )
            drivingFuelState.clearPendingSpeech()
            drivingFuelStore.save(drivingFuelState)
        }
        let releasedSpeechChannel = activeUtterance === utterance
        finishAudioSession(for: utterance)
        // Do not submit a new utterance from inside AVSpeechSynthesizer's
        // completion stack. On the next actor turn the just-freed channel can
        // safely deliver a deferred close-following maneuver even if no new
        // location sample arrives in time.
        if releasedSpeechChannel {
            Task { [weak self] in
                await Task.yield()
                self?.retryCurrentManeuverAfterSpeechBecomesAvailable()
            }
        }
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        let identifier = ObjectIdentifier(utterance)
        let cancelledManeuverClaim = activeManeuverSpeech[identifier]?.first ??
            pendingManeuverSpeech[identifier]?.first
        let hadManeuverClaim = cancelledManeuverClaim != nil
        pendingManeuverSpeech.removeValue(forKey: identifier)
        activeManeuverSpeech.removeValue(forKey: identifier)
        pendingBreakReminderSpeech.removeValue(forKey: identifier)
        activeBreakReminderSpeech.removeValue(forKey: identifier)
        pendingFuelReminderSpeech.removeValue(forKey: identifier)
        activeFuelReminderSpeech.removeValue(forKey: identifier)
        finishAudioSession(for: utterance)
        guard NavigationSpeechCancellationPolicy.shouldRetryUnexpectedCancellation(
            hadManeuverClaim: hadManeuverClaim,
            navigationActive: isNavigating,
            voiceGuidance: DriveSettings.shared.voiceGuidance,
            guidanceReliable: isManeuverGuidanceReliable,
            hasUsableLocation: lastAcceptedNavigationLocation != nil
        ) else { return }
        DriveDiagnosticStore.append(
            .speechDeliveryFailed,
            detail: DriveDiagnosticDetail.navigationSample(
                cancelledManeuverClaim.map {
                    "\($0.stage) · \($0.instruction)"
                } ?? "Fahransage unerwartet vom Audiosystem abgebrochen",
                location: lastAcceptedNavigationLocation
            )
        )
        // Let AVSpeechSynthesizer finish its cancellation callback before a
        // fresh utterance is submitted to the possibly just-changed route.
        Task { [weak self] in
            await Task.yield()
            self?.retryCurrentManeuverAfterSpeechBecomesAvailable()
        }
    }

    private func finishAudioSession(for utterance: AVSpeechUtterance) {
        guard activeUtterance === utterance else { return }
        activeUtterance = nil
        activeSpeechPriority = nil
        #if os(iOS)
        // Return music/podcasts to their normal volume as soon as this exact
        // instruction ends. A cancelled older utterance must not deactivate
        // the session underneath a newer instruction.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    private static func preferredGermanVoice() -> AVSpeechSynthesisVoice? {
        let voices = AVSpeechSynthesisVoice.speechVoices().filter { $0.language == "de-DE" }
        if let identifier = NavigationVoiceSelectionPolicy.selectedIdentifier(
            preferred: DriveSettings.shared.navigationVoiceIdentifier,
            available: voices.map(\.identifier)
        ), let selected = voices.first(where: { $0.identifier == identifier }) {
            return selected
        }
        return voices.max { lhs, rhs in
            let lhsScore = NavigationVoiceSelectionPolicy.score(
                qualityRawValue: lhs.quality.rawValue, identifier: lhs.identifier
            )
            let rhsScore = NavigationVoiceSelectionPolicy.score(
                qualityRawValue: rhs.quality.rawValue, identifier: rhs.identifier
            )
            return lhsScore < rhsScore
        } ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    /// Zählt aufeinanderfolgende Positionsmeldungen weit abseits der Route und
    /// löst nach ein paar Treffern (nicht schon beim ersten GPS-Ausreißer) eine
    /// automatische Neuberechnung ab der aktuellen Position aus.
    private func checkForDeviation(from location: CLLocation, settings: DriveSettings,
                                   allowsAutomaticReroute: Bool) {
        // Continue matching against the still-installed route while MapKit is
        // recalculating. If the driver returns before the request completes,
        // the old route is trustworthy again and the obsolete network result
        // must be prevented from replacing it.
        guard !isLoading else { return }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 65 else { return }
        let rerouteAllowed = NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: lastRerouteAt,
            consecutiveFailures: consecutiveRerouteFailures
        )
        let steps = routeSteps()
        let corridor = NavigationDeviationCorridorPolicy.indices(
            current: navigationStepCursor, stepCount: steps.count
        )
        let reliableSpeed = NavigationMotionPolicy.reliableSpeed(for: location) ?? 0
        let reliableCourse = NavigationMotionPolicy.reliableCourse(for: location)
        guard let nearestMetric = NavigationDeviationGeometryPolicy.nearestUsableMetric(
            corridor.map {
                Self.navigationMetric(
                    from: location.coordinate, on: steps[$0].step.polyline,
                    stepDistance: steps[$0].step.distance,
                    vehicleCourse: reliableCourse
                )
            }
        ) else {
            // Keep the installed guidance state while route geometry is
            // temporarily unavailable. The calculation/watchdog lifecycle is
            // responsible for recovery; a missing polyline is not evidence
            // that the driver left the road.
            resetDeviationTracking()
            return
        }
        let nearest = nearestMetric.distanceFromRoute
        let isWrongWay = NavigationWrongWayPolicy.isOpposing(
            courseDifferenceDegrees: nearestMetric.courseDifferenceDegrees,
            distanceFromRoute: nearest,
            horizontalAccuracy: location.horizontalAccuracy,
            speedMetresPerSecond: reliableSpeed
        )
        let isOutsideCorridor = NavigationDeviationPolicy.isOutsideCorridor(
            distanceFromRoute: nearest,
            horizontalAccuracy: location.horizontalAccuracy,
            speedMetresPerSecond: reliableSpeed
        ) || isWrongWay
        let isReliableRejoinFix = NavigationRouteRejoinPolicy.acceptsInsideFix(
            isOutsideCorridor: isOutsideCorridor,
            courseDifferenceDegrees: nearestMetric.courseDifferenceDegrees,
            speedMetresPerSecond: reliableSpeed
        )
        if isOutsideCorridor {
            onRouteRecoveryFixCount = 0
        } else if !isManeuverGuidanceReliable, isReliableRejoinFix {
            onRouteRecoveryFixCount += 1
            if NavigationRouteRejoinPolicy.isConfirmed(
                consecutiveInsideFixes: onRouteRecoveryFixCount
            ) {
                let shouldCancelReroute = NavigationRouteRejoinPolicy
                    .shouldCancelAutomaticReroute(
                        isRecalculating: isRecalculating,
                        guidanceReliable: isManeuverGuidanceReliable,
                        consecutiveInsideFixes: onRouteRecoveryFixCount
                    )
                if shouldCancelReroute {
                    activeAutomaticRerouteTask?.cancel()
                    activeAutomaticRerouteTask = nil
                    rerouteGeneration = UUID()
                    routeCalculationGeneration = UUID()
                    isRecalculating = false
                    consecutiveRerouteFailures = 0
                }
                isManeuverGuidanceReliable = true
                onRouteRecoveryFixCount = 0
                DriveDiagnosticStore.append(
                    .routeRejoined,
                    detail: DriveDiagnosticDetail.navigationSample(
                        shouldCancelReroute
                            ? "Ursprüngliche Route stabil wieder erreicht; Neuberechnung beendet"
                            : "Ursprüngliche Route stabil wieder erreicht",
                        location: location
                    )
                )
            }
        } else {
            onRouteRecoveryFixCount = 0
        }
        let shouldAccumulate = NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: nearest,
            previousDistance: previousOffRouteDistance,
            horizontalAccuracy: location.horizontalAccuracy,
            speedMetresPerSecond: reliableSpeed,
            rerouteAllowed: rerouteAllowed,
            wrongWay: isWrongWay
        )
        previousOffRouteDistance = nearest
        guard shouldAccumulate else {
            resetDeviationTracking(keepingDistance: nearest)
            return
        }
        let now = location.timestamp
        if offRouteSince == nil {
            offRouteSince = now
            offRouteFixCount = 1
        } else {
            offRouteFixCount += 1
        }
        guard let offRouteSince,
              NavigationDeviationPolicy.isConfirmed(
                elapsed: now.timeIntervalSince(offRouteSince),
                consecutiveFixes: offRouteFixCount,
                speedMetresPerSecond: reliableSpeed
              ), allowsAutomaticReroute, !isRecalculating else { return }
        isManeuverGuidanceReliable = false
        // A confirmed departure invalidates the current maneuver immediately.
        // Do not let a queued or audible instruction from the abandoned road
        // finish while MapKit is still calculating its replacement.
        cancelSpeechForConfirmedDeviationIfNeeded()
        resetDeviationTracking()
        lastRerouteAt = Date()
        let sessionGeneration = navigationSessionGeneration
        let workGeneration = UUID()
        rerouteGeneration = workGeneration
        // Claim the reroute synchronously. Location updates can arrive faster
        // than the unstructured task below gets scheduled; setting this only
        // inside the task left a small window in which several identical
        // reroutes (and spoken status messages) could be queued at once.
        isRecalculating = true
        DriveDiagnosticStore.append(.rerouteRequested,
                                    detail: DriveDiagnosticDetail.navigationSample(
                                        isWrongWay
                                            ? "Falsche Fahrtrichtung auf der Route"
                                            : "Abweichung \(Int(nearest)) m",
                                        location: location
                                    ))
        // A suspended MapKit request must not leave the driving screen covered
        // by "Route wird neu berechnet" forever. The generation checks make
        // this watchdog ownership-specific: a new trip or newer reroute is
        // never stopped by an older timer.
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: NavigationRerouteWatchdogPolicy.timeoutNanoseconds)
            guard let self,
                  NavigationAsyncWorkPolicy.isCurrent(
                    navigationActive: self.isNavigating,
                    session: sessionGeneration,
                    currentSession: self.navigationSessionGeneration,
                    work: workGeneration,
                    currentWork: self.rerouteGeneration
                  ), self.isRecalculating else { return }
            self.rerouteGeneration = UUID()
            self.routeCalculationGeneration = UUID()
            self.isRecalculating = false
            self.activeAutomaticRerouteTask?.cancel()
            self.activeAutomaticRerouteTask = nil
            self.consecutiveRerouteFailures += 1
            self.lastRerouteAt = Date()
            DriveDiagnosticStore.append(
                .rerouteFailed,
                detail: "Zeitüberschreitung nach \(Int(NavigationRerouteWatchdogPolicy.timeout)) Sekunden"
            )
            if settings.voiceGuidance {
                _ = self.speak(
                    "Die Neuberechnung dauert zu lange. Die bisherige Route bleibt aktiv.",
                    priority: .status
                )
            }
        }
        activeAutomaticRerouteTask?.cancel()
        activeAutomaticRerouteTask = Task {
            guard NavigationAsyncWorkPolicy.isCurrent(
                navigationActive: isNavigating,
                session: sessionGeneration, currentSession: navigationSessionGeneration,
                work: workGeneration, currentWork: rerouteGeneration
            ) else { return }
            defer {
                if workGeneration == rerouteGeneration {
                    isRecalculating = false
                    activeAutomaticRerouteTask = nil
                }
            }
            if settings.voiceGuidance { speak("Die Route wird neu berechnet.", priority: .status) }
            // Keep the current route, station data and guidance visible while
            // MapKit searches in the background. The Boolean result is the
            // source of truth: a superseded/empty request may intentionally
            // leave `errorMessage` nil and must not be reported as success.
            let succeeded = await calculate(
                from: location.coordinate, settings: settings, showLoading: false,
                navigationSession: sessionGeneration, navigationWork: workGeneration
            )
            guard NavigationAsyncWorkPolicy.isCurrent(
                navigationActive: isNavigating,
                session: sessionGeneration, currentSession: navigationSessionGeneration,
                work: workGeneration, currentWork: rerouteGeneration
            ) else { return }
            if succeeded {
                consecutiveRerouteFailures = 0
                isManeuverGuidanceReliable = true
                onRouteRecoveryFixCount = 0
                DriveDiagnosticStore.append(.rerouteSucceeded, detail: "\(legs.count) Etappen")
                presentRecalculatedRoute(
                    at: NavigationReroutePresentationPolicy.location(
                        trigger: location, latest: lastAcceptedNavigationLocation
                    ),
                    voiceGuidance: settings.voiceGuidance
                )
            } else {
                consecutiveRerouteFailures += 1
                DriveDiagnosticStore.append(.rerouteFailed,
                                            detail: errorMessage ?? "Keine nutzbare neue Route")
                if settings.voiceGuidance {
                    _ = speak(
                        "Die Route konnte gerade nicht neu berechnet werden. Die bisherige Route bleibt aktiv.",
                        priority: .status
                    )
                }
            }
        }
    }

    /// A successful reroute must publish its first usable instruction
    /// immediately on every surface. With voice enabled it must also never end
    /// acoustically with only the earlier "wird neu berechnet" status; when
    /// the next maneuver is still far away, confirm completion without
    /// manufacturing an early turn cue.
    private func presentRecalculatedRoute(at location: CLLocation,
                                          voiceGuidance: Bool) {
        guard let progress = liveNavigationProgress(at: location) else {
            if voiceGuidance {
                _ = speak("Die neue Route ist bereit.", priority: .status)
            }
            return
        }
        // Phone, CarPlay and MCP must all see the corrected maneuver
        // immediately. Voice guidance is only an audio preference and must
        // never delay the visible route state until another GPS callback.
        updateNextManeuver(using: progress)
        guard voiceGuidance else { return }
        let speed = NavigationGuidanceSpeedPolicy.effective(
            current: NavigationMotionPolicy.reliableSpeed(for: location),
            previous: lastReliableGuidanceSpeedMps,
            previousAt: lastReliableGuidanceSpeedAt,
            now: location.timestamp
        )
        guard NavigationAnnouncementStage.stage(
            distance: progress.distance, speedKmh: speed * 3.6
        ) != nil else {
            _ = speak("Die neue Route ist bereit.", priority: .status)
            return
        }
        announce(progress, guidanceSpeedMps: speed)
    }

    private func resetDeviationTracking(keepingDistance distance: CLLocationDistance? = nil) {
        offRouteSince = nil
        offRouteFixCount = 0
        previousOffRouteDistance = distance
    }

    private func beginNavigationSession() {
        activeAutomaticRerouteTask?.cancel()
        activeAutomaticRerouteTask = nil
        navigationSessionGeneration = UUID()
        rerouteGeneration = UUID()
        isRecalculating = false
        lastRerouteAt = nil
        isManeuverGuidanceReliable = true
        let tripID = activeRouteLock?.id ?? routeLockStore.activeLock?.id
        if let tripID { DriveDiagnosticStore.activateSession(tripID) }
        if usageSessionState.tripID != tripID {
            usageSessionState = DriveUsageSessionState(tripID: tripID)
            usageSessionStore.save(usageSessionState)
        }
        usageSessionLastLocation = nil
        lastUsageSessionPersistedAt = nil
        lastDrivingStatePersistedAt = nil
    }

    private func updateUsageSession(at location: CLLocation) {
        if let segment = DriveUsageSegmentPolicy.segment(
            previous: usageSessionLastLocation, current: location
        ) {
            usageSessionState.distanceMetres += segment.distanceMetres
            usageSessionState.movingTime += segment.movingTime
            if NavigationPersistenceCheckpointPolicy.shouldPersist(
                last: lastUsageSessionPersistedAt, now: location.timestamp
            ) {
                usageSessionStore.save(usageSessionState)
                lastUsageSessionPersistedAt = location.timestamp
            }
        }
        usageSessionLastLocation = location
    }

    private func finishUsageSession() {
        usageStatistics.recordTrip(
            distanceMetres: usageSessionState.distanceMetres,
            movingTime: usageSessionState.movingTime
        )
        DriveUsageStatisticsStore.save(usageStatistics)
        usageSessionState = .init()
        usageSessionStore.clear()
        usageSessionLastLocation = nil
        lastUsageSessionPersistedAt = nil
    }

    private func finishReplacedUsageTripIfNeeded(previousTripID: UUID?, nextTripID: UUID?) {
        guard DriveUsageTripTransitionPolicy.shouldFinalize(
            sessionTripID: usageSessionState.tripID,
            previousTripID: previousTripID,
            nextTripID: nextTripID
        ) else { return }
        if isNavigating { stopNavigation() }
        finishUsageSession()
    }

    func clearUsageStatistics() {
        usageStatistics = .init()
        DriveUsageStatisticsStore.clear()
        usageSessionState = DriveUsageSessionState(
            tripID: activeRouteLock?.id ?? routeLockStore.activeLock?.id
        )
        usageSessionLastLocation = nil
        if usageSessionState.tripID == nil { usageSessionStore.clear() }
        else { usageSessionStore.save(usageSessionState) }
    }

    /// Flushes the latest aggregate driving state before iOS suspends the app
    /// or CarPlay disconnects. No coordinate is encoded; only distance, moving
    /// time, fatigue/fuel state and the already-sanitised route cache persist.
    func checkpointNavigationState() {
        guard isNavigating || usageSessionState.tripID != nil else { return }
        usageSessionStore.save(usageSessionState)
        drivingRestStore.save(drivingRestState)
        drivingFuelStore.save(drivingFuelState)
        if isNavigating {
            persistActiveTrip()
            cacheForOffline(preservingProgress: true)
        }
        let now = Date()
        lastUsageSessionPersistedAt = now
        lastDrivingStatePersistedAt = now
    }

    private func invalidateNavigationAsyncWork() {
        activeAutomaticRerouteTask?.cancel()
        activeAutomaticRerouteTask = nil
        navigationSessionGeneration = UUID()
        rerouteGeneration = UUID()
        isRecalculating = false
    }

    /// Kleinster Abstand zu jedem echten Liniensegment. Die frühere Stichprobe
    /// erzeugte auf langen Routen kilometerweite Lücken und damit Dauer-Rerouting.
    private static func distance(from coordinate: CLLocationCoordinate2D, to polyline: MKPolyline) -> CLLocationDistance {
        guard polyline.pointCount > 0 else { return .greatestFiniteMagnitude }
        let target = MKMapPoint(coordinate)
        let points = polyline.points()
        if polyline.pointCount == 1 { return target.distance(to: points[0]) }
        var best = CLLocationDistance.greatestFiniteMagnitude
        for index in 0..<(polyline.pointCount - 1) {
            let a = points[index], b = points[index + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : max(0, min(1, ((target.x - a.x) * dx + (target.y - a.y) * dy) / lengthSquared))
            let projected = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            best = min(best, target.distance(to: projected))
        }
        return best
    }

    /// Remaining driven distance from the projection of `coordinate` to the
    /// end of a step polyline. Unlike air-line distance this remains correct
    /// on ramps, switchbacks and parallel roads.
    private static func remainingDistance(from coordinate: CLLocationCoordinate2D,
                                          on polyline: MKPolyline) -> CLLocationDistance {
        guard polyline.pointCount > 0 else { return .greatestFiniteMagnitude }
        let target = MKMapPoint(coordinate)
        let points = polyline.points()
        if polyline.pointCount == 1 { return target.distance(to: points[0]) }

        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        var bestSegment = 0
        var bestProjection = points[0]
        for index in 0..<(polyline.pointCount - 1) {
            let a = points[index], b = points[index + 1]
            let dx = b.x - a.x, dy = b.y - a.y
            let lengthSquared = dx * dx + dy * dy
            let t = lengthSquared == 0 ? 0 : max(0, min(1,
                ((target.x - a.x) * dx + (target.y - a.y) * dy) / lengthSquared))
            let projection = MKMapPoint(x: a.x + t * dx, y: a.y + t * dy)
            let distance = target.distance(to: projection)
            if distance < bestDistance {
                bestDistance = distance
                bestSegment = index
                bestProjection = projection
            }
        }
        var remaining = bestProjection.distance(to: points[bestSegment + 1])
        if bestSegment + 1 < polyline.pointCount - 1 {
            for index in (bestSegment + 1)..<(polyline.pointCount - 1) {
                remaining += points[index].distance(to: points[index + 1])
            }
        }
        return remaining
    }

    /// Computes distance, remaining path and local direction in one pass.
    /// Guidance evaluates every route step for every accepted GPS fix, so
    /// walking each polyline three times would be directly visible as UI lag
    /// on long routes.
    private static func navigationMetric(from coordinate: CLLocationCoordinate2D,
                                         on polyline: MKPolyline,
                                         stepDistance: CLLocationDistance,
                                         vehicleCourse: Double?,
                                         hasManeuverInstruction: Bool = false) -> NavigationStepMetric {
        guard polyline.pointCount > 1 else {
            let distance = polyline.pointCount == 1
                ? MKMapPoint(coordinate).distance(to: polyline.points()[0])
                : CLLocationDistance.greatestFiniteMagnitude
            return .init(distanceFromRoute: distance, remainingOnStep: distance,
                         stepDistance: stepDistance,
                         hasUsableGeometry: polyline.pointCount == 1,
                         hasManeuverInstruction: hasManeuverInstruction)
        }
        let target = MKMapPoint(coordinate)
        let points = polyline.points()
        var bestIndex = 0
        var bestProjection = points[0]
        var bestDistance = CLLocationDistance.greatestFiniteMagnitude
        for index in 0..<(polyline.pointCount - 1) {
            let start = points[index], end = points[index + 1]
            let dx = end.x - start.x, dy = end.y - start.y
            let lengthSquared = dx * dx + dy * dy
            let fraction = lengthSquared == 0 ? 0 : max(0, min(1,
                ((target.x - start.x) * dx + (target.y - start.y) * dy) / lengthSquared))
            let projected = MKMapPoint(x: start.x + fraction * dx,
                                       y: start.y + fraction * dy)
            let distance = target.distance(to: projected)
            if distance < bestDistance {
                bestDistance = distance
                bestIndex = index
                bestProjection = projected
            }
        }
        var remaining = bestProjection.distance(to: points[bestIndex + 1])
        if bestIndex + 1 < polyline.pointCount - 1 {
            for index in (bestIndex + 1)..<(polyline.pointCount - 1) {
                remaining += points[index].distance(to: points[index + 1])
            }
        }
        let difference = vehicleCourse.flatMap { course in
            NavigationCourseMatchingPolicy.bearing(
                from: points[bestIndex].coordinate,
                to: points[bestIndex + 1].coordinate
            ).flatMap {
                NavigationCourseMatchingPolicy.angularDifference(
                    courseDegrees: course, routeCourseDegrees: $0
                )
            }
        }
        return .init(
            distanceFromRoute: bestDistance, remainingOnStep: remaining,
            stepDistance: stepDistance, courseDifferenceDegrees: difference,
            hasManeuverInstruction: hasManeuverInstruction
        )
    }

    /// Lädt Tempolimits für abgetastete Routenpunkte (OpenStreetMap/Overpass).
    /// Fehler hier werden bewusst nicht als `errorMessage` angezeigt, damit ein
    /// überlasteter Overpass-Dienst nicht die restliche Routenplanung blockiert.
    func loadSpeedLimits() async {
        guard !legs.isEmpty else {
            speedLimitPoints = []
            speedLimits = []
            comparisonSpeedLimitPoints = []
            comparisonSpeedLimits = []
            return
        }
        let routeGeneration = routeCalculationGeneration
        let generation = UUID()
        speedLimitLoadGeneration = generation
        let points = legs.flatMap { sample($0.polyline, maximum: 80) }
        let comparisonPoints = comparisonRoute.map {
            sample($0.polyline, maximum: 80)
        } ?? []
        var limits: [SpeedLimitResult] = []
        var loadedComparisonLimits: [SpeedLimitResult] = []
        var loadWasSuperseded = false
        await withTaskGroup(of: SpeedLimitLoadOutcome.self) { group in
            group.addTask { [weak self] in
                .main(await self?.fetchSpeedLimits(along: points) ?? [])
            }
            if !comparisonPoints.isEmpty {
                group.addTask { [weak self] in
                    .comparison(await self?.fetchSpeedLimits(along: comparisonPoints) ?? [])
                }
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { break }
                    guard let self else { return .superseded }
                    if !(await self.isCurrentSpeedLimitLoad(
                        routeGeneration: routeGeneration,
                        loadGeneration: generation
                    )) { return .superseded }
                }
                return .superseded
            }
            var remainingRequests = comparisonPoints.isEmpty ? 1 : 2
            while remainingRequests > 0, let outcome = await group.next() {
                switch outcome {
                case .main(let loaded):
                    limits = loaded
                    remainingRequests -= 1
                case .comparison(let loaded):
                    loadedComparisonLimits = loaded
                    remainingRequests -= 1
                case .superseded:
                    loadWasSuperseded = true
                    group.cancelAll()
                    return
                }
            }
            group.cancelAll()
        }
        guard !loadWasSuperseded else { return }
        guard RouteEnrichmentPublicationPolicy.isCurrent(
            route: routeGeneration, currentRoute: routeCalculationGeneration,
            request: generation, currentRequest: speedLimitLoadGeneration
        ) else { return }
        speedLimitPoints = points
        speedLimits = limits
        if !comparisonPoints.isEmpty {
            comparisonSpeedLimitPoints = comparisonPoints
            comparisonSpeedLimits = loadedComparisonLimits
        }
    }

    private func isCurrentSpeedLimitLoad(routeGeneration: UUID,
                                         loadGeneration: UUID) -> Bool {
        RouteEnrichmentPublicationPolicy.isCurrent(
            route: routeGeneration, currentRoute: routeCalculationGeneration,
            request: loadGeneration, currentRequest: speedLimitLoadGeneration
        )
    }

    private func fetchSpeedLimits(along points: [CLLocationCoordinate2D]) async
        -> [SpeedLimitResult] {
        guard !points.isEmpty else { return [] }
        return (try? await DriveAPI.speedLimits(along: points)) ?? []
    }

    private func loadComparisonSpeedLimits() async {
        guard let comparisonRoute else {
            comparisonSpeedLimitPoints = []
            comparisonSpeedLimits = []
            return
        }
        let routeGeneration = routeCalculationGeneration
        let generation = UUID()
        comparisonSpeedLimitLoadGeneration = generation
        let points = sample(comparisonRoute.polyline, maximum: 80)
        var limits: [SpeedLimitResult] = []
        var loadWasSuperseded = false
        await withTaskGroup(of: SpeedLimitLoadOutcome.self) { group in
            group.addTask { [weak self] in
                .comparison(await self?.fetchSpeedLimits(along: points) ?? [])
            }
            group.addTask { [weak self] in
                while !Task.isCancelled {
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    guard !Task.isCancelled else { break }
                    guard let self else { return .superseded }
                    if !(await self.isCurrentComparisonSpeedLimitLoad(
                        routeGeneration: routeGeneration,
                        loadGeneration: generation
                    )) { return .superseded }
                }
                return .superseded
            }
            while let outcome = await group.next() {
                switch outcome {
                case .comparison(let loaded):
                    limits = loaded
                    group.cancelAll()
                    return
                case .superseded:
                    loadWasSuperseded = true
                    group.cancelAll()
                    return
                case .main:
                    continue
                }
            }
        }
        guard !loadWasSuperseded else { return }
        guard RouteEnrichmentPublicationPolicy.isCurrent(
            route: routeGeneration, currentRoute: routeCalculationGeneration,
            request: generation, currentRequest: comparisonSpeedLimitLoadGeneration
        ) else { return }
        comparisonSpeedLimitPoints = points
        comparisonSpeedLimits = limits
    }

    private func isCurrentComparisonSpeedLimitLoad(routeGeneration: UUID,
                                                   loadGeneration: UUID) -> Bool {
        RouteEnrichmentPublicationPolicy.isCurrent(
            route: routeGeneration, currentRoute: routeCalculationGeneration,
            request: loadGeneration, currentRequest: comparisonSpeedLimitLoadGeneration
        )
    }

    /// Aktuelles Tempolimit für den nächstgelegenen abgetasteten Routenpunkt
    /// zur übergebenen Position (z.B. der aktuelle Standort während der Fahrt).
    func currentSpeedLimit(near coordinate: CLLocationCoordinate2D) -> SpeedLimitResult? {
        let expectedProgress = RouteSearchPolicy.installedRouteProgress(
            totalDistance: totalDistance,
            remainingDistance: remainingDistanceMetres,
            navigationActive: isNavigating
        )
        guard let index = SpeedLimitSelectionPolicy.index(
            near: coordinate,
            points: speedLimitPoints,
            availableLimitCount: speedLimits.count,
            expectedProgress: expectedProgress
        ) else { return nil }
        let result = speedLimits[index]
        guard SpeedLimitPresentationPolicy.presentation(for: result) != .unavailable else {
            return nil
        }
        return result
    }

    private func computeRoutes(from source: MKMapItem, to destination: MKMapItem, settings: DriveSettings,
                               alternates: Bool, avoidTollsOverride: Bool? = nil,
                               lockedOptions: LockedRouteOptions? = nil) async throws -> [MKRoute] {
        let request = MKDirections.Request()
        request.source = source
        request.destination = destination
        request.transportType = .automobile
        request.requestsAlternateRoutes = alternates
        request.tollPreference = (avoidTollsOverride ?? lockedOptions?.avoidTolls ?? settings.avoidTolls) ? .avoid : .any
        request.highwayPreference = (lockedOptions?.avoidHighways ?? settings.avoidHighways) ? .avoid : .any
        let routes = try await Self.calculateDirections(
            request, timeout: NavigationDirectionsTimeoutPolicy.routeCalculation
        )
        guard let lock = routeLockStore.activeLock,
              let corridor = lock.corridorPoints, !corridor.isEmpty else { return routes }
        return routes.filter { routeInsideLockedCorridor($0, points: corridor,
                                                         width: lock.corridorWidthMetres) }
    }

    private func buildLongTripPlan(settings: DriveSettings) {
        guard !legs.isEmpty else { longTripPlan = nil; return }
        let isRemainingRoutePlan = isNavigating && remainingDistanceMetres > 0 && totalDistance > 0
        let mainDistance = isRemainingRoutePlan ? remainingDistanceMetres : totalDistance
        let mainTime = isRemainingRoutePlan ? remainingTravelTime : totalTravelTime
        let distanceProgress = isRemainingRoutePlan
            ? min(1, max(0, 1 - mainDistance / totalDistance)) : 0
        let timeProgress = isRemainingRoutePlan
            ? min(1, max(0, 1 - mainTime / max(totalTravelTime, 1))) : 0
        let unlimitedFraction = SpeedScenarioPolicy.unlimitedDistanceFraction(
            points: speedLimitPoints, limits: speedLimits,
            fromProgress: distanceProgress
        )
        let allCandidates = breakCandidates(along: legs, useMeasuredDetours: true)
        let candidates = isRemainingRoutePlan
            ? RemainingRoutePlanningPolicy.rebasedCandidates(
                allCandidates, distanceProgress: distanceProgress, timeProgress: timeProgress
            ) : allCandidates
        var inputs = [RoutePlanningInput(
            id: settings.avoidTolls ? "toll-avoiding" : "standard",
            title: settings.avoidTolls ? "Maut vermeiden" : "Schnellste Route",
            distanceMetres: mainDistance,
            mapKitExpectedTravelTime: mainTime,
            unlimitedMotorwayFraction: unlimitedFraction,
            typicalUnlimitedSpeedKmh: 130,
            toll: settings.avoidTolls ? researchedAvoidingToll : researchedStandardToll,
            breakCandidates: candidates,
            installedRouteStartProgress: distanceProgress
        )]
        if !isRemainingRoutePlan, let comparisonRoute,
           abs(comparisonRoute.distance - mainDistance) > 100 || abs(comparisonRoute.expectedTravelTime - mainTime) > 60 {
            let comparisonUnlimitedFraction = SpeedScenarioPolicy.unlimitedDistanceFraction(
                points: comparisonSpeedLimitPoints,
                limits: comparisonSpeedLimits
            )
            inputs.append(.init(
                id: settings.avoidTolls ? "standard" : "toll-avoiding",
                title: settings.avoidTolls ? "Schnellste Route" : "Maut vermeiden",
                distanceMetres: comparisonRoute.distance,
                mapKitExpectedTravelTime: comparisonRoute.expectedTravelTime,
                unlimitedMotorwayFraction: comparisonUnlimitedFraction,
                typicalUnlimitedSpeedKmh: 130,
                toll: settings.avoidTolls ? researchedStandardToll : researchedAvoidingToll,
                breakCandidates: breakCandidates(along: [comparisonRoute])
            ))
        }
        let currentFuelFraction: Double
        if isRemainingRoutePlan, let tripID = activeRouteLock?.id ?? routeLockStore.activeLock?.id {
            currentFuelFraction = DrivingFuelPolicy.estimatedFraction(
                drivingFuelState, tripID: tripID,
                tankCapacityLitres: settings.tankCapacityL,
                consumptionLPer100km: settings.consumptionLPer100km,
                fallback: settings.departureFuelPercent / 100
            )
        } else {
            currentFuelFraction = min(1, max(0, settings.departureFuelPercent / 100))
        }
        let profile = VehicleProfile(
            baseConsumptionLPer100km: settings.consumptionLPer100km,
            fuelPricePerLitre: settings.fuelPricePerLitre,
            tankCapacityLitres: settings.tankCapacityL,
            initialFuelFraction: currentFuelFraction
        ).sanitized
        let scenarios = SpeedScenarioPolicy.scenarios(
            configuredSpeed: settings.targetSpeedKmh
        )
        longTripPlan = RouteComparison(fuelModel: .init(), breakPlanner: .init())
            .compare(routes: inputs, scenarios: scenarios, vehicle: profile,
                     alreadyDrivenSinceBreak: drivingRestState.continuousDriving)
    }

    private func loadTollCost(from start: CLLocationCoordinate2D,
                              settings: DriveSettings) async {
        guard let destination else { return }
        let routeGeneration = routeCalculationGeneration
        let lock = routeLockStore.activeLock
        let destinationName = TollDestinationLabelPolicy.label(
            lockedDestinationName: lock?.destinationName,
            mapItemName: destination.name,
            enteredText: destinationText,
            placemarkTitle: destination.placemark.title
        )
        let visited = Set(lock?.visitedWaypointIDs ?? [])
        let openTollWaypoints = lock?.waypoints.filter {
            $0.required && !visited.contains($0.id) && $0.isTollEvidenceAnchor
        } ?? []
        let via = openTollWaypoints.map(\.name)
        let destinationCoordinate = destination.placemark.coordinate
        let generation = UUID()
        tollLoadGeneration = generation
        // Search evidence normally names towns, not raw coordinates. Resolve
        // only the coarse locality/region/country so the provider can verify
        // both endpoints without sending the user's street address.
        let origin = await tollOriginLabel(for: start)
            ?? String(format: "%.4f, %.4f", start.latitude, start.longitude)
        // Reverse geocoding may take a couple of seconds. A reroute or newly
        // selected destination during that wait owns a different toll lookup;
        // do not send obsolete SearXNG requests that compete with it.
        guard TollLookupBatchPolicy.mayStartRequests(
            route: routeGeneration, currentRoute: routeCalculationGeneration,
            request: generation, currentRequest: tollLoadGeneration
        ) else { return }
        var results: [TollLookupBatchItem] = []
        var requests: [(avoidTolls: Bool, routeIdentity: String)] = []
        let requestedVariants = TollLookupBatchPolicy.requestedVariants(
            mainRouteAvoidsTolls: settings.avoidTolls,
            comparisonAvailable: comparisonRoute != nil
        )
        for avoidTolls in [false, true] where requestedVariants.contains(avoidTolls) {
            let usesComparison = TollVariantRoutePolicy.usesComparisonRoute(
                requestAvoidsTolls: avoidTolls,
                mainRouteAvoidsTolls: settings.avoidTolls,
                comparisonAvailable: comparisonRoute != nil
            )
            let variantRoutes = usesComparison ? comparisonRoute.map { [$0] } ?? [] : legs
            let variantDistance = variantRoutes.reduce(0) { $0 + $1.distance }
            let variantAnchors = variantRoutes.flatMap { sample($0.polyline, maximum: 12) }
            let routeIdentity = TollRouteIdentityPolicy.identity(
                destination: destinationCoordinate,
                via: openTollWaypoints.map(\.coordinate),
                distanceMetres: variantDistance,
                routeAnchors: variantAnchors
            ) + (avoidTolls ? "|avoid" : "|standard")
            if let cached = TollLookupCachePolicy.reusable(
                tollLookupSnapshots[avoidTolls], routeIdentity: routeIdentity, origin: start
            ) {
                results.append(.init(avoidTolls: avoidTolls, routeIdentity: routeIdentity,
                                     cost: cached, fetched: false))
            } else {
                requests.append((avoidTolls, routeIdentity))
            }
        }
        var lookupWasSuperseded = false
        await withTaskGroup(of: TollLookupBatchOutcome.self) { group in
            for request in requests {
                group.addTask {
                    do {
                        let cost = try await DriveAPI.tollCost(
                            origin: origin, destination: destinationName, via: via,
                            avoidTolls: request.avoidTolls
                        )
                        return .item(.init(
                            avoidTolls: request.avoidTolls,
                            routeIdentity: request.routeIdentity,
                            cost: cost, fetched: true
                        ))
                    } catch {
                        return .item(.init(
                            avoidTolls: request.avoidTolls,
                            routeIdentity: request.routeIdentity,
                            cost: .unknown(reason: "SearXNG-Mautrecherche nicht verfügbar: \(error.localizedDescription)"),
                            fetched: true
                        ))
                    }
                }
            }
            if !requests.isEmpty {
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        guard !Task.isCancelled else { break }
                        guard let self else { return .superseded }
                        if !(await self.isCurrentTollLookup(
                            routeGeneration: routeGeneration,
                            lookupGeneration: generation
                        )) { return .superseded }
                    }
                    return .superseded
                }
            }
            var remainingRequests = requests.count
            while remainingRequests > 0, let outcome = await group.next() {
                switch outcome {
                case .item(let result):
                    remainingRequests -= 1
                    results.append(result)
                case .superseded:
                    lookupWasSuperseded = true
                    group.cancelAll()
                    return
                }
            }
            group.cancelAll()
        }
        if lookupWasSuperseded { return }
        guard TollLookupBatchPolicy.complete(results, expected: requestedVariants),
              RouteEnrichmentPublicationPolicy.isCurrent(
                route: routeGeneration, currentRoute: routeCalculationGeneration,
                request: generation, currentRequest: tollLoadGeneration
              ) else { return }
        let loadedAt = Date()
        for result in results {
            setResearchedToll(result.cost, avoidTolls: result.avoidTolls)
            if result.fetched {
                tollLookupSnapshots[result.avoidTolls] = .init(
                    routeIdentity: result.routeIdentity, origin: start,
                    cost: result.cost, loadedAt: loadedAt
                )
            }
        }
    }

    private func isCurrentTollLookup(routeGeneration: UUID,
                                     lookupGeneration: UUID) -> Bool {
        TollLookupBatchPolicy.mayStartRequests(
            route: routeGeneration, currentRoute: routeCalculationGeneration,
            request: lookupGeneration, currentRequest: tollLoadGeneration
        )
    }

    private func tollOriginLabel(for coordinate: CLLocationCoordinate2D) async -> String? {
        let geocoder = CLGeocoder()
        let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        let placemark = await withTaskGroup(of: CLPlacemark?.self) { group in
            group.addTask {
                try? await geocoder.reverseGeocodeLocation(
                    location, preferredLocale: Locale(identifier: "de_DE")
                ).first
            }
            group.addTask {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            geocoder.cancelGeocode()
            return first
        }
        guard let placemark else { return nil }
        let components = [placemark.locality, placemark.administrativeArea, placemark.isoCountryCode]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let unique = components.reduce(into: [String]()) { result, component in
            if !result.contains(where: { $0.caseInsensitiveCompare(component) == .orderedSame }) {
                result.append(component)
            }
        }
        return unique.isEmpty ? nil : unique.joined(separator: ", ")
    }

    private func setResearchedToll(_ toll: TollCost, avoidTolls: Bool) {
        if avoidTolls { researchedAvoidingToll = toll }
        else { researchedStandardToll = toll }
    }

    /// Recomputes scenario numbers from the already loaded route when vehicle
    /// or target-speed settings change; no network request is required.
    func refreshLongTripPlan(settings: DriveSettings) {
        buildLongTripPlan(settings: settings)
    }

    /// Reloads the complete stop-planning chain after a fuel or route change.
    /// Publishing only the station pins would leave breaks, detours and fuel
    /// costs based on the previous selection.
    func reloadStopPlanning(fuel: FuelKind, settings: DriveSettings,
                            reloadAmenities: Bool = false) async {
        let routeGeneration = routeCalculationGeneration
        let planningGeneration = UUID()
        stopPlanningGeneration = planningGeneration
        await loadStations(fuel: fuel)
        guard routeGeneration == routeCalculationGeneration,
              planningGeneration == stopPlanningGeneration else { return }
        if reloadAmenities || amenityBreakCandidates.isEmpty {
            await loadBreakAmenities()
            guard routeGeneration == routeCalculationGeneration,
                  planningGeneration == stopPlanningGeneration else { return }
        }
        measuredBreakDetours = [:]
        await measureBreakCandidateDetours()
        guard routeGeneration == routeCalculationGeneration,
              planningGeneration == stopPlanningGeneration else { return }
        buildLongTripPlan(settings: settings)
        cacheForOffline(preservingProgress: true)
    }

    private func breakCandidates(along routes: [MKRoute], useMeasuredDetours: Bool = true) -> [BreakCandidate] {
        let routeCoordinates = routes.flatMap { sample($0.polyline, maximum: 160) }
        guard routeCoordinates.count > 1 else { return [] }
        let timeline = routes.map { (distance: $0.distance, travelTime: $0.expectedTravelTime) }
        let projectionRange: ClosedRange<Double>? = {
            guard isNavigating, totalDistance > 0, remainingDistanceMetres >= 0 else { return nil }
            return RemainingRoutePlanningPolicy.projectionRange(
                distanceProgress: 1 - remainingDistanceMetres / totalDistance,
                totalDistance: totalDistance
            )
        }()
        let startingDistanceProgress = isNavigating && totalDistance > 0 && remainingDistanceMetres >= 0
            ? min(1, max(0, 1 - remainingDistanceMetres / totalDistance)) : 0
        let startingTimeProgress = isNavigating && totalTravelTime > 0 && remainingTravelTime >= 0
            ? min(1, max(0, 1 - remainingTravelTime / totalTravelTime)) : 0
        let fuelCandidates: [BreakCandidate] = stations.compactMap { station -> BreakCandidate? in
            guard let projection = RouteGeometryProgress.nearestProgress(
                of: station.coordinate, on: routeCoordinates, progressRange: projectionRange
            ),
                  projection.distance <= 4_000 else { return nil }
            return BreakCandidateFactory.fuelStation(
                station, progress: projection.progress,
                timeProgress: RouteTravelTimeProgress.value(
                    distanceProgress: projection.progress, segments: timeline
                ),
                detourMetres: useMeasuredDetours ? measuredBreakDetours[station.id] ?? projection.distance * 2 : projection.distance * 2,
                detourIsEstimated: !useMeasuredDetours || measuredBreakDetours[station.id] == nil
            )
        }
        let amenities = amenityBreakCandidates.compactMap { candidate -> BreakCandidate? in
            guard let projection = RouteGeometryProgress.nearestProgress(
                of: candidate.coordinate, on: routeCoordinates, progressRange: projectionRange
            ),
                  projection.distance <= 4_000 else { return nil }
            return .init(id: candidate.id, name: candidate.name, coordinate: candidate.coordinate,
                         progress: projection.progress,
                         timeProgress: RouteTravelTimeProgress.value(
                            distanceProgress: projection.progress, segments: timeline
                         ),
                         detourMetres: useMeasuredDetours ? measuredBreakDetours[candidate.id] ?? projection.distance * 2 : projection.distance * 2,
                         detourIsEstimated: !useMeasuredDetours || measuredBreakDetours[candidate.id] == nil,
                         isOpen: candidate.isOpen, supportsFuel: candidate.supportsFuel)
        }
        return BreakCandidateSelectionPolicy.shortlist(
            fuelCandidates + amenities,
            startingDistanceProgress: startingDistanceProgress,
            startingTimeProgress: startingTimeProgress
        )
    }

    /// Measures only the already shortlisted stops. Six candidates mean at
    /// most twelve directions requests (route entry to stop, then stop to a
    /// forward route exit), independent of the provider result count.
    private func measureBreakCandidateDetours() async {
        let routeGeneration = routeCalculationGeneration
        let generation = UUID()
        breakDetourLoadGeneration = generation
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 160) }
        let candidates = breakCandidates(along: legs, useMeasuredDetours: false)
        let projectionRange: ClosedRange<Double>? = {
            guard isNavigating, totalDistance > 0, remainingDistanceMetres >= 0 else { return nil }
            return RemainingRoutePlanningPolicy.projectionRange(
                distanceProgress: 1 - remainingDistanceMetres / totalDistance,
                totalDistance: totalDistance
            )
        }()
        var measurements: [String: CLLocationDistance] = [:]
        var measurementCount = 0
        var loadWasSuperseded = false
        await withTaskGroup(of: BreakDetourLoadOutcome.self) { group in
            for candidate in candidates {
                guard let projection = RouteGeometryProgress.nearestProgress(
                    of: candidate.coordinate, on: routeCoordinates,
                    progressRange: projectionRange
                ), let anchors = RouteSearchPolicy.detourAnchors(
                    routeCoordinates: routeCoordinates, progress: projection.progress
                ) else { continue }
                group.addTask { [weak self] in
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: candidate.coordinate))
                    let distance = await self?.drivingDetour(through: item, anchors: anchors)
                    return .measurement(candidate.id, distance)
                }
                measurementCount += 1
            }
            if measurementCount > 0 {
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        guard !Task.isCancelled else { break }
                        guard let self else { return .superseded }
                        if !(await self.isCurrentBreakDetourLoad(
                            routeGeneration: routeGeneration,
                            loadGeneration: generation
                        )) { return .superseded }
                    }
                    return .superseded
                }
            }
            var remainingMeasurements = measurementCount
            while remainingMeasurements > 0, let outcome = await group.next() {
                switch outcome {
                case .measurement(let id, let distance):
                    remainingMeasurements -= 1
                    if let distance, distance <= 20_000 { measurements[id] = distance }
                case .superseded:
                    loadWasSuperseded = true
                    group.cancelAll()
                    return
                }
            }
            group.cancelAll()
        }
        guard !loadWasSuperseded else { return }
        guard RouteEnrichmentPublicationPolicy.isCurrent(
            route: routeGeneration, currentRoute: routeCalculationGeneration,
            request: generation, currentRequest: breakDetourLoadGeneration
        ) else { return }
        measuredBreakDetours = measurements
    }

    private func isCurrentBreakDetourLoad(routeGeneration: UUID,
                                          loadGeneration: UUID) -> Bool {
        RouteEnrichmentPublicationPolicy.isCurrent(
            route: routeGeneration, currentRoute: routeCalculationGeneration,
            request: loadGeneration, currentRequest: breakDetourLoadGeneration
        )
    }

    /// Finds real rest areas and motorway service locations near the route so
    /// break planning is not limited to petrol stations.
    private func loadBreakAmenities() async {
        guard !legs.isEmpty else { amenityBreakCandidates = []; return }
        let routeGeneration = routeCalculationGeneration
        let generation = UUID()
        breakCandidateLoadGeneration = generation
        activeAmenitySearches.forEach { $0.cancel() }
        activeAmenitySearches = []
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 180) }
        let queryCount = 2
        let pointLimit = max(
            1,
            NavigationSearchBatchPolicy.maximumConcurrentAmenitySearches / queryCount
        )
        let timeline = legs.map { (distance: $0.distance, travelTime: $0.expectedTravelTime) }
        let startingTimeProgress = isNavigating && remainingTravelTime > 0 && totalTravelTime > 0
            ? min(1, max(0, 1 - remainingTravelTime / totalTravelTime)) : 0
        let searchProgresses = BreakAmenitySearchPolicy.distanceProgresses(
            drivingTime: totalTravelTime,
            alreadyDrivenSinceBreak: drivingRestState.continuousDriving,
            segments: timeline,
            maximum: pointLimit,
            startingTimeProgress: startingTimeProgress
        )
        let searchPoints = searchProgresses.compactMap {
            RouteGeometryProgress.coordinate(at: $0, on: routeCoordinates)
        }
        guard !searchPoints.isEmpty else {
            activeAmenitySearches = []
            amenityBreakCandidates = []
            return
        }
        var matches: [String: MKMapItem] = [:]
        let searches = searchPoints.flatMap { point in
            ["Raststätte Autohof", "Rastplatz"].map { query -> MKLocalSearch in
                let request = MKLocalSearch.Request()
                request.naturalLanguageQuery = query
                request.region = .init(center: point, latitudinalMeters: 90_000,
                                       longitudinalMeters: 90_000)
                return MKLocalSearch(request: request)
            }
        }
        activeAmenitySearches = searches
        for item in await boundedMapSearchResults(searches) {
            let coordinate = item.placemark.coordinate
            matches["\(item.name ?? "Halt"):\(coordinate.latitude):\(coordinate.longitude)"] = item
        }
        guard RouteEnrichmentPublicationPolicy.isCurrent(
            route: routeGeneration, currentRoute: routeCalculationGeneration,
            request: generation, currentRequest: breakCandidateLoadGeneration
        ) else { return }
        activeAmenitySearches = []
        guard routeCoordinates.count > 1 else { amenityBreakCandidates = []; return }
        let candidates = matches.values.compactMap { item -> BreakCandidate? in
            guard let projection = RouteGeometryProgress.nearestProgress(
                of: item.placemark.coordinate, on: routeCoordinates
            ), projection.distance <= 4_000 else { return nil }
            let coordinate = item.placemark.coordinate
            return .init(id: "amenity-\(coordinate.latitude)-\(coordinate.longitude)",
                         name: item.name ?? "Rastmöglichkeit", coordinate: coordinate,
                         progress: projection.progress,
                         detourMetres: projection.distance * 2, isOpen: nil)
        }
        let buckets = Dictionary(grouping: candidates) { min(9, Int($0.progress * 10)) }
        amenityBreakCandidates = buckets.keys.sorted().compactMap { bucket in
            buckets[bucket]?.min { $0.detourMetres < $1.detourMetres }
        }
    }

    /// MapKit occasionally leaves one request suspended while the other
    /// searches in the same batch have already completed. Cancel the exact
    /// batch after a short deadline so route search, break planning and their
    /// loading indicators always return control to the driver.
    private func boundedMapSearchResults(_ searches: [MKLocalSearch]) async -> [MKMapItem] {
        guard !searches.isEmpty else { return [] }
        let timeout = Task {
            try? await Task.sleep(nanoseconds: NavigationSearchBatchPolicy.timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            searches.forEach { $0.cancel() }
        }
        defer { timeout.cancel() }
        return await withTaskGroup(of: [MKMapItem].self, returning: [MKMapItem].self) { group in
            for search in searches {
                group.addTask { (try? await search.start().mapItems) ?? [] }
            }
            var results: [MKMapItem] = []
            for await items in group { results.append(contentsOf: items) }
            return results
        }
    }

    func loadStations(fuel: FuelKind) async {
        guard !legs.isEmpty else { return }
        let routeGeneration = routeCalculationGeneration
        let generation = UUID()
        stationLoadGeneration = generation
        let allQueryCoordinates = legs.flatMap { sample($0.polyline, maximum: 80) }
        let expectedProgress = RouteSearchPolicy.installedRouteProgress(
            totalDistance: totalDistance,
            remainingDistance: remainingDistanceMetres,
            navigationActive: isNavigating
        )
        let currentProgress = RouteSearchPolicy.currentProgress(
            projected: expectedProgress,
            persisted: activeRouteLock?.lastRouteProgress ?? routeLockStore.activeLock?.lastRouteProgress,
            navigationActive: isNavigating
        )
        let remainingQueryCoordinates = RouteSearchPolicy.remainingRouteCoordinates(
            allQueryCoordinates, currentProgress: currentProgress
        )
        let remainingDistance = isNavigating && remainingDistanceMetres > 0
            ? remainingDistanceMetres : totalDistance
        // Short remaining routes use only two requests; continental journeys
        // scale gradually but remain capped. This prevents server and map-pin
        // floods without throwing away geographic coverage on holiday trips.
        let points = evenlySpaced(
            remainingQueryCoordinates,
            maximum: FuelStationQueryPolicy.sampleCount(remainingDistanceMetres: remainingDistance)
        )
        var unique: [String: FuelStation] = [:]
        var loadWasSuperseded = false
        await withTaskGroup(of: FuelStationLoadOutcome.self) { group in
            for point in points {
                group.addTask {
                    .batch((try? await DriveAPI.stations(
                        near: point, fuel: fuel, radiusKm: 8
                    )) ?? [])
                }
            }
            if !points.isEmpty {
                group.addTask { [weak self] in
                    while !Task.isCancelled {
                        try? await Task.sleep(nanoseconds: 100_000_000)
                        guard !Task.isCancelled else { break }
                        guard let self else { return .superseded }
                        if !(await self.isCurrentStationLoad(
                            routeGeneration: routeGeneration,
                            loadGeneration: generation
                        )) { return .superseded }
                    }
                    return .superseded
                }
            }
            var remainingRequests = points.count
            while remainingRequests > 0, let outcome = await group.next() {
                switch outcome {
                case .batch(let batch):
                    remainingRequests -= 1
                    // A malformed or unexpectedly broad backend response must
                    // not turn a bounded route query back into hundreds of
                    // objects to sort and project on the main actor.
                    for station in batch.prefix(FuelStationQueryPolicy.maximumResultsPerSample) {
                        unique[station.id] = station
                    }
                case .superseded:
                    loadWasSuperseded = true
                    group.cancelAll()
                    return
                }
            }
            // End the generation watcher after all provider requests finish.
            // If a newer route or fuel choice wins first, cancellation reaches
            // the underlying URLSession requests instead of wasting bandwidth.
            group.cancelAll()
        }
        guard !loadWasSuperseded else { return }
        guard RouteEnrichmentPublicationPolicy.isCurrent(
            route: routeGeneration, currentRoute: routeCalculationGeneration,
            request: generation, currentRequest: stationLoadGeneration
        ) else { return }
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 160) }
        let nearRoute = unique.values.compactMap { station -> (station: FuelStation, progress: Double,
                                                                corridorDistance: Double)? in
            guard let projection = RouteGeometryProgress.nearestProgress(
                    of: station.coordinate, on: routeCoordinates
                  ), projection.distance < 4_000,
                  RouteSearchPolicy.isAhead(candidateProgress: projection.progress,
                                            currentProgress: currentProgress,
                                            totalRouteDistance: totalDistance) else { return nil }
            return (station, projection.progress, projection.distance)
        }
        // Keep at most one strong candidate per route section. This gives the
        // break planner geographic coverage without flooding MapKit with pins.
        let bucketCount = min(12, max(1, routeCoordinates.count))
        let grouped = Dictionary(grouping: nearRoute) { item in
            FuelStationDistributionPolicy.bucket(
                progress: item.progress,
                currentProgress: currentProgress,
                bucketCount: bucketCount
            ) ?? 0
        }
        stations = grouped.keys.sorted().compactMap { bucket in
            grouped[bucket]?.min {
                FuelStationSelectionPolicy.isPreferred(
                    $0.station, corridorDistance: $0.corridorDistance,
                    over: $1.station, corridorDistance: $1.corridorDistance
                )
            }?.station
        }
    }

    private func isCurrentStationLoad(routeGeneration: UUID, loadGeneration: UUID) -> Bool {
        RouteEnrichmentPublicationPolicy.isCurrent(
            route: routeGeneration, currentRoute: routeCalculationGeneration,
            request: loadGeneration, currentRequest: stationLoadGeneration
        )
    }

    /// Fügt eine Tankstelle als Zwischenstopp ein (oder entfernt sie erneut,
    /// wenn sie bereits als Zwischenstopp gesetzt ist) und berechnet die
    /// Route neu.
    @discardableResult
    func toggleWaypoint(_ station: FuelStation, from start: CLLocationCoordinate2D,
                        settings: DriveSettings) async -> Bool {
        let navigationSession = isNavigating ? navigationSessionGeneration : nil
        let wasSelected = RouteStopSelectionPolicy.contains(
            stopID: station.id,
            transientStationIDs: viaStations.map(\.id),
            lockedWaypoints: routeLockStore.activeLock?.waypoints ?? []
        )
        guard PlannedStopSelectionPolicy.acceptsFuelStation(
            id: station.id, coordinate: station.coordinate,
            currentlySelected: wasSelected, available: stations
        ) else {
            errorMessage = "Diese Tankstelle gehört nicht mehr zur aktuellen Route. Bitte neu auswählen."
            return false
        }
        let knownProgress: Double?
        if wasSelected {
            knownProgress = nil
        } else {
            guard mayInsertRouteStop(at: station.coordinate) else { return false }
            knownProgress = breakCandidates(along: legs)
                .first(where: { $0.id == station.id })?.progress
            if isNavigating {
                guard let knownProgress, RouteSearchPolicy.isAhead(
                    candidateProgress: knownProgress,
                    currentProgress: currentInstalledRouteProgress(from: start),
                    totalRouteDistance: totalDistance
                ) else {
                    errorMessage = "Diese Tankstelle liegt inzwischen hinter dir."
                    return false
                }
            }
        }
        let mutationGeneration = UUID()
        routeStopMutationGeneration = mutationGeneration
        let rollback = RouteMutationBaselinePolicy.choose(
            existing: routeStopMutationSnapshot,
            current: RouteStopMutationSnapshot(
                lock: routeLockStore.activeLock,
                stations: viaStations,
                searchResults: routeSearchResults,
                searchQuery: routeSearchQuery
            )
        )
        routeStopMutationSnapshot = rollback
        defer {
            if mutationGeneration == routeStopMutationGeneration {
                routeStopMutationSnapshot = nil
            }
        }
        if wasSelected {
            viaStations.removeAll { $0.id == station.id }
            routeLockStore.update { lock in
                lock.removeWaypoint(id: station.id)
            }
            activeRouteLock = routeLockStore.activeLock
        } else {
            viaStations.append(station)
            if routeLockStore.activeLock == nil { persistActiveTrip() }
            insertLockedWaypoint(
                id: station.id, name: station.brand.isEmpty ? station.name : station.brand,
                coordinate: station.coordinate, knownProgress: knownProgress,
                kind: .fuelStop
            )
        }
        let mutatedStations = viaStations
        let mutatedLock = routeLockStore.activeLock
        guard await calculate(
            from: start, settings: settings,
            navigationSession: navigationSession
        ) else {
            guard mutationGeneration == routeStopMutationGeneration else { return false }
            guard RouteMutationRollbackPolicy.shouldRollback(
                current: viaStations, mutated: mutatedStations
            ), RouteMutationRollbackPolicy.shouldRollback(
                current: routeLockStore.activeLock, mutated: mutatedLock
            ) else { return false }
            viaStations = rollback.stations
            routeLockStore.replace(with: rollback.lock)
            activeRouteLock = rollback.lock
            routeSearchResults = rollback.searchResults
            routeSearchQuery = rollback.searchQuery
            isSearchingAlongRoute = false
            return false
        }
        return true
    }

    @discardableResult
    func addPlannedBreak(_ plannedBreak: PlannedBreak, from start: CLLocationCoordinate2D,
                         settings: DriveSettings) async -> Bool {
        guard PlannedStopSelectionPolicy.acceptsBreak(
            plannedBreak, currentPlan: longTripPlan
        ) else {
            errorMessage = "Der Reiseplan wurde inzwischen aktualisiert. Bitte wähle den Pausenstopp erneut."
            return false
        }
        guard let candidate = plannedBreak.candidate else {
            errorMessage = "Für diesen geplanten Stopp ist kein Ort verfügbar."
            return false
        }
        guard mayInsertRouteStop(at: candidate.coordinate) else { return false }
        if isNavigating, !RouteSearchPolicy.isAhead(
            candidateProgress: plannedBreak.insertionRouteProgress,
            currentProgress: currentInstalledRouteProgress(from: start),
            totalRouteDistance: totalDistance
        ) {
            errorMessage = "Dieser geplante Stopp liegt inzwischen hinter dir."
            return false
        }
        if let station = stations.first(where: { $0.id == candidate.id }) {
            guard !RouteStopSelectionPolicy.contains(
                stopID: station.id,
                transientStationIDs: viaStations.map(\.id),
                lockedWaypoints: routeLockStore.activeLock?.waypoints ?? []
            ) else { return true }
            let navigationSession = isNavigating ? navigationSessionGeneration : nil
            let mutationGeneration = UUID()
            routeStopMutationGeneration = mutationGeneration
            let rollback = RouteMutationBaselinePolicy.choose(
                existing: routeStopMutationSnapshot,
                current: RouteStopMutationSnapshot(
                    lock: routeLockStore.activeLock,
                    stations: viaStations,
                    searchResults: routeSearchResults,
                    searchQuery: routeSearchQuery
                )
            )
            routeStopMutationSnapshot = rollback
            defer {
                if mutationGeneration == routeStopMutationGeneration {
                    routeStopMutationSnapshot = nil
                }
            }
            viaStations.append(station)
            let progressByID = Dictionary(uniqueKeysWithValues: breakCandidates(along: legs)
                .map { ($0.id, $0.progress) })
            viaStations.sort { lhs, rhs in
                (progressByID[lhs.id] ?? 1) < (progressByID[rhs.id] ?? 1)
            }
            if routeLockStore.activeLock == nil { persistActiveTrip() }
            insertLockedWaypoint(
                id: station.id, name: station.brand.isEmpty ? station.name : station.brand,
                coordinate: station.coordinate,
                knownProgress: plannedBreak.insertionRouteProgress,
                kind: .fuelStop
            )
            let mutatedStations = viaStations
            let mutatedLock = routeLockStore.activeLock
            guard await calculate(
                from: start, settings: settings,
                navigationSession: navigationSession
            ) else {
                guard mutationGeneration == routeStopMutationGeneration else { return false }
                guard RouteMutationRollbackPolicy.shouldRollback(
                    current: viaStations, mutated: mutatedStations
                ), RouteMutationRollbackPolicy.shouldRollback(
                    current: routeLockStore.activeLock, mutated: mutatedLock
                ) else { return false }
                viaStations = rollback.stations
                routeLockStore.replace(with: rollback.lock)
                activeRouteLock = rollback.lock
                routeSearchResults = rollback.searchResults
                routeSearchQuery = rollback.searchQuery
                isSearchingAlongRoute = false
                return false
            }
            return true
        } else {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: candidate.coordinate))
            item.name = candidate.name
            return await addRouteStop(
                item, from: start, settings: settings,
                knownRouteProgress: plannedBreak.insertionRouteProgress
            )
        }
    }

    private func sample(_ polyline: MKPolyline, maximum: Int) -> [CLLocationCoordinate2D] {
        guard polyline.pointCount > 0 else { return [] }
        let coordinates = UnsafeMutablePointer<CLLocationCoordinate2D>.allocate(capacity: polyline.pointCount)
        defer { coordinates.deallocate() }
        polyline.getCoordinates(coordinates, range: NSRange(location: 0, length: polyline.pointCount))
        let allPoints = Array(UnsafeBufferPointer(start: coordinates, count: polyline.pointCount))
        // Index strides over-sample dense junction geometry and can omit the
        // final route coordinate. Distance-based sampling covers the complete
        // journey and always preserves both origin and destination.
        return RouteGeometryProgress.evenlySpaced(allPoints, maximum: maximum)
    }

    private func mayInsertRouteStop(at coordinate: CLLocationCoordinate2D) -> Bool {
        guard RouteStopEndpointPolicy.isValid(coordinate) else {
            errorMessage = "Dieser Zwischenstopp hat keinen gültigen Standort."
            return false
        }
        guard RouteStopEndpointPolicy.isDistinctFromDestination(
            stop: coordinate,
            destination: destination?.placemark.coordinate
        ) else {
            errorMessage = "Dieser Ort ist bereits dein Ziel und muss nicht zusätzlich angefahren werden."
            return false
        }
        return true
    }

    private func evenlySpaced(_ points: [CLLocationCoordinate2D], maximum: Int) -> [CLLocationCoordinate2D] {
        RouteGeometryProgress.evenlySpaced(points, maximum: maximum)
    }

    private func routeInsideLockedCorridor(_ route: MKRoute, points: [DriveCoordinate], width: Double) -> Bool {
        let routePoints = sample(route.polyline, maximum: 100)
        // Einzelne Anschlussstellen duerfen den Korridor leicht verlassen;
        // mindestens 90 % der Neuberechnung muessen innerhalb bleiben.
        return RouteCorridorPolicy.contains(route: routePoints, corridor: points,
                                            widthMetres: width, requiredFraction: 0.9)
    }
}
