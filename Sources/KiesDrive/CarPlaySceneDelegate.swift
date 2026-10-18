#if os(iOS)
import CarPlay
import Combine
import MapKit
import UIKit

/// Native CarPlay navigation surface. Navigation remains local in Kies Drive;
/// CarPlay is only another presentation and control surface for the shared trip.
@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate, CPMapTemplateDelegate,
                                  CPSearchTemplateDelegate {
    private enum CameraMode { case follow, overview, free }
    private enum OneShotSearchOutcome {
        case results([MKMapItem])
        case failed
        case timedOut
    }
    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mapView: MKMapView?
    private var mapTemplate: CPMapTemplate?
    private var audioMapButton: CPMapButton?
    private var navigationSession: CPNavigationSession?
    private var activeTrip: CPTrip?
    private var activeTripDestination: CLLocationCoordinate2D?
    private var cameraMode: CameraMode = .follow
    private var lastReliableCourse: CLLocationDirection?
    private var lastCameraUpdateAt: Date?
    private var carPlaySearchResults: [ObjectIdentifier: MKMapItem] = [:]
    private var carPlaySearchGeneration = UUID()
    private var activeCarPlaySearch: MKLocalSearch?
    private var hasShownLocationAccessAlert = false
    private var routeRestoreInProgress = false
    private var hasShownRouteRestoreAlert = false
    private var cancellables: Set<AnyCancellable> = []

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController, to window: CPWindow) {
        connect(interfaceController: interfaceController, window: window)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didConnect interfaceController: CPInterfaceController) {
        connect(interfaceController: interfaceController, window: nil)
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController, from window: CPWindow) {
        disconnect()
    }

    func templateApplicationScene(_ scene: CPTemplateApplicationScene, didDisconnectInterfaceController interfaceController: CPInterfaceController) {
        disconnect()
    }

    private func connect(interfaceController: CPInterfaceController, window: CPWindow?) {
        self.interfaceController = interfaceController
        carWindow = window
        LocationService.shared.setNavigationActive(RoutePlanner.shared.isNavigating)
        LocationService.shared.start()

        if let window {
            let controller = UIViewController()
            let map = MKMapView(frame: .zero)
            map.translatesAutoresizingMaskIntoConstraints = false
            map.showsUserLocation = true
            map.userTrackingMode = .followWithHeading
            map.delegate = self
            controller.view.addSubview(map)
            NSLayoutConstraint.activate([
                map.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
                map.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
                map.topAnchor.constraint(equalTo: controller.view.topAnchor),
                map.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor)
            ])
            window.rootViewController = controller
            window.isHidden = false
            mapView = map
        }

        let template = CPMapTemplate()
        template.mapDelegate = self
        template.automaticallyHidesNavigationBar = true
        template.mapButtons = makeMapButtons()
        mapTemplate = template
        interfaceController.setRootTemplate(template, animated: false, completion: nil)
        observeDriveState()
        redrawRoute()
        restoreLockedTripIfNeeded()
    }

    private func disconnect() {
        interfaceController = nil
        carWindow = nil
        mapView = nil
        mapTemplate = nil
        audioMapButton = nil
        navigationSession = nil
        activeTrip = nil
        activeTripDestination = nil
        cancellables.removeAll()
        activeCarPlaySearch?.cancel()
        activeCarPlaySearch = nil
        carPlaySearchResults = [:]
        hasShownLocationAccessAlert = false
        routeRestoreInProgress = false
        hasShownRouteRestoreAlert = false
        lastCameraUpdateAt = nil
        LocationService.shared.setNavigationActive(RoutePlanner.shared.isNavigating)
    }

    private func observeDriveState() {
        let planner = RoutePlanner.shared
        Publishers.CombineLatest3(planner.$legs, planner.$destination, planner.$isNavigating)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, isNavigating in
                // CarPlay can own the only visible scene. Do not rely on the
                // phone SwiftUI view to switch Core Location into navigation
                // accuracy/background mode when a trip starts in the car.
                LocationService.shared.setNavigationActive(isNavigating)
                self?.redrawRoute()
                self?.synchroniseNavigationSession()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(
            planner.$nextManeuverInstruction.removeDuplicates(),
            planner.$upcomingManeuverInstructions.removeDuplicates(),
            planner.$isManeuverGuidanceReliable.removeDuplicates()
        )
            // RoutePlanner publishes the next instruction and its following
            // list in consecutive assignments on the same location update.
            // Coalesce that tiny burst so CarPlay never renders the new title
            // once with the previous maneuver list in between junctions.
            .debounce(for: .milliseconds(20), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.publishManeuver()
                self?.updateGuidanceEstimates()
            }
            .store(in: &cancellables)

        planner.$nextManeuverDistance
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                // Distance changes every GPS fix. Update estimates in place;
                // replacing CPManeuver objects here causes visible flicker and
                // can briefly remove the instruction at busy junctions.
                self?.updateGuidanceEstimates()
            }
            .store(in: &cancellables)

        planner.$breakReminderText
            .removeDuplicates()
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reminder in
                self?.presentBreakReminder(reminder)
            }
            .store(in: &cancellables)

        DriveSettings.shared.$voiceGuidance
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] enabled in
                RoutePlanner.shared.setVoiceGuidanceEnabled(enabled)
                self?.audioMapButton?.image = UIImage(
                    systemName: enabled ? "speaker.wave.2.fill" : "speaker.slash.fill"
                )
            }
            .store(in: &cancellables)

        LocationService.shared.$location
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                self?.updateCamera(for: location)
                self?.updateGuidanceEstimates()
                self?.restoreLockedTripIfNeeded(at: location)
            }
            .store(in: &cancellables)

        LocationService.shared.$authorization
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] authorization in
                guard let self,
                      NavigationLocationAuthorizationPolicy.requiresSystemSettings(authorization),
                      !self.hasShownLocationAccessAlert else { return }
                self.hasShownLocationAccessAlert = true
                self.showFailure(
                    "Standortzugriff fehlt. Bitte aktiviere ihn in den iPhone-Einstellungen für Kies Drive."
                )
            }
            .store(in: &cancellables)
    }

    private func restoreLockedTripIfNeeded(at suppliedLocation: CLLocation? = nil) {
        let planner = RoutePlanner.shared
        guard planner.activeRouteLock != nil, !planner.isNavigating,
              !routeRestoreInProgress,
              let location = suppliedLocation ?? LocationService.shared.location,
              NavigationLocationPolicy.accepts(location, after: nil) else { return }
        routeRestoreInProgress = true
        Task {
            let restored = await planner.restoreActiveTripIfNeeded(
                from: location.coordinate, settings: .shared
            )
            self.routeRestoreInProgress = false
            if restored {
                self.hasShownRouteRestoreAlert = false
            } else if !self.hasShownRouteRestoreAlert {
                self.hasShownRouteRestoreAlert = true
                self.showFailure(
                    "Die gespeicherte Route ist gerade weder online noch offline verfügbar. Bitte prüfe die Verbindung auf dem iPhone."
                )
            }
        }
    }

    private func makeMapButtons() -> [CPMapButton] {
        let follow = CPMapButton { [weak self] _ in self?.followVehicle() }
        follow.image = UIImage(systemName: "location.fill")
        let overview = CPMapButton { [weak self] _ in self?.showRouteOverview() }
        overview.image = UIImage(systemName: "map")
        let stops = CPMapButton { [weak self] _ in self?.showDestinationsAndStops() }
        stops.image = UIImage(systemName: "list.bullet")
        let audio = CPMapButton { button in
            DriveSettings.shared.voiceGuidance.toggle()
            RoutePlanner.shared.setVoiceGuidanceEnabled(DriveSettings.shared.voiceGuidance)
            button.image = UIImage(systemName: DriveSettings.shared.voiceGuidance
                                   ? "speaker.wave.2.fill" : "speaker.slash.fill")
        }
        audio.image = UIImage(systemName: DriveSettings.shared.voiceGuidance ? "speaker.wave.2.fill" : "speaker.slash.fill")
        audioMapButton = audio
        return [follow, overview, stops, audio]
    }

    private func followVehicle() {
        cameraMode = .follow
        lastCameraUpdateAt = nil
        refreshRouteStroke()
        mapView?.setUserTrackingMode(.followWithHeading, animated: true)
    }

    private func showRouteOverview() {
        guard let mapView else { return }
        let polylines = visibleRoutePolylines
        guard !polylines.isEmpty else { return }
        cameraMode = .overview
        refreshRouteStroke()
        mapView.setUserTrackingMode(.none, animated: false)
        let rect = polylines.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
        mapView.setVisibleMapRect(rect, edgePadding: .init(top: 90, left: 55, bottom: 90, right: 55), animated: true)
    }

    private func refreshRouteStroke() {
        guard let mapView else { return }
        for overlay in mapView.overlays {
            mapView.renderer(for: overlay)?.setNeedsDisplay()
        }
    }

    private func showDestinationsAndStops() {
        let planner = RoutePlanner.shared
        var coreItems: [CPListItem] = [makeDestinationSearchItem()]
        var savedDestinationItems: [CPListItem] = []
        var routeManagementItems: [CPListItem] = []
        var nearbyFuelItems: [CPListItem] = []
        var tripActionItems: [CPListItem] = []
        var routeSearchItems: [CPListItem] = []
        let home = DriveSettings.shared.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        if !home.isEmpty {
            let item = CPListItem(text: "Zuhause", detailText: home,
                                  image: UIImage(systemName: "house.fill"))
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.navigateHome(home)
                    completion()
                }
            }
            coreItems.append(item)
        }
        for favorite in DriveFavoriteStore.load().prefix(4) {
            let item = CPListItem(text: favorite.name,
                                  detailText: favorite.subtitle.isEmpty ? "Favorit" : favorite.subtitle,
                                  image: UIImage(systemName: "heart.fill"))
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.navigate(to: favorite)
                    completion()
                }
            }
            savedDestinationItems.append(item)
        }
        for recent in RecentDestinationStore.load().prefix(3) {
            let item = CPListItem(text: recent.name,
                                  detailText: recent.subtitle.isEmpty ? "Letztes Ziel" : recent.subtitle,
                                  image: UIImage(systemName: "clock.arrow.circlepath"))
            item.handler = { [weak self] _, completion in
                Task {
                    await self?.navigate(to: recent)
                    completion()
                }
            }
            savedDestinationItems.append(item)
        }
        for stop in planner.removableRouteStops.prefix(3) {
            let item = CPListItem(text: stop.name, detailText: "Zwischenstopp entfernen",
                                  image: UIImage(systemName: "minus.circle.fill"))
            item.handler = { [weak self] _, completion in
                Task {
                    guard let start = LocationService.shared.location?.coordinate else {
                        completion()
                        self?.showFailure("Der aktuelle Standort ist noch nicht verfügbar.")
                        return
                    }
                    let succeeded = await planner.removeRouteStop(id: stop.id, from: start, settings: .shared)
                    completion()
                    if succeeded { self?.showDestinationsAndStopsReplacingCurrentList() }
                    else { self?.showFailure(planner.errorMessage ?? "Der Zwischenstopp konnte nicht entfernt werden.") }
                }
            }
            routeManagementItems.append(item)
        }
        for station in planner.transientViaStations.prefix(2) {
            let item = CPListItem(text: station.brand.isEmpty ? station.name : station.brand,
                                  detailText: "Tankstopp entfernen",
                                  image: UIImage(systemName: "fuelpump.slash.fill"))
            item.handler = { [weak self] _, completion in
                Task {
                    guard let start = LocationService.shared.location?.coordinate else {
                        completion()
                        self?.showFailure("Der aktuelle Standort ist noch nicht verfügbar.")
                        return
                    }
                    let succeeded = await planner.toggleWaypoint(station, from: start, settings: .shared)
                    completion()
                    if succeeded { self?.showDestinationsAndStopsReplacingCurrentList() }
                    else { self?.showFailure(planner.errorMessage ?? "Der Tankstopp konnte nicht entfernt werden.") }
                }
            }
            routeManagementItems.append(item)
        }
        nearbyFuelItems.append(contentsOf: planner.stations.prefix(3).map { station in
            let selected = planner.isRouteStopSelected(id: station.id)
            let detail = selected
                ? String(format: "%.3f € · hinzugefügt", station.price)
                : String(format: "%.3f € · %.1f km", station.price, station.distanceKm)
            let item = CPListItem(text: station.brand.isEmpty ? station.name : station.brand,
                                  detailText: detail,
                                  image: UIImage(systemName: selected
                                                 ? "checkmark.circle.fill" : "fuelpump.fill"))
            item.handler = { _, completion in
                Task {
                    guard let start = LocationService.shared.location?.coordinate else {
                        completion()
                        self.showFailure("Der aktuelle Standort ist noch nicht verfügbar.")
                        return
                    }
                    let succeeded = await planner.toggleWaypoint(station, from: start, settings: .shared)
                    completion()
                    if succeeded { self.interfaceController?.popToRootTemplate(animated: true, completion: nil) }
                    else { self.showFailure(planner.errorMessage ?? "Die Route zum Tankstopp konnte nicht berechnet werden.") }
                }
            }
            return item
        })
        if planner.isNavigating {
            let fullTank = CPListItem(text: "Vollgetankt bestätigen",
                                      detailText: "Tankplanung ab jetzt neu berechnen",
                                      image: UIImage(systemName: "fuelpump.circle.fill"))
            fullTank.handler = { [weak self] _, completion in
                planner.confirmFullTank(settings: .shared)
                completion()
                self?.showDestinationsAndStopsReplacingCurrentList()
            }
            tripActionItems.append(fullTank)

            let completedBreak = CPListItem(
                text: "Pause beendet",
                detailText: "Fahrzeit zurücksetzen und weitere Pausen neu planen",
                image: UIImage(systemName: "cup.and.saucer.fill")
            )
            completedBreak.handler = { [weak self] _, completion in
                let succeeded = planner.confirmRestBreak(settings: .shared)
                completion()
                if succeeded {
                    self?.showDestinationsAndStopsReplacingCurrentList()
                } else {
                    self?.showFailure(planner.errorMessage ?? "Die Pause konnte nicht bestätigt werden.")
                }
            }
            tripActionItems.append(completedBreak)

            let lockedWaypoints = planner.activeRouteLock?.waypoints ?? []
            let actions = CarPlayPlannedStopPolicy.actions(
                plan: planner.longTripPlan,
                existingWaypointIDs: Set(lockedWaypoints.map(\.id)),
                existingWaypointNames: Set(lockedWaypoints.map(\.name)),
                currentRouteProgress: planner.currentInstalledRouteProgress
            )
            tripActionItems.append(contentsOf: actions.map { action in
                let title: String
                let symbol: String
                switch action.purpose {
                case .breakOnly:
                    title = "Geplante Pause: \(action.candidate.name)"
                    symbol = "cup.and.saucer.fill"
                case .fuelOnly:
                    title = "Geplanter Tankstopp: \(action.candidate.name)"
                    symbol = "fuelpump.fill"
                case .breakAndFuel:
                    title = "Pause und Tanken: \(action.candidate.name)"
                    symbol = "car.side.fill"
                }
                let item = CPListItem(text: title, detailText: plannedStopDetail(action),
                                      image: UIImage(systemName: symbol))
                item.handler = { [weak self] _, completion in
                    Task {
                        guard let start = LocationService.shared.location?.coordinate else {
                            completion()
                            self?.showFailure("Der aktuelle Standort ist noch nicht verfügbar.")
                            return
                        }
                        let plannedBreak = PlannedBreak(
                            id: action.candidate.id, candidate: action.candidate,
                            afterDriving: action.afterDriving ?? 0, duration: 0,
                            routeProgress: action.candidate.progress,
                            explanation: "Über CarPlay zur Route hinzugefügt"
                        )
                        let succeeded = await planner.addPlannedBreak(
                            plannedBreak, from: start, settings: .shared
                        )
                        completion()
                        if succeeded {
                            self?.interfaceController?.popToRootTemplate(animated: true, completion: nil)
                        } else {
                            self?.showFailure(
                                planner.errorMessage ??
                                    "Der geplante Stopp konnte nicht zur Route hinzugefügt werden."
                            )
                        }
                    }
                }
                return item
            })
        }
        if !visibleRoutePolylines.isEmpty {
            for (title, query, symbol) in [
                ("McDonald’s entlang der Route", "McDonald's", "m.circle.fill"),
                ("Essen entlang der Route", "Restaurant", "fork.knife"),
                ("Rastplätze entlang der Route", "Raststätte Autohof", "cup.and.saucer.fill")
            ] {
                let item = CPListItem(text: title, detailText: "Mit kleinem Umweg suchen",
                                      image: UIImage(systemName: symbol))
                item.handler = { [weak self] _, completion in
                    Task {
                        await planner.searchAlongRoute(query)
                        await MainActor.run {
                            completion()
                            self?.showSearchResults(title: title)
                        }
                    }
                }
                routeSearchItems.append(item)
            }
        }
        // CarPlay lists must stay short and glanceable. Allocate the fixed
        // twelve slots by driving importance rather than allowing favorites
        // or nearby stations to hide live trip controls.
        let groups = [
            coreItems, tripActionItems, routeSearchItems,
            routeManagementItems, savedDestinationItems, nearbyFuelItems,
        ]
        let allocation = CarPlayListPriorityPolicy.allocation(
            groupCounts: groups.map(\.count)
        )
        let items = zip(groups, allocation).flatMap { group, count in
            group.prefix(count)
        }
        if items.isEmpty {
            let fallback = CPListItem(
                text: "Noch keine Ziele",
                detailText: "Lege Zuhause oder ein Ziel auf dem iPhone fest."
            )
            let list = CPListTemplate(title: "Ziele und Stopps", sections: [CPListSection(items: [fallback])])
            interfaceController?.pushTemplate(list, animated: true, completion: nil)
            return
        }
        let list = CPListTemplate(title: "Ziele und Stopps", sections: [CPListSection(items: items)])
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }

    private func plannedStopDetail(_ action: CarPlayPlannedStopAction) -> String {
        if let seconds = action.afterDriving, seconds > 0 {
            let minutes = Int((seconds / 60).rounded())
            return minutes >= 60
                ? "In etwa \(minutes / 60) Std. \(minutes % 60) Min."
                : "In etwa \(minutes) Min."
        }
        if let metres = action.afterDistanceMetres, metres > 0 {
            return String(format: "In etwa %.0f km", metres / 1_000)
        }
        return "Mit kleinem Umweg zur Route hinzufügen"
    }

    private func makeDestinationSearchItem() -> CPListItem {
        let item = CPListItem(text: "Ziel suchen", detailText: "Orte, Adressen und Firmen",
                              image: UIImage(systemName: "magnifyingglass"))
        item.handler = { [weak self] _, completion in
            let search = CPSearchTemplate()
            search.delegate = self
            self?.interfaceController?.pushTemplate(search, animated: true) { _, _ in completion() }
        }
        return item
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, updatedSearchText searchText: String,
                        completionHandler: @escaping ([CPListItem]) -> Void) {
        let completionGate = NavigationSearchCompletionGate<[CPListItem]>()
        let finish: ([CPListItem]) -> Void = { items in
            _ = completionGate.complete(items, using: completionHandler)
        }
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard query.count >= 2 else {
            carPlaySearchGeneration = UUID()
            activeCarPlaySearch?.cancel()
            activeCarPlaySearch = nil
            carPlaySearchResults = [:]
            finish([])
            return
        }
        let generation = UUID()
        carPlaySearchGeneration = generation
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = query
        if let coordinate = LocationService.shared.location?.coordinate {
            request.region = .init(center: coordinate, latitudinalMeters: 300_000,
                                   longitudinalMeters: 300_000)
        }
        activeCarPlaySearch?.cancel()
        let search = MKLocalSearch(request: request)
        activeCarPlaySearch = search
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: NavigationSearchTimeoutPolicy.timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            search.cancel()
            if generation == self?.carPlaySearchGeneration {
                self?.activeCarPlaySearch = nil
                self?.carPlaySearchResults = [:]
            }
            finish([])
        }
        Task { [weak self] in
            let response = try? await search.start()
            timeout.cancel()
            guard !completionGate.didComplete else { return }
            guard let self else {
                finish([])
                return
            }
            // CarPlay requires every search update to complete. Returning an
            // empty result for a superseded query prevents an old spinner
            // from surviving while the driver is already typing a new query.
            guard generation == self.carPlaySearchGeneration else {
                finish([])
                return
            }
            self.activeCarPlaySearch = nil
            var mapped: [ObjectIdentifier: MKMapItem] = [:]
            let origin = LocationService.shared.location
            let ordered = (response?.mapItems ?? []).sorted { lhs, rhs in
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
            var unique: [MKMapItem] = []
            for mapItem in ordered where unique.count < 8 {
                guard !unique.contains(where: { existing in
                    DestinationSearchRankingPolicy.isDuplicate(
                        name: mapItem.name, coordinate: mapItem.placemark.coordinate,
                        existingName: existing.name,
                        existingCoordinate: existing.placemark.coordinate
                    )
                }) else { continue }
                unique.append(mapItem)
            }
            let items = unique.map { mapItem in
                let address = [mapItem.placemark.thoroughfare, mapItem.placemark.locality]
                    .compactMap { $0 }.joined(separator: ", ")
                let item = CPListItem(text: mapItem.name ?? "Ziel",
                                      detailText: address.isEmpty ? mapItem.placemark.title : address,
                                      image: UIImage(systemName: "mappin.and.ellipse"))
                mapped[ObjectIdentifier(item)] = mapItem
                return item
            }
            self.carPlaySearchResults = mapped
            finish(items)
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        guard let mapItem = carPlaySearchResults[ObjectIdentifier(item)],
              let start = LocationService.shared.location?.coordinate else {
            completionHandler()
            showFailure("Das Ziel oder der aktuelle Standort ist nicht mehr verfügbar.")
            return
        }
        Task { [weak self] in
            await self?.navigate(to: mapItem, from: start)
            completionHandler()
        }
    }

    private func showDestinationsAndStopsReplacingCurrentList() {
        interfaceController?.popTemplate(animated: false, completion: { [weak self] _, _ in
            self?.showDestinationsAndStops()
        })
    }

    private func navigateHome(_ address: String) async {
        guard let start = LocationService.shared.location?.coordinate else {
            showFailure("Der aktuelle Standort ist noch nicht verfügbar.")
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        request.region = .init(center: start, latitudinalMeters: 500_000, longitudinalMeters: 500_000)
        let outcome = await boundedOneShotSearch(request)
        guard case .results(let items) = outcome, let item = items.first else {
            if case .timedOut = outcome {
                showFailure("Die Zuhause-Suche dauert zu lange. Bitte versuche es erneut.")
                return
            }
            showFailure("Die Zuhause-Adresse konnte nicht gefunden werden.")
            return
        }
        await navigate(to: item, from: start)
    }

    private func boundedOneShotSearch(_ request: MKLocalSearch.Request) async
        -> OneShotSearchOutcome {
        let search = MKLocalSearch(request: request)
        return await withTaskGroup(of: OneShotSearchOutcome.self) { group in
            group.addTask {
                do { return .results(try await search.start().mapItems) }
                catch { return .failed }
            }
            group.addTask {
                do {
                    try await Task.sleep(
                        nanoseconds: NavigationSearchTimeoutPolicy.timeoutNanoseconds
                    )
                    return .timedOut
                } catch {
                    return .failed
                }
            }
            let first = await group.next() ?? .failed
            group.cancelAll()
            search.cancel()
            return first
        }
    }

    private func navigate(to recent: RecentDestination) async {
        guard let start = LocationService.shared.location?.coordinate else {
            showFailure("Der aktuelle Standort ist noch nicht verfügbar.")
            return
        }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: recent.coordinate))
        item.name = recent.name
        await navigate(to: item, from: start)
    }

    private func navigate(to favorite: DriveFavorite) async {
        guard let start = LocationService.shared.location?.coordinate else {
            showFailure("Der aktuelle Standort ist noch nicht verfügbar.")
            return
        }
        let item = MKMapItem(placemark: MKPlacemark(coordinate: favorite.coordinate))
        item.name = favorite.name
        await navigate(to: item, from: start)
    }

    private func navigate(to item: MKMapItem, from start: CLLocationCoordinate2D) async {
        guard await RoutePlanner.shared.activateDestination(item, from: start, settings: .shared) else {
            showFailure(RoutePlanner.shared.errorMessage ?? "Die Route zu diesem Ziel konnte nicht berechnet werden.")
            return
        }
        let coordinate = item.placemark.coordinate
        RecentDestinationStore.record(.init(
            name: item.name ?? "Ziel", subtitle: item.placemark.title ?? "",
            latitude: coordinate.latitude, longitude: coordinate.longitude
        ))
        interfaceController?.popToRootTemplate(animated: true, completion: nil)
        followVehicle()
    }

    private func showSearchResults(title: String) {
        let planner = RoutePlanner.shared
        let items = planner.routeSearchResults.prefix(10).map { result in
            let mapItem = result.mapItem
            let address = [mapItem.placemark.thoroughfare, mapItem.placemark.locality]
                .compactMap { $0 }.joined(separator: ", ")
            let item = CPListItem(text: mapItem.name ?? "Zwischenstopp",
                                  detailText: String(format: "%@ · %@%.1f km Umweg",
                                                     address.isEmpty ? "Entlang der Route" : address,
                                                     result.detourIsEstimated ? "ca. " : "",
                                                     result.detourMetres / 1_000))
            item.handler = { _, completion in
                Task {
                    // The list can remain open while the car moves. Always
                    // route from the newest fix at selection time, not the
                    // coordinate captured when the list was first shown.
                    guard let start = LocationService.shared.location?.coordinate else {
                        completion()
                        self.showFailure("Der aktuelle Standort ist noch nicht verfügbar.")
                        return
                    }
                    let succeeded = await planner.addRouteStop(
                        mapItem, from: start, settings: .shared,
                        knownRouteProgress: result.routeProgress
                    )
                    completion()
                    if succeeded { self.interfaceController?.popToRootTemplate(animated: true, completion: nil) }
                    else { self.showFailure(planner.errorMessage ?? "Der Zwischenstopp konnte nicht hinzugefügt werden.") }
                }
            }
            return item
        }
        let visible = items.isEmpty
            ? [CPListItem(text: "Nichts Passendes gefunden", detailText: "Bitte später erneut versuchen.")]
            : items
        interfaceController?.pushTemplate(
            CPListTemplate(title: title, sections: [CPListSection(items: visible)]),
            animated: true, completion: nil
        )
    }

    private func showFailure(_ message: String) {
        let action = CPAlertAction(title: "OK", style: .default) { _ in }
        let alert = CPAlertTemplate(
            titleVariants: CarPlayAlertPresentationPolicy.titleVariants(for: message),
            actions: [action]
        )
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    private func presentBreakReminder(_ message: String) {
        guard RoutePlanner.shared.isNavigating, let mapTemplate else { return }
        let variants = CarPlayBreakReminderPresentationPolicy.titleVariants(for: message)
        guard !variants.isEmpty else { return }
        let acknowledge = CPAlertAction(title: "OK", style: .default) { _ in }
        let alert = CPNavigationAlert(
            titleVariants: variants,
            subtitleVariants: nil,
            image: UIImage(systemName: "cup.and.saucer.fill"),
            primaryAction: acknowledge,
            secondaryAction: nil,
            duration: 8
        )
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    private func redrawRoute() {
        guard let mapView else { return }
        mapView.removeOverlays(mapView.overlays)
        // Guidance geometry must win over labels and map decorations at busy
        // interchanges. Otherwise the route can look interrupted precisely
        // where the driver needs it most.
        visibleRoutePolylines.forEach { mapView.addOverlay($0, level: .aboveLabels) }
        // MapKit may temporarily report `.none` after a programmatic camera
        // update. `cameraMode` is the user's actual intent and prevents a
        // route refresh/reroute from unexpectedly replacing follow mode with
        // a full-route overview.
        if cameraMode == .overview { showRouteOverview() }
    }

    private var visibleRoutePolylines: [MKPolyline] {
        let live = RoutePlanner.shared.legs.map(\.polyline)
        return live.isEmpty ? RoutePlanner.shared.offlinePolylines : live
    }

    private func synchroniseNavigationSession() {
        let planner = RoutePlanner.shared
        guard planner.isNavigating, let destination = planner.destination,
              let fallback = visibleRoutePolylines.first?.coordinate else {
            navigationSession?.finishTrip()
            navigationSession = nil
            activeTrip = nil
            activeTripDestination = nil
            return
        }
        let requestedDestination = destination.placemark.coordinate
        if navigationSession != nil,
           !NavigationDestinationIdentityPolicy.matches(activeTripDestination, requestedDestination) {
            navigationSession?.finishTrip()
            navigationSession = nil
            activeTrip = nil
            activeTripDestination = nil
        }
        if navigationSession == nil, let mapTemplate {
            let origin = MKMapItem(placemark: MKPlacemark(coordinate: LocationService.shared.location?.coordinate ?? fallback))
            let distance = planner.remainingDistanceMetres > 0 ? planner.remainingDistanceMetres : planner.totalDistance
            let time = planner.remainingTravelTime > 0 ? planner.remainingTravelTime : planner.totalTravelTime
            let choice = CPRouteChoice(summaryVariants: [destination.name ?? "Route"],
                                       additionalInformationVariants: [formatDistance(distance)],
                                       selectionSummaryVariants: [formatTime(time)])
            let trip = CPTrip(origin: origin, destination: destination, routeChoices: [choice])
            activeTrip = trip
            activeTripDestination = requestedDestination
            navigationSession = mapTemplate.startNavigationSession(for: trip)
        }
        publishManeuver()
        updateGuidanceEstimates()
    }

    private func publishManeuver() {
        guard let session = navigationSession else { return }
        let planner = RoutePlanner.shared
        let instructions = CarPlayGuidancePresentationPolicy.instructions(
            upcoming: planner.upcomingManeuverInstructions,
            next: planner.nextInstruction,
            guidanceReliable: planner.isManeuverGuidanceReliable
        )
        session.upcomingManeuvers = instructions.enumerated().map { index, instruction in
            let maneuver = CPManeuver()
            let variants = CarPlayGuidancePresentationPolicy.variants(for: instruction)
            maneuver.instructionVariants = variants
            maneuver.dashboardInstructionVariants = variants
            maneuver.notificationInstructionVariants = variants
            let presentation = NavigationManeuverPresentation(instruction)
            maneuver.symbolImage = UIImage(systemName: presentation.direction.symbolName)
            if index == 0 {
                maneuver.initialTravelEstimates = maneuverTravelEstimates()
            }
            return maneuver
        }
    }

    private func updateGuidanceEstimates() {
        guard let session = navigationSession else { return }
        // A confirmed route departure intentionally removes every stale
        // CPManeuver. Trip-level distance and ETA are still safe, useful
        // context and must continue updating while MapKit searches for the
        // replacement route or cached guidance is being rejoined.
        if let maneuver = session.upcomingManeuvers.first {
            session.updateEstimates(maneuverTravelEstimates(), for: maneuver)
        }
        if let trip = activeTrip { mapTemplate?.updateEstimates(travelEstimates(), for: trip) }
    }

    private func maneuverTravelEstimates() -> CPTravelEstimates {
        let distance = max(RoutePlanner.shared.nextManeuverDistance ?? 0, 0)
        let speed = LocationService.shared.location.flatMap(NavigationMotionPolicy.reliableSpeed(for:)) ?? 0
        return CPTravelEstimates(
            distanceRemaining: Measurement(value: distance, unit: UnitLength.meters),
            timeRemaining: NavigationEstimatePolicy.timeToManeuver(
                distanceMetres: distance, speedMetresPerSecond: speed
            )
        )
    }

    private func travelEstimates() -> CPTravelEstimates {
        let planner = RoutePlanner.shared
        let distance = planner.remainingDistanceMetres > 0 ? planner.remainingDistanceMetres : planner.totalDistance
        let time = planner.remainingTravelTime > 0 ? planner.remainingTravelTime : planner.totalTravelTime
        return CPTravelEstimates(distanceRemaining: Measurement(value: max(distance, 0), unit: UnitLength.meters),
                                 timeRemaining: max(time, 0))
    }

    private func updateCamera(for location: CLLocation) {
        guard RoutePlanner.shared.isNavigating, cameraMode == .follow,
              CarPlayCameraUpdatePolicy.shouldUpdate(
                last: lastCameraUpdateAt, current: location.timestamp
              ) else { return }
        lastCameraUpdateAt = location.timestamp
        if let course = NavigationMotionPolicy.reliableCourse(for: location) {
            lastReliableCourse = course
        }
        let heading = lastReliableCourse ?? mapView?.camera.heading ?? 0
        let speed = NavigationMotionPolicy.reliableSpeed(for: location)
        let center = NavigationFollowCameraPolicy.center(
            from: location.coordinate,
            headingDegrees: heading,
            speedMetresPerSecond: speed
        )
        let camera = MKMapCamera(
            lookingAtCenter: center,
            fromDistance: NavigationFollowCameraPolicy.distance(speedMetresPerSecond: speed),
            pitch: 55,
            heading: heading
        )
        // Location samples already form a smooth stream. Immediate camera
        // commits avoid stacking MapKit animations and keeping the car icon
        // visibly behind its real position at motorway speed.
        mapView?.setCamera(camera, animated: false)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {}
    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        RoutePlanner.shared.startNavigation()
        synchroniseNavigationSession()
    }
    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        // CarPlay's system cancel control is an explicit end action, just
        // like the red "Beenden" control on the phone. Merely pausing here
        // leaves the persistent route lock active and would make the trip
        // restart automatically on a later GPS fix.
        RoutePlanner.shared.completeActiveTrip()
        navigationSession?.cancelTrip()
        navigationSession = nil
        activeTrip = nil
        activeTripDestination = nil
    }

    private func formatDistance(_ metres: Double) -> String {
        metres >= 1000 ? String(format: "%.1f km", metres / 1000) : "\(Int(metres)) m"
    }
    private func formatTime(_ seconds: TimeInterval) -> String {
        let minutes = Int(seconds / 60)
        return minutes >= 60 ? "\(minutes / 60) Std. \(minutes % 60) Min." : "\(minutes) Min."
    }
}

extension CarPlaySceneDelegate: MKMapViewDelegate {
    func mapView(_ mapView: MKMapView, regionWillChangeAnimated animated: Bool) {
        var recognizers = mapView.gestureRecognizers ?? []
        for subview in mapView.subviews {
            recognizers.append(contentsOf: subview.gestureRecognizers ?? [])
        }
        let isUserGesture = recognizers.contains { recognizer in
            recognizer.state == .began || recognizer.state == .changed
        }
        if isUserGesture {
            // Respect manual pan/zoom until the driver explicitly taps the
            // location button. Incoming GPS fixes must not fight the gesture.
            cameraMode = .free
            mapView.setUserTrackingMode(.none, animated: false)
        }
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: polyline)
        renderer.strokeColor = .systemBlue
        renderer.lineWidth = CarPlayRouteLinePolicy.width(isOverview: cameraMode == .overview)
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }
}
#endif
