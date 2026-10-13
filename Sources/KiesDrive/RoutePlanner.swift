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
    struct Step: Codable { let instructions: String; let distance: Double }
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
    private var comparisonRoute: MKRoute?
    private var researchedToll: TollCost = .unknown(reason: "Mautrecherche läuft noch.")

    /// Tempolimits entlang der Route, parallel zu `speedLimitPoints` indiziert.
    private var speedLimitPoints: [CLLocationCoordinate2D] = []
    private var speedLimits: [SpeedLimitResult] = []

    private let synthesizer = AVSpeechSynthesizer()
    private var navigationStepCursor = 0
    private var announcedManeuverStages: [String: Set<NavigationAnnouncementStage>] = [:]
    private var offRouteStrikes = 0
    private var lastRerouteAt: Date?
    private var lastAcceptedNavigationLocation: CLLocation?
    private var lastLocationRejectionLoggedAt: Date?
    private var arrivalStrikes = 0
    private var stationLoadGeneration = UUID()
    private var speedLimitLoadGeneration = UUID()
    private var tollLoadGeneration = UUID()
    private var routeCalculationGeneration = UUID()
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
        synthesizer.stopSpeaking(at: .immediate)
        lastAnnouncement = nil
        speedWarning = false
    }

    func setVoiceGuidanceEnabled(_ enabled: Bool) {
        if !enabled { synthesizer.stopSpeaking(at: .immediate) }
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
        if !legs.isEmpty { startNavigation() }
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

    var nextInstruction: String? {
        if let nextManeuverInstruction { return nextManeuverInstruction }
        return legs.lazy
            .flatMap(\.steps)
            .first(where: { !$0.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })?
            .instructions
    }

    func searchDestination(near coordinate: CLLocationCoordinate2D?) async {
        guard destinationText.count > 2 else { suggestions = []; return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = destinationText
        if let coordinate { request.region = .init(center: coordinate, latitudinalMeters: 100_000, longitudinalMeters: 100_000) }
        do { suggestions = try await MKLocalSearch(request: request).start().mapItems }
        catch { errorMessage = "Zielsuche fehlgeschlagen: \(error.localizedDescription)" }
    }

    /// Sucht POIs entlang der bereits berechneten Route statt nur am aktuellen
    /// Standort. Wenige Suchregionen und ein enger Korridor vermeiden Umwege.
    func searchAlongRoute(_ query: String) async {
        guard !legs.isEmpty, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        routeSearchQuery = query
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 180) }
        let searchPoints = evenlySpaced(routeCoordinates, maximum: 5)
        var matches: [String: MKMapItem] = [:]
        await withTaskGroup(of: [MKMapItem].self) { group in
            for point in searchPoints {
                group.addTask {
                    let request = MKLocalSearch.Request()
                    request.naturalLanguageQuery = query
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
        let routePoints = routeCoordinates.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        routeSearchResults = matches.values.compactMap { item -> (MKMapItem, Int, Double)? in
            let point = CLLocation(latitude: item.placemark.coordinate.latitude, longitude: item.placemark.coordinate.longitude)
            guard let nearest = routePoints.enumerated().min(by: {
                $0.element.distance(from: point) < $1.element.distance(from: point)
            }) else { return nil }
            let detour = nearest.element.distance(from: point)
            guard detour <= 5_000 else { return nil }
            return (item, nearest.offset, detour)
        }
        .sorted { $0.1 == $1.1 ? $0.2 < $1.2 : $0.1 < $1.1 }
        .prefix(12).map(\.0)
    }

    func addRouteStop(_ item: MKMapItem, from start: CLLocationCoordinate2D, settings: DriveSettings) async {
        // A user may add a stop while merely previewing a calculated route,
        // before tapping Start. Materialise the lock here so the action never
        // appears to succeed while silently doing nothing.
        if routeLockStore.activeLock == nil { persistActiveTrip() }
        guard var lock = routeLockStore.activeLock else {
            errorMessage = "Zwischenstopp konnte nicht gespeichert werden."
            return
        }
        let coordinate = item.placemark.coordinate
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 240) }
        func progress(_ coordinate: CLLocationCoordinate2D) -> Int {
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return routeCoordinates.enumerated().min(by: {
                CLLocation(latitude: $0.element.latitude, longitude: $0.element.longitude).distance(from: location) <
                CLLocation(latitude: $1.element.latitude, longitude: $1.element.longitude).distance(from: location)
            })?.offset ?? routeCoordinates.count
        }
        let insertionProgress = progress(coordinate)
        let index = lock.waypoints.firstIndex { progress($0.coordinate.clLocationCoordinate) > insertionProgress } ?? lock.waypoints.endIndex
        let inheritedOptions = index == 0 ? lock.defaultOptions : (lock.waypoints[index - 1].optionsAfter ?? lock.defaultOptions)
        lock.waypoints.insert(.init(id: "poi-\(UUID().uuidString)", name: item.name ?? "Zwischenstopp",
                                    coordinate: .init(latitude: coordinate.latitude, longitude: coordinate.longitude),
                                    required: true, optionsAfter: inheritedOptions), at: index)
        routeLockStore.save(lock)
        activeRouteLock = lock
        routeSearchResults = []
        await calculate(from: start, settings: settings)
        if !legs.isEmpty { startNavigation() }
    }

    func calculate(from start: CLLocationCoordinate2D, settings: DriveSettings) async {
        guard let destination else { return }
        let calculationGeneration = UUID()
        routeCalculationGeneration = calculationGeneration
        isLoading = true; errorMessage = nil; stations = []
        let startItem = MKMapItem(placemark: MKPlacemark(coordinate: start))
        do {
            if let existing = routeLockStore.activeLock {
                let passed = existing.passedWaypointIDs(at: .init(latitude: start.latitude, longitude: start.longitude))
                if !passed.isEmpty {
                    routeLockStore.update { lock in
                        var visited = Set(lock.visitedWaypointIDs ?? [])
                        visited.formUnion(passed)
                        lock.visitedWaypointIDs = Array(visited)
                    }
                    activeRouteLock = routeLockStore.activeLock
                }
            }
            let lock = routeLockStore.activeLock
            let visited = Set(lock?.visitedWaypointIDs ?? [])
            let lockedWaypoints = lock?.waypoints.filter { $0.required && !visited.contains($0.id) } ?? []
            if viaStations.isEmpty && lockedWaypoints.isEmpty {
                let routes = try await computeRoutes(from: startItem, to: destination, settings: settings, alternates: true)
                guard calculationGeneration == routeCalculationGeneration else { return }
                alternatives = routes
                legs = routes.first.map { [$0] } ?? []
                // Request the opposite toll preference for an honest route-level
                // distance/time comparison. MapKit exposes no toll price; that
                // remains explicitly unknown until a verified provider responds.
                comparisonRoute = try? await computeRoutes(
                    from: startItem, to: destination, settings: settings,
                    alternates: false, avoidTollsOverride: !settings.avoidTolls
                ).first
                guard calculationGeneration == routeCalculationGeneration else { return }
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
                    guard calculationGeneration == routeCalculationGeneration else { return }
                    newLegs.append(leg)
                }
                legs = newLegs
                alternatives = []
                comparisonRoute = nil
            }
            resetLiveNavigationProgress()
            remainingDistanceMetres = totalDistance
            remainingTravelTime = totalTravelTime
            offRouteStrikes = 0
            cacheForOffline()
            DriveDiagnosticStore.append(.routeCalculated, detail: "\(legs.count) Etappen · \(Int(totalDistance)) m")
            // Die sichtbare Route ist jetzt fertig. Langsame Server-Zusatzdaten
            // duerfen Navigation und UI nicht mehr blockieren.
            isLoading = false
            Task { [weak self] in
                guard let self else { return }
                await self.loadStations(fuel: settings.fuel)
                guard calculationGeneration == self.routeCalculationGeneration else { return }
                await self.loadSpeedLimits()
                guard calculationGeneration == self.routeCalculationGeneration else { return }
                await self.loadTollCost(from: start)
                guard calculationGeneration == self.routeCalculationGeneration else { return }
                self.buildLongTripPlan(settings: settings)
                self.cacheForOffline()
            }
        } catch {
            guard calculationGeneration == routeCalculationGeneration else { return }
            isLoading = false
            errorMessage = "Route konnte nicht berechnet werden: \(error.localizedDescription)"
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
                                 steps: leg.steps.map { .init(instructions: $0.instructions, distance: $0.distance) },
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
        guard isNavigating, !legs.isEmpty else { return }
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
        if let progress = liveNavigationProgress(at: location) {
            updateNextManeuver(using: progress)
            if settings.voiceGuidance { announce(progress, at: location) }
        }
        markReachedWaypoints(at: location, settings: settings)
        checkSpeedLimit(at: location.coordinate, speedMps: location.speed)
        checkForDeviation(from: location, settings: settings)
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
    }

    private func resetLiveNavigationProgress() {
        navigationStepCursor = 0
        announcedManeuverStages = [:]
        offRouteStrikes = 0
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
        offRouteStrikes = 0
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

        // Search forward from the last confirmed segment. A small one-step
        // look-behind tolerates GPS jitter without ever jumping far backwards.
        let lower = max(0, navigationStepCursor - 1)
        let upper = min(steps.count - 1, navigationStepCursor + 12)
        let localRange = lower...upper
        var currentIndex = localRange.min { lhs, rhs in
            Self.distance(from: location.coordinate, to: steps[lhs].step.polyline) <
            Self.distance(from: location.coordinate, to: steps[rhs].step.polyline)
        } ?? navigationStepCursor

        let localDistance = Self.distance(from: location.coordinate, to: steps[currentIndex].step.polyline)
        if localDistance > 300,
           let recovered = steps.indices.min(by: {
               Self.distance(from: location.coordinate, to: steps[$0].step.polyline) <
               Self.distance(from: location.coordinate, to: steps[$1].step.polyline)
           }), recovered >= navigationStepCursor {
            // Handles returning after a long pause or a large location jump.
            currentIndex = recovered
        }
        navigationStepCursor = max(navigationStepCursor, currentIndex)
        currentIndex = navigationStepCursor

        guard let maneuverIndex = steps.indices.dropFirst(currentIndex + 1).first(where: {
            !steps[$0].step.instructions.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }) else {
            nextManeuverInstruction = "Ziel erreicht"
            nextManeuverDistance = 0
            upcomingManeuverInstructions = []
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
        return LiveNavigationProgress(
            maneuver: steps[maneuverIndex], maneuverFlatIndex: maneuverIndex,
            distance: max(0, distance),
            totalRemainingDistance: max(0, Self.remainingDistance(from: location.coordinate,
                                                                  on: steps[currentIndex].step.polyline)
                + steps.dropFirst(currentIndex + 1).reduce(0) { $0 + $1.step.distance }),
            upcomingInstructions: Array(upcoming.prefix(5))
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

    private func checkSpeedLimit(at coordinate: CLLocationCoordinate2D, speedMps: Double) {
        guard speedMps >= 0, let limit = currentSpeedLimit(near: coordinate), let maxspeed = limit.maxspeed else {
            speedWarning = false
            return
        }
        let speedKmh = speedMps * 3.6
        // 5 km/h Toleranz für GPS-Ungenauigkeit / Tacho-Rundung.
        speedWarning = speedKmh > Double(maxspeed) + 5
    }

    private func announce(_ progress: LiveNavigationProgress, at location: CLLocation) {
        let speedKmh = max(0, location.speed) * 3.6
        guard let stage = NavigationAnnouncementStage.stage(distance: progress.distance, speedKmh: speedKmh) else { return }
        let key = "\(progress.maneuver.legIndex):\(progress.maneuver.stepIndex):\(progress.maneuver.step.instructions)"
        let completed = announcedManeuverStages[key] ?? []
        guard !completed.contains(stage) else { return }

        // If a sparse GPS update lands directly in the immediate zone, mark
        // earlier stages complete as well so they cannot be spoken afterwards.
        announcedManeuverStages[key] = Set(NavigationAnnouncementStage.allCases.filter { $0.rawValue <= stage.rawValue })
        let spokenDistance: CLLocationDistance = stage == .now ? min(progress.distance, 35) : progress.distance
        speak(NavigationSpeechFormatter.spokenText(progress.maneuver.step.instructions, distance: spokenDistance))
        lastAnnouncement = progress.maneuver.step.instructions
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
        if nearest > 150 {
            offRouteStrikes += 1
        } else {
            offRouteStrikes = 0
        }
        guard offRouteStrikes >= 8 else { return }
        offRouteStrikes = 0
        lastRerouteAt = Date()
        DriveDiagnosticStore.append(.rerouteRequested, detail: "Abweichung \(Int(nearest)) m")
        Task {
            isRecalculating = true
            lastAnnouncement = "Route wird neu berechnet …"
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
        let knownLimits = speedLimits.filter { $0.maxspeed != nil || $0.unlimited }
        let unlimitedFraction = knownLimits.isEmpty ? 0 : Double(knownLimits.filter(\.unlimited).count) / Double(knownLimits.count)
        let candidates = breakCandidates(totalDistance: mainDistance)
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
                breakCandidates: []
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
        do {
            let toll = try await DriveAPI.tollCost(origin: origin, destination: destinationName)
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

    private func breakCandidates(totalDistance: Double) -> [BreakCandidate] {
        let routeCoordinates = legs.flatMap { sample($0.polyline, maximum: 160) }
        guard routeCoordinates.count > 1 else { return [] }
        return stations.compactMap { station in
            let location = CLLocation(latitude: station.lat, longitude: station.lon)
            guard let match = routeCoordinates.enumerated().min(by: {
                location.distance(from: CLLocation(latitude: $0.element.latitude, longitude: $0.element.longitude)) <
                location.distance(from: CLLocation(latitude: $1.element.latitude, longitude: $1.element.longitude))
            }) else { return nil }
            let detour = location.distance(from: CLLocation(latitude: match.element.latitude, longitude: match.element.longitude))
            return BreakCandidate(
                id: station.id, name: station.brand.isEmpty ? station.name : station.brand,
                coordinate: station.coordinate,
                progress: Double(match.offset) / Double(routeCoordinates.count - 1),
                detourMetres: detour * 2, isOpen: station.open != false
            )
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
        let nearRoute = unique.values.compactMap { station -> (FuelStation, Int)? in
            let point = CLLocation(latitude: station.lat, longitude: station.lon)
            guard let match = routePoints.enumerated().min(by: { $0.element.distance(from: point) < $1.element.distance(from: point) }),
                  match.element.distance(from: point) < 4_000 else { return nil }
            return (station, match.offset)
        }
        // Keep at most one strong candidate per route section. This gives the
        // break planner geographic coverage without flooding MapKit with pins.
        let bucketCount = min(12, max(1, routeCoordinates.count))
        let grouped = Dictionary(grouping: nearRoute) { item in
            min(bucketCount - 1, item.1 * bucketCount / max(1, routeCoordinates.count))
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
    func toggleWaypoint(_ station: FuelStation, from start: CLLocationCoordinate2D, settings: DriveSettings) async {
        if let index = viaStations.firstIndex(where: { $0.id == station.id }) {
            viaStations.remove(at: index)
        } else {
            viaStations.append(station)
        }
        await calculate(from: start, settings: settings)
    }

    func addPlannedBreak(_ plannedBreak: PlannedBreak, from start: CLLocationCoordinate2D, settings: DriveSettings) async {
        guard let candidate = plannedBreak.candidate,
              let station = stations.first(where: { $0.id == candidate.id }),
              !viaStations.contains(where: { $0.id == station.id }) else { return }
        viaStations.append(station)
        let progressByID = Dictionary(uniqueKeysWithValues: breakCandidates(totalDistance: totalDistance).map { ($0.id, $0.progress) })
        viaStations.sort { lhs, rhs in
            (progressByID[lhs.id] ?? 1) < (progressByID[rhs.id] ?? 1)
        }
        await calculate(from: start, settings: settings)
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
        let anchors = points.map { CLLocation(latitude: $0.latitude, longitude: $0.longitude) }
        let routePoints = sample(route.polyline, maximum: 100)
        guard !anchors.isEmpty, !routePoints.isEmpty else { return false }
        // Einzelne Anschlussstellen duerfen den Korridor leicht verlassen;
        // mindestens 90 % der Neuberechnung muessen innerhalb bleiben.
        let inside = routePoints.filter { coordinate in
            let location = CLLocation(latitude: coordinate.latitude, longitude: coordinate.longitude)
            return anchors.contains { $0.distance(from: location) <= width }
        }.count
        return Double(inside) / Double(routePoints.count) >= 0.9
    }
}
