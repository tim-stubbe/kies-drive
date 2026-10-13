import Foundation
@preconcurrency import CoreLocation

@MainActor
final class LocationService: NSObject, ObservableObject, @preconcurrency CLLocationManagerDelegate {
    /// Gemeinsame Instanz für die SwiftUI-Oberfläche und die CarPlay-Szene.
    static let shared = LocationService()

    @Published var location: CLLocation?
    @Published var heading: CLHeading?
    @Published var authorization: CLAuthorizationStatus = .notDetermined
    private let manager = CLLocationManager()
    private var started = false

    override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = 25
        manager.activityType = .automotiveNavigation
        #if os(iOS)
        manager.headingFilter = 3
        manager.headingOrientation = .portrait
        #endif
        authorization = manager.authorizationStatus
    }

    func start() {
        #if targetEnvironment(simulator)
        // UI previews use a deterministic camera and must not be blocked by
        // system permission sheets. Real devices still request full access.
        return
        #else
        guard !started else { return }
        started = true
        #if os(iOS)
        // "Always" statt nur "when in use", damit Ansagen und CarPlay-
        // Navigation auch bei gesperrtem Bildschirm weiterlaufen.
        manager.requestAlwaysAuthorization()
        manager.allowsBackgroundLocationUpdates = false
        manager.pausesLocationUpdatesAutomatically = true
        #else
        manager.requestAlwaysAuthorization()
        #endif
        manager.startUpdatingLocation()
        if CLLocationManager.headingAvailable() { manager.startUpdatingHeading() }
        DriveRemoteBridge.shared.start()
        #endif
    }

    /// Uses full navigation GPS only during guidance. While browsing/searching
    /// a lower update rate is sufficient and avoids running the receiver at
    /// maximum power for the whole time the app is open.
    func setNavigationActive(_ active: Bool) {
        manager.desiredAccuracy = active ? kCLLocationAccuracyBestForNavigation : kCLLocationAccuracyNearestTenMeters
        manager.distanceFilter = active ? 8 : 25
        #if os(iOS)
        manager.allowsBackgroundLocationUpdates = active
        manager.pausesLocationUpdatesAutomatically = !active
        #endif
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        authorization = manager.authorizationStatus
        #if os(iOS)
        if authorization == .authorizedAlways || authorization == .authorizedWhenInUse { manager.startUpdatingLocation() }
        #else
        if authorization == .authorizedAlways { manager.startUpdatingLocation() }
        #endif
    }
    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        location = locations.last
        if let location { Task { await DriveRemoteBridge.shared.sync(location: location) } }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        heading = newHeading
    }
}
