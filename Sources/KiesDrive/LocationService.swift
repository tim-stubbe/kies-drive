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
        if NavigationLocationAuthorizationPolicy.shouldRequestAlways(
            navigationActive: active,
            hasWhenInUseAuthorization: manager.authorizationStatus == .authorizedWhenInUse
        ) {
            manager.requestAlwaysAuthorization()
        }
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
        let deliveredAt = Date()
        let guidanceSamples = NavigationLocationBatchPolicy.orderedDistinct(locations)
        guard let latest = guidanceSamples.last else { return }
        // Buffered samples are trusted only when Core Location finishes the
        // batch with a normal, current and physically plausible fix. Keep the
        // previously published fix when GPS briefly jumps: otherwise the map,
        // remote status and trip restore could all show the same bad position
        // even though turn guidance correctly rejected it.
        let batchEndsWithFreshFix = NavigationLocationPolicy.accepts(
            latest, after: location, now: deliveredAt
        )
        if batchEndsWithFreshFix { location = latest }

        // Navigation progress must be driven by Core Location itself, not by
        // a SwiftUI `onReceive` callback. SwiftUI view updates are not a
        // reliable execution path while the display is locked, the app is in
        // the background, or CarPlay owns the visible navigation surface.
        // Keeping this here also guarantees exactly one progress update per
        // distinct delivered GPS fix across the phone, Mac and CarPlay
        // presentations. Core Location may deliver a batch after tunnels or
        // background execution; processing only its last value can jump over
        // a junction and suppress the final maneuver cue.
        let planner = RoutePlanner.shared
        // `isNavigating` also covers guidance restored from the persisted
        // offline cache, where no fresh MapKit `legs` exist yet.
        if planner.isNavigating, batchEndsWithFreshFix {
            for sample in guidanceSamples where planner.isNavigating {
                planner.updateProgress(
                    at: sample,
                    settings: .shared,
                    evaluationDate: deliveredAt,
                    maximumLocationAge: NavigationLocationBatchPolicy.maximumBufferedSampleAge
                )
            }
        }

        guard batchEndsWithFreshFix else { return }
        Task {
            // A cached, stale or kilometre-uncertain first fix must not spend
            // the restore attempt or calculate a route from the wrong place.
            await planner.restoreActiveTripIfNeeded(from: latest.coordinate, settings: .shared)
            await DriveRemoteBridge.shared.sync(location: latest)
        }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateHeading newHeading: CLHeading) {
        guard newHeading.headingAccuracy >= 0 else { return }
        heading = newHeading
    }
}
