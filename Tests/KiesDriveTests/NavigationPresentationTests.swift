import XCTest
import CoreLocation
@testable import Kies_Drive

final class NavigationPresentationTests: XCTestCase {
    func testRemainingTimePreservesPerLegTravelCharacteristics() throws {
        let estimate = try XCTUnwrap(RouteRemainingTimePolicy.estimate(
            currentLegRemainingDistance: 25_000,
            currentLegDistance: 100_000,
            currentLegTravelTime: 2 * 3600,
            followingLegTravelTimes: [3600]
        ))

        XCTAssertEqual(estimate, 1.5 * 3600, accuracy: 1)
    }

    func testRemainingTimeClampsProgressAndRejectsInvalidLegs() throws {
        let estimate = try XCTUnwrap(RouteRemainingTimePolicy.estimate(
            currentLegRemainingDistance: 120_000,
            currentLegDistance: 100_000,
            currentLegTravelTime: 3600,
            followingLegTravelTimes: [1800, .nan, -20]
        ))

        XCTAssertEqual(estimate, 5400, accuracy: 1)
        XCTAssertNil(RouteRemainingTimePolicy.estimate(
            currentLegRemainingDistance: 1,
            currentLegDistance: 0,
            currentLegTravelTime: 10,
            followingLegTravelTimes: [20]
        ))
    }

    func testOfflineRemainingTimeKeepsFollowingLegEstimate() throws {
        let estimate = try XCTUnwrap(OfflineRouteRemainingTimePolicy.estimate(
            totalRemainingDistance: 125_000,
            currentLegIndex: 0,
            legs: [
                (distance: 100_000, travelTime: 2 * 3600),
                (distance: 100_000, travelTime: 3600),
            ]
        ))

        XCTAssertEqual(estimate, 1.5 * 3600, accuracy: 1)
    }

    func testOfflineRemainingTimeRejectsUnknownLeg() {
        XCTAssertNil(OfflineRouteRemainingTimePolicy.estimate(
            totalRemainingDistance: 1_000,
            currentLegIndex: 2,
            legs: [(distance: 1_000, travelTime: 60)]
        ))
    }

    func testManagedServerURLUsesProductionHTTPSConfiguration() {
        XCTAssertEqual(DriveSettings.configuredBaseURL(info: [
            DriveSettings.serverURLInfoKey: " https://drive.example.test/ "
        ]), "https://drive.example.test")
    }

    func testManagedServerURLRejectsUnsafeOrUnexpandedConfiguration() {
        XCTAssertEqual(DriveSettings.configuredBaseURL(info: [
            DriveSettings.serverURLInfoKey: "http://drive.example.test"
        ]), DriveSettings.standaloneBaseURL)
        XCTAssertEqual(DriveSettings.configuredBaseURL(info: [
            DriveSettings.serverURLInfoKey: "$(KIES_DRIVE_SERVER_URL)"
        ]), DriveSettings.standaloneBaseURL)
    }

    func testAlwaysLocationUpgradeIsRequestedOnlyForActiveGuidance() {
        XCTAssertTrue(NavigationLocationAuthorizationPolicy.shouldRequestAlways(
            navigationActive: true, hasWhenInUseAuthorization: true
        ))
        XCTAssertFalse(NavigationLocationAuthorizationPolicy.shouldRequestAlways(
            navigationActive: false, hasWhenInUseAuthorization: true
        ))
        XCTAssertFalse(NavigationLocationAuthorizationPolicy.shouldRequestAlways(
            navigationActive: true, hasWhenInUseAuthorization: false
        ))
        XCTAssertTrue(NavigationLocationAuthorizationPolicy.requiresSystemSettings(.denied))
        XCTAssertTrue(NavigationLocationAuthorizationPolicy.requiresSystemSettings(.restricted))
        XCTAssertFalse(NavigationLocationAuthorizationPolicy.requiresSystemSettings(.notDetermined))
    }

    func testBatchedLocationsAreProcessedChronologicallyWithoutExactDuplicates() {
        let base = Date(timeIntervalSince1970: 1_000)
        func location(_ seconds: TimeInterval, latitude: Double,
                      horizontalAccuracy: CLLocationAccuracy = 5) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: latitude, longitude: 8), altitude: 0,
                horizontalAccuracy: horizontalAccuracy, verticalAccuracy: 5,
                course: 0, speed: 15, timestamp: base.addingTimeInterval(seconds)
            )
        }
        let oldest = location(1, latitude: 50.0)
        let coarseJunction = location(2, latitude: 50.001, horizontalAccuracy: 75)
        let preciseJunction = location(2, latitude: 50.001, horizontalAccuracy: 4)
        let latest = location(3, latitude: 50.002)

        let ordered = NavigationLocationBatchPolicy.orderedDistinct([
            latest, coarseJunction, preciseJunction, oldest,
        ])

        XCTAssertEqual(ordered.map(\.timestamp), [oldest.timestamp, preciseJunction.timestamp, latest.timestamp])
        XCTAssertEqual(ordered.map(\.coordinate.latitude), [50.0, 50.001, 50.002])
        XCTAssertEqual(ordered[1].horizontalAccuracy, 4)
    }

    func testMotionPolicyRejectsNoisyOrImpossibleSpeeds() {
        XCTAssertEqual(NavigationMotionPolicy.reliableSpeed(
            speedMetresPerSecond: 27, speedAccuracy: 1.5, horizontalAccuracy: 12), 27)
        XCTAssertNil(NavigationMotionPolicy.reliableSpeed(
            speedMetresPerSecond: -1, speedAccuracy: 1, horizontalAccuracy: 12))
        XCTAssertNil(NavigationMotionPolicy.reliableSpeed(
            speedMetresPerSecond: 30, speedAccuracy: 12, horizontalAccuracy: 12))
        XCTAssertNil(NavigationMotionPolicy.reliableSpeed(
            speedMetresPerSecond: 95, speedAccuracy: 1, horizontalAccuracy: 12))
    }

    func testMotionPolicyKeepsCameraStableAtLowSpeed() {
        XCTAssertEqual(NavigationMotionPolicy.reliableCourse(
            courseDegrees: 182, courseAccuracy: 8, speedMetresPerSecond: 18), 182)
        XCTAssertNil(NavigationMotionPolicy.reliableCourse(
            courseDegrees: 182, courseAccuracy: 8, speedMetresPerSecond: 1))
        XCTAssertNil(NavigationMotionPolicy.reliableCourse(
            courseDegrees: 182, courseAccuracy: 80, speedMetresPerSecond: 18))
        XCTAssertNil(NavigationMotionPolicy.reliableCourse(
            courseDegrees: -1, courseAccuracy: 8, speedMetresPerSecond: 18))
    }

    func testGuidanceSpeedSurvivesBriefInvalidGPSReading() {
        let measuredAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(NavigationGuidanceSpeedPolicy.effective(
            current: nil, previous: 33.3, previousAt: measuredAt,
            now: measuredAt.addingTimeInterval(8)
        ), 33.3, accuracy: 0.01)
    }

    func testGuidanceSpeedExpiresToSafeCityFallback() {
        let measuredAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(NavigationGuidanceSpeedPolicy.effective(
            current: nil, previous: 33.3, previousAt: measuredAt,
            now: measuredAt.addingTimeInterval(30)
        ), NavigationGuidanceSpeedPolicy.fallbackMetresPerSecond, accuracy: 0.01)
        XCTAssertEqual(NavigationGuidanceSpeedPolicy.effective(
            current: 22, previous: 33.3, previousAt: measuredAt,
            now: measuredAt.addingTimeInterval(30)
        ), 22, accuracy: 0.01)
    }

    func testManeuverEstimateUsesMovementAndSensibleFallback() {
        XCTAssertEqual(NavigationEstimatePolicy.timeToManeuver(distanceMetres: 1_000, speedMetresPerSecond: 20), 50, accuracy: 0.01)
        XCTAssertEqual(NavigationEstimatePolicy.timeToManeuver(distanceMetres: 1_390, speedMetresPerSecond: 0), 100, accuracy: 0.1)
        XCTAssertEqual(NavigationEstimatePolicy.timeToManeuver(distanceMetres: 0, speedMetresPerSecond: 30), 0)
    }
    func testDeviationPolicyIgnoresStopsNoiseAndConvergingSlipRoads() {
        XCTAssertTrue(NavigationDeviationPolicy.isOutsideCorridor(
            distanceFromRoute: 180, horizontalAccuracy: 10, speedMetresPerSecond: 0
        ), "Offline guidance must freeze a distant instruction even while the car is stopped")
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
        XCTAssertFalse(NavigationDeviationPolicy.isConfirmed(
            elapsed: 30, consecutiveFixes: 2, speedMetresPerSecond: 30
        ))
        XCTAssertFalse(NavigationDeviationPolicy.isConfirmed(
            elapsed: 7, consecutiveFixes: 3, speedMetresPerSecond: 30
        ))
        XCTAssertTrue(NavigationDeviationPolicy.isConfirmed(
            elapsed: 8, consecutiveFixes: 3, speedMetresPerSecond: 30
        ))
    }

    func testDeviationCorridorIgnoresDistantFutureCrossing() {
        XCTAssertEqual(
            NavigationDeviationCorridorPolicy.indices(current: 4, stepCount: 80),
            2..<21
        )
        XCTAssertTrue(
            NavigationDeviationCorridorPolicy.indices(current: 4, stepCount: 80).contains(3),
            "A briefly advanced manoeuvre cursor must still include the road immediately behind it"
        )
        XCTAssertFalse(
            NavigationDeviationCorridorPolicy.indices(current: 4, stepCount: 80).contains(0),
            "Old route sections must not mask a genuine deviation"
        )
        XCTAssertFalse(
            NavigationDeviationCorridorPolicy.indices(current: 4, stepCount: 80).contains(60),
            "A much later route crossing must not hide a current wrong turn"
        )
    }

    func testDeviationCorridorClampsAtFinalStepAndInvalidCursor() {
        XCTAssertEqual(NavigationDeviationCorridorPolicy.indices(current: 78, stepCount: 80), 76..<80)
        XCTAssertEqual(NavigationDeviationCorridorPolicy.indices(current: 200, stepCount: 80), 77..<80)
        XCTAssertEqual(NavigationDeviationCorridorPolicy.indices(current: -5, stepCount: 3), 0..<3)
        XCTAssertEqual(NavigationDeviationCorridorPolicy.indices(current: 0, stepCount: 0), 0..<0)
    }

    func testFailedReroutesBackOffInsteadOfLooping() {
        let attemptedAt = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(NavigationRerouteRetryPolicy.cooldown(consecutiveFailures: 0), 45)
        XCTAssertEqual(NavigationRerouteRetryPolicy.cooldown(consecutiveFailures: 1), 120)
        XCTAssertEqual(NavigationRerouteRetryPolicy.cooldown(consecutiveFailures: 4), 300)
        XCTAssertFalse(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt, consecutiveFailures: 2,
            now: attemptedAt.addingTimeInterval(299)
        ))
        XCTAssertTrue(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt, consecutiveFailures: 2,
            now: attemptedAt.addingTimeInterval(300)
        ))
    }

    func testRerouteWatchdogEndsOnlyAfterBoundedWait() {
        let startedAt = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(NavigationRerouteWatchdogPolicy.hasTimedOut(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(NavigationRerouteWatchdogPolicy.timeout - 0.1)
        ))
        XCTAssertTrue(NavigationRerouteWatchdogPolicy.hasTimedOut(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(NavigationRerouteWatchdogPolicy.timeout)
        ))
        XCTAssertEqual(NavigationRerouteWatchdogPolicy.timeoutNanoseconds, 45_000_000_000)
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
        XCTAssertEqual(presentation.destinationLabel, "Neufahrn")
    }

    func testManeuverUsesFirstActionWhenInstructionMentionsFollowingTurn() {
        XCTAssertEqual(
            NavigationManeuverPresentation("Links halten, danach rechts abbiegen").direction,
            .slightLeft
        )
        XCTAssertEqual(
            NavigationManeuverPresentation("Scharf rechts, danach links").direction,
            .sharpRight
        )
    }

    func testDestinationSignOmitsRepeatedRoadAction() {
        let presentation = NavigationManeuverPresentation(
            "Ausfahrt 12 rechts Richtung Wiesbaden auf die A66"
        )
        XCTAssertEqual(presentation.exitLabel, "Ausfahrt 12")
        XCTAssertEqual(presentation.roadLabel, "A66")
        XCTAssertEqual(presentation.destinationLabel, "Wiesbaden")
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

    func testSpeechNormalisesCompactRoadNamesAndUnsafeCharacters() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("\u{FFFC} ↗ A66 • B40 – Richtung Köln (E40)"),
            "A 66, B 40, Richtung Köln, E 40."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Der BAB3 Richtung Passau folgen"),
            "Der Autobahn 3 Richtung Passau folgen."
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

    func testSpeechChainsOnlyCloseFollowingManeuver() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Rechts abbiegen", distance: 20,
                then: "links halten Richtung A 66", followingDistance: 180
            ),
            "Jetzt, Rechts abbiegen. Danach, Links halten Richtung A 66."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Rechts abbiegen", distance: 20,
                then: "links halten", followingDistance: 900
            ),
            "Jetzt, Rechts abbiegen."
        )
    }

    func testOfflineGuidanceMeasuresDistanceBetweenCloseManeuvers() throws {
        let points = [
            CLLocationCoordinate2D(latitude: 50.0000, longitude: 8.0000),
            CLLocationCoordinate2D(latitude: 50.0010, longitude: 8.0000),
            CLLocationCoordinate2D(latitude: 50.0020, longitude: 8.0000),
            CLLocationCoordinate2D(latitude: 50.0030, longitude: 8.0000),
        ]
        let steps = [
            OfflineGuidanceStep(instruction: "", distance: 111, coordinates: [points[0], points[1]]),
            OfflineGuidanceStep(instruction: "Rechts abbiegen", distance: 111, coordinates: [points[1], points[2]]),
            OfflineGuidanceStep(instruction: "Links halten", distance: 111, coordinates: [points[2], points[3]]),
        ]
        let progress = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: points[0], currentIndex: 0, steps: steps, transitionRadius: 12
        ))
        XCTAssertEqual(progress.followingManeuverDistance ?? -1, 111, accuracy: 0.1)
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

    func testSpeechPriorityProtectsImmediateManeuverFromStatusMessage() {
        XCTAssertEqual(NavigationSpeechPriority.forAnnouncementStage(.early), .maneuver)
        XCTAssertEqual(NavigationSpeechPriority.forAnnouncementStage(.now), .critical)
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .critical, incoming: .status
        ))
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .status, incoming: .maneuver
        ))
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .maneuver, incoming: .critical
        ))
    }

    func testNewRouteSeedsItsOwnFirstManeuverImmediately() throws {
        let seed = try XCTUnwrap(NavigationInitialManeuverPolicy.seed(steps: [
            (instruction: "", distance: 420),
            (instruction: "Rechts auf die A 66 fahren", distance: 1_200),
            (instruction: "Links halten Richtung Wiesbaden", distance: 800),
        ]))
        XCTAssertEqual(seed.instruction, "Rechts auf die A 66 fahren")
        XCTAssertEqual(seed.distance, 420)
        XCTAssertEqual(seed.upcomingInstructions, [
            "Rechts auf die A 66 fahren", "Links halten Richtung Wiesbaden"
        ])
        XCTAssertEqual(seed.followingManeuverDistance, 1_200)
    }

    func testNewRouteWithoutManeuverDoesNotReuseOldInstruction() {
        XCTAssertNil(NavigationInitialManeuverPolicy.seed(steps: [
            (instruction: "", distance: 200),
            (instruction: "   ", distance: 300),
        ]))
    }

    func testCarPlayGuidanceUsesOnlyRealRouteInstructions() {
        XCTAssertEqual(CarPlayGuidancePresentationPolicy.instructions(
            upcoming: [" Rechts abbiegen ", "", "Links halten", "Ausfahrt nehmen"],
            next: "Ignorierter alter Hinweis"
        ), ["Rechts abbiegen", "Links halten", "Ausfahrt nehmen"])
        XCTAssertEqual(CarPlayGuidancePresentationPolicy.instructions(
            upcoming: [], next: " Geradeaus fahren "
        ), ["Geradeaus fahren"])
        XCTAssertEqual(CarPlayGuidancePresentationPolicy.instructions(
            upcoming: ["  "], next: nil
        ), ["Route folgen"])
    }

    func testFinalCueHasEnoughHighSpeedReactionTime() {
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 320, speedKmh: 200), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 350, speedKmh: 200), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 190, speedKmh: 120), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 210, speedKmh: 120), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 80, speedKmh: 50), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 90, speedKmh: 50), .prepare)
    }

    func testManeuverDiagnosticsDetectMissingFinalCue() {
        XCTAssertTrue(ManeuverDiagnosticPolicy.missedFinalCue(stages: [.early, .prepare]))
        XCTAssertFalse(ManeuverDiagnosticPolicy.missedFinalCue(stages: [.early, .prepare, .now]))
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .routeTransition
        ))
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .arrival
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .userStopped
        ), "An explicit stop must not be diagnosed as a missed turn")
    }

    func testManeuverTransitionRecoversFinalCueOnlyOnceWhenGPSCrossesJunction() {
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early, .prepare]
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early, .prepare, .now]
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:1:Rechts abbiegen",
            stages: [.early, .prepare]
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: nil, nextKey: "0:1:Rechts abbiegen", stages: []
        ))
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

    func testDiagnosticReportIsReadableAndContainsNoInventedLocationTrail() {
        let event = DriveDiagnosticEvent(
            kind: .maneuverFinalCueMissed,
            date: Date(timeIntervalSince1970: 0),
            detail: "Rechts abbiegen\nauf die A66"
        )
        let report = DriveDiagnosticReport.text(events: [event], appVersion: "1.0 (42)")
        XCTAssertTrue(report.contains("App-Version: 1.0 (42)"))
        XCTAssertTrue(report.contains("maneuverFinalCueMissed"))
        XCTAssertTrue(report.contains("Rechts abbiegen auf die A66"))
        XCTAssertTrue(report.contains("Keine vollständige Standortspur"))
    }

    func testDiagnosticContextContainsQualityButNeverCoordinates() {
        let location = CLLocation(
            coordinate: .init(latitude: 50.123456, longitude: 8.654321),
            altitude: 0, horizontalAccuracy: 13.6, verticalAccuracy: 5,
            course: 90, speed: 27.8, timestamp: Date()
        )
        let detail = DriveDiagnosticDetail.navigationSample("Rechts abbiegen", location: location)
        XCTAssertEqual(detail, "Rechts abbiegen · GPS ±14 m · 100 km/h")
        XCTAssertFalse(detail.contains("50.123456"))
        XCTAssertFalse(detail.contains("8.654321"))
    }

    func testDiagnosticSummaryUsesOnlyLatestNavigationSession() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Alte Fahrt"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Alter Fehler"),
            DriveDiagnosticEvent(kind: .navigationStopped, detail: "Alte Fahrt"),
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Neue Fahrt"),
            DriveDiagnosticEvent(kind: .maneuverAnnounced, detail: "Rechts"),
            DriveDiagnosticEvent(kind: .locationRejected, detail: "GPS ±90 m"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertEqual(summary.rerouteFailures, 0)
        XCTAssertEqual(summary.rejectedLocations, 1)
        XCTAssertEqual(summary.resolvedRouteIssues, 0)
    }

    func testDiagnosticSummaryFlagsMissedFinalCue() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .maneuverFinalCueMissed, detail: "Ausfahrt"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.missedFinalCues, 1)
    }

    func testDiagnosticSummaryClearsTransientRouteFailureAfterSuccessfulRecovery() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Kein Netz"),
            DriveDiagnosticEvent(kind: .offlineRouteDeparture, detail: "Korridor verlassen"),
            DriveDiagnosticEvent(kind: .rerouteSucceeded, detail: "Online wiederhergestellt"),
            DriveDiagnosticEvent(kind: .maneuverAnnounced, detail: "Rechts"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.rerouteFailures, 0)
        XCTAssertEqual(summary.offlineRouteDepartures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 2)
        XCTAssertTrue(summary.recommendation.contains("automatisch behoben"))
    }

    func testDiagnosticSummaryKeepsFailureAfterLatestRecoveryOpen() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .rerouteSucceeded, detail: "Erholt"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Erneut kein Netz"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.rerouteFailures, 1)
        XCTAssertEqual(summary.resolvedRouteIssues, 0)
    }

    func testDiagnosticSummaryEndsAtStopAndIgnoresLateAsyncEvents() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .maneuverAnnounced, detail: "Rechts"),
            DriveDiagnosticEvent(kind: .navigationStopped, detail: "Fahrt beendet"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Verspätete Antwort"),
            DriveDiagnosticEvent(kind: .maneuverFinalCueMissed, detail: "Verspätete Diagnose"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertEqual(summary.rerouteFailures, 0)
        XCTAssertEqual(summary.missedFinalCues, 0)
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
        XCTAssertTrue(NavigationLocationPolicy.rejectionReason(
            for: jump, after: first, now: now
        )?.contains("Unplausibler GPS-Sprung") == true)
        XCTAssertEqual(NavigationLocationPolicy.rejectionReason(
            for: stale, after: nil, now: now
        ), "GPS-Messung ist veraltet")
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

    func testServerEndpointRequiresHTTPSOutsidePrivateNetworks() {
        XCTAssertNotNil(ServerEndpointPolicy.url(baseURL: "https://drive.example.com", path: "/auth/login"))
        XCTAssertNotNil(ServerEndpointPolicy.url(baseURL: "http://100.72.226.91:18080", path: "/auth/login"))
        XCTAssertNotNil(ServerEndpointPolicy.url(baseURL: "http://192.168.1.20:8080", path: "/auth/login"))
        XCTAssertNil(ServerEndpointPolicy.url(baseURL: "http://drive.example.com", path: "/auth/login"))
        XCTAssertNil(ServerEndpointPolicy.url(baseURL: "ftp://drive.example.com", path: "/auth/login"))
        XCTAssertEqual(ServerEndpointPolicy.url(
            baseURL: "https://drive.example.com", path: "/stations?fuel=e10&radius=8"
        )?.query, "fuel=e10&radius=8")
    }

    func testServerEndpointPreservesBasePathAndNormalisesSlash() throws {
        let url = try XCTUnwrap(ServerEndpointPolicy.url(
            baseURL: "https://drive.example.com/service/", path: "auth/login"
        ))
        XCTAssertEqual(url.absoluteString, "https://drive.example.com/service/auth/login")
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

    func testStepSelectionDoesNotDropFinalCueBeforeJunctionWithCoarseGPS() {
        let beforeJunction = [
            NavigationStepMetric(distanceFromRoute: 7, remainingOnStep: 22),
            NavigationStepMetric(distanceFromRoute: 9, remainingOnStep: 500),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: beforeJunction, transitionRadius: 30
        ), 0, "The current maneuver must remain active until the junction")

        let atJunction = [
            NavigationStepMetric(distanceFromRoute: 5, remainingOnStep: 7),
            NavigationStepMetric(distanceFromRoute: 6, remainingOnStep: 500),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: atJunction, transitionRadius: 30
        ), 1)
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

    func testStepRecoveryDoesNotSnapToDistantRouteCrossing() {
        var metrics = Array(repeating: NavigationStepMetric(distanceFromRoute: 600, remainingOnStep: 0),
                            count: 30)
        metrics[3] = .init(distanceFromRoute: 35, remainingOnStep: 400)
        metrics[25] = .init(distanceFromRoute: 2, remainingOnStep: 20_000)
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(current: 0, metrics: metrics,
                                                                    transitionRadius: 12), 3)
    }

    func testStepRecoveryCanCatchUpAcrossManyShortUrbanSteps() {
        var metrics = Array(repeating: NavigationStepMetric(
            distanceFromRoute: 700, remainingOnStep: 0, stepDistance: 120
        ), count: 50)
        metrics[31] = .init(distanceFromRoute: 12, remainingOnStep: 80, stepDistance: 120)

        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12
        ), 31)
    }

    func testMeasuredRecoveryStillPrefersEarlierPlausibleCrossing() {
        var metrics = Array(repeating: NavigationStepMetric(
            distanceFromRoute: 700, remainingOnStep: 0, stepDistance: 150
        ), count: 60)
        metrics[22] = .init(distanceFromRoute: 35, remainingOnStep: 90, stepDistance: 150)
        metrics[40] = .init(distanceFromRoute: 2, remainingOnStep: 600, stepDistance: 150)

        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12
        ), 22)
    }

    func testInitialOfflineRecoveryCanResumeFarBeyondShortRecoveryWindow() {
        var metrics = Array(repeating: NavigationStepMetric(
            distanceFromRoute: 3_000, remainingOnStep: 0
        ), count: 80)
        metrics[54] = .init(distanceFromRoute: 18, remainingOnStep: 700)
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12, allowsFullRecovery: true
        ), 54)
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12
        ), 0, "Ordinary updates must not jump across most of the route")
    }

    func testInitialOfflineRecoveryPrefersEarlierPlausibleSegmentAtCrossing() {
        var metrics = Array(repeating: NavigationStepMetric(
            distanceFromRoute: 2_000, remainingOnStep: 0
        ), count: 80)
        metrics[42] = .init(distanceFromRoute: 30, remainingOnStep: 600)
        metrics[70] = .init(distanceFromRoute: 2, remainingOnStep: 8_000)
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12, allowsFullRecovery: true
        ), 42)
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
        XCTAssertLessThan(progress.distanceFromRoute, 20)
    }

    func testOfflineGuidanceReportsDistanceFromCachedCorridor() throws {
        let steps = [
            OfflineGuidanceStep(instruction: "Geradeaus", distance: 1_000, coordinates: [
                .init(latitude: 50, longitude: 8), .init(latitude: 50, longitude: 8.014)
            ])
        ]

        let progress = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: .init(latitude: 50.01, longitude: 8.007), currentIndex: 0,
            steps: steps, transitionRadius: 12
        ))

        XCTAssertGreaterThan(progress.distanceFromRoute, 1_000)
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

    func testOfflineRecoveryPublishesOnlyACommittedActiveOnlineRoute() {
        XCTAssertTrue(OfflineRouteRecoveryPolicy.acceptsOnlineResult(
            calculationSucceeded: true, navigationActive: true,
            stillUsingOfflineGuidance: false
        ))
        XCTAssertFalse(OfflineRouteRecoveryPolicy.acceptsOnlineResult(
            calculationSucceeded: false, navigationActive: true,
            stillUsingOfflineGuidance: true
        ))
        XCTAssertFalse(OfflineRouteRecoveryPolicy.acceptsOnlineResult(
            calculationSucceeded: true, navigationActive: false,
            stillUsingOfflineGuidance: false
        ))
        XCTAssertFalse(OfflineRouteRecoveryPolicy.acceptsOnlineResult(
            calculationSucceeded: true, navigationActive: true,
            stillUsingOfflineGuidance: true
        ))
    }

    func testLockedTripRestoreRetriesAfterTransientFailureWithoutRequestStorm() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: false, attemptInProgress: false, lastAttempt: nil, now: now
        ))
        XCTAssertFalse(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: false, attemptInProgress: false,
            lastAttempt: now.addingTimeInterval(-89), now: now
        ))
        XCTAssertTrue(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: false, attemptInProgress: false,
            lastAttempt: now.addingTimeInterval(-90), now: now
        ))
        XCTAssertFalse(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: true, attemptInProgress: false, lastAttempt: nil, now: now
        ))
        XCTAssertFalse(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: false, attemptInProgress: true, lastAttempt: nil, now: now
        ))
    }

    func testTripRestorePrefersFreshOnlineThenOfflineBeforeStaleLiveRoute() {
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: true, hasLiveRoute: true,
            hasMatchingOfflineRoute: true
        ), .online)
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: false, hasLiveRoute: true,
            hasMatchingOfflineRoute: true
        ), .offline)
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: false, hasLiveRoute: true,
            hasMatchingOfflineRoute: false
        ), .staleLive)
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: false, hasLiveRoute: false,
            hasMatchingOfflineRoute: false
        ), .unavailable)
    }

    func testNavigationDestinationIdentityUsesRoadLevelTolerance() {
        let destination = CLLocationCoordinate2D(latitude: 50.0147, longitude: 8.3522)
        XCTAssertTrue(NavigationDestinationIdentityPolicy.matches(
            .init(latitude: 50.01475, longitude: 8.3522), destination
        ))
        XCTAssertFalse(NavigationDestinationIdentityPolicy.matches(
            .init(latitude: 50.02, longitude: 8.3522), destination
        ))
        XCTAssertFalse(NavigationDestinationIdentityPolicy.matches(nil, destination))
    }

    func testOnlyLatestDestinationActivationMayRestoreItsSnapshot() {
        let older = UUID()
        let latest = UUID()
        XCTAssertFalse(DestinationActivationRollbackPolicy.shouldRollback(
            request: older, current: latest
        ))
        XCTAssertTrue(DestinationActivationRollbackPolicy.shouldRollback(
            request: latest, current: latest
        ))
    }

    func testRouteEnrichmentRequiresMatchingRouteAndRequest() {
        let route = UUID()
        let request = UUID()
        XCTAssertTrue(RouteEnrichmentPublicationPolicy.isCurrent(
            route: route, currentRoute: route,
            request: request, currentRequest: request
        ))
        XCTAssertFalse(RouteEnrichmentPublicationPolicy.isCurrent(
            route: route, currentRoute: UUID(),
            request: request, currentRequest: request
        ))
        XCTAssertFalse(RouteEnrichmentPublicationPolicy.isCurrent(
            route: route, currentRoute: route,
            request: request, currentRequest: UUID()
        ))
    }

    func testFailedRouteMutationCannotRollbackNewerState() {
        XCTAssertTrue(RouteMutationRollbackPolicy.shouldRollback(
            current: ["fuel-a", "rest-b"], mutated: ["fuel-a", "rest-b"]
        ))
        XCTAssertFalse(RouteMutationRollbackPolicy.shouldRollback(
            current: ["fuel-a", "rest-b", "food-c"], mutated: ["fuel-a", "rest-b"]
        ))
    }

    func testAsyncGuidanceWorkCannotSurviveStopOrNewSession() {
        let session = UUID()
        let work = UUID()
        XCTAssertTrue(NavigationAsyncWorkPolicy.isCurrent(
            navigationActive: true,
            session: session, currentSession: session,
            work: work, currentWork: work
        ))
        XCTAssertFalse(NavigationAsyncWorkPolicy.isCurrent(
            navigationActive: false,
            session: session, currentSession: session,
            work: work, currentWork: work
        ))
        XCTAssertFalse(NavigationAsyncWorkPolicy.isCurrent(
            navigationActive: true,
            session: session, currentSession: UUID(),
            work: work, currentWork: work
        ))
        XCTAssertFalse(NavigationAsyncWorkPolicy.isCurrent(
            navigationActive: true,
            session: session, currentSession: session,
            work: work, currentWork: UUID()
        ))
    }

    func testOfflineCacheRequiresSameDestinationWhenCoordinatesAreAvailable() {
        let cached = CLLocationCoordinate2D(latitude: 50.0000, longitude: 8.0000)
        XCTAssertTrue(OfflineRouteCachePolicy.matches(
            cacheName: "Hauptstraße 1", cacheCoordinate: cached,
            destinationName: "Anderer Anzeigename",
            destinationCoordinate: .init(latitude: 50.0010, longitude: 8.0000)
        ))
        XCTAssertFalse(OfflineRouteCachePolicy.matches(
            cacheName: "Hauptstraße 1", cacheCoordinate: cached,
            destinationName: "Hauptstraße 1",
            destinationCoordinate: .init(latitude: 51.0000, longitude: 8.0000)
        ), "An identical place label must never override a clearly different coordinate")
    }

    func testLegacyOfflineCacheFallsBackToTrimmedName() {
        XCTAssertTrue(OfflineRouteCachePolicy.matches(
            cacheName: "  Hochheim am Main ", cacheCoordinate: nil,
            destinationName: "hochheim am main", destinationCoordinate: .init(latitude: 50, longitude: 8)
        ))
        XCTAssertFalse(OfflineRouteCachePolicy.matches(
            cacheName: "Hochheim am Main", cacheCoordinate: nil,
            destinationName: "Hochheim bei Erfurt", destinationCoordinate: .init(latitude: 51, longitude: 11)
        ))
    }

    func testOfflineGuidanceRejectsExpiredAndInvalidFutureCaches() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(-6 * 24 * 60 * 60), now: now
        ))
        XCTAssertFalse(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(-8 * 24 * 60 * 60), now: now
        ))
        XCTAssertTrue(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
            belongsToActiveTrip: true, now: now
        ))
        XCTAssertFalse(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            belongsToActiveTrip: true, now: now
        ))
        XCTAssertTrue(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(4 * 60), now: now
        ))
        XCTAssertFalse(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(10 * 60), now: now
        ))
    }

    func testExtendedOfflineRetentionRequiresExactActiveTripIdentity() {
        let firstTrip = UUID()
        let secondTrip = UUID()
        XCTAssertTrue(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: firstTrip, activeTripID: firstTrip, active: true
        ))
        XCTAssertFalse(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: firstTrip, activeTripID: secondTrip, active: true
        ))
        XCTAssertFalse(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: nil, activeTripID: firstTrip, active: true
        ))
        XCTAssertFalse(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: firstTrip, activeTripID: firstTrip, active: false
        ))
    }

    func testOfflineRouteIsNeverDisplayedWithoutMatchingActiveDestination() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let cached = CLLocationCoordinate2D(latitude: 50.0, longitude: 8.0)
        XCTAssertFalse(OfflineRouteAvailabilityPolicy.isUsable(
            savedAt: now, cacheName: "Altes Ziel", cacheCoordinate: cached,
            destinationName: nil, destinationCoordinate: nil, now: now
        ))
        XCTAssertFalse(OfflineRouteAvailabilityPolicy.isUsable(
            savedAt: now, cacheName: "Altes Ziel", cacheCoordinate: cached,
            destinationName: "Neues Ziel",
            destinationCoordinate: .init(latitude: 51, longitude: 9),
            belongsToActiveTrip: true, now: now
        ))
        XCTAssertTrue(OfflineRouteAvailabilityPolicy.isUsable(
            savedAt: now, cacheName: "Ziel", cacheCoordinate: cached,
            destinationName: "Ziel",
            destinationCoordinate: .init(latitude: 50.001, longitude: 8), now: now
        ))
        XCTAssertTrue(OfflineRouteAvailabilityPolicy.isUsable(
            savedAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
            cacheName: "Ziel", cacheCoordinate: cached,
            destinationName: "Ziel",
            destinationCoordinate: .init(latitude: 50.001, longitude: 8),
            belongsToActiveTrip: true, now: now
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

    func testRouteSearchAheadCheckUsesDistanceProgress() {
        XCTAssertTrue(RouteSearchPolicy.isAhead(candidateProgress: 0.49, currentProgress: 0.50))
        XCTAssertFalse(RouteSearchPolicy.isAhead(candidateProgress: 0.40, currentProgress: 0.50))
        XCTAssertTrue(RouteSearchPolicy.isAhead(candidateProgress: 0.75, currentProgress: 0.50))
    }

    func testRouteSearchQueriesOnlyTheRemainingRoute() {
        let route = (0...10).map {
            CLLocationCoordinate2D(latitude: 50, longitude: 8 + Double($0) / 100)
        }
        let remaining = RouteSearchPolicy.remainingRouteCoordinates(route, currentProgress: 0.6)
        XCTAssertLessThan(remaining.count, route.count)
        XCTAssertGreaterThanOrEqual(remaining.first?.longitude ?? 0, 8.05)
        XCTAssertEqual(remaining.last?.longitude, route.last?.longitude)
    }

    func testRouteSearchRadiusScalesWithoutFloodingLocalSearch() {
        let short = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50.1, longitude: 8),
        ]
        let long = [
            CLLocationCoordinate2D(latitude: 45, longitude: 8),
            CLLocationCoordinate2D(latitude: 55, longitude: 8),
        ]
        XCTAssertEqual(RouteSearchPolicy.searchRadiusMetres(
            routeCoordinates: short, searchPointCount: 5
        ), 15_000, accuracy: 1)
        XCTAssertGreaterThan(RouteSearchPolicy.searchRadiusMetres(
            routeCoordinates: long, searchPointCount: 5
        ), 100_000)
        XCTAssertLessThanOrEqual(RouteSearchPolicy.searchRadiusMetres(
            routeCoordinates: long, searchPointCount: 5
        ), 150_000)
    }

    func testRouteSearchRejectsExcessiveOrInvalidDrivingDetours() {
        XCTAssertTrue(RouteSearchPolicy.acceptsDetour(4_500))
        XCTAssertTrue(RouteSearchPolicy.acceptsDetour(20_000))
        XCTAssertFalse(RouteSearchPolicy.acceptsDetour(20_001))
        XCTAssertFalse(RouteSearchPolicy.acceptsDetour(.infinity))
        XCTAssertFalse(RouteSearchPolicy.acceptsDetour(-1))
    }

    func testRouteSearchOnlyEstimatesSmallUnverifiedDetours() throws {
        XCTAssertEqual(
            try XCTUnwrap(RouteSearchPolicy.estimatedDetour(airDistance: 900)),
            1_800,
            accuracy: 0.1
        )
        XCTAssertEqual(RouteSearchPolicy.estimatedDetour(airDistance: 3_000), 6_000)
        XCTAssertNil(RouteSearchPolicy.estimatedDetour(airDistance: 3_001))
        XCTAssertNil(RouteSearchPolicy.estimatedDetour(airDistance: .infinity))
        XCTAssertNil(RouteSearchPolicy.estimatedDetour(airDistance: -1))
    }

    func testRouteSearchCompletionPublishesOnlyForCurrentGeometryAndQuery() {
        let request = UUID()
        let route = UUID()
        XCTAssertEqual(RouteSearchCompletionPolicy.disposition(
            request: request, currentRequest: request,
            routeGeneration: route, currentRouteGeneration: route,
            query: "McDonald’s", currentQuery: "McDonald’s"
        ), .publish)
    }

    func testRouteSearchCompletionFinishesSpinnerWhenOwnedSearchBecomesStale() {
        let request = UUID()
        XCTAssertEqual(RouteSearchCompletionPolicy.disposition(
            request: request, currentRequest: request,
            routeGeneration: UUID(), currentRouteGeneration: UUID(),
            query: "Tankstelle", currentQuery: "Tankstelle"
        ), .discardAndFinish)
        let route = UUID()
        XCTAssertEqual(RouteSearchCompletionPolicy.disposition(
            request: request, currentRequest: request,
            routeGeneration: route, currentRouteGeneration: route,
            query: "Tankstelle", currentQuery: "Raststätte"
        ), .discardAndFinish)
    }

    func testOlderRouteSearchCannotFinishNewerSearchState() {
        let route = UUID()
        XCTAssertEqual(RouteSearchCompletionPolicy.disposition(
            request: UUID(), currentRequest: UUID(),
            routeGeneration: route, currentRouteGeneration: route,
            query: "Essen", currentQuery: "Essen"
        ), .superseded)
    }
}
