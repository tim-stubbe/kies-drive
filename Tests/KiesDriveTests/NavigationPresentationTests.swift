import XCTest
import CoreLocation
@testable import Kies_Drive

final class NavigationPresentationTests: XCTestCase {
    func testManeuverEstimateUsesMovementAndSensibleFallback() {
        XCTAssertEqual(NavigationEstimatePolicy.timeToManeuver(distanceMetres: 1_000, speedMetresPerSecond: 20), 50, accuracy: 0.01)
        XCTAssertEqual(NavigationEstimatePolicy.timeToManeuver(distanceMetres: 1_390, speedMetresPerSecond: 0), 100, accuracy: 0.1)
        XCTAssertEqual(NavigationEstimatePolicy.timeToManeuver(distanceMetres: 0, speedMetresPerSecond: 30), 0)
    }
    func testDeviationPolicyIgnoresStopsNoiseAndConvergingSlipRoads() {
        XCTAssertFalse(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 250, previousDistance: 230, horizontalAccuracy: 12, speedMetresPerSecond: 0.5))
        XCTAssertFalse(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 250, previousDistance: 320, horizontalAccuracy: 12, speedMetresPerSecond: 20))
        XCTAssertFalse(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 250, previousDistance: 230, horizontalAccuracy: 90, speedMetresPerSecond: 20))
    }

    func testDeviationPolicyRequiresSustainedMovingDeparture() {
        XCTAssertTrue(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 210, previousDistance: 190, horizontalAccuracy: 15, speedMetresPerSecond: 20))
        XCTAssertEqual(NavigationDeviationPolicy.confirmationDuration(speedMetresPerSecond: 20), 12)
        XCTAssertEqual(NavigationDeviationPolicy.confirmationDuration(speedMetresPerSecond: 30), 8)
    }

    func testRemoteSyncPolicyIsFastOnlyDuringNavigationAndRejectsBadFixes() {
        XCTAssertEqual(DriveRemoteSyncPolicy.interval(navigationActive: true), 5)
        XCTAssertEqual(DriveRemoteSyncPolicy.interval(navigationActive: false), 15)
        XCTAssertTrue(DriveRemoteSyncPolicy.accepts(CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 20, verticalAccuracy: 20, timestamp: Date()
        )))
        XCTAssertFalse(DriveRemoteSyncPolicy.accepts(CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 250, verticalAccuracy: 20, timestamp: Date()
        )))
    }
    func testExitNumberAndDirectionAreExtracted() {
        let presentation = NavigationManeuverPresentation("Ausfahrt 69 rechts Richtung Neufahrn nehmen")
        XCTAssertEqual(presentation.exitLabel, "Ausfahrt 69")
        XCTAssertEqual(presentation.direction, .right)
        XCTAssertEqual(presentation.destinationLabel, "Neufahrn nehmen")
    }

    func testFollowingRoadDefaultsToStraight() {
        let presentation = NavigationManeuverPresentation("Der A9 folgen")
        XCTAssertEqual(presentation.direction, .straight)
        XCTAssertEqual(presentation.roadLabel, "A9")
    }

    func testRoadShieldAllowsWhitespace() {
        XCTAssertEqual(NavigationManeuverPresentation("Auf die A 10 fahren").roadLabel, "A10")
    }

    func testMapChoicesExcludePureSatelliteMode() {
        XCTAssertEqual(DriveMapAppearance.allCases, [.standard, .hybrid])
    }

    func testRemoteStateUsesServerCompatibleSnakeCaseKeys() throws {
        let state = DriveRemoteState(
            location: .init(latitude: 50, longitude: 8, accuracyMetres: 4),
            headingDegrees: 180, speedKmh: 90,
            activeRoute: .init(destination: "Hochheim", distanceMetres: 1_000, travelTimeSeconds: 60),
            nextManeuver: .init(instruction: "Rechts abbiegen", distanceMetres: 120), routeLock: nil,
            navigationActive: true, recordedAt: Date(timeIntervalSince1970: 1))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])

        XCTAssertEqual(object["heading_degrees"] as? Double, 180)
        XCTAssertEqual(object["speed_kmh"] as? Double, 90)
        XCTAssertNotNil(object["active_route"])
        XCTAssertNotNil(object["next_maneuver"])
        let maneuver = try XCTUnwrap(object["next_maneuver"] as? [String: Any])
        XCTAssertEqual(maneuver["distance_metres"] as? Double, 120)
        XCTAssertEqual(object["navigation_active"] as? Bool, true)
        XCTAssertNil(object["headingDegrees"])
    }

    func testSpeechInstructionsRemoveSymbolsAndSoundLikeSentences() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("rechts ↗ Richtung A 66 / Wiesbaden", distance: 112),
            "In 100 Metern, Rechts Richtung A 66, Wiesbaden."
        )
    }

    func testSpeechInstructionUsesImmediateCueNearManeuver() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("links abbiegen", distance: 20),
            "Jetzt, Links abbiegen."
        )
    }

    func testSpeechUsesNaturalKilometreDistance() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Ausfahrt rechts nehmen", distance: 1_760),
            "In 2 Kilometern, Ausfahrt rechts nehmen."
        )
    }

    func testAnnouncementStagesAdaptToRoadSpeed() {
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 850, speedKmh: 120), .early)
        XCTAssertNil(NavigationAnnouncementStage.stage(distance: 850, speedKmh: 50))
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 200, speedKmh: 50), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 30, speedKmh: 50), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 1_700, speedKmh: 200), .early)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 650, speedKmh: 200), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 120, speedKmh: 200), .now)
    }

    func testFinalCueHasEnoughHighSpeedReactionTime() {
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 210, speedKmh: 200), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 250, speedKmh: 200), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 125, speedKmh: 120), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 170, speedKmh: 120), .prepare)
    }

    func testManeuverDiagnosticsDetectMissingFinalCue() {
        XCTAssertTrue(ManeuverDiagnosticPolicy.missedFinalCue(stages: [.early, .prepare]))
        XCTAssertFalse(ManeuverDiagnosticPolicy.missedFinalCue(stages: [.early, .prepare, .now]))
    }

    func testRecentDestinationsDeduplicateAndKeepLatestFirst() {
        let suite = "DriveHistoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = RecentDestination(name: "Zuhause", subtitle: "A", latitude: 50, longitude: 8,
                                      lastUsedAt: Date(timeIntervalSince1970: 1))
        let newer = RecentDestination(name: "Zuhause neu", subtitle: "B", latitude: 50, longitude: 8,
                                      lastUsedAt: Date(timeIntervalSince1970: 2))
        _ = RecentDestinationStore.record(first, defaults: defaults)
        let values = RecentDestinationStore.record(newer, defaults: defaults)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.name, "Zuhause neu")
    }

    func testFavoritesRoundTripForPhoneAndCarPlay() {
        let suite = "DriveFavoriteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = [
            DriveFavorite(name: "Büro", subtitle: "Mainz", latitude: 50.01, longitude: 8.27),
            DriveFavorite(name: "Hotel", subtitle: "Graz", latitude: 47.07, longitude: 15.44)
        ]
        DriveFavoriteStore.save(favorites, defaults: defaults)
        XCTAssertEqual(DriveFavoriteStore.load(defaults: defaults), favorites)
    }

    func testDiagnosticsAreBounded() {
        let suite = "DriveDiagnosticTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for index in 0..<120 {
            DriveDiagnosticStore.append(.routeCalculated, detail: "\(index)", defaults: defaults)
        }
        let events = DriveDiagnosticStore.load(defaults: defaults)
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(events.first?.detail, "20")
        XCTAssertEqual(events.last?.detail, "119")
    }

    func testNavigationLocationPolicyRejectsImpossibleJumpAndStaleFix() {
        let now = Date()
        let first = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                               horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-2))
        let jump = CLLocation(coordinate: .init(latitude: 51, longitude: 9), altitude: 0,
                              horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-1))
        let stale = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                               horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-60))
        XCTAssertFalse(NavigationLocationPolicy.accepts(jump, after: first, now: now))
        XCTAssertFalse(NavigationLocationPolicy.accepts(stale, after: nil, now: now))
    }

    func testNavigationLocationPolicyAcceptsNormalMovement() {
        let now = Date()
        let first = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                               horizontalAccuracy: 8, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-2))
        let next = CLLocation(coordinate: .init(latitude: 50.0005, longitude: 8), altitude: 0,
                              horizontalAccuracy: 8, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-1))
        XCTAssertTrue(NavigationLocationPolicy.accepts(next, after: first, now: now))
    }

    func testArrivalRequiresAccurateSlowFixNearDestination() {
        let destination = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        let nearAndSlow = CLLocation(coordinate: destination, altitude: 0,
                                     horizontalAccuracy: 8, verticalAccuracy: 5,
                                     course: 0, speed: 2, timestamp: Date())
        let fast = CLLocation(coordinate: destination, altitude: 0,
                              horizontalAccuracy: 8, verticalAccuracy: 5,
                              course: 0, speed: 20, timestamp: Date())
        XCTAssertTrue(NavigationArrivalPolicy.isArrivalFix(nearAndSlow, destination: destination))
        XCTAssertFalse(NavigationArrivalPolicy.isArrivalFix(fast, destination: destination))
    }

    func testAccountLoginResponseDecodesServerSession() throws {
        let data = Data(#"{"session":"secure-session","expires_at":"2026-11-01T00:00:00Z","email":"driver@example.com","two_factor_enabled":true}"#.utf8)
        let response = try JSONDecoder().decode(AccountLoginResponse.self, from: data)
        XCTAssertEqual(response.session, "secure-session")
        XCTAssertEqual(response.email, "driver@example.com")
        XCTAssertTrue(response.twoFactorEnabled)
    }

    func testStepSelectionDoesNotJumpToNearbyFutureRamp() {
        let metrics = [
            NavigationStepMetric(distanceFromRoute: 4, remainingOnStep: 600),
            NavigationStepMetric(distanceFromRoute: 2, remainingOnStep: 900),
            NavigationStepMetric(distanceFromRoute: 3, remainingOnStep: 1_200),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(current: 0, metrics: metrics,
                                                                    transitionRadius: 10), 0)
    }

    func testStepSelectionAdvancesSequentiallyAtJunction() {
        let metrics = [
            NavigationStepMetric(distanceFromRoute: 5, remainingOnStep: 4),
            NavigationStepMetric(distanceFromRoute: 6, remainingOnStep: 500),
            NavigationStepMetric(distanceFromRoute: 3, remainingOnStep: 900),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(current: 0, metrics: metrics,
                                                                    transitionRadius: 10), 1)
    }

    func testStepSelectionRecoversForwardAfterLargeLocationGap() {
        let metrics = [
            NavigationStepMetric(distanceFromRoute: 700, remainingOnStep: 0),
            NavigationStepMetric(distanceFromRoute: 550, remainingOnStep: 0),
            NavigationStepMetric(distanceFromRoute: 7, remainingOnStep: 300),
            NavigationStepMetric(distanceFromRoute: 20, remainingOnStep: 800),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(current: 0, metrics: metrics,
                                                                    transitionRadius: 12), 2)
    }

    func testOfflineGuidanceFindsNextManeuverAlongCachedGeometry() throws {
        let steps = [
            OfflineGuidanceStep(instruction: "", distance: 1_000, coordinates: [
                .init(latitude: 50, longitude: 8), .init(latitude: 50, longitude: 8.014)
            ]),
            OfflineGuidanceStep(instruction: "Rechts auf die B 40 abbiegen", distance: 700, coordinates: [
                .init(latitude: 50, longitude: 8.014), .init(latitude: 49.994, longitude: 8.014)
            ]),
            OfflineGuidanceStep(instruction: "Links Richtung Ziel", distance: 300, coordinates: [
                .init(latitude: 49.994, longitude: 8.014), .init(latitude: 49.994, longitude: 8.01)
            ]),
        ]
        let progress = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: .init(latitude: 50, longitude: 8.007), currentIndex: 0,
            steps: steps, transitionRadius: 15
        ))

        XCTAssertEqual(progress.currentStepIndex, 0)
        XCTAssertEqual(progress.maneuverStepIndex, 1)
        XCTAssertEqual(progress.instruction, "Rechts auf die B 40 abbiegen")
        XCTAssertGreaterThan(progress.distanceToManeuver, 400)
        XCTAssertLessThan(progress.distanceToManeuver, 600)
        XCTAssertEqual(progress.upcomingInstructions.count, 2)
    }

    func testOfflineGuidanceDoesNotJumpToNearbyFutureParallelStep() throws {
        let steps = [
            OfflineGuidanceStep(instruction: "", distance: 1_000, coordinates: [
                .init(latitude: 50, longitude: 8), .init(latitude: 50, longitude: 8.014)
            ]),
            OfflineGuidanceStep(instruction: "Rechts abbiegen", distance: 1_000, coordinates: [
                .init(latitude: 50.00005, longitude: 8), .init(latitude: 50.00005, longitude: 8.014)
            ]),
        ]
        let progress = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: .init(latitude: 50, longitude: 8.003), currentIndex: 0,
            steps: steps, transitionRadius: 12
        ))
        XCTAssertEqual(progress.currentStepIndex, 0)
        XCTAssertEqual(progress.maneuverStepIndex, 1)
    }

    func testOfflineRecoveryIsThrottled() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(OfflineRouteRecoveryPolicy.shouldAttempt(lastAttempt: nil, now: now))
        XCTAssertFalse(OfflineRouteRecoveryPolicy.shouldAttempt(
            lastAttempt: now.addingTimeInterval(-89), now: now
        ))
        XCTAssertTrue(OfflineRouteRecoveryPolicy.shouldAttempt(
            lastAttempt: now.addingTimeInterval(-90), now: now
        ))
    }

    func testRouteSearchNeverSuggestsMateriallyPassedStops() {
        XCTAssertFalse(RouteSearchPolicy.isAhead(candidateIndex: 20, currentIndex: 60,
                                                 routePointCount: 100))
        XCTAssertTrue(RouteSearchPolicy.isAhead(candidateIndex: 58, currentIndex: 60,
                                                routePointCount: 100))
        XCTAssertTrue(RouteSearchPolicy.isAhead(candidateIndex: 75, currentIndex: 60,
                                                routePointCount: 100))
    }
}
