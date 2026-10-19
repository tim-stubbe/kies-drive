#if os(iOS)
import CarPlay
import Combine
import MapKit
import UIKit

private final class CarPlaySpeedLimitBadgeView: UIView {
    private let label = UILabel()

    override init(frame: CGRect) {
        super.init(frame: frame)
        isHidden = true
        isUserInteractionEnabled = false
        backgroundColor = .white
        layer.cornerRadius = 34
        layer.borderWidth = 6
        layer.borderColor = UIColor.systemRed.cgColor
        layer.shadowColor = UIColor.black.cgColor
        layer.shadowOpacity = 0.25
        layer.shadowRadius = 5
        layer.shadowOffset = .init(width: 0, height: 2)
        label.translatesAutoresizingMaskIntoConstraints = false
        label.textAlignment = .center
        label.textColor = .black
        label.font = .systemFont(ofSize: 25, weight: .black)
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.7
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
        ])
    }

    required init?(coder: NSCoder) { nil }

    func update(_ state: CarPlaySpeedLimitBadgePolicy.State) {
        switch state {
        case .hidden:
            isHidden = true
            accessibilityLabel = nil
        case .numeric(let value, let warning):
            isHidden = false
            label.text = String(value)
            label.font = .systemFont(ofSize: 25, weight: .black)
            backgroundColor = warning ? UIColor.systemRed.withAlphaComponent(0.18) : .white
            layer.borderColor = UIColor.systemRed.cgColor
            layer.borderWidth = warning ? 8 : 6
            accessibilityLabel = warning
                ? "Zu schnell. Tempolimit \(value) Kilometer pro Stunde"
                : "Tempolimit \(value) Kilometer pro Stunde"
        case .unrestricted:
            isHidden = false
            label.text = "∞"
            label.font = .systemFont(ofSize: 32, weight: .bold)
            backgroundColor = .white
            layer.borderColor = UIColor.systemGray.cgColor
            layer.borderWidth = 5
            accessibilityLabel = "Keine streckenbezogene Geschwindigkeitsbeschränkung"
        }
    }
}

/// Native CarPlay navigation surface. Navigation remains local in Kies Drive;
/// CarPlay is only another presentation and control surface for the shared trip.
@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate, CPMapTemplateDelegate,
                                  CPSearchTemplateDelegate {
    private struct SearchSelection<Value> {
        let generation: UUID
        let purpose: CarPlaySearchPurpose
        let value: Value
    }

    private enum OneShotSearchOutcome {
        case results([MKMapItem])
        case failed
        case timedOut
    }
    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mapView: MKMapView?
    private var speedLimitBadgeView: CarPlaySpeedLimitBadgeView?
    private var mapTemplate: CPMapTemplate?
    private var audioMapButton: CPMapButton?
    private var navigationSession: CPNavigationSession?
    private var activeTrip: CPTrip?
    private var activeTripDestination: CLLocationCoordinate2D?
    private var cameraMode: CarPlayCameraMode = .follow
    private var observedNavigationActive = false
    private var lastReliableCourse: CLLocationDirection?
    private var lastCameraUpdateAt: Date?
    private var carPlaySearchResults: [ObjectIdentifier: SearchSelection<MKMapItem>] = [:]
    private var carPlayRouteSearchResults: [ObjectIdentifier: SearchSelection<RouteSearchResult>] = [:]
    private var carPlaySearchPurpose: CarPlaySearchPurpose = .destination
    private var carPlaySearchGeneration = UUID()
    private var activeCarPlaySearches: [MKLocalSearch] = []
    private var hasShownLocationAccessAlert = false
    private var hasShownBackgroundLocationAlert = false
    private var routeRestoreInProgress = false
    private var routeRestoreTask: Task<Void, Never>?
    private var connectionGeneration = UUID()
    private var hasShownRouteRestoreAlert = false
    private var routeRecoveryPresentationState: CarPlayRouteRecoveryPresentationState = .normal
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
        // A reconnect can arrive without a matching disconnect callback (for
        // example after the head unit briefly resets its template process).
        // The old CPNavigationSession belongs to the old CPMapTemplate and
        // must not prevent a fresh session from being attached below. This
        // finishes only the CarPlay presentation; RoutePlanner keeps the
        // local trip and guidance running on the phone.
        navigationSession?.finishTrip()
        routeRestoreTask?.cancel()
        routeRestoreTask = nil
        routeRestoreInProgress = false
        connectionGeneration = UUID()
        navigationSession = nil
        activeTrip = nil
        activeTripDestination = nil
        cancellables.removeAll()
        activeCarPlaySearches.forEach { $0.cancel() }
        activeCarPlaySearches = []
        carPlaySearchResults = [:]
        carPlayRouteSearchResults = [:]
        cameraMode = CarPlayCameraLifecyclePolicy.modeAfterConnection(previous: cameraMode)
        observedNavigationActive = false
        lastReliableCourse = nil
        lastCameraUpdateAt = nil
        self.interfaceController = interfaceController
        carWindow = window
        LocationService.shared.setNavigationActive(RoutePlanner.shared.isNavigating)
        LocationService.shared.start()

        if let window {
            let controller = UIViewController()
            let map = MKMapView(frame: .zero)
            map.translatesAutoresizingMaskIntoConstraints = false
            map.showsUserLocation = true
            map.mapType = CarPlayMapAppearancePolicy.mapType(
                for: DriveSettings.shared.mapAppearance
            )
            map.userTrackingMode = .followWithHeading
            map.delegate = self
            controller.view.addSubview(map)
            let speedBadge = CarPlaySpeedLimitBadgeView()
            speedBadge.translatesAutoresizingMaskIntoConstraints = false
            controller.view.addSubview(speedBadge)
            NSLayoutConstraint.activate([
                map.leadingAnchor.constraint(equalTo: controller.view.leadingAnchor),
                map.trailingAnchor.constraint(equalTo: controller.view.trailingAnchor),
                map.topAnchor.constraint(equalTo: controller.view.topAnchor),
                map.bottomAnchor.constraint(equalTo: controller.view.bottomAnchor),
                speedBadge.leadingAnchor.constraint(
                    equalTo: controller.view.safeAreaLayoutGuide.leadingAnchor, constant: 22
                ),
                speedBadge.bottomAnchor.constraint(
                    equalTo: controller.view.safeAreaLayoutGuide.bottomAnchor, constant: -22
                ),
                speedBadge.widthAnchor.constraint(equalToConstant: 68),
                speedBadge.heightAnchor.constraint(equalToConstant: 68),
            ])
            window.rootViewController = controller
            window.isHidden = false
            mapView = map
            speedLimitBadgeView = speedBadge
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
        // CarPlay can be the only active scene. Persist its latest aggregate
        // navigation state before iOS tears the scene down.
        RoutePlanner.shared.checkpointNavigationState()
        // Explicitly close the system presentation so dashboard/cluster state
        // cannot retain stale maneuvers after unplugging. The shared planner
        // remains active and continues guidance on the iPhone.
        navigationSession?.finishTrip()
        routeRestoreTask?.cancel()
        routeRestoreTask = nil
        connectionGeneration = UUID()
        interfaceController = nil
        carWindow = nil
        mapView = nil
        speedLimitBadgeView = nil
        mapTemplate = nil
        audioMapButton = nil
        navigationSession = nil
        activeTrip = nil
        activeTripDestination = nil
        cancellables.removeAll()
        activeCarPlaySearches.forEach { $0.cancel() }
        activeCarPlaySearches = []
        carPlaySearchResults = [:]
        carPlayRouteSearchResults = [:]
        hasShownLocationAccessAlert = false
        hasShownBackgroundLocationAlert = false
        routeRestoreInProgress = false
        hasShownRouteRestoreAlert = false
        routeRecoveryPresentationState = .normal
        lastCameraUpdateAt = nil
        lastReliableCourse = nil
        cameraMode = CarPlayCameraLifecyclePolicy.modeAfterConnection(previous: cameraMode)
        observedNavigationActive = false
        LocationService.shared.setNavigationActive(RoutePlanner.shared.isNavigating)
    }

    private func observeDriveState() {
        let planner = RoutePlanner.shared
        Publishers.CombineLatest3(planner.$legs, planner.$destination, planner.$isNavigating)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, isNavigating in
                guard let self else { return }
                // CarPlay can own the only visible scene. Do not rely on the
                // phone SwiftUI view to switch Core Location into navigation
                // accuracy/background mode when a trip starts in the car.
                LocationService.shared.setNavigationActive(isNavigating)
                let requestedMode = CarPlayCameraLifecyclePolicy.mode(
                    previous: self.cameraMode,
                    navigationWasActive: self.observedNavigationActive,
                    navigationIsActive: isNavigating
                )
                let startedNewNavigation = requestedMode == .follow && self.cameraMode != .follow
                self.cameraMode = requestedMode
                self.observedNavigationActive = isNavigating
                self.redrawRoute()
                self.synchroniseNavigationSession()
                if startedNewNavigation { self.followVehicle() }
            }
            .store(in: &cancellables)

        Publishers.CombineLatest4(
            planner.$nextManeuverIdentity.removeDuplicates(),
            planner.$nextManeuverInstruction.removeDuplicates(),
            planner.$upcomingManeuverInstructions.removeDuplicates(),
            planner.$isManeuverGuidanceReliable.removeDuplicates()
        )
            // RoutePlanner publishes the next instruction and its following
            // list in consecutive assignments on the same location update.
            // Coalesce that tiny burst so CarPlay never renders the new title
            // once with the previous maneuver list in between junctions.
            .debounce(for: .milliseconds(20), scheduler: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
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

        Publishers.CombineLatest(
            planner.$isRecalculating.removeDuplicates(),
            planner.$isManeuverGuidanceReliable.removeDuplicates()
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] recalculating, guidanceReliable in
                self?.presentRouteRecoveryStateIfNeeded(
                    recalculating: recalculating,
                    guidanceReliable: guidanceReliable
                )
            }
            .store(in: &cancellables)

        planner.$drivingStopReminderText
            .removeDuplicates()
            .compactMap { $0 }
            // RoutePlanner can publish the break wording and replace it with
            // a combined break/fuel sentence in the same GPS update. Coalesce
            // that burst so CarPlay presents one stable alert.
            .debounce(for: .milliseconds(50), scheduler: DispatchQueue.main)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] reminder in
                self?.presentStopReminder(reminder)
            }
            .store(in: &cancellables)

        planner.$speedWarning
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _ in
                guard let location = LocationService.shared.location else { return }
                self?.updateSpeedLimitBadge(for: location)
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

        DriveSettings.shared.$mapAppearance
            .removeDuplicates()
            .receive(on: DispatchQueue.main)
            .sink { [weak self] appearance in
                self?.mapView?.mapType = CarPlayMapAppearancePolicy.mapType(for: appearance)
            }
            .store(in: &cancellables)

        LocationService.shared.$location
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                self?.updateCamera(for: location)
                self?.updateSpeedLimitBadge(for: location)
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

        Publishers.CombineLatest(
            LocationService.shared.$authorization.removeDuplicates(),
            planner.$isNavigating.removeDuplicates()
        )
            .receive(on: DispatchQueue.main)
            .sink { [weak self] authorization, isNavigating in
                guard let self,
                      NavigationLocationAuthorizationPolicy.shouldRequestAlways(
                        navigationActive: isNavigating,
                        hasWhenInUseAuthorization: authorization == .authorizedWhenInUse
                      ),
                      !self.hasShownBackgroundLocationAlert else { return }
                self.hasShownBackgroundLocationAlert = true
                self.showFailure(
                    "Für Navigation bei gesperrtem iPhone benötigt Kies Drive den Standortzugriff „Immer“. Bitte aktiviere ihn in den iPhone-Einstellungen."
                )
            }
            .store(in: &cancellables)
    }

    private func updateSpeedLimitBadge(for location: CLLocation) {
        let planner = RoutePlanner.shared
        speedLimitBadgeView?.update(CarPlaySpeedLimitBadgePolicy.state(
            limit: planner.currentSpeedLimit(near: location.coordinate),
            speedWarning: planner.speedWarning,
            navigationActive: planner.isNavigating
        ))
    }

    private func restoreLockedTripIfNeeded(at suppliedLocation: CLLocation? = nil) {
        let planner = RoutePlanner.shared
        guard planner.activeRouteLock != nil, !planner.isNavigating,
              !routeRestoreInProgress,
              let location = suppliedLocation ?? LocationService.shared.location,
              NavigationLocationPolicy.accepts(location, after: nil) else { return }
        routeRestoreInProgress = true
        let requestedConnection = connectionGeneration
        routeRestoreTask = Task { [weak self] in
            let restored = await planner.restoreActiveTripIfNeeded(
                from: location.coordinate, settings: .shared
            )
            guard !Task.isCancelled, let self,
                  CarPlayConnectionWorkPolicy.mayPublish(
                    request: requestedConnection,
                    current: self.connectionGeneration,
                    connected: self.interfaceController != nil
                  ) else { return }
            self.routeRestoreTask = nil
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
        var routeOptionItems: [CPListItem] = []
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
        nearbyFuelItems.append(contentsOf: planner.actionableStations(
            from: LocationService.shared.location?.coordinate
        ).prefix(3).map { station in
            let selected = planner.isRouteStopSelected(id: station.id)
            let price = FuelStationPricePresentationPolicy.compact(
                price: station.price, cached: planner.stationPricesAreCached
            )
            let detail = selected
                ? "\(price) · hinzugefügt"
                : String(format: "%@ · %.1f km", price, station.distanceKm)
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
                        let succeeded = await planner.addCarPlayPlannedStop(
                            action, from: start, settings: .shared
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
        if !planner.legs.isEmpty || planner.activeRouteLock != nil {
            let lockedOptions = planner.activeRouteLock?.defaultOptions
            let avoidsTolls = lockedOptions?.avoidTolls ?? DriveSettings.shared.avoidTolls
            let avoidsHighways = lockedOptions?.avoidHighways ?? DriveSettings.shared.avoidHighways
            for option in [
                (title: "Maut vermeiden", enabled: avoidsTolls, tolls: true),
                (title: "Autobahnen vermeiden", enabled: avoidsHighways, tolls: false),
            ] {
                let item = CPListItem(
                    text: option.title,
                    detailText: CarPlayRouteOptionPresentationPolicy.detail(enabled: option.enabled),
                    image: UIImage(systemName: CarPlayRouteOptionPresentationPolicy.symbol(
                        enabled: option.enabled
                    ))
                )
                item.handler = { [weak self] _, completion in
                    Task {
                        guard let start = LocationService.shared.location?.coordinate else {
                            completion()
                            self?.showFailure("Der aktuelle Standort ist noch nicht verfügbar.")
                            return
                        }
                        let succeeded = await planner.updateRouteOptionsAndRecalculate(
                            waypointID: nil,
                            avoidTolls: option.tolls ? !option.enabled : nil,
                            avoidHighways: option.tolls ? nil : !option.enabled,
                            from: start, settings: .shared
                        )
                        completion()
                        if succeeded {
                            self?.showDestinationsAndStopsReplacingCurrentList()
                        } else {
                            self?.showFailure(
                                planner.errorMessage ??
                                    "Die Route mit dieser Vorgabe konnte nicht berechnet werden."
                            )
                        }
                    }
                }
                routeOptionItems.append(item)
            }
        }
        if !visibleRoutePolylines.isEmpty {
            routeSearchItems.append(makeAlongRouteSearchItem())
            for (title, query, symbol) in [
                ("McDonald’s entlang der Route", "McDonald's", "m.circle.fill"),
                ("Essen entlang der Route", "Restaurant", "fork.knife"),
                ("Rastplätze entlang der Route", "Raststätte Autohof", "cup.and.saucer.fill")
            ] {
                let item = CPListItem(text: title, detailText: "Mit kleinem Umweg suchen",
                                      image: UIImage(systemName: symbol))
                item.handler = { [weak self] _, completion in
                    Task {
                        let completedCurrentSearch = await planner.searchAlongRoute(query)
                        await MainActor.run {
                            completion()
                            if completedCurrentSearch {
                                self?.showSearchResults(title: title)
                            }
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
            coreItems, tripActionItems, routeOptionItems, routeManagementItems,
            routeSearchItems, savedDestinationItems, nearbyFuelItems,
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
        CarPlayPlannedStopDetailPolicy.text(for: action)
    }

    private func makeDestinationSearchItem() -> CPListItem {
        let item = CPListItem(text: "Ziel suchen", detailText: "Orte, Adressen und Firmen",
                              image: UIImage(systemName: "magnifyingglass"))
        item.handler = { [weak self] _, completion in
            self?.carPlaySearchPurpose = .destination
            self?.carPlayRouteSearchResults = [:]
            let search = CPSearchTemplate()
            search.delegate = self
            self?.interfaceController?.pushTemplate(search, animated: true) { _, _ in completion() }
        }
        return item
    }

    private func makeAlongRouteSearchItem() -> CPListItem {
        let item = CPListItem(
            text: "Auf der Route suchen",
            detailText: "Eigene Suche als Zwischenstopp",
            image: UIImage(systemName: "point.bottomleft.forward.to.point.topright.scurvepath")
        )
        item.handler = { [weak self] _, completion in
            self?.carPlaySearchPurpose = .routeStop
            self?.carPlaySearchResults = [:]
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
            activeCarPlaySearches.forEach { $0.cancel() }
            activeCarPlaySearches = []
            carPlaySearchResults = [:]
            carPlayRouteSearchResults = [:]
            finish([])
            return
        }
        let generation = UUID()
        carPlaySearchGeneration = generation
        // CPSearchTemplate can keep the previous rows visible while a new
        // query is loading. Revoke their action ownership synchronously.
        carPlaySearchResults = [:]
        carPlayRouteSearchResults = [:]
        if carPlaySearchPurpose == .routeStop {
            activeCarPlaySearches.forEach { $0.cancel() }
            activeCarPlaySearches = []
            Task { [weak self] in
                guard let self else {
                    finish([])
                    return
                }
                let completedCurrentSearch = await RoutePlanner.shared.searchAlongRoute(query)
                guard completedCurrentSearch,
                      generation == self.carPlaySearchGeneration,
                      self.carPlaySearchPurpose == .routeStop else {
                    finish([])
                    return
                }
                var mapped: [ObjectIdentifier: SearchSelection<RouteSearchResult>] = [:]
                let items = RoutePlanner.shared.actionableRouteSearchResults.prefix(8).map { result in
                    let name = result.mapItem.name ?? "Zwischenstopp"
                    let item = CPListItem(
                        text: name,
                        detailText: String(
                            format: "%@%.1f km Umweg",
                            result.detourIsEstimated ? "ca. " : "",
                            result.detourMetres / 1_000
                        ),
                        image: UIImage(systemName: "plus.circle.fill")
                    )
                    mapped[ObjectIdentifier(item)] = SearchSelection(
                        generation: generation, purpose: .routeStop, value: result
                    )
                    return item
                }
                self.carPlayRouteSearchResults = mapped
                finish(items)
            }
            return
        }
        var requests: [MKLocalSearch.Request] = []
        if let coordinate = LocationService.shared.location?.coordinate {
            let local = MKLocalSearch.Request()
            local.naturalLanguageQuery = query
            local.region = .init(center: coordinate, latitudinalMeters: 300_000,
                                 longitudinalMeters: 300_000)
            requests.append(local)
        }
        let global = MKLocalSearch.Request()
        global.naturalLanguageQuery = query
        requests.append(global)
        activeCarPlaySearches.forEach { $0.cancel() }
        let searches = requests.map { MKLocalSearch(request: $0) }
        activeCarPlaySearches = searches
        let timeout = Task { [weak self] in
            try? await Task.sleep(nanoseconds: NavigationSearchTimeoutPolicy.timeoutNanoseconds)
            guard !Task.isCancelled else { return }
            searches.forEach { $0.cancel() }
            if generation == self?.carPlaySearchGeneration {
                self?.activeCarPlaySearches = []
                self?.carPlaySearchResults = [:]
            }
            finish([])
        }
        Task { [weak self] in
            let mapItems = await withTaskGroup(
                of: [MKMapItem].self, returning: [MKMapItem].self
            ) { group in
                for search in searches {
                    group.addTask { (try? await search.start().mapItems) ?? [] }
                }
                var combined: [MKMapItem] = []
                for await items in group { combined.append(contentsOf: items) }
                return combined
            }
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
            self.activeCarPlaySearches = []
            var mapped: [ObjectIdentifier: SearchSelection<MKMapItem>] = [:]
            let origin = LocationService.shared.location
            let ordered = mapItems.sorted { lhs, rhs in
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
                mapped[ObjectIdentifier(item)] = SearchSelection(
                    generation: generation, purpose: .destination, value: mapItem
                )
                return item
            }
            self.carPlaySearchResults = mapped
            finish(items)
        }
    }

    func searchTemplate(_ searchTemplate: CPSearchTemplate, selectedResult item: CPListItem,
                        completionHandler: @escaping () -> Void) {
        if let selection = carPlayRouteSearchResults[ObjectIdentifier(item)],
           CarPlaySearchSelectionPolicy.accepts(
               resultGeneration: selection.generation,
               currentGeneration: carPlaySearchGeneration,
               resultPurpose: selection.purpose,
               currentPurpose: carPlaySearchPurpose
           ) {
            let result = selection.value
            guard let start = LocationService.shared.location?.coordinate else {
                completionHandler()
                showFailure("Der aktuelle Standort ist nicht mehr verfügbar.")
                return
            }
            Task { [weak self] in
                let succeeded = await RoutePlanner.shared.addRouteStop(
                    result.mapItem, from: start, settings: .shared,
                    knownRouteProgress: result.routeProgress,
                    expectedRouteGeneration: result.routeGeneration
                )
                completionHandler()
                if succeeded {
                    self?.interfaceController?.popToRootTemplate(animated: true, completion: nil)
                } else {
                    self?.showFailure(
                        RoutePlanner.shared.errorMessage ??
                            "Der Zwischenstopp konnte nicht hinzugefügt werden."
                    )
                }
            }
            return
        }
        guard let selection = carPlaySearchResults[ObjectIdentifier(item)],
              CarPlaySearchSelectionPolicy.accepts(
                  resultGeneration: selection.generation,
                  currentGeneration: carPlaySearchGeneration,
                  resultPurpose: selection.purpose,
                  currentPurpose: carPlaySearchPurpose
              ),
              let start = LocationService.shared.location?.coordinate else {
            completionHandler()
            showFailure("Das Ziel oder der aktuelle Standort ist nicht mehr verfügbar.")
            return
        }
        let mapItem = selection.value
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
        let items = planner.actionableRouteSearchResults.prefix(10).map { result in
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
                        knownRouteProgress: result.routeProgress,
                        expectedRouteGeneration: result.routeGeneration
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

    private func presentStopReminder(_ message: String) {
        guard RoutePlanner.shared.isNavigating, let mapTemplate else { return }
        let variants = CarPlayStopReminderPresentationPolicy.titleVariants(for: message)
        guard !variants.isEmpty else { return }
        let symbol: String
        switch CarPlayStopReminderPresentationPolicy.kind(for: message) {
        case .rest: symbol = "cup.and.saucer.fill"
        case .fuel: symbol = "fuelpump.fill"
        case .combined: symbol = "car.fill"
        }
        let acknowledge = CPAlertAction(title: "OK", style: .default) { _ in }
        let alert = CPNavigationAlert(
            titleVariants: variants,
            subtitleVariants: nil,
            image: UIImage(systemName: symbol),
            primaryAction: acknowledge,
            secondaryAction: nil,
            duration: 8
        )
        mapTemplate.present(navigationAlert: alert, animated: true)
    }

    private func presentRouteRecoveryStateIfNeeded(
        recalculating: Bool,
        guidanceReliable: Bool
    ) {
        let state = CarPlayRouteRecoveryPresentationPolicy.state(
            recalculating: recalculating,
            guidanceReliable: guidanceReliable,
            matchingPosition: RoutePlanner.shared.isMatchingOfflinePosition
        )
        guard state != routeRecoveryPresentationState else { return }
        routeRecoveryPresentationState = state
        let titles = CarPlayRouteRecoveryPresentationPolicy.titleVariants(for: state)
        guard RoutePlanner.shared.isNavigating, !titles.isEmpty, let mapTemplate else { return }
        let acknowledge = CPAlertAction(title: "OK", style: .default) { _ in }
        let alert = CPNavigationAlert(
            titleVariants: titles,
            subtitleVariants: nil,
            image: UIImage(systemName: state == .searching
                           ? "arrow.triangle.2.circlepath"
                           : state == .matchingPosition
                           ? "location.magnifyingglass" : "exclamationmark.triangle.fill"),
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
            if #available(iOS 17.4, *) {
                maneuver.maneuverType = carPlayManeuverType(
                    CarPlayManeuverSemanticPolicy.semantic(for: presentation)
                )
                if let exit = presentation.highwayExitLabel {
                    maneuver.highwayExitLabel = exit
                }
                if let road = presentation.roadLabel {
                    maneuver.roadFollowingManeuverVariants = [road]
                }
            }
            if index == 0, let estimates = maneuverTravelEstimates() {
                maneuver.initialTravelEstimates = estimates
            }
            return maneuver
        }
    }

    @available(iOS 17.4, *)
    private func carPlayManeuverType(_ semantic: CarPlayManeuverSemantic) -> CPManeuverType {
        switch semantic {
        case .followRoad: return .followRoad
        case .straight: return .straightAhead
        case .slightRight: return .slightRightTurn
        case .right: return .rightTurn
        case .sharpRight: return .sharpRightTurn
        case .slightLeft: return .slightLeftTurn
        case .left: return .leftTurn
        case .sharpLeft: return .sharpLeftTurn
        case .uTurn: return .uTurn
        case .highwayOffRampLeft: return .highwayOffRampLeft
        case .highwayOffRampRight: return .highwayOffRampRight
        case .roundabout(let exit):
            switch exit {
            case 1: return .roundaboutExit1
            case 2: return .roundaboutExit2
            case 3: return .roundaboutExit3
            case 4: return .roundaboutExit4
            case 5: return .roundaboutExit5
            case 6: return .roundaboutExit6
            case 7: return .roundaboutExit7
            case 8: return .roundaboutExit8
            case 9: return .roundaboutExit9
            case 10: return .roundaboutExit10
            case 11: return .roundaboutExit11
            case 12: return .roundaboutExit12
            case 13: return .roundaboutExit13
            case 14: return .roundaboutExit14
            case 15: return .roundaboutExit15
            case 16: return .roundaboutExit16
            case 17: return .roundaboutExit17
            case 18: return .roundaboutExit18
            case 19: return .roundaboutExit19
            default: return .enterRoundabout
            }
        }
    }

    private func updateGuidanceEstimates() {
        guard let session = navigationSession else { return }
        // A confirmed route departure intentionally removes every stale
        // CPManeuver. Trip-level distance and ETA are still safe, useful
        // context and must continue updating while MapKit searches for the
        // replacement route or cached guidance is being rejoined.
        if let maneuver = session.upcomingManeuvers.first,
           let estimates = maneuverTravelEstimates() {
            session.updateEstimates(estimates, for: maneuver)
        }
        if let trip = activeTrip { mapTemplate?.updateEstimates(travelEstimates(), for: trip) }
    }

    private func maneuverTravelEstimates() -> CPTravelEstimates? {
        guard let distance = CarPlayManeuverEstimatePolicy.distance(
            RoutePlanner.shared.nextManeuverDistance
        ) else { return nil }
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
        let planner = RoutePlanner.shared
        if CarPlayTripStartPolicy.shouldStartNavigation(isNavigating: planner.isNavigating) {
            planner.startNavigation()
        }
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
