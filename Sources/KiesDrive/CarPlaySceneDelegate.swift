#if os(iOS)
import CarPlay
import Combine
import MapKit
import UIKit

/// Native CarPlay navigation surface. Navigation remains local in Kies Drive;
/// CarPlay is only another presentation and control surface for the shared trip.
@MainActor
final class CarPlaySceneDelegate: NSObject, CPTemplateApplicationSceneDelegate, CPMapTemplateDelegate {
    private var interfaceController: CPInterfaceController?
    private var carWindow: CPWindow?
    private var mapView: MKMapView?
    private var mapTemplate: CPMapTemplate?
    private var navigationSession: CPNavigationSession?
    private var activeTrip: CPTrip?
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
        let stops = CPMapButton { [weak self] _ in self?.showStops() }
        stops.image = UIImage(systemName: "fork.knife")
        return [follow, overview, stops]
    }

    private func followVehicle() {
        mapView?.setUserTrackingMode(.followWithHeading, animated: true)
    }

    private func showRouteOverview() {
        guard let mapView, !RoutePlanner.shared.legs.isEmpty else { return }
        let rect = RoutePlanner.shared.legs.reduce(MKMapRect.null) { $0.union($1.polyline.boundingMapRect) }
        mapView.setVisibleMapRect(rect, edgePadding: .init(top: 90, left: 55, bottom: 90, right: 55), animated: true)
    }

    private func showStops() {
        let planner = RoutePlanner.shared
        let items = planner.stations.prefix(8).map { station in
            let item = CPListItem(text: station.brand.isEmpty ? station.name : station.brand,
                                  detailText: String(format: "%.3f € · %.1f km", station.price, station.distanceKm))
            item.handler = { _, completion in
                guard let start = LocationService.shared.location?.coordinate else { completion(); return }
                Task {
                    await planner.toggleWaypoint(station, from: start, settings: .shared)
                    completion()
                }
            }
            return item
        }
        let empty = CPListItem(text: "Keine Stopps gefunden", detailText: "Die Suche wird entlang der Route begrenzt.")
        let list = CPListTemplate(title: "Auf der Route", sections: [CPListSection(items: items.isEmpty ? [empty] : items)])
        interfaceController?.pushTemplate(list, animated: true, completion: nil)
    }

    private func redrawRoute() {
        guard let mapView else { return }
        mapView.removeOverlays(mapView.overlays)
        RoutePlanner.shared.legs.forEach { mapView.addOverlay($0.polyline, level: .aboveRoads) }
        if mapView.userTrackingMode == .none { showRouteOverview() }
    }

    private func synchroniseNavigationSession() {
        let planner = RoutePlanner.shared
        guard planner.isNavigating, let destination = planner.destination, !planner.legs.isEmpty else {
            navigationSession?.finishTrip()
            navigationSession = nil
            activeTrip = nil
            return
        }
        if navigationSession == nil, let mapTemplate {
            let fallback = planner.legs[0].polyline.coordinate
            let origin = MKMapItem(placemark: MKPlacemark(coordinate: LocationService.shared.location?.coordinate ?? fallback))
            let choice = CPRouteChoice(summaryVariants: [destination.name ?? "Route"],
                                       additionalInformationVariants: [formatDistance(planner.totalDistance)],
                                       selectionSummaryVariants: [formatTime(planner.totalTravelTime)])
            let trip = CPTrip(origin: origin, destination: destination, routeChoices: [choice])
            activeTrip = trip
            navigationSession = mapTemplate.startNavigationSession(for: trip)
        }
        publishManeuver()
    }

    private func publishManeuver() {
        guard let session = navigationSession else { return }
        let maneuver = CPManeuver()
        maneuver.instructionVariants = [RoutePlanner.shared.nextInstruction ?? RoutePlanner.shared.lastAnnouncement ?? "Route folgen"]
        maneuver.initialTravelEstimates = travelEstimates()
        session.upcomingManeuvers = [maneuver]
    }

    private func updateGuidanceEstimates() {
        guard let session = navigationSession, let maneuver = session.upcomingManeuvers.first else { return }
        let estimates = travelEstimates()
        session.updateEstimates(estimates, for: maneuver)
        if let trip = activeTrip { mapTemplate?.updateEstimates(estimates, for: trip) }
    }

    private func travelEstimates() -> CPTravelEstimates {
        CPTravelEstimates(distanceRemaining: Measurement(value: max(RoutePlanner.shared.totalDistance, 0), unit: UnitLength.meters),
                          timeRemaining: max(RoutePlanner.shared.totalTravelTime, 0))
    }

    private func updateCamera(for location: CLLocation) {
        guard RoutePlanner.shared.isNavigating else { return }
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
