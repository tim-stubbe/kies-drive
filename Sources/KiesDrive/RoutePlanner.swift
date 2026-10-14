import Foundation
import MapKit
import AVFoundation

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
    /// Optional for backwards compatibility with caches written before the
    /// destination identity was anchored geographically.
    let destinationCoordinate: DriveCoordinate?
    let legs: [Leg]
    let stations: [FuelStation]
    let savedAt: Date
}

struct OfflineRouteCacheStore {
    let fileURL: URL

    static func live(fileManager: FileManager = .default) -> Self {
        let base = fileManager.urls(for: .applicationSupportDirectory,
                                    in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        return .init(fileURL: base.appendingPathComponent("KiesDrive", isDirectory: true)
            .appendingPathComponent("offline-route.json"))
    }

    func load() -> CachedRoute? {
        guard let data = try? Data(contentsOf: fileURL) else { return nil }
        return try? JSONDecoder().decode(CachedRoute.self, from: data)
    }

    @discardableResult
    func save(_ route: CachedRoute, fileManager: FileManager = .default) -> Bool {
        do {
            try fileManager.createDirectory(at: fileURL.deletingLastPathComponent(),
                                            withIntermediateDirectories: true)
            let data = try JSONEncoder().encode(route)
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
        guard fileManager.fileExists(atPath: fileURL.path) else { return }
        try? fileManager.removeItem(at: fileURL)
    }
}

struct RouteSearchResult: Identifiable {
    let id: String
    let mapItem: MKMapItem
    let detourMetres: CLLocationDistance
    let detourIsEstimated: Bool
    let routeProgress: Double
}

@MainActor
final class RoutePlanner: NSObject, ObservableObject, AVSpeechSynthesizerDelegate {
    /// Shared by the phone UI and CarPlay so both surfaces operate on the
    /// same route, stops and long-trip plan.
    static let shared = RoutePlanner()
    @Published var destinationText = ""
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
    @Published var isNavigating = false
    @Published var activeRouteLock: ActiveRouteLock?
    @Published var routeSearchQuery = ""
    @Published var routeSearchResults: [RouteSearchResult] = []
    @Published var isSearchingAlongRoute = false
    @Published var nextManeuverInstruction: String?
    @Published var nextManeuverDistance: CLLocationDistance?
    @Published var upcomingManeuverInstructions: [String] = []
    @Published var remainingDistanceMetres: CLLocationDistance = 0
    @Published var remainingTravelTime: TimeInterval = 0
    @Published var hasArrived = false
    @Published private(set) var isUsingOfflineGuidance = false
    private var comparisonRoute: MKRoute?
    private var researchedStandardToll: TollCost = .unknown(reason: "Mautrecherche läuft noch.")
    private var researchedAvoidingToll: TollCost = .unknown(reason: "Mautfreie Route wird geprüft.")
    private var tollLookupSnapshots: [Bool: TollLookupSnapshot] = [:]
    private var amenityBreakCandidates: [BreakCandidate] = []
    private var measuredBreakDetours: [String: CLLocationDistance] = [:]

    /// Tempolimits entlang der Route, parallel zu `speedLimitPoints` indiziert.
    private var speedLimitPoints: [CLLocationCoordinate2D] = []
    private var speedLimits: [SpeedLimitResult] = []

    private let synthesizer = AVSpeechSynthesizer()
    private var activeUtterance: AVSpeechUtterance?
    private var activeSpeechPriority: NavigationSpeechPriority?
    private var navigationStepCursor = 0
    private var announcedManeuverStages: [String: Set<NavigationAnnouncementStage>] = [:]
    private var diagnosticManeuverKey: String?
    private var diagnosticManeuverInstruction: String?
    private var offRouteSince: Date?
    private var offRouteFixCount = 0
    private var previousOffRouteDistance: CLLocationDistance?
    private var lastRerouteAt: Date?
    private var consecutiveRerouteFailures = 0
    private var lastAcceptedNavigationLocation: CLLocation?
    private var lastReliableGuidanceSpeedMps: Double?
    private var lastReliableGuidanceSpeedAt: Date?
    private var lastLocationRejectionLoggedAt: Date?
    private var lastOfflineRecoveryAttempt: Date?
    private var offlineNeedsInitialPositionMatch = false
    private var offlineDeviationWarningActive = false
    private var arrivalStrikes = 0
    private var stationLoadGeneration = UUID()
    private var breakCandidateLoadGeneration = UUID()
    private var stopPlanningGeneration = UUID()
    private var speedLimitLoadGeneration = UUID()
    private var tollLoadGeneration = UUID()
    private var routeCalculationGeneration = UUID()
    private var destinationSearchGeneration = UUID()
    private var routeSearchGeneration = UUID()
    private var activeDestinationSearch: MKLocalSearch?
    private var activeRouteSearches: [MKLocalSearch] = []
    private var activeAmenitySearches: [MKLocalSearch] = []
    private var automaticRestoreInProgress = false
    private var lastAutomaticRestoreAttempt: Date?
    private var lastRouteProgressPersistedAt: Date?
    private static let cacheKey = "drive.offlineRoute"
    private static let offlineCacheStore = OfflineRouteCacheStore.live()
    private static let forcedHomeTripKey = "drive.forcedHomeTrip.austrianMountainPasses.v2"
    private let routeLockStore = RouteLockStore.shared

    override init() {
        super.init()
        synthesizer.delegate = self
        offlineRoute = Self.loadCache()
        // Einmalige, versionierte Migration fuer die ausdrücklich festgelegte
        // Heimfahrt. Sie greift auch dann, wenn iOS einen URL-Fernstart wegen
        // gesperrtem Bildschirm ablehnt.
        #if !targetEnvironment(simulator)
        if !UserDefaults.standard.bool(forKey: Self.forcedHomeTripKey) {
            routeLockStore.save(.hochheimViaWurzenpass())
            UserDefaults.standard.set(true, forKey: Self.forcedHomeTripKey)
        }
        #endif
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
    var offlinePolylines: [MKPolyline] {
        offlineRoute?.legs.compactMap { leg in
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
        guard alternatives.indices.contains(index), !isNavigating else { return }
        legs = [alternatives[index]]
        resetLiveNavigationProgress()
        seedInitialNavigationPresentation()
        remainingDistanceMetres = totalDistance
        remainingTravelTime = totalTravelTime
        stations = []
        amenityBreakCandidates = []
        measuredBreakDetours = [:]
        cacheForOffline()
        buildLongTripPlan(settings: settings)
        Task { [weak self] in
            guard let self else { return }
            await self.reloadStopPlanning(fuel: settings.fuel, settings: settings,
                                          reloadAmenities: true)
            await self.loadSpeedLimits()
        }
    }

    func startNavigation(voiceGuidance: Bool? = nil) {
        guard !legs.isEmpty else { return }
        let shouldSpeak = voiceGuidance ?? DriveSettings.shared.voiceGuidance
        isUsingOfflineGuidance = false
        persistActiveTrip()
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
        if wasNavigating { closeOutstandingManeuverDiagnostic() }
        isNavigating = false
        isUsingOfflineGuidance = false
        synthesizer.stopSpeaking(at: .immediate)
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
            diagnosticManeuverKey = nil
            diagnosticManeuverInstruction = nil
        }
    }

    /// Beendet den Trip bewusst. Ein normales Stoppen/Pausieren der Navigation
    /// loescht den Lock dagegen nicht, damit Rast und App-Neustart sicher sind.
    func completeActiveTrip() {
        stopNavigation()
        routeLockStore.finish()
        activeRouteLock = nil
        routeLockStore.clearFinished()
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
    }

    /// Einmaliger Wiederanlauf nach App-Start. Erst mit einer echten Position
    /// wird neu gerechnet; dadurch setzt MapKit am passenden aktuellen
    /// Routenabschnitt an, waehrend Pflichtpunkte und Segmentregeln erhalten bleiben.
    func restoreActiveTripIfNeeded(from current: CLLocationCoordinate2D, settings: DriveSettings) async {
        guard let lock = routeLockStore.activeLock, lock.isActive else { return }
        guard RouteLockRestorePolicy.shouldAttempt(
            navigationActive: isNavigating,
            attemptInProgress: automaticRestoreInProgress,
            lastAttempt: lastAutomaticRestoreAttempt
        ) else { return }
        automaticRestoreInProgress = true
        lastAutomaticRestoreAttempt = Date()
        defer { automaticRestoreInProgress = false }
        activeRouteLock = lock
        destinationText = lock.destinationName
        let item = MKMapItem(placemark: MKPlacemark(coordinate: lock.destination.clLocationCoordinate))
        item.name = lock.destinationName
        destination = item
        let onlineCalculationSucceeded = await calculate(from: current, settings: settings)
        let hasMatchingOfflineRoute = offlineRoute.map {
            OfflineRouteCachePolicy.matches(
                cacheName: $0.destinationName,
                cacheCoordinate: $0.destinationCoordinate?.clLocationCoordinate,
                destinationName: destination?.name ?? destinationText,
                destinationCoordinate: destination?.placemark.coordinate
            ) && $0.legs.flatMap(\.steps).contains { ($0.coordinates?.count ?? 0) > 1 }
        } ?? false
        switch RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: onlineCalculationSucceeded,
            hasLiveRoute: !legs.isEmpty,
            hasMatchingOfflineRoute: hasMatchingOfflineRoute
        ) {
        case .online, .staleLive:
            startNavigation(voiceGuidance: settings.voiceGuidance)
        case .offline:
            _ = startOfflineGuidanceIfAvailable(replacingLiveRoute: true)
        case .unavailable:
            break
        }
    }

    func restoreActiveTrip(from current: CLLocationCoordinate2D, settings: DriveSettings) async {
        lastAutomaticRestoreAttempt = nil
        await restoreActiveTripIfNeeded(from: current, settings: settings)
    }

    func installCroatiaSplitTripLock() {
        let lock = ActiveRouteLock.croatiaSplit()
        routeLockStore.save(lock)
        activeRouteLock = lock
        destinationText = lock.destinationName
        let item = MKMapItem(placemark: MKPlacemark(coordinate: lock.destination.clLocationCoordinate))
        item.name = lock.destinationName
        destination = item
        stopNavigation()
        lastAutomaticRestoreAttempt = nil
        legs = []
        alternatives = []
    }

    func installHochheimViaWurzenpassTripLock() {
        let lock = ActiveRouteLock.hochheimViaWurzenpass()
        routeLockStore.save(lock)
        activeRouteLock = lock
        destinationText = lock.destinationName
        let item = MKMapItem(placemark: MKPlacemark(coordinate: lock.destination.clLocationCoordinate))
        item.name = lock.destinationName
        destination = item
        stopNavigation()
        lastAutomaticRestoreAttempt = nil
        legs = []
        alternatives = []
    }

    func updateLockedRouteOptions(waypointID: String?, avoidTolls: Bool?, avoidHighways: Bool?) {
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
        destinationSearchGeneration = UUID()
        suggestions = []
        let previousDestination = destination
        let previousDestinationText = destinationText
        let previousLock = routeLockStore.activeLock
        destination = item
        destinationText = item.name ?? item.placemark.title ?? "Ziel"
        replaceRouteLockForRemoteDestination(waypoints: requiredWaypoints)
        guard await calculate(from: start, settings: settings) else {
            destination = previousDestination
            destinationText = previousDestinationText
            routeLockStore.replace(with: previousLock)
            activeRouteLock = previousLock
            return false
        }
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
        activeDestinationSearch?.cancel()
        activeDestinationSearch = nil
        guard query.count > 2 else { suggestions = []; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coordinate { request.region = .init(center: coordinate, latitudinalMeters: 100_000, longitudinalMeters: 100_000) }
        let search = MKLocalSearch(request: request)
        activeDestinationSearch = search
        do {
            let items = try await search.start().mapItems
            guard generation == destinationSearchGeneration,
                  destinationText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            activeDestinationSearch = nil
            suggestions = items
        } catch {
            guard generation == destinationSearchGeneration else { return }
            activeDestinationSearch = nil
            errorMessage = "Zielsuche fehlgeschlagen: \(error.localizedDescription)"
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
            isSearchingAlongRoute = false
            return
        }
        isSearchingAlongRoute = true
        let routeGeneration = routeCalculationGeneration
        routeSearchQuery = cleanQuery
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 180) }
        let currentRouteProgress: Double = {
            guard let location = LocationService.shared.location,
                  let projection = RouteGeometryProgress.nearestProgress(
                    of: location.coordinate, on: routeCoordinates,
                    progressRange: currentRouteProgressSearchRange
                  ), projection.distance <= 5_000 else { return 0 }
            return projection.progress
        }()
        let remainingCoordinates = RouteSearchPolicy.remainingRouteCoordinates(
            routeCoordinates, currentProgress: currentRouteProgress
        )
        let searchPoints = evenlySpaced(remainingCoordinates, maximum: 5)
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
        await withTaskGroup(of: [MKMapItem].self) { group in
            for search in searches {
                group.addTask {
                    (try? await search.start().mapItems) ?? []
                }
            }
            for await items in group {
                for item in items {
                    let c = item.placemark.coordinate
                    matches["\(item.name ?? ""):\(c.latitude):\(c.longitude)"] = item
                }
            }
        }
        guard generation == routeSearchGeneration,
              routeGeneration == routeCalculationGeneration,
              routeSearchQuery == cleanQuery else { return }
        activeRouteSearches = []
        let candidates = matches.values.compactMap {
            item -> (item: MKMapItem, progress: Double, airDistance: Double,
                     routeCoordinate: CLLocationCoordinate2D)? in
            guard let projection = RouteGeometryProgress.nearestProgress(
                of: item.placemark.coordinate, on: routeCoordinates,
                progressRange: max(0, currentRouteProgress - 0.02)...1
            ) else { return nil }
            guard projection.distance <= 5_000,
                  RouteSearchPolicy.isAhead(candidateProgress: projection.progress,
                                            currentProgress: currentRouteProgress) else { return nil }
            return (item, projection.progress, projection.distance, projection.coordinate)
        }
        .sorted {
            $0.progress == $1.progress ? $0.airDistance < $1.airDistance : $0.progress < $1.progress
        }
        // Route only a small shortlist. This is a user-triggered search, but
        // dozens of MKDirections requests would still make the screen lag and
        // can trigger provider throttling.
        let shortlist = Array(candidates.prefix(6))
        var routed: [RouteSearchResult] = []
        await withTaskGroup(of: RouteSearchResult?.self) { group in
            for candidate in shortlist {
                group.addTask { [weak self] in
                    let driven = await self?.drivingDetour(
                        between: candidate.routeCoordinate, and: candidate.item
                    )
                    guard let detour = driven ?? RouteSearchPolicy.estimatedDetour(
                        airDistance: candidate.airDistance
                    ) else { return nil }
                    guard RouteSearchPolicy.acceptsDetour(detour) else { return nil }
                    let coordinate = candidate.item.placemark.coordinate
                    return RouteSearchResult(
                        id: "\(candidate.item.name ?? ""): \(coordinate.latitude):\(coordinate.longitude)",
                        mapItem: candidate.item,
                        detourMetres: detour,
                        detourIsEstimated: driven == nil,
                        routeProgress: candidate.progress
                    )
                }
            }
            for await result in group {
                if let result { routed.append(result) }
            }
        }
        guard generation == routeSearchGeneration,
              routeGeneration == routeCalculationGeneration,
              routeSearchQuery == cleanQuery else { return }
        routeSearchResults = routed.sorted {
            $0.routeProgress == $1.routeProgress
                ? $0.detourMetres < $1.detourMetres
                : $0.routeProgress < $1.routeProgress
        }
        isSearchingAlongRoute = false
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

    private func drivingDetour(between routeCoordinate: CLLocationCoordinate2D,
                               and item: MKMapItem) async -> CLLocationDistance? {
        let routeItem = MKMapItem(placemark: MKPlacemark(coordinate: routeCoordinate))
        do {
            async let outbound = Self.drivingDistance(from: routeItem, to: item)
            async let inbound = Self.drivingDistance(from: item, to: routeItem)
            return try await outbound + inbound
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
        guard let route = try await MKDirections(request: request).calculate().routes.first else {
            throw DriveAPIError.invalidData
        }
        return route.distance
    }

    @discardableResult
    func addRouteStop(_ item: MKMapItem, from start: CLLocationCoordinate2D,
                      settings: DriveSettings) async -> Bool {
        let previousLock = routeLockStore.activeLock
        let previousSearchResults = routeSearchResults
        let previousSearchQuery = routeSearchQuery
        // A user may add a stop while merely previewing a calculated route,
        // before tapping Start. Materialise the lock here so the action never
        // appears to succeed while silently doing nothing.
        if routeLockStore.activeLock == nil { persistActiveTrip() }
        guard routeLockStore.activeLock != nil else {
            errorMessage = "Zwischenstopp konnte nicht gespeichert werden."
            return false
        }
        let coordinate = item.placemark.coordinate
        // A route-search result already has an unambiguous progress value.
        // Reuse it so a POI beside a later parallel carriageway or a route
        // crossing cannot be inserted into an earlier locked segment.
        let knownProgress = routeSearchResults.first(where: { result in
            let resultCoordinate = result.mapItem.placemark.coordinate
            return CLLocation(latitude: resultCoordinate.latitude, longitude: resultCoordinate.longitude)
                .distance(from: CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)) <= 30
        })?.routeProgress
        insertLockedWaypoint(id: "poi-\(UUID().uuidString)", name: item.name ?? "Zwischenstopp",
                             coordinate: coordinate, knownProgress: knownProgress)
        routeSearchResults = []
        isSearchingAlongRoute = false
        let succeeded = await calculate(from: start, settings: settings)
        guard succeeded else {
            routeLockStore.replace(with: previousLock)
            activeRouteLock = previousLock
            routeSearchQuery = previousSearchQuery
            routeSearchResults = previousSearchResults
            isSearchingAlongRoute = false
            return false
        }
        startNavigation(voiceGuidance: settings.voiceGuidance)
        return true
    }

    var removableRouteStops: [LockedWaypoint] {
        activeRouteLock?.waypoints.filter { $0.id.hasPrefix("poi-") } ?? []
    }

    @discardableResult
    func removeRouteStop(id: String, from start: CLLocationCoordinate2D,
                         settings: DriveSettings) async -> Bool {
        guard id.hasPrefix("poi-"),
              routeLockStore.activeLock?.waypoints.contains(where: { $0.id == id }) == true else {
            return false
        }
        let previousLock = routeLockStore.activeLock
        routeLockStore.update { $0.removeWaypoint(id: id) }
        activeRouteLock = routeLockStore.activeLock
        guard await calculate(from: start, settings: settings) else {
            routeLockStore.replace(with: previousLock)
            activeRouteLock = previousLock
            return false
        }
        return true
    }

    /// Every user-selected stop is written into the persistent trip lock. This
    /// avoids the former split-brain state where fuel stops lived only in
    /// `viaStations` and disappeared whenever mandatory route points existed.
    private func insertLockedWaypoint(id: String, name: String, coordinate: CLLocationCoordinate2D,
                                      knownProgress: Double? = nil) {
        guard var lock = routeLockStore.activeLock,
              !lock.waypoints.contains(where: { $0.id == id }) else { return }
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 240) }
        func progress(_ coordinate: CLLocationCoordinate2D) -> Double {
            RouteGeometryProgress.nearestProgress(of: coordinate, on: routeCoordinates)?.progress ?? 1
        }
        lock.insertWaypoint(.init(
            id: id, name: name,
            coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
            required: true, optionsAfter: nil
        ), knownProgress: knownProgress, progress: { progress($0.clLocationCoordinate) })
        routeLockStore.save(lock)
        activeRouteLock = lock
    }

    @discardableResult
    func calculate(from start: CLLocationCoordinate2D, settings: DriveSettings,
                   showLoading: Bool = true) async -> Bool {
        guard let destination else { return false }
        let calculationGeneration = UUID()
        routeCalculationGeneration = calculationGeneration
        destinationSearchGeneration = UUID()
        routeSearchGeneration = UUID()
        activeDestinationSearch?.cancel()
        activeDestinationSearch = nil
        activeRouteSearches.forEach { $0.cancel() }
        activeRouteSearches = []
        activeAmenitySearches.forEach { $0.cancel() }
        activeAmenitySearches = []
        routeSearchResults = []
        isSearchingAlongRoute = false
        if showLoading { isLoading = true; stations = [] }
        errorMessage = nil
        let startItem = MKMapItem(placemark: MKPlacemark(coordinate: start))
        do {
            let lock = routeLockStore.activeLock
            let newlyPassed = Set(lock?.passedWaypointIDs(at: .init(
                latitude: start.latitude, longitude: start.longitude
            )) ?? [])
            let visited = Set(lock?.visitedWaypointIDs ?? []).union(newlyPassed)
            let lockedWaypoints = lock?.waypoints.filter { $0.required && !visited.contains($0.id) } ?? []
            let computedLegs: [MKRoute]
            let computedAlternatives: [MKRoute]
            let computedComparison: MKRoute?
            if viaStations.isEmpty && lockedWaypoints.isEmpty {
                let routes = try await computeRoutes(from: startItem, to: destination, settings: settings, alternates: true)
                guard calculationGeneration == routeCalculationGeneration else { return false }
                // A strict trip corridor may reject every MapKit alternative.
                // Never replace an active, still usable route with an empty
                // result; retaining it lets guidance continue and retry later.
                guard let firstRoute = routes.first else { throw DriveAPIError.invalidData }
                computedAlternatives = routes
                computedLegs = [firstRoute]
                // Request the opposite toll preference for an honest route-level
                // distance/time comparison. MapKit exposes no toll price; that
                // remains explicitly unknown until a verified provider responds.
                computedComparison = try? await computeRoutes(
                    from: startItem, to: destination, settings: settings,
                    alternates: false, avoidTollsOverride: !settings.avoidTolls
                ).first
                guard calculationGeneration == routeCalculationGeneration else { return false }
            } else {
                // MapKit kennt keine mehrgliedrigen Routen als ein einziges Objekt.
                // Daher Teilstrecken sequentiell (Start→wp1→wp2→…→Ziel) berechnen.
                let waypoints: [MKMapItem] = lockedWaypoints.isEmpty
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
                    let lockedOptions = i == 0 ? routeLockStore.activeLock?.defaultOptions
                        : lockedWaypoints[safe: i - 1]?.optionsAfter ?? routeLockStore.activeLock?.defaultOptions
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
            }
            guard calculationGeneration == routeCalculationGeneration,
                  lock?.id == routeLockStore.activeLock?.id else { return false }
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
            }
            legs = computedLegs
            alternatives = computedAlternatives
            comparisonRoute = computedComparison
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
            if showLoading { isLoading = false }
            Task { [weak self] in
                guard let self else { return }
                await self.loadStations(fuel: settings.fuel)
                guard calculationGeneration == self.routeCalculationGeneration else { return }
                await self.loadBreakAmenities()
                guard calculationGeneration == self.routeCalculationGeneration else { return }
                await self.measureBreakCandidateDetours()
                guard calculationGeneration == self.routeCalculationGeneration else { return }
                await self.loadSpeedLimits()
                guard calculationGeneration == self.routeCalculationGeneration else { return }
                await self.loadTollCost(from: start)
                guard calculationGeneration == self.routeCalculationGeneration else { return }
                self.buildLongTripPlan(settings: settings)
                self.cacheForOffline()
            }
            return true
        } catch {
            guard calculationGeneration == routeCalculationGeneration else { return false }
            if showLoading {
                isLoading = false
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
    private func cacheForOffline() {
        guard !legs.isEmpty else { return }
        let cached = CachedRoute(
            destinationName: destination?.name ?? destinationText,
            destinationCoordinate: destination.map {
                .init(latitude: $0.placemark.coordinate.latitude,
                      longitude: $0.placemark.coordinate.longitude)
            },
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
            savedAt: Date()
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
              let route = try? JSONDecoder().decode(CachedRoute.self, from: data) else { return nil }
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
    func updateProgress(at location: CLLocation, settings: DriveSettings) {
        guard isNavigating, !legs.isEmpty || isUsingOfflineGuidance else { return }
        let evaluationDate = Date()
        if let rejection = NavigationLocationPolicy.rejectionReason(
            for: location, after: lastAcceptedNavigationLocation, now: evaluationDate
        ) {
            if lastLocationRejectionLoggedAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
                lastLocationRejectionLoggedAt = Date()
                DriveDiagnosticStore.append(.locationRejected,
                                            detail: DriveDiagnosticDetail.navigationSample(
                                                rejection, location: location
                                            ))
            }
            return
        }
        lastAcceptedNavigationLocation = location
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
        if detectArrival(at: location, settings: settings) { return }
        if isUsingOfflineGuidance {
            updateOfflineProgress(at: location, guidanceSpeedMps: guidanceSpeed, settings: settings)
        } else if let progress = liveNavigationProgress(at: location) {
            updateNextManeuver(using: progress)
            if settings.voiceGuidance { announce(progress, guidanceSpeedMps: guidanceSpeed) }
        }
        persistRouteLockProgress(at: location)
        markReachedWaypoints(at: location, settings: settings)
        if !isUsingOfflineGuidance {
            checkSpeedLimit(at: location.coordinate,
                            speedMps: NavigationMotionPolicy.reliableSpeed(for: location))
            checkForDeviation(from: location, settings: settings)
        }
    }

    @discardableResult
    private func startOfflineGuidanceIfAvailable(replacingLiveRoute: Bool = false) -> Bool {
        guard (legs.isEmpty || replacingLiveRoute), let cache = offlineRoute,
              OfflineRouteCachePolicy.matches(
                cacheName: cache.destinationName,
                cacheCoordinate: cache.destinationCoordinate?.clLocationCoordinate,
                destinationName: destination?.name ?? destinationText,
                destinationCoordinate: destination?.placemark.coordinate
              ),
              cache.legs.flatMap(\.steps).contains(where: { ($0.coordinates?.count ?? 0) > 1 }) else {
            return false
        }
        if replacingLiveRoute {
            legs = []
            alternatives = []
            comparisonRoute = nil
        }
        resetLiveNavigationProgress()
        errorMessage = nil
        isUsingOfflineGuidance = true
        offlineNeedsInitialPositionMatch = true
        lastOfflineRecoveryAttempt = Date()
        isNavigating = true
        hasArrived = false
        remainingDistanceMetres = cache.legs.reduce(0) { $0 + $1.distance }
        remainingTravelTime = cache.legs.reduce(0) { $0 + $1.travelTime }
        nextManeuverInstruction = cache.legs.flatMap(\.steps)
            .first(where: { !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?.instructions
        lastAnnouncement = "Offline-Route wiederhergestellt"
        DriveDiagnosticStore.append(.navigationStarted, detail: "Offline · \(cache.destinationName)")
        return true
    }

    private func updateOfflineProgress(at location: CLLocation, guidanceSpeedMps: Double,
                                       settings: DriveSettings) {
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
            allowsFullRecovery: offlineNeedsInitialPositionMatch
        ) else { return }
        offlineNeedsInitialPositionMatch = false

        if OfflineRouteRecoveryPolicy.shouldAttempt(lastAttempt: lastOfflineRecoveryAttempt) {
            lastOfflineRecoveryAttempt = Date()
            Task { [weak self] in
                guard let self, self.isUsingOfflineGuidance, self.isNavigating else { return }
                await self.calculate(from: location.coordinate, settings: settings, showLoading: false)
            }
        }

        let reliableSpeed = NavigationMotionPolicy.reliableSpeed(for: location) ?? 0
        let isOutsideCorridor = NavigationDeviationPolicy.isOutsideCorridor(
            distanceFromRoute: progress.distanceFromRoute,
            horizontalAccuracy: location.horizontalAccuracy,
            speedMetresPerSecond: reliableSpeed
        )
        let isDeparting = NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: progress.distanceFromRoute,
            previousDistance: previousOffRouteDistance,
            horizontalAccuracy: location.horizontalAccuracy,
            speedMetresPerSecond: reliableSpeed
        )
        previousOffRouteDistance = progress.distanceFromRoute
        if isOutsideCorridor {
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
                    DriveDiagnosticStore.append(
                        .offlineRouteDeparture,
                        detail: DriveDiagnosticDetail.navigationSample(
                            "Abstand zum Offline-Korridor \(Int(progress.distanceFromRoute.rounded())) m",
                            location: location
                        )
                    )
                    if settings.voiceGuidance {
                        _ = speak(
                            "Du hast die gespeicherte Route verlassen. Sobald eine Verbindung verfügbar ist, wird neu berechnet.",
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
            offlineDeviationWarningActive = false
            if settings.voiceGuidance {
                _ = speak("Du bist wieder auf der gespeicherten Route.", priority: .status)
            }
        }
        resetDeviationTracking(keepingDistance: progress.distanceFromRoute)
        navigationStepCursor = progress.currentStepIndex
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
        let key = "offline:\(progress.maneuverStepIndex):\(progress.instruction)"
        recordManeuverTransition(key: key, instruction: progress.instruction)
        guard
              let stage = NavigationAnnouncementStage.stage(
                distance: progress.distanceToManeuver,
                speedKmh: guidanceSpeedMps * 3.6
              ) else { return }
        let completed = announcedManeuverStages[key] ?? []
        guard !completed.contains(stage) else { return }
        let spokenDistance = stage == .now ? min(progress.distanceToManeuver, 35) : progress.distanceToManeuver
        let following = progress.upcomingInstructions.dropFirst().first
        let speech = stage == .now
            ? NavigationSpeechFormatter.spokenText(
                progress.instruction, distance: spokenDistance,
                then: following, followingDistance: progress.followingManeuverDistance
            )
            : NavigationSpeechFormatter.spokenText(progress.instruction, distance: spokenDistance)
        guard speak(speech, priority: .forAnnouncementStage(stage)) else { return }
        announcedManeuverStages[key] = Set(NavigationAnnouncementStage.allCases.filter { $0.rawValue <= stage.rawValue })
        lastAnnouncement = progress.instruction
        DriveDiagnosticStore.append(.maneuverAnnounced,
                                    detail: "\(stage) · \(Int(progress.distanceToManeuver)) m · \(progress.instruction)")
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
        diagnosticManeuverKey = nil
        diagnosticManeuverInstruction = nil
        resetDeviationTracking()
        arrivalStrikes = 0
        lastAcceptedNavigationLocation = nil
        lastReliableGuidanceSpeedMps = nil
        lastReliableGuidanceSpeedAt = nil
        consecutiveRerouteFailures = 0
        offlineNeedsInitialPositionMatch = false
        offlineDeviationWarningActive = false
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
            nextManeuverInstruction = legs.isEmpty ? nil : "Dem Straßenverlauf bis zum Ziel folgen"
            nextManeuverDistance = legs.isEmpty ? nil : totalDistance
            upcomingManeuverInstructions = nextManeuverInstruction.map { [$0] } ?? []
            return
        }
        nextManeuverInstruction = seed.instruction
        nextManeuverDistance = seed.distance
        upcomingManeuverInstructions = seed.upcomingInstructions
    }

    @discardableResult
    private func detectArrival(at location: CLLocation, settings: DriveSettings) -> Bool {
        guard let coordinate = destination?.placemark.coordinate else { return false }
        if NavigationArrivalPolicy.isArrivalFix(location, destination: coordinate) {
            arrivalStrikes += 1
        } else {
            arrivalStrikes = 0
        }
        guard arrivalStrikes >= NavigationArrivalPolicy.requiredConsecutiveFixes else { return false }

        arrivalStrikes = 0
        closeOutstandingManeuverDiagnostic()
        isNavigating = false
        isRecalculating = false
        remainingDistanceMetres = 0
        remainingTravelTime = 0
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
        DriveDiagnosticStore.append(.arrivalReached, detail: destination?.name ?? destinationText)
        return true
    }

    private func routeSteps() -> [LiveRouteStep] {
        legs.enumerated().flatMap { legIndex, leg in
            leg.steps.enumerated().map { LiveRouteStep(legIndex: legIndex, stepIndex: $0.offset, step: $0.element) }
        }
    }

    private func liveNavigationProgress(at location: CLLocation) -> LiveNavigationProgress? {
        let steps = routeSteps()
        guard !steps.isEmpty else { return nil }

        let metrics = steps.map {
            NavigationStepMetric(
                distanceFromRoute: Self.distance(from: location.coordinate, to: $0.step.polyline),
                remainingOnStep: Self.remainingDistance(from: location.coordinate, on: $0.step.polyline),
                stepDistance: $0.step.distance
            )
        }
        let transitionRadius = max(8, location.horizontalAccuracy * 1.5)
        navigationStepCursor = NavigationStepSelectionPolicy.selectedIndex(
            current: min(navigationStepCursor, steps.count - 1), metrics: metrics,
            transitionRadius: transitionRadius
        )
        let currentIndex = navigationStepCursor

        let currentStepRemaining = Self.remainingDistance(
            from: location.coordinate, on: steps[currentIndex].step.polyline
        )
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
            nextManeuverInstruction = "Dem Straßenverlauf bis zum Ziel folgen"
            nextManeuverDistance = routeRemaining
            upcomingManeuverInstructions = ["Dem Straßenverlauf bis zum Ziel folgen"]
            remainingDistanceMetres = routeRemaining
            remainingTravelTime = routeRemainingTime
            return nil
        }

        var distance = Self.remainingDistance(from: location.coordinate, on: steps[currentIndex].step.polyline)
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
        let followingIndex = steps.indices.dropFirst(maneuverIndex + 1).first(where: {
            !steps[$0].step.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        })
        let followingDistance = followingIndex.map { index in
            steps[maneuverIndex..<index].reduce(0) { $0 + $1.step.distance }
        }
        return LiveNavigationProgress(
            maneuver: steps[maneuverIndex], maneuverFlatIndex: maneuverIndex,
            distance: max(0, distance),
            totalRemainingDistance: routeRemaining,
            totalRemainingTravelTime: routeRemainingTime,
            upcomingInstructions: Array(upcoming.prefix(5)),
            followingManeuverDistance: followingDistance
        )
    }

    private func updateNextManeuver(using progress: LiveNavigationProgress) {
        guard !progress.upcomingInstructions.isEmpty else {
            nextManeuverInstruction = "Route folgen"
            nextManeuverDistance = nil
            upcomingManeuverInstructions = []
            return
        }
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
        guard let lock = routeLockStore.activeLock else { return }
        let visited = Set(lock.visitedWaypointIDs ?? [])
        guard let reachedID = RouteWaypointVisitPolicy.reachedWaypointID(
            waypoints: lock.waypoints, visitedIDs: visited, location: location
        ) else { return }
        routeLockStore.update { current in
            var ids = current.visitedWaypointIDs ?? []
            if !ids.contains(reachedID) { ids.append(reachedID) }
            current.visitedWaypointIDs = ids
        }
        activeRouteLock = routeLockStore.activeLock
        Task { await calculate(from: location.coordinate, settings: settings) }
    }

    private func persistRouteLockProgress(at location: CLLocation) {
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
        let periodicCheckpoint = lastRouteProgressPersistedAt.map {
            now.timeIntervalSince($0) >= 60
        } ?? true
        guard enoughMovement || periodicCheckpoint else { return }
        routeLockStore.update { current in
            current.lastRouteProgress = max(current.lastRouteProgress ?? 0, progress)
        }
        activeRouteLock = routeLockStore.activeLock
        lastRouteProgressPersistedAt = now
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

    private func announce(_ progress: LiveNavigationProgress, guidanceSpeedMps: Double) {
        let speedKmh = guidanceSpeedMps * 3.6
        let key = "\(progress.maneuver.legIndex):\(progress.maneuver.stepIndex):\(progress.maneuver.step.instructions)"
        recordManeuverTransition(key: key, instruction: progress.maneuver.step.instructions)
        guard let stage = NavigationAnnouncementStage.stage(distance: progress.distance, speedKmh: speedKmh) else { return }
        let completed = announcedManeuverStages[key] ?? []
        guard !completed.contains(stage) else { return }

        // If a sparse GPS update lands directly in the immediate zone, mark
        // earlier stages complete as well so they cannot be spoken afterwards.
        let spokenDistance: CLLocationDistance = stage == .now ? min(progress.distance, 35) : progress.distance
        let following = progress.upcomingInstructions.dropFirst().first
        let speech = stage == .now
            ? NavigationSpeechFormatter.spokenText(
                progress.maneuver.step.instructions, distance: spokenDistance,
                then: following, followingDistance: progress.followingManeuverDistance
            )
            : NavigationSpeechFormatter.spokenText(progress.maneuver.step.instructions, distance: spokenDistance)
        guard speak(speech, priority: .forAnnouncementStage(stage)) else { return }
        announcedManeuverStages[key] = Set(NavigationAnnouncementStage.allCases.filter { $0.rawValue <= stage.rawValue })
        lastAnnouncement = progress.maneuver.step.instructions
        DriveDiagnosticStore.append(.maneuverAnnounced,
                                    detail: "\(stage) · \(Int(progress.distance)) m · \(progress.maneuver.step.instructions)")
    }

    private func recordManeuverTransition(key: String, instruction: String) {
        guard diagnosticManeuverKey != key else { return }
        closeOutstandingManeuverDiagnostic()
        diagnosticManeuverKey = key
        diagnosticManeuverInstruction = instruction
    }

    private func closeOutstandingManeuverDiagnostic() {
        if let previous = diagnosticManeuverKey,
           ManeuverDiagnosticPolicy.missedFinalCue(stages: announcedManeuverStages[previous] ?? []) {
            DriveDiagnosticStore.append(.maneuverFinalCueMissed,
                                        detail: DriveDiagnosticDetail.navigationSample(
                                            diagnosticManeuverInstruction ?? "Unbekanntes Manöver",
                                            location: lastAcceptedNavigationLocation
                                        ))
        }
        diagnosticManeuverKey = nil
        diagnosticManeuverInstruction = nil
    }

    @discardableResult
    private func speak(_ text: String, priority: NavigationSpeechPriority) -> Bool {
        guard !text.isEmpty else { return false }
        if synthesizer.isSpeaking, let activeSpeechPriority,
           !NavigationSpeechInterruptionPolicy.shouldInterrupt(
               active: activeSpeechPriority, incoming: priority
           ) {
            return false
        }
        #if os(iOS)
        let audioSession = AVAudioSession.sharedInstance()
        try? audioSession.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
        try? audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        #endif
        if synthesizer.isSpeaking { synthesizer.stopSpeaking(at: .immediate) }
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
        synthesizer.speak(utterance)
        return true
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didFinish utterance: AVSpeechUtterance) {
        finishAudioSession(for: utterance)
    }

    func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer,
                           didCancel utterance: AVSpeechUtterance) {
        finishAudioSession(for: utterance)
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
        return voices.max { lhs, rhs in
            let lhsScore = lhs.quality.rawValue + (lhs.identifier.localizedCaseInsensitiveContains("siri") ? 10 : 0)
            let rhsScore = rhs.quality.rawValue + (rhs.identifier.localizedCaseInsensitiveContains("siri") ? 10 : 0)
            return lhsScore < rhsScore
        } ?? AVSpeechSynthesisVoice(language: "de-DE")
    }

    /// Zählt aufeinanderfolgende Positionsmeldungen weit abseits der Route und
    /// löst nach ein paar Treffern (nicht schon beim ersten GPS-Ausreißer) eine
    /// automatische Neuberechnung ab der aktuellen Position aus.
    private func checkForDeviation(from location: CLLocation, settings: DriveSettings) {
        guard !isLoading, !isRecalculating else { return }
        guard location.horizontalAccuracy >= 0, location.horizontalAccuracy <= 65 else { return }
        guard NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: lastRerouteAt,
            consecutiveFailures: consecutiveRerouteFailures
        ) else { return }
        let steps = routeSteps()
        let corridor = NavigationDeviationCorridorPolicy.indices(
            current: navigationStepCursor, stepCount: steps.count
        )
        let nearest = corridor.map {
            Self.distance(from: location.coordinate, to: steps[$0].step.polyline)
        }.min() ?? .greatestFiniteMagnitude
        let shouldAccumulate = NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: nearest,
            previousDistance: previousOffRouteDistance,
            horizontalAccuracy: location.horizontalAccuracy,
            speedMetresPerSecond: NavigationMotionPolicy.reliableSpeed(for: location) ?? 0
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
                speedMetresPerSecond: NavigationMotionPolicy.reliableSpeed(for: location) ?? 0
              ) else { return }
        resetDeviationTracking()
        lastRerouteAt = Date()
        // Claim the reroute synchronously. Location updates can arrive faster
        // than the unstructured task below gets scheduled; setting this only
        // inside the task left a small window in which several identical
        // reroutes (and spoken status messages) could be queued at once.
        isRecalculating = true
        DriveDiagnosticStore.append(.rerouteRequested,
                                    detail: DriveDiagnosticDetail.navigationSample(
                                        "Abweichung \(Int(nearest)) m", location: location
                                    ))
        Task {
            defer { isRecalculating = false }
            if settings.voiceGuidance { speak("Die Route wird neu berechnet.", priority: .status) }
            // Keep the current route, station data and guidance visible while
            // MapKit searches in the background. The Boolean result is the
            // source of truth: a superseded/empty request may intentionally
            // leave `errorMessage` nil and must not be reported as success.
            let succeeded = await calculate(from: location.coordinate, settings: settings,
                                            showLoading: false)
            if succeeded {
                consecutiveRerouteFailures = 0
                DriveDiagnosticStore.append(.rerouteSucceeded, detail: "\(legs.count) Etappen")
                if settings.voiceGuidance {
                    announceRecalculatedRoute(at: location)
                }
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

    /// A successful reroute must never end acoustically with only the earlier
    /// "wird neu berechnet" status. Publish and speak the first usable
    /// instruction immediately; when the next maneuver is still far away,
    /// confirm completion without manufacturing an early turn cue.
    private func announceRecalculatedRoute(at location: CLLocation) {
        guard let progress = liveNavigationProgress(at: location) else {
            _ = speak("Die neue Route ist bereit.", priority: .status)
            return
        }
        updateNextManeuver(using: progress)
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

    /// Lädt Tempolimits für abgetastete Routenpunkte (OpenStreetMap/Overpass).
    /// Fehler hier werden bewusst nicht als `errorMessage` angezeigt, damit ein
    /// überlasteter Overpass-Dienst nicht die restliche Routenplanung blockiert.
    func loadSpeedLimits() async {
        guard !legs.isEmpty else { speedLimitPoints = []; speedLimits = []; return }
        let generation = UUID()
        speedLimitLoadGeneration = generation
        let points = legs.flatMap { sample($0.polyline, maximum: 80) }
        let limits = (try? await DriveAPI.speedLimits(along: points)) ?? []
        guard generation == speedLimitLoadGeneration else { return }
        speedLimitPoints = points
        speedLimits = limits
    }

    /// Aktuelles Tempolimit für den nächstgelegenen abgetasteten Routenpunkt
    /// zur übergebenen Position (z.B. der aktuelle Standort während der Fahrt).
    func currentSpeedLimit(near coordinate: CLLocationCoordinate2D) -> SpeedLimitResult? {
        guard !speedLimitPoints.isEmpty else { return nil }
        let here = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
        var bestIndex = 0
        var bestDistance = Double.greatestFiniteMagnitude
        for (i, point) in speedLimitPoints.enumerated() {
            let dist = here.distance(from: CLLocation(latitude: point.latitude, longitude: point.longitude))
            if dist < bestDistance { bestDistance = dist; bestIndex = i }
        }
        guard bestDistance <= 200 else { return nil }
        return speedLimits[safe: bestIndex]
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
        let routes = try await MKDirections(request: request).calculate().routes
        guard let lock = routeLockStore.activeLock,
              let corridor = lock.corridorPoints, !corridor.isEmpty else { return routes }
        return routes.filter { routeInsideLockedCorridor($0, points: corridor,
                                                         width: lock.corridorWidthMetres) }
    }

    private func buildLongTripPlan(settings: DriveSettings) {
        guard !legs.isEmpty else { longTripPlan = nil; return }
        let mainDistance = totalDistance
        let mainTime = totalTravelTime
        let unlimitedFraction = SpeedScenarioPolicy.unlimitedDistanceFraction(
            points: speedLimitPoints, limits: speedLimits
        )
        let candidates = breakCandidates(along: legs, useMeasuredDetours: true)
        var inputs = [RoutePlanningInput(
            id: settings.avoidTolls ? "toll-avoiding" : "standard",
            title: settings.avoidTolls ? "Maut vermeiden" : "Schnellste Route",
            distanceMetres: mainDistance,
            mapKitExpectedTravelTime: mainTime,
            unlimitedMotorwayFraction: unlimitedFraction,
            typicalUnlimitedSpeedKmh: 130,
            toll: settings.avoidTolls ? researchedAvoidingToll : researchedStandardToll,
            breakCandidates: candidates
        )]
        if let comparisonRoute,
           abs(comparisonRoute.distance - mainDistance) > 100 || abs(comparisonRoute.expectedTravelTime - mainTime) > 60 {
            inputs.append(.init(
                id: settings.avoidTolls ? "standard" : "toll-avoiding",
                title: settings.avoidTolls ? "Schnellste Route" : "Maut vermeiden",
                distanceMetres: comparisonRoute.distance,
                mapKitExpectedTravelTime: comparisonRoute.expectedTravelTime,
                unlimitedMotorwayFraction: 0,
                typicalUnlimitedSpeedKmh: 130,
                toll: settings.avoidTolls ? researchedStandardToll : researchedAvoidingToll,
                breakCandidates: breakCandidates(along: [comparisonRoute])
            ))
        }
        let profile = VehicleProfile(
            baseConsumptionLPer100km: settings.consumptionLPer100km,
            fuelPricePerLitre: settings.fuelPricePerLitre,
            tankCapacityLitres: settings.tankCapacityL,
            initialFuelFraction: min(1, max(0, settings.departureFuelPercent / 100))
        )
        let scenarios = [SpeedScenario.target(settings.targetSpeedKmh)] + (settings.targetSpeedKmh == 200 ? [] : [.target(200)])
        longTripPlan = RouteComparison(fuelModel: .init(), breakPlanner: .init())
            .compare(routes: inputs, scenarios: scenarios, vehicle: profile)
    }

    private func loadTollCost(from start: CLLocationCoordinate2D) async {
        guard let destination else { return }
        let destinationName = destination.placemark.title ?? destination.name ?? destinationText
        let lock = routeLockStore.activeLock
        let visited = Set(lock?.visitedWaypointIDs ?? [])
        let via = lock?.waypoints.filter { $0.required && !visited.contains($0.id) }.map(\.name) ?? []
        let destinationCoordinate = destination.placemark.coordinate
        let baseRouteIdentity = String(format: "%.5f:%.5f", destinationCoordinate.latitude,
                                       destinationCoordinate.longitude) + "|" + via.joined(separator: "|")
        let generation = UUID()
        tollLoadGeneration = generation
        let origin = String(format: "%.4f, %.4f", start.latitude, start.longitude)
        for avoidTolls in [false, true] {
            let routeIdentity = baseRouteIdentity + (avoidTolls ? "|avoid" : "|standard")
            if let cached = TollLookupCachePolicy.reusable(
                tollLookupSnapshots[avoidTolls], routeIdentity: routeIdentity, origin: start
            ) {
                setResearchedToll(cached, avoidTolls: avoidTolls)
                continue
            }
            do {
                let toll = try await DriveAPI.tollCost(
                    origin: origin, destination: destinationName, via: via,
                    avoidTolls: avoidTolls
                )
                guard generation == tollLoadGeneration else { return }
                setResearchedToll(toll, avoidTolls: avoidTolls)
                tollLookupSnapshots[avoidTolls] = .init(
                    routeIdentity: routeIdentity, origin: start, cost: toll, loadedAt: Date()
                )
            } catch {
                guard generation == tollLoadGeneration else { return }
                setResearchedToll(
                    .unknown(reason: "SearXNG-Mautrecherche nicht verfügbar: \(error.localizedDescription)"),
                    avoidTolls: avoidTolls
                )
            }
        }
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
        cacheForOffline()
    }

    private func breakCandidates(along routes: [MKRoute], useMeasuredDetours: Bool = true) -> [BreakCandidate] {
        let routeCoordinates = routes.flatMap { sample($0.polyline, maximum: 160) }
        guard routeCoordinates.count > 1 else { return [] }
        let timeline = routes.map { (distance: $0.distance, travelTime: $0.expectedTravelTime) }
        let fuelCandidates: [BreakCandidate] = stations.compactMap { station -> BreakCandidate? in
            guard let projection = RouteGeometryProgress.nearestProgress(of: station.coordinate, on: routeCoordinates),
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
            guard let projection = RouteGeometryProgress.nearestProgress(of: candidate.coordinate, on: routeCoordinates),
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
        return BreakCandidateSelectionPolicy.shortlist(fuelCandidates + amenities)
    }

    /// Measures only the already shortlisted stops. Six candidates mean at
    /// most twelve directions requests (out and back), independent of the
    /// number of stations returned by providers.
    private func measureBreakCandidateDetours() async {
        let generation = breakCandidateLoadGeneration
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 160) }
        let candidates = breakCandidates(along: legs, useMeasuredDetours: false)
        var measurements: [String: CLLocationDistance] = [:]
        await withTaskGroup(of: (String, CLLocationDistance?).self) { group in
            for candidate in candidates {
                guard let projection = RouteGeometryProgress.nearestProgress(
                    of: candidate.coordinate, on: routeCoordinates
                ) else { continue }
                group.addTask { [weak self] in
                    let item = MKMapItem(placemark: MKPlacemark(coordinate: candidate.coordinate))
                    let distance = await self?.drivingDetour(between: projection.coordinate, and: item)
                    return (candidate.id, distance)
                }
            }
            for await (id, distance) in group {
                if let distance, distance <= 20_000 { measurements[id] = distance }
            }
        }
        guard generation == breakCandidateLoadGeneration else { return }
        measuredBreakDetours = measurements
    }

    /// Finds real rest areas and motorway service locations near the route so
    /// break planning is not limited to petrol stations.
    private func loadBreakAmenities() async {
        guard !legs.isEmpty else { amenityBreakCandidates = []; return }
        let generation = UUID()
        breakCandidateLoadGeneration = generation
        activeAmenitySearches.forEach { $0.cancel() }
        activeAmenitySearches = []
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 180) }
        let searchPoints = evenlySpaced(routeCoordinates, maximum: 4)
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
        await withTaskGroup(of: [MKMapItem].self) { group in
            for search in searches {
                group.addTask {
                    (try? await search.start().mapItems) ?? []
                }
            }
            for await items in group {
                for item in items {
                    let coordinate = item.placemark.coordinate
                    matches["\(item.name ?? "Halt"):\(coordinate.latitude):\(coordinate.longitude)"] = item
                }
            }
        }
        guard generation == breakCandidateLoadGeneration else { return }
        activeAmenitySearches = []
        let routePoints = routeCoordinates.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let routeProgress = RouteGeometryProgress.cumulativeFractions(routeCoordinates)
        guard routePoints.count > 1 else { amenityBreakCandidates = []; return }
        let candidates = matches.values.compactMap { item -> BreakCandidate? in
            let point = CLLocation(latitude: item.placemark.coordinate.latitude,
                                   longitude: item.placemark.coordinate.longitude)
            guard let nearest = routePoints.enumerated().min(by: {
                $0.element.distance(from: point) < $1.element.distance(from: point)
            }) else { return nil }
            let detour = nearest.element.distance(from: point)
            guard detour <= 4_000 else { return nil }
            let coordinate = item.placemark.coordinate
            return .init(id: "amenity-\(coordinate.latitude)-\(coordinate.longitude)",
                         name: item.name ?? "Rastmöglichkeit", coordinate: coordinate,
                         progress: routeProgress[nearest.offset],
                         detourMetres: detour * 2, isOpen: nil)
        }
        let buckets = Dictionary(grouping: candidates) { min(9, Int($0.progress * 10)) }
        amenityBreakCandidates = buckets.keys.sorted().compactMap { bucket in
            buckets[bucket]?.min { $0.detourMetres < $1.detourMetres }
        }
    }

    func loadStations(fuel: FuelKind) async {
        guard !legs.isEmpty else { return }
        let generation = UUID()
        stationLoadGeneration = generation
        // A handful of evenly distributed requests is sufficient. The old
        // 25-km radius at ten route points returned hundreds of duplicates.
        let points = evenlySpaced(legs.flatMap { sample($0.polyline, maximum: 80) }, maximum: 6)
        var unique: [String: FuelStation] = [:]
        await withTaskGroup(of: [FuelStation].self) { group in
            for point in points { group.addTask { (try? await DriveAPI.stations(near: point, fuel: fuel, radiusKm: 8)) ?? [] } }
            for await batch in group { for station in batch { unique[station.id] = station } }
        }
        guard generation == stationLoadGeneration else { return }
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 160) }
        let routePoints = routeCoordinates.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let routeProgress = RouteGeometryProgress.cumulativeFractions(routeCoordinates)
        let nearRoute = unique.values.compactMap { station -> (station: FuelStation, progress: Double,
                                                                corridorDistance: Double)? in
            let point = CLLocation(latitude: station.lat, longitude: station.lon)
            guard let match = routePoints.enumerated().min(by: { $0.element.distance(from: point) < $1.element.distance(from: point) }),
                  match.element.distance(from: point) < 4_000 else { return nil }
            return (station, routeProgress[match.offset], match.element.distance(from: point))
        }
        // Keep at most one strong candidate per route section. This gives the
        // break planner geographic coverage without flooding MapKit with pins.
        let bucketCount = min(12, max(1, routeCoordinates.count))
        let grouped = Dictionary(grouping: nearRoute) { item in
            min(bucketCount - 1, Int(item.progress * Double(bucketCount)))
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

    /// Fügt eine Tankstelle als Zwischenstopp ein (oder entfernt sie erneut,
    /// wenn sie bereits als Zwischenstopp gesetzt ist) und berechnet die
    /// Route neu.
    @discardableResult
    func toggleWaypoint(_ station: FuelStation, from start: CLLocationCoordinate2D,
                        settings: DriveSettings) async -> Bool {
        let previousStations = viaStations
        let previousLock = routeLockStore.activeLock
        if let index = viaStations.firstIndex(where: { $0.id == station.id }) {
            viaStations.remove(at: index)
            routeLockStore.update { lock in
                lock.removeWaypoint(id: station.id)
            }
            activeRouteLock = routeLockStore.activeLock
        } else {
            viaStations.append(station)
            if routeLockStore.activeLock == nil { persistActiveTrip() }
            insertLockedWaypoint(
                id: station.id, name: station.brand.isEmpty ? station.name : station.brand,
                coordinate: station.coordinate
            )
        }
        guard await calculate(from: start, settings: settings) else {
            viaStations = previousStations
            routeLockStore.replace(with: previousLock)
            activeRouteLock = previousLock
            return false
        }
        return true
    }

    func addPlannedBreak(_ plannedBreak: PlannedBreak, from start: CLLocationCoordinate2D, settings: DriveSettings) async {
        guard let candidate = plannedBreak.candidate else { return }
        if let station = stations.first(where: { $0.id == candidate.id }) {
            guard !viaStations.contains(where: { $0.id == station.id }) else { return }
            let previousStations = viaStations
            let previousLock = routeLockStore.activeLock
            viaStations.append(station)
            let progressByID = Dictionary(uniqueKeysWithValues: breakCandidates(along: legs)
                .map { ($0.id, $0.progress) })
            viaStations.sort { lhs, rhs in
                (progressByID[lhs.id] ?? 1) < (progressByID[rhs.id] ?? 1)
            }
            if routeLockStore.activeLock == nil { persistActiveTrip() }
            insertLockedWaypoint(
                id: station.id, name: station.brand.isEmpty ? station.name : station.brand,
                coordinate: station.coordinate
            )
            guard await calculate(from: start, settings: settings) else {
                viaStations = previousStations
                routeLockStore.replace(with: previousLock)
                activeRouteLock = previousLock
                return
            }
        } else {
            let item = MKMapItem(placemark: MKPlacemark(coordinate: candidate.coordinate))
            item.name = candidate.name
            await addRouteStop(item, from: start, settings: settings)
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
