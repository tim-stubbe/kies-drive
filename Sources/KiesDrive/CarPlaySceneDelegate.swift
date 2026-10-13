#if os(iOS)
import CarPlay
import Combine
import MapKit
import UIKit

/// Native CarPlay navigation surface. Navigation remains local in Kies Drive;
/// CarPlay is only another presentation and control surface for the shared trip.
@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate, CPMapTemplateDelegate {
    private enum CameraMode { case follow, overview }
    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mapView: MKMapView?
    private var mapTemplate: CPMapTemplate?
    private var navigationSession: CPNavigationSession?
    private var activeTrip: CPTrip?
    private var cameraMode: CameraMode = .follow
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
        navigationSession = nil
        activeTrip = nil
        cancellables.removeAll()
        LocationService.shared.setNavigationActive(RoutePlanner.shared.isNavigating)
    }

    private func observeDriveState() {
        let planner = RoutePlanner.shared
        Publishers.CombineLatest4(planner.$legs, planner.$destination, planner.$isNavigating, planner.$lastAnnouncement)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _, _ in
                self?.redrawRoute()
                self?.synchroniseNavigationSession()
            }
            .store(in: &cancellables)

        Publishers.CombineLatest3(planner.$nextManeuverInstruction,
                                  planner.$nextManeuverDistance,
                                  planner.$upcomingManeuverInstructions)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, _, _ in
                self?.publishManeuver()
                self?.updateGuidanceEstimates()
            }
            .store(in: &cancellables)

        LocationService.shared.$location
            .compactMap { $0 }
            .receive(on: DispatchQueue.main)
            .sink { [weak self] location in
                self?.updateCamera(for: location)
                self?.updateGuidanceEstimates()
            }
            .store(in: &cancellables)
    }

    private func restoreLockedTripIfNeeded() {
        guard let coordinate = LocationService.shared.location?.coordinate else { return }
        Task { await RoutePlanner.shared.restoreActiveTripIfNeeded(from: coordinate, settings: .shared) }
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
            button.image = UIImage(systemName: DriveSettings.shared.voiceGuidance
                                   ? "speaker.wave.2.fill" : "speaker.slash.fill")
        }
        audio.image = UIImage(systemName: DriveSettings.shared.voiceGuidance ? "speaker.wave.2.fill" : "speaker.slash.fill")
        return [follow, overview, stops, audio]
    }

    private func followVehicle() {
        cameraMode = .follow
        mapView?.setUserTrackingMode(.followWithHeading, animated: true)
    }

    private func showRouteOverview() {
        guard let mapView else { return }
        let polylines = visibleRoutePolylines
        guard !polylines.isEmpty else { return }
        cameraMode = .overview
        mapView.setUserTrackingMode(.none, animated: false)
        let rect = polylines.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
        mapView.setVisibleMapRect(rect, edgePadding: .init(top: 90, left: 55, bottom: 90, right: 55), animated: true)
    }

    private func showDestinationsAndStops() {
        let planner = RoutePlanner.shared
        var items: [CPListItem] = []
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
            items.append(item)
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
            items.append(item)
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
            items.append(item)
        }
        items.append(contentsOf: planner.stations.prefix(3).map { station in
            let item = CPListItem(text: station.brand.isEmpty ? station.name : station.brand,
                                  detailText: String(format: "%.3f € · %.1f km", station.price, station.distanceKm))
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
                items.append(item)
            }
        }
        if items.isEmpty {
            items = [CPListItem(text: "Noch keine Ziele", detailText: "Lege Zuhause oder ein Ziel auf dem iPhone fest.")]
        }
        let list = CPListTemplate(title: "Ziele und Stopps", sections: [CPListSection(items: Array(items.prefix(12)))])
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }

    private func navigateHome(_ address: String) async {
        guard let start = LocationService.shared.location?.coordinate else {
            showFailure("Der aktuelle Standort ist noch nicht verfügbar.")
            return
        }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = address
        request.region = .init(center: start, latitudinalMeters: 500_000, longitudinalMeters: 500_000)
        guard let item = try? await MKLocalSearch(request: request).start().mapItems.first else {
            showFailure("Die Zuhause-Adresse konnte nicht gefunden werden.")
            return
        }
        await navigate(to: item, from: start)
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
        let start = LocationService.shared.location?.coordinate
        let items = planner.routeSearchResults.prefix(10).map { mapItem in
            let address = [mapItem.placemark.thoroughfare, mapItem.placemark.locality]
                .compactMap { $0 }.joined(separator: ", ")
            let item = CPListItem(text: mapItem.name ?? "Zwischenstopp",
                                  detailText: address.isEmpty ? "Entlang der Route" : address)
            item.handler = { _, completion in
                Task {
                    guard let start else {
                        completion()
                        self.showFailure("Der aktuelle Standort ist noch nicht verfügbar.")
                        return
                    }
                    let succeeded = await planner.addRouteStop(mapItem, from: start, settings: .shared)
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
        let alert = CPAlertTemplate(titleVariants: ["Aktion nicht möglich", message], actions: [action])
        interfaceController?.presentTemplate(alert, animated: true, completion: nil)
    }

    private func redrawRoute() {
        guard let mapView else { return }
        mapView.removeOverlays(mapView.overlays)
        visibleRoutePolylines.forEach { mapView.addOverlay($0, level: .aboveRoads) }
        if mapView.userTrackingMode == .none { showRouteOverview() }
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
            return
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
            navigationSession = mapTemplate.startNavigationSession(for: trip)
        }
        publishManeuver()
    }

    private func publishManeuver() {
        guard let session = navigationSession else { return }
        let planner = RoutePlanner.shared
        let instructions = planner.upcomingManeuverInstructions.isEmpty
            ? [planner.nextInstruction ?? planner.lastAnnouncement ?? "Route folgen"]
            : Array(planner.upcomingManeuverInstructions.prefix(3))
        session.upcomingManeuvers = instructions.enumerated().map { index, instruction in
            let maneuver = CPManeuver()
            maneuver.instructionVariants = [instruction]
            if index == 0 {
                maneuver.initialTravelEstimates = CPTravelEstimates(
                    distanceRemaining: Measurement(value: max(planner.nextManeuverDistance ?? 0, 0),
                                                   unit: UnitLength.meters),
                    timeRemaining: 0)
            }
            return maneuver
        }
    }

    private func updateGuidanceEstimates() {
        guard let session = navigationSession, let maneuver = session.upcomingManeuvers.first else { return }
        session.updateEstimates(maneuverTravelEstimates(), for: maneuver)
        if let trip = activeTrip { mapTemplate?.updateEstimates(travelEstimates(), for: trip) }
    }

    private func maneuverTravelEstimates() -> CPTravelEstimates {
        let distance = max(RoutePlanner.shared.nextManeuverDistance ?? 0, 0)
        let speed = max(LocationService.shared.location?.speed ?? 0, 0)
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
        guard RoutePlanner.shared.isNavigating, cameraMode == .follow else { return }
        let camera = MKMapCamera(lookingAtCenter: location.coordinate, fromDistance: 850, pitch: 55, heading: max(location.course, 0))
        mapView?.setCamera(camera, animated: true)
    }

    func mapTemplate(_ mapTemplate: CPMapTemplate, selectedPreviewFor trip: CPTrip, using routeChoice: CPRouteChoice) {}
    func mapTemplate(_ mapTemplate: CPMapTemplate, startedTrip trip: CPTrip, using routeChoice: CPRouteChoice) {
        RoutePlanner.shared.startNavigation()
        synchroniseNavigationSession()
    }
    func mapTemplateDidCancelNavigation(_ mapTemplate: CPMapTemplate) {
        RoutePlanner.shared.stopNavigation()
        navigationSession?.cancelTrip()
        navigationSession = nil
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
    func mapView(_ mapView: MKMapView, rendererFor overlay: MKOverlay) -> MKOverlayRenderer {
        guard let polyline = overlay as? MKPolyline else { return MKOverlayRenderer(overlay: overlay) }
        let renderer = MKPolylineRenderer(polyline: polyline)
        renderer.strokeColor = .systemBlue
        renderer.lineWidth = 7
        renderer.lineCap = .round
        renderer.lineJoin = .round
        return renderer
    }
}
#endif
