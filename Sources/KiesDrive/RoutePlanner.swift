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
    let legs: [Leg]
    let stations: [FuelStation]
    let savedAt: Date
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
    @Published var routeSearchResults: [MKMapItem] = []
    @Published var nextManeuverInstruction: String?
    @Published var nextManeuverDistance: CLLocationDistance?
    @Published var upcomingManeuverInstructions: [String] = []
    @Published var remainingDistanceMetres: CLLocationDistance = 0
    @Published var remainingTravelTime: TimeInterval = 0
    @Published var hasArrived = false
    @Published private(set) var isUsingOfflineGuidance = false
    private var comparisonRoute: MKRoute?
    private var researchedToll: TollCost = .unknown(reason: "Mautrecherche läuft noch.")
    private var amenityBreakCandidates: [BreakCandidate] = []

    /// Tempolimits entlang der Route, parallel zu `speedLimitPoints` indiziert.
    private var speedLimitPoints: [CLLocationCoordinate2D] = []
    private var speedLimits: [SpeedLimitResult] = []

    private let synthesizer = AVSpeechSynthesizer()
    private var navigationStepCursor = 0
    private var announcedManeuverStages: [String: Set<NavigationAnnouncementStage>] = [:]
    private var diagnosticManeuverKey: String?
    private var diagnosticManeuverInstruction: String?
    private var offRouteSince: Date?
    private var previousOffRouteDistance: CLLocationDistance?
    private var lastRerouteAt: Date?
    private var lastAcceptedNavigationLocation: CLLocation?
    private var lastLocationRejectionLoggedAt: Date?
    private var lastOfflineRecoveryAttempt: Date?
    private var arrivalStrikes = 0
    private var stationLoadGeneration = UUID()
    private var breakCandidateLoadGeneration = UUID()
    private var speedLimitLoadGeneration = UUID()
    private var tollLoadGeneration = UUID()
    private var routeCalculationGeneration = UUID()
    private var destinationSearchGeneration = UUID()
    private var routeSearchGeneration = UUID()
    private var didAttemptAutomaticRestore = false
    private static let cacheKey = "drive.offlineRoute"
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
        remainingDistanceMetres = totalDistance
        remainingTravelTime = totalTravelTime
        stations = []
        cacheForOffline()
        buildLongTripPlan(settings: settings)
        Task { [weak self] in
            guard let self else { return }
            await self.loadStations(fuel: settings.fuel)
            await self.loadSpeedLimits()
            self.buildLongTripPlan(settings: settings)
            self.cacheForOffline()
        }
    }

    func startNavigation() {
        guard !legs.isEmpty else { return }
        isUsingOfflineGuidance = false
        persistActiveTrip()
        isNavigating = true
        hasArrived = false
        resetLiveNavigationProgress()
        lastAnnouncement = nextInstruction ?? "Route gestartet"
        let opening = lastAnnouncement.map { "Route gestartet. \(NavigationSpeechFormatter.spokenText($0))" }
            ?? "Route gestartet."
        speak(opening)
        DriveDiagnosticStore.append(.navigationStarted, detail: destination?.name ?? destinationText)
    }

    func stopNavigation() {
        isNavigating = false
        isUsingOfflineGuidance = false
        synthesizer.stopSpeaking(at: .immediate)
        lastAnnouncement = nil
        speedWarning = false
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
        guard !didAttemptAutomaticRestore else { return }
        didAttemptAutomaticRestore = true
        guard let lock = routeLockStore.activeLock, lock.isActive else { return }
        activeRouteLock = lock
        destinationText = lock.destinationName
        let item = MKMapItem(placemark: MKPlacemark(coordinate: lock.destination.clLocationCoordinate))
        item.name = lock.destinationName
        destination = item
        await calculate(from: current, settings: settings)
        if !legs.isEmpty {
            startNavigation()
        } else {
            startOfflineGuidanceIfAvailable()
        }
    }

    func restoreActiveTrip(from current: CLLocationCoordinate2D, settings: DriveSettings) async {
        didAttemptAutomaticRestore = false
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
        didAttemptAutomaticRestore = false
        stopNavigation()
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
        didAttemptAutomaticRestore = false
        stopNavigation()
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
        startNavigation()
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
        guard query.count > 2 else { suggestions = []; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coordinate { request.region = .init(center: coordinate, latitudinalMeters: 100_000, longitudinalMeters: 100_000) }
        do {
            let items = try await MKLocalSearch(request: request).start().mapItems
            guard generation == destinationSearchGeneration,
                  destinationText.trimmingCharacters(in: .whitespacesAndNewlines) == query else { return }
            suggestions = items
        } catch {
            guard generation == destinationSearchGeneration else { return }
            errorMessage = "Zielsuche fehlgeschlagen: \(error.localizedDescription)"
        }
    }

    /// Sucht POIs entlang der bereits berechneten Route statt nur am aktuellen
    /// Standort. Wenige Suchregionen und ein enger Korridor vermeiden Umwege.
    func searchAlongRoute(_ query: String) async {
        let cleanQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let generation = UUID()
        routeSearchGeneration = generation
        guard !legs.isEmpty, !cleanQuery.isEmpty else {
            routeSearchQuery = cleanQuery
            routeSearchResults = []
            return
        }
        let routeGeneration = routeCalculationGeneration
        routeSearchQuery = cleanQuery
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 180) }
        let searchPoints = evenlySpaced(routeCoordinates, maximum: 5)
        var matches: [String: MKMapItem] = [:]
        await withTaskGroup(of: [MKMapItem].self) { group in
            for point in searchPoints {
                group.addTask {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = cleanQuery
                    request.region = .init(center: point, latitudinalMeters: 120_000, longitudinalMeters: 120_000)
                    return (try? await MKLocalSearch(request: request).start().mapItems) ?? []
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
        let routePoints = routeCoordinates.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let currentRouteIndex: Int = {
            guard let location = LocationService.shared.location,
                  let nearest = routePoints.enumerated().min(by: {
                      $0.element.distance(from: location) < $1.element.distance(from: location)
                  }), nearest.element.distance(from: location) <= 5_000 else { return 0 }
            return nearest.offset
        }()
        routeSearchResults = matches.values.compactMap { item -> (MKMapItem, Int, Double)? in
            let point = CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
            guard let nearest = routePoints.enumerated().min(by: {
                $0.element.distance(from: point) < $1.element.distance(from: point)
            }) else { return nil }
            let detour = nearest.element.distance(from: point)
            guard detour <= 5_000,
                  RouteSearchPolicy.isAhead(candidateIndex: nearest.offset,
                                            currentIndex: currentRouteIndex,
                                            routePointCount: routePoints.count) else { return nil }
            return (item, nearest.offset, detour)
        }
        .sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }
        .prefix(12).map(\.0)
    }

    @discardableResult
    func addRouteStop(_ item: MKMapItem, from start: CLLocationCoordinate2D,
                      settings: DriveSettings) async -> Bool {
        let previousLock = routeLockStore.activeLock
        // A user may add a stop while merely previewing a calculated route,
        // before tapping Start. Materialise the lock here so the action never
        // appears to succeed while silently doing nothing.
        if routeLockStore.activeLock == nil { persistActiveTrip() }
        guard routeLockStore.activeLock != nil else {
            errorMessage = "Zwischenstopp konnte nicht gespeichert werden."
            return false
        }
        let coordinate = item.placemark.coordinate
        insertLockedWaypoint(id: "poi-\(UUID().uuidString)", name: item.name ?? "Zwischenstopp",
                             coordinate: coordinate)
        routeSearchResults = []
        let succeeded = await calculate(from: start, settings: settings)
        guard succeeded else {
            routeLockStore.replace(with: previousLock)
            activeRouteLock = previousLock
            return false
        }
        startNavigation()
        return true
    }

    /// Every user-selected stop is written into the persistent trip lock. This
    /// avoids the former split-brain state where fuel stops lived only in
    /// `viaStations` and disappeared whenever mandatory route points existed.
    private func insertLockedWaypoint(id: String, name: String, coordinate: CLLocationCoordinate2D) {
        guard var lock = routeLockStore.activeLock,
              !lock.waypoints.contains(where: { $0.id == id }) else { return }
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 240) }
        func progress(_ coordinate: CLLocationCoordinate2D) -> Int {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return routeCoordinates.enumerated().min(by: {
                CLLocation(latitude: $0.element.latitude, longitude: $0.element.longitude).distance(from: location) <
                CLLocation(latitude: $1.element.latitude, longitude: $1.element.longitude).distance(from: location)
            })?.offset ?? routeCoordinates.count
        }
        lock.insertWaypoint(.init(
            id: id, name: name,
            coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
            required: true, optionsAfter: nil
        ), progress: { progress($0.clLocationCoordinate) })
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
        routeSearchResults = []
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
            resetLiveNavigationProgress()
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
        if let data = try? JSONEncoder().encode(cached) { UserDefaults.standard.set(data, forKey: Self.cacheKey) }
    }

    private static func loadCache() -> CachedRoute? {
        guard let data = UserDefaults.standard.data(forKey: Self.cacheKey) else { return nil }
        return try? JSONDecoder().decode(CachedRoute.self, from: data)
    }

    /// Löscht die zwischengespeicherte Offline-Route (z.B. wenn sie veraltet ist).
    func clearOfflineCache() {
        offlineRoute = nil
        UserDefaults.standard.removeObject(forKey: Self.cacheKey)
    }

    // MARK: - Navigation live: Ansagen, Tempowarnung, automatische Neuberechnung

    /// Wird laufend mit der aktuellen Position während der Fahrt aufgerufen.
    /// Kümmert sich um drei Dinge: nächste Fahranweisung ansagen, Tempolimit-
    /// Überschreitung erkennen und bei Abweichung von der Route automatisch
    /// neu berechnen.
    func updateProgress(at location: CLLocation, settings: DriveSettings) {
        guard isNavigating, !legs.isEmpty || isUsingOfflineGuidance else { return }
        guard NavigationLocationPolicy.accepts(location, after: lastAcceptedNavigationLocation) else {
            if lastLocationRejectionLoggedAt.map({ Date().timeIntervalSince($0) >= 60 }) ?? true {
                lastLocationRejectionLoggedAt = Date()
                DriveDiagnosticStore.append(.locationRejected,
                                            detail: "Genauigkeit \(Int(location.horizontalAccuracy)) m")
            }
            return
        }
        lastAcceptedNavigationLocation = location
        if detectArrival(at: location, settings: settings) { return }
        if isUsingOfflineGuidance {
            updateOfflineProgress(at: location, settings: settings)
        } else if let progress = liveNavigationProgress(at: location) {
            updateNextManeuver(using: progress)
            if settings.voiceGuidance { announce(progress, at: location) }
        }
        markReachedWaypoints(at: location, settings: settings)
        if !isUsingOfflineGuidance {
            checkSpeedLimit(at: location.coordinate,
                            speedMps: NavigationMotionPolicy.reliableSpeed(for: location))
            checkForDeviation(from: location, settings: settings)
        }
    }

    @discardableResult
    private func startOfflineGuidanceIfAvailable() -> Bool {
        guard legs.isEmpty, let cache = offlineRoute,
              cache.destinationName.localizedCaseInsensitiveCompare(destination?.name ?? destinationText) == .orderedSame,
              cache.legs.flatMap(\.steps).contains(where: { ($0.coordinates?.count ?? 0) > 1 }) else {
            return false
        }
        resetLiveNavigationProgress()
        errorMessage = nil
        isUsingOfflineGuidance = true
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

    private func updateOfflineProgress(at location: CLLocation, settings: DriveSettings) {
        guard let cache = offlineRoute else { return }
        let steps = cache.legs.flatMap(\.steps).compactMap { step -> OfflineGuidanceStep? in
            guard let coordinates = step.coordinates, coordinates.count > 1 else { return nil }
            return .init(instruction: step.instructions, distance: step.distance,
                         coordinates: coordinates.map(\.clLocationCoordinate))
        }
        guard let progress = OfflineGuidanceEngine.progress(
            at: location.coordinate, currentIndex: navigationStepCursor, steps: steps,
            transitionRadius: max(8, location.horizontalAccuracy * 1.5)
        ) else { return }
        navigationStepCursor = progress.currentStepIndex
        nextManeuverInstruction = progress.instruction
        nextManeuverDistance = progress.distanceToManeuver
        upcomingManeuverInstructions = progress.upcomingInstructions
        remainingDistanceMetres = progress.remainingDistance
        let cachedDistance = cache.legs.reduce(0) { $0 + $1.distance }
        let cachedTime = cache.legs.reduce(0) { $0 + $1.travelTime }
        remainingTravelTime = progress.remainingDistance / max(cachedDistance / max(cachedTime, 1), 1)

        if OfflineRouteRecoveryPolicy.shouldAttempt(lastAttempt: lastOfflineRecoveryAttempt) {
            lastOfflineRecoveryAttempt = Date()
            Task { [weak self] in
                guard let self, self.isUsingOfflineGuidance, self.isNavigating else { return }
                await self.calculate(from: location.coordinate, settings: settings, showLoading: false)
            }
        }

        guard settings.voiceGuidance else { return }
        let key = "offline:\(progress.maneuverStepIndex):\(progress.instruction)"
        recordManeuverTransition(key: key, instruction: progress.instruction)
        guard
              let stage = NavigationAnnouncementStage.stage(
                distance: progress.distanceToManeuver,
                speedKmh: (NavigationMotionPolicy.reliableSpeed(for: location) ?? 0) * 3.6
              ) else { return }
        let completed = announcedManeuverStages[key] ?? []
        guard !completed.contains(stage) else { return }
        announcedManeuverStages[key] = Set(NavigationAnnouncementStage.allCases.filter { $0.rawValue <= stage.rawValue })
        let spokenDistance = stage == .now ? min(progress.distanceToManeuver, 35) : progress.distanceToManeuver
        let following = progress.upcomingInstructions.dropFirst().first
        let speech = stage == .now
            ? NavigationSpeechFormatter.spokenText(
                progress.instruction, distance: spokenDistance,
                then: following, followingDistance: progress.followingManeuverDistance
            )
            : NavigationSpeechFormatter.spokenText(progress.instruction, distance: spokenDistance)
        speak(speech)
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
        if settings.voiceGuidance { speak("Du hast dein Ziel erreicht.") }
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
                remainingOnStep: Self.remainingDistance(from: location.coordinate, on: $0.step.polyline)
            )
        }
        let transitionRadius = max(8, location.horizontalAccuracy * 1.5)
        navigationStepCursor = NavigationStepSelectionPolicy.selectedIndex(
            current: min(navigationStepCursor, steps.count - 1), metrics: metrics,
            transitionRadius: transitionRadius
        )
        let currentIndex = navigationStepCursor

        let routeRemaining = max(0, Self.remainingDistance(from: location.coordinate,
                                                            on: steps[currentIndex].step.polyline)
            + steps.dropFirst(currentIndex + 1).reduce(0) { $0 + $1.step.distance })

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
            let averageMetresPerSecond = totalDistance / max(totalTravelTime, 1)
            remainingTravelTime = routeRemaining / max(averageMetresPerSecond, 1)
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
        let averageMetresPerSecond = totalDistance / max(totalTravelTime, 1)
        remainingTravelTime = progress.totalRemainingDistance / max(averageMetresPerSecond, 1)
    }

    private func markReachedWaypoints(at location: CLLocation, settings: DriveSettings) {
        guard let lock = routeLockStore.activeLock else { return }
        let visited = Set(lock.visitedWaypointIDs ?? [])
        guard let reached = lock.waypoints.first(where: {
            !visited.contains($0.id) && location.distance(from: CLLocation(
                latitude: $0.coordinate.latitude, longitude: $0.coordinate.longitude)) <= 250
        }) else { return }
        routeLockStore.update { current in
            var ids = current.visitedWaypointIDs ?? []
            if !ids.contains(reached.id) { ids.append(reached.id) }
            current.visitedWaypointIDs = ids
        }
        activeRouteLock = routeLockStore.activeLock
        Task { await calculate(from: location.coordinate, settings: settings) }
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

    private func announce(_ progress: LiveNavigationProgress, at location: CLLocation) {
        let speedKmh = (NavigationMotionPolicy.reliableSpeed(for: location) ?? 0) * 3.6
        let key = "\(progress.maneuver.legIndex):\(progress.maneuver.stepIndex):\(progress.maneuver.step.instructions)"
        recordManeuverTransition(key: key, instruction: progress.maneuver.step.instructions)
        guard let stage = NavigationAnnouncementStage.stage(distance: progress.distance, speedKmh: speedKmh) else { return }
        let completed = announcedManeuverStages[key] ?? []
        guard !completed.contains(stage) else { return }

        // If a sparse GPS update lands directly in the immediate zone, mark
        // earlier stages complete as well so they cannot be spoken afterwards.
        announcedManeuverStages[key] = Set(NavigationAnnouncementStage.allCases.filter { $0.rawValue <= stage.rawValue })
        let spokenDistance: CLLocationDistance = stage == .now ? min(progress.distance, 35) : progress.distance
        let following = progress.upcomingInstructions.dropFirst().first
        let speech = stage == .now
            ? NavigationSpeechFormatter.spokenText(
                progress.maneuver.step.instructions, distance: spokenDistance,
                then: following, followingDistance: progress.followingManeuverDistance
            )
            : NavigationSpeechFormatter.spokenText(progress.maneuver.step.instructions, distance: spokenDistance)
        speak(speech)
        lastAnnouncement = progress.maneuver.step.instructions
        DriveDiagnosticStore.append(.maneuverAnnounced,
                                    detail: "\(stage) · \(Int(progress.distance)) m · \(progress.maneuver.step.instructions)")
    }

    private func recordManeuverTransition(key: String, instruction: String) {
        guard diagnosticManeuverKey != key else { return }
        if let previous = diagnosticManeuverKey,
           ManeuverDiagnosticPolicy.missedFinalCue(stages: announcedManeuverStages[previous] ?? []) {
            DriveDiagnosticStore.append(.maneuverFinalCueMissed,
                                        detail: diagnosticManeuverInstruction ?? "Unbekanntes Manöver")
        }
        diagnosticManeuverKey = key
        diagnosticManeuverInstruction = instruction
    }

    private func speak(_ text: String) {
        guard !text.isEmpty else { return }
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
        synthesizer.speak(utterance)
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
        if let lastRerouteAt, Date().timeIntervalSince(lastRerouteAt) < 45 { return }
        let nearest = legs.map { Self.distance(from: location.coordinate, to: $0.polyline) }.min()
            ?? .greatestFiniteMagnitude
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
        if offRouteSince == nil { offRouteSince = now }
        guard let offRouteSince,
              now.timeIntervalSince(offRouteSince) >= NavigationDeviationPolicy.confirmationDuration(
                speedMetresPerSecond: NavigationMotionPolicy.reliableSpeed(for: location) ?? 0
              ) else { return }
        resetDeviationTracking()
        lastRerouteAt = Date()
        DriveDiagnosticStore.append(.rerouteRequested, detail: "Abweichung \(Int(nearest)) m")
        Task {
            isRecalculating = true
            if settings.voiceGuidance { speak("Die Route wird neu berechnet.") }
            await calculate(from: location.coordinate, settings: settings)
            if let errorMessage {
                DriveDiagnosticStore.append(.rerouteFailed, detail: errorMessage)
            } else {
                DriveDiagnosticStore.append(.rerouteSucceeded, detail: "\(legs.count) Etappen")
            }
            isRecalculating = false
        }
    }

    private func resetDeviationTracking(keepingDistance distance: CLLocationDistance? = nil) {
        offRouteSince = nil
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
        let candidates = breakCandidates(along: legs)
        var inputs = [RoutePlanningInput(
            id: settings.avoidTolls ? "toll-avoiding" : "standard",
            title: settings.avoidTolls ? "Maut vermeiden" : "Schnellste Route",
            distanceMetres: mainDistance,
            mapKitExpectedTravelTime: mainTime,
            unlimitedMotorwayFraction: unlimitedFraction,
            typicalUnlimitedSpeedKmh: 130,
            toll: settings.avoidTolls ? .unknown(reason: "Mautvermeidung gewählt; Restmaut wird nicht als null angenommen.") : researchedToll,
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
                toll: settings.avoidTolls ? researchedToll : .unknown(reason: "Mautvermeidung gewählt; Restmaut wird nicht als null angenommen."),
                breakCandidates: breakCandidates(along: [comparisonRoute])
            ))
        }
        let profile = VehicleProfile(
            baseConsumptionLPer100km: settings.consumptionLPer100km,
            fuelPricePerLitre: settings.fuelPricePerLitre,
            tankCapacityLitres: settings.tankCapacityL
        )
        let scenarios = [SpeedScenario.target(settings.targetSpeedKmh)] + (settings.targetSpeedKmh == 200 ? [] : [.target(200)])
        longTripPlan = RouteComparison(fuelModel: .init(), breakPlanner: .init())
            .compare(routes: inputs, scenarios: scenarios, vehicle: profile)
    }

    private func loadTollCost(from start: CLLocationCoordinate2D) async {
        guard let destination else { return }
        let generation = UUID()
        tollLoadGeneration = generation
        let origin = String(format: "%.4f, %.4f", start.latitude, start.longitude)
        let destinationName = destination.placemark.title ?? destination.name ?? destinationText
        let via = routeLockStore.activeLock?.waypoints.filter(\.required).map(\.name) ?? []
        do {
            let toll = try await DriveAPI.tollCost(origin: origin, destination: destinationName, via: via)
            guard generation == tollLoadGeneration else { return }
            researchedToll = toll
        } catch {
            guard generation == tollLoadGeneration else { return }
            researchedToll = .unknown(reason: "SearXNG-Mautrecherche nicht verfügbar: \(error.localizedDescription)")
        }
    }

    /// Recomputes scenario numbers from the already loaded route when vehicle
    /// or target-speed settings change; no network request is required.
    func refreshLongTripPlan(settings: DriveSettings) {
        buildLongTripPlan(settings: settings)
    }

    private func breakCandidates(along routes: [MKRoute]) -> [BreakCandidate] {
        let routeCoordinates = routes.flatMap { sample($0.polyline, maximum: 160) }
        guard routeCoordinates.count > 1 else { return [] }
        let fuelCandidates: [BreakCandidate] = stations.compactMap { station -> BreakCandidate? in
            guard let projection = RouteGeometryProgress.nearestProgress(of: station.coordinate, on: routeCoordinates),
                  projection.distance <= 4_000 else { return nil }
            return BreakCandidateFactory.fuelStation(
                station, progress: projection.progress, detourMetres: projection.distance * 2
            )
        }
        let amenities = amenityBreakCandidates.compactMap { candidate -> BreakCandidate? in
            guard let projection = RouteGeometryProgress.nearestProgress(of: candidate.coordinate, on: routeCoordinates),
                  projection.distance <= 4_000 else { return nil }
            return .init(id: candidate.id, name: candidate.name, coordinate: candidate.coordinate,
                         progress: projection.progress, detourMetres: projection.distance * 2,
                         isOpen: candidate.isOpen, supportsFuel: candidate.supportsFuel)
        }
        return (fuelCandidates + amenities)
            .reduce(into: [String: BreakCandidate]()) { result, candidate in result[candidate.id] = candidate }
            .values.sorted { $0.progress < $1.progress }
    }

    /// Finds real rest areas and motorway service locations near the route so
    /// break planning is not limited to petrol stations.
    private func loadBreakAmenities() async {
        guard !legs.isEmpty else { amenityBreakCandidates = []; return }
        let generation = UUID()
        breakCandidateLoadGeneration = generation
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 180) }
        let searchPoints = evenlySpaced(routeCoordinates, maximum: 4)
        var matches: [String: MKMapItem] = [:]
        await withTaskGroup(of: [MKMapItem].self) { group in
            for point in searchPoints {
                for query in ["Raststätte Autohof", "Rastplatz"] {
                    group.addTask {
                        let request = MKLocalSearch.Request()
                        request.naturalLanguageQuery = query
                        request.region = .init(center: point, latitudinalMeters: 90_000,
                                               longitudinalMeters: 90_000)
                        return (try? await MKLocalSearch(request: request).start().mapItems) ?? []
                    }
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
        let nearRoute = unique.values.compactMap { station -> (FuelStation, Int, Double)? in
            let point = CLLocation(latitude: station.lat, longitude: station.lon)
            guard let match = routePoints.enumerated().min(by: { $0.element.distance(from: point) < $1.element.distance(from: point) }),
                  match.element.distance(from: point) < 4_000 else { return nil }
            return (station, match.offset, routeProgress[match.offset])
        }
        // Keep at most one strong candidate per route section. This gives the
        // break planner geographic coverage without flooding MapKit with pins.
        let bucketCount = min(12, max(1, routeCoordinates.count))
        let grouped = Dictionary(grouping: nearRoute) { item in
            min(bucketCount - 1, Int(item.2 * Double(bucketCount)))
        }
        stations = grouped.keys.sorted().compactMap { bucket in
            grouped[bucket]?.min {
                if $0.0.open != $1.0.open { return $0.0.open != false }
                return $0.0.price == $1.0.price ? $0.0.distanceKm < $1.0.distanceKm : $0.0.price < $1.0.price
            }?.0
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
        let stride = max(1, polyline.pointCount / maximum)
        return Swift.stride(from: 0, to: polyline.pointCount, by: stride).map { coordinates[$0] }
    }

    private func evenlySpaced(_ points: [CLLocationCoordinate2D], maximum: Int) -> [CLLocationCoordinate2D] {
        guard points.count > maximum, maximum > 1 else { return points }
        return (0..<maximum).map { index in
            points[index * (points.count - 1) / (maximum - 1)]
        }
    }

    private func routeInsideLockedCorridor(_ route: MKRoute, points: [DriveCoordinate], width: Double) -> Bool {
        let routePoints = sample(route.polyline, maximum: 100)
        // Einzelne Anschlussstellen duerfen den Korridor leicht verlassen;
        // mindestens 90 % der Neuberechnung muessen innerhalb bleiben.
        return RouteCorridorPolicy.contains(route: routePoints, corridor: points,
                                            widthMetres: width, requiredFraction: 0.9)
    }
}
