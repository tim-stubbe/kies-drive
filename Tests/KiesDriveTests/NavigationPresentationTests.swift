import XCTest
import CoreLocation
import MapKit
@testable import Kies_Drive

final class NavigationPresentationTests: XCTestCase {
    func testRoundaboutPresentationKeepsOrdinalExitVisible() {
        let german = NavigationManeuverPresentation(
            "Im Kreisverkehr die zweite Ausfahrt Richtung Mainz nehmen"
        )
        XCTAssertEqual(german.direction, .roundabout)
        XCTAssertEqual(german.exitLabel, "2. Ausfahrt")
        XCTAssertEqual(german.destinationLabel, "Mainz")

        XCTAssertEqual(
            NavigationManeuverPresentation(
                "Im Kreisverkehr die 3. Ausfahrt nehmen"
            ).exitLabel,
            "3. Ausfahrt"
        )
        XCTAssertEqual(
            NavigationManeuverPresentation(
                "At the roundabout, take the 4th exit"
            ).exitLabel,
            "4. Ausfahrt"
        )
    }

    func testOrdinalsOutsideRoundaboutsDoNotInventExitLabels() {
        XCTAssertNil(NavigationManeuverPresentation(
            "Die zweite Straße rechts nehmen"
        ).exitLabel)
        XCTAssertNil(NavigationManeuverPresentation(
            "Am Kreisverkehr geradeaus fahren"
        ).exitLabel)
    }

    func testSearchCompletionGatePublishesExactlyOnce() {
        let gate = NavigationSearchCompletionGate<[String]>()
        var published: [[String]] = []

        XCTAssertTrue(gate.complete(["first"]) { published.append($0) })
        XCTAssertFalse(gate.complete(["late"]) { published.append($0) })
        XCTAssertTrue(gate.didComplete)
        XCTAssertEqual(published, [["first"]])
        XCTAssertEqual(NavigationSearchTimeoutPolicy.timeoutNanoseconds, 8_000_000_000)
    }

    func testCarPlayAlertPrefersConcreteFailureReason() {
        XCTAssertEqual(
            CarPlayAlertPresentationPolicy.titleVariants(for: "  Standort fehlt.  "),
            ["Standort fehlt.", "Aktion nicht möglich"]
        )
        XCTAssertEqual(
            CarPlayAlertPresentationPolicy.titleVariants(for: "  "),
            ["Aktion nicht möglich"]
        )
    }

    func testCarPlayBreakReminderKeepsConcreteTextAndShortFallback() {
        XCTAssertEqual(
            CarPlayBreakReminderPresentationPolicy.titleVariants(
                for: "  Bitte in etwa 10 Minuten Pause einlegen.  "
            ),
            ["Bitte in etwa 10 Minuten Pause einlegen.", "Pause einplanen"]
        )
        XCTAssertEqual(CarPlayBreakReminderPresentationPolicy.titleVariants(for: "  "), [])
    }

    func testDestinationSearchPublishesOnlyForCurrentUnchangedQuery() {
        let current = UUID()
        XCTAssertTrue(DestinationSearchCompletionPolicy.mayPublish(
            request: current, currentRequest: current,
            query: "Hochheim", currentText: "  Hochheim  "
        ))
        XCTAssertFalse(DestinationSearchCompletionPolicy.mayPublish(
            request: UUID(), currentRequest: current,
            query: "Hochheim", currentText: "Hochheim"
        ))
        XCTAssertFalse(DestinationSearchCompletionPolicy.mayPublish(
            request: current, currentRequest: current,
            query: "Hochheim", currentText: "Mainz"
        ))
    }

    func testDestinationSearchRanksExactAndAddressMatchesBeforeLooseResults() {
        XCTAssertLessThan(
            DestinationSearchRankingPolicy.relevanceScore(
                query: "Hochheim am Main", name: "Hochheim am Main", title: "Hessen"
            ),
            DestinationSearchRankingPolicy.relevanceScore(
                query: "Hochheim am Main", name: "Hochheim", title: "Erfurt"
            )
        )
        XCTAssertLessThan(
            DestinationSearchRankingPolicy.relevanceScore(
                query: "Raiffeisenstraße 10", name: nil,
                title: "Raiffeisenstraße 10, 55270 Schwabsburg"
            ),
            DestinationSearchRankingPolicy.relevanceScore(
                query: "Raiffeisenstraße 10", name: "Raiffeisenmarkt", title: "Mainz"
            )
        )
    }

    func testDestinationSearchKeepsLocalityQualifierForSameNamedPlaces() {
        let correctLocality = DestinationSearchRankingPolicy.relevanceScore(
            query: "Hochheim am Main", name: "Hochheim",
            title: "Hochheim am Main, Hessen"
        )
        let wrongLocality = DestinationSearchRankingPolicy.relevanceScore(
            query: "Hochheim am Main", name: "Hochheim",
            title: "Hochheim, Thüringen"
        )

        XCTAssertLessThan(correctLocality, wrongLocality)
    }

    func testDestinationSearchDeduplicatesOnlySameNearbyPlace() {
        let first = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        let nearby = CLLocationCoordinate2D(latitude: 50.0001, longitude: 8)
        XCTAssertTrue(DestinationSearchRankingPolicy.isDuplicate(
            name: "McDonald’s", coordinate: first,
            existingName: "McDonald's", existingCoordinate: nearby
        ))
        XCTAssertFalse(DestinationSearchRankingPolicy.isDuplicate(
            name: "McDonald’s", coordinate: first,
            existingName: "Burger King", existingCoordinate: nearby
        ))
    }


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
        // Core Location may revise both accuracy and coordinate while keeping
        // the same timestamp. Only the refined sample may drive guidance.
        let preciseJunction = location(2, latitude: 50.0012, horizontalAccuracy: 4)
        let latest = location(3, latitude: 50.002)

        let ordered = NavigationLocationBatchPolicy.orderedDistinct([
            latest, coarseJunction, preciseJunction, oldest,
        ])

        XCTAssertEqual(ordered.map(\.timestamp), [oldest.timestamp, preciseJunction.timestamp, latest.timestamp])
        XCTAssertEqual(ordered.map(\.coordinate.latitude), [50.0, 50.0012, 50.002])
        XCTAssertEqual(ordered[1].horizontalAccuracy, 4)
    }

    func testCarPlayCameraDoesNotQueueUpdatesFasterThanMapCanRender() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(CarPlayCameraUpdatePolicy.shouldUpdate(last: nil, current: start))
        XCTAssertFalse(CarPlayCameraUpdatePolicy.shouldUpdate(
            last: start, current: start.addingTimeInterval(0.19)
        ))
        XCTAssertTrue(CarPlayCameraUpdatePolicy.shouldUpdate(
            last: start, current: start.addingTimeInterval(0.2)
        ))
        XCTAssertTrue(CarPlayCameraUpdatePolicy.shouldUpdate(
            last: start, current: start.addingTimeInterval(-1)
        ), "A corrected device clock must not freeze the CarPlay camera")
    }

    func testCarPlayReconnectAlwaysRestoresVehicleFollowing() {
        XCTAssertEqual(
            CarPlayCameraLifecyclePolicy.modeAfterConnection(previous: .free), .follow
        )
        XCTAssertEqual(
            CarPlayCameraLifecyclePolicy.modeAfterConnection(previous: .overview), .follow
        )
        XCTAssertEqual(
            CarPlayCameraLifecyclePolicy.modeAfterConnection(previous: .follow), .follow
        )
    }

    func testCarPlayOverviewUsesAThinnerRouteWithoutWeakeningFollowMode() {
        XCTAssertEqual(CarPlayRouteLinePolicy.width(isOverview: false), 7)
        XCTAssertEqual(CarPlayRouteLinePolicy.width(isOverview: true), 4.5)
        XCTAssertLessThan(
            CarPlayRouteLinePolicy.width(isOverview: true),
            CarPlayRouteLinePolicy.width(isOverview: false)
        )
    }

    func testRouteOverviewIncludesVehicleDestinationAndRequiredStops() throws {
        let routeStart = MKMapPoint(CLLocationCoordinate2D(latitude: 50, longitude: 8))
        let routeEnd = MKMapPoint(CLLocationCoordinate2D(latitude: 50.1, longitude: 8.1))
        let base = MKMapRect(
            x: min(routeStart.x, routeEnd.x), y: min(routeStart.y, routeEnd.y),
            width: abs(routeEnd.x - routeStart.x), height: abs(routeEnd.y - routeStart.y)
        )
        let vehicle = CLLocationCoordinate2D(latitude: 49.9, longitude: 7.9)
        let destination = CLLocationCoordinate2D(latitude: 50.2, longitude: 8.2)

        let expanded = try XCTUnwrap(RouteOverviewMapRectPolicy.including(
            base, coordinates: [vehicle, destination]
        ))

        XCTAssertTrue(expanded.contains(MKMapPoint(vehicle)))
        XCTAssertTrue(expanded.contains(MKMapPoint(destination)))
        XCTAssertNil(RouteOverviewMapRectPolicy.including(
            nil, coordinates: [.init(latitude: .nan, longitude: 8)]
        ))
    }

    func testLocationBatchKeepsUsefulFixesBeforeBadTrailingSample() {
        let now = Date(timeIntervalSince1970: 2_000)
        func location(_ secondsAgo: TimeInterval, latitude: Double,
                      accuracy: CLLocationAccuracy = 5) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: latitude, longitude: 8), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: 5,
                course: 0, speed: 15,
                timestamp: now.addingTimeInterval(-secondsAgo)
            )
        }
        let previous = location(12, latitude: 50)
        let junction = location(4, latitude: 50.001)
        let badTail = location(1, latitude: 50.5, accuracy: 250)

        let batch = NavigationLocationBatchPolicy.freshGuidanceBatch(
            [badTail, junction], after: previous, now: now
        )

        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.last?.coordinate.latitude, junction.coordinate.latitude)
    }

    func testLocationBatchRejectsAllSamplesWithoutFreshPlausibleEndpoint() {
        let now = Date(timeIntervalSince1970: 2_000)
        let stale = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 0, speed: 15, timestamp: now.addingTimeInterval(-60)
        )
        let inaccurate = CLLocation(
            coordinate: .init(latitude: 50.001, longitude: 8), altitude: 0,
            horizontalAccuracy: 250, verticalAccuracy: 5,
            course: 0, speed: 15, timestamp: now.addingTimeInterval(-1)
        )

        XCTAssertTrue(NavigationLocationBatchPolicy.freshGuidanceBatch(
            [stale, inaccurate], after: nil, now: now
        ).isEmpty)
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

    func testFollowCameraShowsMoreRoadAheadAtMotorwaySpeed() {
        XCTAssertEqual(NavigationFollowCameraPolicy.distance(speedMetresPerSecond: nil), 700)
        XCTAssertEqual(NavigationFollowCameraPolicy.distance(speedMetresPerSecond: 30), 1_190)
        XCTAssertEqual(NavigationFollowCameraPolicy.lookAheadDistance(speedMetresPerSecond: 1), 0)
        XCTAssertEqual(NavigationFollowCameraPolicy.lookAheadDistance(speedMetresPerSecond: 30), 270)

        let origin = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        let north = NavigationFollowCameraPolicy.center(
            from: origin, headingDegrees: 0, speedMetresPerSecond: 30
        )
        XCTAssertGreaterThan(north.latitude, origin.latitude)
        XCTAssertEqual(north.longitude, origin.longitude, accuracy: 0.000_001)
    }

    func testFollowCameraClampsImplausibleSpeedAndDistance() {
        XCTAssertEqual(NavigationFollowCameraPolicy.distance(speedMetresPerSecond: -1), 700)
        XCTAssertEqual(NavigationFollowCameraPolicy.distance(speedMetresPerSecond: 100), 1_400)
        XCTAssertEqual(NavigationFollowCameraPolicy.lookAheadDistance(speedMetresPerSecond: 100), 450)
    }

    func testCourseMatchingHandlesWraparoundAndOppositeCarriageway() throws {
        XCTAssertEqual(try XCTUnwrap(NavigationCourseMatchingPolicy.angularDifference(
            courseDegrees: 355, routeCourseDegrees: 5
        )), 10, accuracy: 0.001)
        XCTAssertTrue(NavigationCourseMatchingPolicy.isPlausible(65))
        XCTAssertFalse(NavigationCourseMatchingPolicy.isPlausible(179))
        XCTAssertTrue(NavigationCourseMatchingPolicy.isPlausible(nil),
                      "Stopped or course-less fixes retain safe distance matching")
    }

    func testStepSelectionDoesNotAdvanceOntoOpposingParallelRoad() {
        let selected = NavigationStepSelectionPolicy.selectedIndex(
            current: 0,
            metrics: [
                .init(distanceFromRoute: 5, remainingOnStep: 4,
                      courseDifferenceDegrees: 5),
                .init(distanceFromRoute: 3, remainingOnStep: 500,
                      courseDifferenceDegrees: 175),
            ],
            transitionRadius: 12
        )
        XCTAssertEqual(selected, 0)
    }

    func testStepSelectionAdvancesAfterVehicleTurnsOntoRamp() {
        let selected = NavigationStepSelectionPolicy.selectedIndex(
            current: 0,
            metrics: [
                .init(distanceFromRoute: 5, remainingOnStep: 4,
                      courseDifferenceDegrees: 88),
                .init(distanceFromRoute: 3, remainingOnStep: 500,
                      courseDifferenceDegrees: 8),
            ],
            transitionRadius: 12
        )
        XCTAssertEqual(selected, 1)
    }

    func testOfflineCourseUsesLocalNearestSegment() throws {
        let northbound = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50.01, longitude: 8),
        ]
        let course = try XCTUnwrap(NavigationCourseMatchingPolicy.routeCourse(
            near: .init(latitude: 50.005, longitude: 8.0001),
            coordinates: northbound
        ))
        XCTAssertEqual(course, 0, accuracy: 0.5)
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
        XCTAssertEqual(NavigationDeviationPolicy.confirmationDuration(speedMetresPerSecond: 8), 6)
        XCTAssertEqual(NavigationDeviationPolicy.confirmationDuration(speedMetresPerSecond: 20), 8)
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

    func testRouteRejoinRequiresSeveralInsideFixesBeforeOldGuidanceReturns() {
        XCTAssertEqual(NavigationRouteRejoinPolicy.requiredConsecutiveInsideFixes, 3)
        XCTAssertFalse(NavigationRouteRejoinPolicy.isConfirmed(consecutiveInsideFixes: 1))
        XCTAssertFalse(NavigationRouteRejoinPolicy.isConfirmed(consecutiveInsideFixes: 2))
        XCTAssertTrue(NavigationRouteRejoinPolicy.isConfirmed(consecutiveInsideFixes: 3))
        XCTAssertTrue(NavigationRouteRejoinPolicy.isConfirmed(consecutiveInsideFixes: 4))
    }

    func testDeviationThresholdReroutesSoonerInTownWithoutWeakeningMotorwayNoiseMargin() {
        XCTAssertEqual(NavigationDeviationPolicy.threshold(
            horizontalAccuracy: 8, speedMetresPerSecond: 8
        ), 55)
        XCTAssertEqual(NavigationDeviationPolicy.threshold(
            horizontalAccuracy: 8, speedMetresPerSecond: 20
        ), 80)
        XCTAssertEqual(NavigationDeviationPolicy.threshold(
            horizontalAccuracy: 8, speedMetresPerSecond: 35
        ), 140)
        XCTAssertEqual(NavigationDeviationPolicy.threshold(
            horizontalAccuracy: 50, speedMetresPerSecond: 8
        ), 150, "Poor GPS accuracy must still widen the corridor")
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

    func testDeviationIgnoresMissingAndInvalidRouteGeometry() {
        XCTAssertNil(NavigationDeviationGeometryPolicy.nearestUsableDistance([]))
        XCTAssertNil(NavigationDeviationGeometryPolicy.nearestUsableDistance([
            (pointCount: 0, distance: 900),
            (pointCount: 1, distance: 800),
            (pointCount: 2, distance: .infinity),
        ]))
        XCTAssertEqual(
            NavigationDeviationGeometryPolicy.nearestUsableDistance([
                (pointCount: 2, distance: 130),
                (pointCount: 8, distance: 45),
            ]),
            45
        )
    }

    func testFailedReroutesBackOffInsteadOfLooping() {
        let attemptedAt = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(NavigationRerouteRetryPolicy.cooldown(consecutiveFailures: 0), 30)
        XCTAssertEqual(NavigationRerouteRetryPolicy.cooldown(consecutiveFailures: 1), 60)
        XCTAssertEqual(NavigationRerouteRetryPolicy.cooldown(consecutiveFailures: 4), 180)
        XCTAssertFalse(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt, consecutiveFailures: 2,
            now: attemptedAt.addingTimeInterval(179)
        ))
        XCTAssertTrue(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt, consecutiveFailures: 2,
            now: attemptedAt.addingTimeInterval(180)
        ))
        XCTAssertTrue(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt.addingTimeInterval(1), consecutiveFailures: 4,
            now: attemptedAt
        ), "Clock rollback must not suppress rerouting until a future timestamp")
        XCTAssertFalse(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 300, previousDistance: 280,
            horizontalAccuracy: 8, speedMetresPerSecond: 25,
            rerouteAllowed: false
        ), "A cooldown must clear rather than preserve an old deviation streak")
        XCTAssertTrue(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 300, previousDistance: 280,
            horizontalAccuracy: 8, speedMetresPerSecond: 25,
            rerouteAllowed: true
        ))
    }

    func testConfirmedDeviationSuppressesUnsafeOldRouteAnnouncements() {
        XCTAssertTrue(NavigationManeuverSafetyPolicy.mayAnnounceLiveManeuver(
            navigationActive: true, rerouting: false, confirmedOffRoute: false
        ))
        XCTAssertFalse(NavigationManeuverSafetyPolicy.mayAnnounceLiveManeuver(
            navigationActive: true, rerouting: true, confirmedOffRoute: true
        ))
        XCTAssertFalse(NavigationManeuverSafetyPolicy.mayAnnounceLiveManeuver(
            navigationActive: true, rerouting: false, confirmedOffRoute: true
        ), "A failed reroute must not revive spoken instructions from the abandoned road")
        XCTAssertFalse(NavigationManeuverSafetyPolicy.mayAnnounceLiveManeuver(
            navigationActive: false, rerouting: false, confirmedOffRoute: false
        ))
    }

    func testConfirmedDeviationHidesStaleTurnCard() {
        let searching = NavigationInstructionDisplayPolicy.display(
            instruction: "Rechts abbiegen", distance: 80,
            upcomingInstructions: ["Rechts abbiegen", "Links abbiegen"],
            guidanceReliable: false, recalculating: true
        )
        XCTAssertEqual(searching.instruction, "Neue Route wird gesucht")
        XCTAssertNil(searching.distance)
        XCTAssertTrue(searching.upcomingInstructions.isEmpty)
        XCTAssertTrue(searching.guidanceUnavailable)

        let failed = NavigationInstructionDisplayPolicy.display(
            instruction: "Rechts abbiegen", distance: 80,
            upcomingInstructions: ["Rechts abbiegen"],
            guidanceReliable: false, recalculating: false
        )
        XCTAssertEqual(failed.instruction, "Route verlassen – sicher weiterfahren")
        XCTAssertNil(failed.distance)
    }

    func testReliableGuidanceKeepsLiveTurnCard() {
        let display = NavigationInstructionDisplayPolicy.display(
            instruction: "Links halten", distance: 450,
            upcomingInstructions: ["Links halten", "Ausfahrt nehmen"],
            guidanceReliable: true, recalculating: false
        )
        XCTAssertEqual(display.instruction, "Links halten")
        XCTAssertEqual(display.distance, 450)
        XCTAssertEqual(display.upcomingInstructions, ["Links halten", "Ausfahrt nehmen"])
        XCTAssertFalse(display.guidanceUnavailable)
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
        XCTAssertEqual(NavigationRerouteWatchdogPolicy.timeoutNanoseconds, 20_000_000_000)
    }

    func testDelayedGuidanceCalculationCannotCommitAfterStopOrWatchdog() {
        let session = UUID()
        let work = UUID()
        XCTAssertTrue(NavigationAsyncWorkPolicy.mayCommitCalculation(
            navigationActive: true, session: session, currentSession: session,
            work: work, currentWork: work
        ))
        XCTAssertFalse(NavigationAsyncWorkPolicy.mayCommitCalculation(
            navigationActive: false, session: session, currentSession: session,
            work: work, currentWork: work
        ), "Stopping navigation must invalidate an in-flight calculation")
        XCTAssertFalse(NavigationAsyncWorkPolicy.mayCommitCalculation(
            navigationActive: true, session: session, currentSession: session,
            work: work, currentWork: UUID()
        ), "The reroute watchdog must prevent its late MapKit result from publishing")
        XCTAssertFalse(NavigationAsyncWorkPolicy.mayCommitCalculation(
            navigationActive: true, session: session, currentSession: UUID(),
            work: nil, currentWork: UUID()
        ), "A calculation from an older drive must not replace the current route")
    }

    func testForegroundCalculationDoesNotDependOnNavigationSession() {
        XCTAssertTrue(NavigationAsyncWorkPolicy.mayCommitCalculation(
            navigationActive: false, session: nil, currentSession: UUID(),
            work: nil, currentWork: UUID()
        ))
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

    func testRemoteActiveRouteRemainsVisibleDuringOfflineGuidance() {
        XCTAssertTrue(DriveRemoteRouteVisibilityPolicy.hasRoute(
            liveLegCount: 0, offlineGuidanceActive: true
        ))
        XCTAssertTrue(DriveRemoteRouteVisibilityPolicy.hasRoute(
            liveLegCount: 1, offlineGuidanceActive: false
        ))
        XCTAssertFalse(DriveRemoteRouteVisibilityPolicy.hasRoute(
            liveLegCount: 0, offlineGuidanceActive: false
        ))
    }

    func testExpiredRemoteMutationIsRejectedAgainOnDevice() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(DriveRemoteCommandExpiryPolicy.isExpired(
            formatter.string(from: now.addingTimeInterval(-1)), now: now
        ))
        XCTAssertTrue(DriveRemoteCommandExpiryPolicy.isExpired(
            formatter.string(from: now), now: now
        ))
        XCTAssertFalse(DriveRemoteCommandExpiryPolicy.isExpired(
            formatter.string(from: now.addingTimeInterval(1)), now: now
        ))
        XCTAssertFalse(DriveRemoteCommandExpiryPolicy.isExpired(nil, now: now))
    }

    func testExitNumberAndDirectionAreExtracted() {
        let presentation = NavigationManeuverPresentation("Ausfahrt 69 rechts Richtung Neufahrn nehmen")
        XCTAssertEqual(presentation.exitLabel, "Ausfahrt 69")
        XCTAssertEqual(presentation.direction, .right)
        XCTAssertEqual(presentation.destinationLabel, "Neufahrn")
    }

    func testMotorwayJunctionVariantsProduceCompactExitLabels() {
        XCTAssertEqual(
            NavigationManeuverPresentation(
                "Anschlussstelle 12 rechts Richtung Wiesbaden, danach links halten"
            ).exitLabel,
            "Ausfahrt 12"
        )
        let spaced = NavigationManeuverPresentation(
            "Ausfahrt 69 A rechts Richtung Neufahrn, danach der A9 folgen"
        )
        XCTAssertEqual(spaced.exitLabel, "Ausfahrt 69A")
        XCTAssertEqual(spaced.destinationLabel, "Neufahrn")
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

    func testRemoteCommandJournalPersistsOutcomeUntilServerAcknowledgesIt() throws {
        let suite = "KiesDriveTests.RemoteJournal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = DriveRemoteCommandJournal(defaults: defaults, maximumCount: 2)
        journal.save([
            1: .init(ok: true, message: "fertig"),
            2: .init(ok: false, message: "keine Route"),
            3: .init(ok: true, message: "später bestätigt"),
        ])

        let restored = journal.load()
        XCTAssertNil(restored[1], "The bounded journal keeps only the newest outcomes")
        XCTAssertEqual(restored[2], .init(ok: false, message: "keine Route"))
        XCTAssertEqual(restored[3], .init(ok: true, message: "später bestätigt"))

        var acknowledged = restored
        acknowledged.removeValue(forKey: 2)
        journal.save(acknowledged)
        XCTAssertNil(journal.load()[2])
    }

    func testSpeechInstructionsRemoveSymbolsAndSoundLikeSentences() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("rechts ↗ Richtung A 66 / Wiesbaden", distance: 112),
            "In 100 Metern, Rechts Richtung A 66, Wiesbaden."
        )
    }

    func testVoiceSelectionPrioritisesAudioQualityBeforeSiriBranding() {
        let compactSiri = NavigationVoiceSelectionPolicy.score(
            qualityRawValue: 1, identifier: "com.apple.voice.compact.de-DE.siri"
        )
        let premium = NavigationVoiceSelectionPolicy.score(
            qualityRawValue: 3, identifier: "com.apple.voice.premium.de-DE.anna"
        )
        XCTAssertGreaterThan(premium, compactSiri)

        let enhancedSiri = NavigationVoiceSelectionPolicy.score(
            qualityRawValue: 2, identifier: "com.apple.voice.enhanced.de-DE.siri"
        )
        let enhancedGeneric = NavigationVoiceSelectionPolicy.score(
            qualityRawValue: 2, identifier: "com.apple.voice.enhanced.de-DE.anna"
        )
        XCTAssertGreaterThan(enhancedSiri, enhancedGeneric)
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

    func testSpeechExpandsSpeedUnitBeforeRemovingSlash() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Tempolimit 80 km/h"),
            "Tempolimit 80 Kilometer pro Stunde."
        )
    }

    func testSpeechExpandsGermanJunctionAndRoadAbbreviationsNaturally() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Am AK Wiesbaden rechts auf St 2060, Rtg. Bhf. abfahren"
            ),
            "Am Autobahnkreuz Wiesbaden rechts auf Staatsstraße 2060, Richtung Bahnhof abfahren."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Am AD links zur AS 12 [St. Goar]"
            ),
            "Am Autobahndreieck links zur Anschlussstelle 12, Sankt Goar."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Richtung Ak Saray"),
            "Richtung Ak Saray."
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

    func testDenseFollowingManeuverIsIncludedFromFinalCueOnward() {
        XCTAssertFalse(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .prepare, followingDistance: 180
        ))
        XCTAssertTrue(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .final, followingDistance: 180
        ))
        XCTAssertTrue(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .now, followingDistance: 450
        ))
        XCTAssertFalse(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .now, followingDistance: 451
        ))
        XCTAssertFalse(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .now, followingDistance: .infinity
        ))
    }

    func testMissedCueIsNeverRecoveredAfterTheOldJunctionIsClearlyBehind() {
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "old", nextKey: "new", stages: [],
            previousDistance: 40, speedMetresPerSecond: 25
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "old", nextKey: "new", stages: [],
            previousDistance: 180, speedMetresPerSecond: 25
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "old", nextKey: "new", stages: [],
            previousDistance: .infinity, speedMetresPerSecond: 25
        ))
    }

    func testOnlineAndOfflineManeuverSpeechShareDenseTurnWording() {
        XCTAssertEqual(
            NavigationManeuverSpeechPolicy.text(
                instruction: "Rechts abbiegen", distance: 90, stage: .final,
                followingInstruction: "Links halten", followingDistance: 180
            ),
            "In 100 Metern, Rechts abbiegen. Danach, Links halten."
        )
        XCTAssertEqual(
            NavigationManeuverSpeechPolicy.text(
                instruction: "Rechts abbiegen", distance: 90, stage: .prepare,
                followingInstruction: "Links halten", followingDistance: 180
            ),
            "In 100 Metern, Rechts abbiegen."
        )
        XCTAssertEqual(
            NavigationManeuverSpeechPolicy.text(
                instruction: "Rechts abbiegen", distance: 70, stage: .now,
                followingInstruction: "Links halten", followingDistance: 180
            ),
            "Jetzt, Rechts abbiegen. Danach, Links halten."
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

    func testImmediateCueUsesRealisticSpeedDependentWindow() {
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 40, speedKmh: 50), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 55, speedKmh: 50), .final)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 95, speedKmh: 120), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 130, speedKmh: 120), .final)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 165, speedKmh: 200), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 220, speedKmh: 200), .final)
    }

    func testSpeechPriorityProtectsImmediateManeuverFromStatusMessage() {
        XCTAssertEqual(NavigationSpeechPriority.forAnnouncementStage(.early), .maneuver)
        XCTAssertEqual(NavigationSpeechPriority.forAnnouncementStage(.now), .critical)
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.hasActiveWork(
            isSpeaking: false, hasQueuedUtterance: true
        ), "An utterance queued before playback must already own the speech slot")
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.hasActiveWork(
            isSpeaking: true, hasQueuedUtterance: false
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.hasActiveWork(
            isSpeaking: false, hasQueuedUtterance: false
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .critical, incoming: .status
        ))
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .status, incoming: .maneuver
        ))
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .maneuver, incoming: .critical
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .critical, incoming: .critical
        ), "A following immediate turn must not cut the current decisive cue in half")
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .maneuver, incoming: .maneuver
        ), "A later preparation stage must be able to supersede an unfinished earlier stage")
    }

    func testFinishedSpeechCommitsQueuedClaimWhenStartCallbackWasLost() {
        XCTAssertEqual(
            NavigationAnnouncementDeliveryPolicy.completedClaims(
                active: "started", queued: "queued"
            ),
            "started"
        )
        XCTAssertEqual(
            NavigationAnnouncementDeliveryPolicy.completedClaims(
                active: Optional<String>.none, queued: "queued"
            ),
            "queued"
        )
        XCTAssertNil(
            NavigationAnnouncementDeliveryPolicy.completedClaims(
                active: Optional<String>.none, queued: Optional<String>.none
            )
        )
    }

    func testCommittedReplacementRouteCancelsEveryOldSpokenManeuver() {
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldCancelForRouteReplacement(
            navigationActive: true, hasSpeechWork: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldCancelForRouteReplacement(
            navigationActive: false, hasSpeechWork: true
        ), "Route preview changes must not cancel unrelated speech")
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldCancelForRouteReplacement(
            navigationActive: true, hasSpeechWork: false
        ))
    }

    func testConfirmedDeviationCancelsUnsafeOldRouteSpeech() {
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldCancelForConfirmedDeviation(
            confirmedOffRoute: true, navigationActive: true, hasSpeechWork: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldCancelForConfirmedDeviation(
            confirmedOffRoute: false, navigationActive: true, hasSpeechWork: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldCancelForConfirmedDeviation(
            confirmedOffRoute: true, navigationActive: false, hasSpeechWork: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldCancelForConfirmedDeviation(
            confirmedOffRoute: true, navigationActive: true, hasSpeechWork: false
        ))
    }

    func testManeuverAnnouncementRemainsRetryableUntilSpeechActuallyStarts() {
        XCTAssertTrue(NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            .prepare, delivered: [], pending: []
        ))
        XCTAssertFalse(NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            .prepare, delivered: [], pending: [.prepare]
        ), "A queued utterance must not be enqueued repeatedly")
        XCTAssertTrue(NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            .prepare, delivered: [], pending: []
        ), "A cancelled-before-start utterance must be retryable")
        XCTAssertFalse(NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            .prepare,
            delivered: NavigationAnnouncementDeliveryPolicy.stages(upTo: .prepare),
            pending: []
        ))
    }

    func testStalledSpeechClaimExpiresAndCanBeRetried() {
        let issuedAt = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(NavigationSpeechClaimTimeoutPolicy.isExpired(
            issuedAt: issuedAt, now: issuedAt.addingTimeInterval(3.9), active: false
        ))
        XCTAssertTrue(NavigationSpeechClaimTimeoutPolicy.isExpired(
            issuedAt: issuedAt, now: issuedAt.addingTimeInterval(4), active: false
        ))
        XCTAssertFalse(NavigationSpeechClaimTimeoutPolicy.isExpired(
            issuedAt: issuedAt, now: issuedAt.addingTimeInterval(19.9), active: true
        ))
        XCTAssertTrue(NavigationSpeechClaimTimeoutPolicy.isExpired(
            issuedAt: issuedAt, now: issuedAt.addingTimeInterval(20), active: true
        ))
        XCTAssertTrue(NavigationSpeechClaimTimeoutPolicy.isExpired(
            issuedAt: issuedAt, now: issuedAt.addingTimeInterval(-1), active: false
        ), "Clock rollback must release a speech claim that could otherwise block forever")
    }

    func testManeuverDeliveryCommitsOnlyAfterCompletePlayback() {
        XCTAssertFalse(NavigationAnnouncementDeliveryPolicy.shouldCommitDelivery(
            didFinish: false
        ), "Starting or later cancelling audio must not consume a maneuver cue")
        XCTAssertTrue(NavigationAnnouncementDeliveryPolicy.shouldCommitDelivery(
            didFinish: true
        ))
    }

    func testLateOlderSpeechCompletionCannotRegressDeliveredManeuverStage() {
        let decisive = NavigationAnnouncementDeliveryPolicy.stages(upTo: .now)
        let afterLatePrepare = NavigationAnnouncementDeliveryPolicy.committedStages(
            delivered: decisive, completing: .prepare
        )

        XCTAssertEqual(afterLatePrepare, decisive)
        XCTAssertFalse(NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            .now, delivered: afterLatePrepare, pending: []
        ), "A late older callback must not make the completed final cue eligible again")
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

    func testRestoredOfflineRouteSeedsDistanceAndUpcomingFromRemainingStepsOnly() throws {
        let cachedSteps = [
            (instruction: "Alte Abfahrt", distance: 700.0),
            (instruction: "", distance: 420.0),
            (instruction: "Rechts auf die A66", distance: 900.0),
            (instruction: "Links halten Richtung Wiesbaden", distance: 600.0),
        ]

        let seed = try XCTUnwrap(NavigationInitialManeuverPolicy.seed(
            steps: Array(cachedSteps.dropFirst())
        ))

        XCTAssertEqual(seed.instruction, "Rechts auf die A66")
        XCTAssertEqual(seed.distance, 420, accuracy: 0.001)
        XCTAssertEqual(seed.upcomingInstructions, [
            "Rechts auf die A66", "Links halten Richtung Wiesbaden"
        ])
        XCTAssertFalse(seed.upcomingInstructions.contains("Alte Abfahrt"))
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
        XCTAssertEqual(CarPlayGuidancePresentationPolicy.instructions(
            upcoming: ["Alte Abfahrt nehmen"], next: "Alte Abfahrt nehmen",
            guidanceReliable: false
        ), [], "CarPlay must remove stale maneuver cards after a confirmed deviation")
    }

    func testCarPlayListAllocationNeverExceedsLimitAndKeepsPriorityOrder() {
        XCTAssertEqual(
            CarPlayListPriorityPolicy.allocation(
                groupCounts: [2, 4, 3, 5, 7, 3], maximum: 12
            ),
            [2, 4, 3, 3, 0, 0]
        )
        XCTAssertEqual(
            CarPlayListPriorityPolicy.allocation(
                groupCounts: [1, 0, 0, 0, 2, 3], maximum: 12
            ),
            [1, 0, 0, 0, 2, 3]
        )
    }

    func testCarPlayRouteOptionsClearlyShowTheirToggleState() {
        XCTAssertEqual(
            CarPlayRouteOptionPresentationPolicy.detail(enabled: true),
            "Aktiv · antippen zum Ausschalten"
        )
        XCTAssertEqual(
            CarPlayRouteOptionPresentationPolicy.detail(enabled: false),
            "Aus · antippen zum Einschalten"
        )
        XCTAssertEqual(CarPlayRouteOptionPresentationPolicy.symbol(enabled: true),
                       "checkmark.circle.fill")
        XCTAssertEqual(CarPlayRouteOptionPresentationPolicy.symbol(enabled: false), "circle")
    }

    func testCarPlayPriorityKeepsRouteOptionsAheadOfComfortSearch() {
        let allocation = CarPlayListPriorityPolicy.allocation(
            groupCounts: [2, 4, 2, 3, 3, 7, 3], maximum: 12
        )
        XCTAssertEqual(allocation, [2, 4, 2, 3, 1, 0, 0])
    }

    func testCarPlayGuidanceKeepsExitAndRoadVisibleOnSmallDisplays() {
        let variants = CarPlayGuidancePresentationPolicy.variants(
            for: "Ausfahrt 69 rechts auf die A 9 Richtung München nehmen"
        )
        XCTAssertEqual(variants.first, "Ausfahrt 69 rechts auf die A 9 Richtung München nehmen")
        XCTAssertTrue(variants.contains("Ausfahrt 69, Richtung München"))
        XCTAssertTrue(variants.contains("A9, Richtung München"))
        XCTAssertTrue(variants.contains("Ausfahrt 69"))
        XCTAssertTrue(variants.contains("A9"))
    }

    func testCarPlayGuidanceVariantsAreNonemptyAndUnique() {
        let variants = CarPlayGuidancePresentationPolicy.variants(for: "A 66 folgen")
        XCTAssertFalse(variants.contains(where: { $0.isEmpty }))
        XCTAssertEqual(variants.count, Set(variants).count)
    }

    func testCarPlayPlannedStopsCombineBreakAndFuelAtSamePlace() {
        let candidate = BreakCandidate(id: "stop-a", name: "Autohof A",
                                       coordinate: .init(latitude: 49, longitude: 8),
                                       progress: 0.3, detourMetres: 900, isOpen: true,
                                       supportsFuel: true)
        let result = RouteScenarioResult(
            id: "route", routeTitle: "Route", scenario: .init(id: "normal", name: "Normal",
            targetSpeedKmh: 130), distanceMetres: 500_000, drivingTime: 18_000,
            totalTime: 19_000, fuel: .init(litres: 30, cost: 55,
            averageConsumptionLPer100km: 6), toll: .noToll(source: "Test"),
            breaks: [.init(id: "break", candidate: candidate, afterDriving: 7_200,
                           duration: 900, routeProgress: 0.3, explanation: "Pause")],
            fuelStops: [.init(id: "fuel", candidate: candidate, afterDistanceMetres: 150_000,
                              routeProgress: 0.3, explanation: "Tanken")], unlimitedFraction: 0.2)
        let plan = LongTripPlan(createdAt: Date(), results: [result], note: "")

        let actions = CarPlayPlannedStopPolicy.actions(
            plan: plan, existingWaypointIDs: [], existingWaypointNames: [],
            currentRouteProgress: 0
        )

        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.purpose, CarPlayPlannedStopAction.Purpose.breakAndFuel)
        XCTAssertEqual(actions.first?.candidate.id, "stop-a")
    }

    func testCarPlayPlannedStopsExcludeExistingAndKeepEarliestTwo() {
        func candidate(_ id: String, _ progress: Double) -> BreakCandidate {
            .init(id: id, name: "Stop \(id)", coordinate: .init(latitude: 49, longitude: 8),
                  progress: progress, detourMetres: 500, isOpen: true)
        }
        let first = candidate("first", 0.15)
        let second = candidate("second", 0.3)
        let third = candidate("third", 0.5)
        let result = RouteScenarioResult(
            id: "route", routeTitle: "Route", scenario: .init(id: "normal", name: "Normal",
            targetSpeedKmh: 130), distanceMetres: 500_000, drivingTime: 18_000,
            totalTime: 19_000, fuel: .init(litres: 30, cost: 55,
            averageConsumptionLPer100km: 6), toll: .noToll(source: "Test"),
            breaks: [first, second, third].map {
                .init(id: $0.id, candidate: $0, afterDriving: $0.progress * 18_000,
                      duration: 900, routeProgress: $0.progress, explanation: "Pause")
            }, fuelStops: [], unlimitedFraction: 0.2)
        let plan = LongTripPlan(createdAt: Date(), results: [result], note: "")

        let actions = CarPlayPlannedStopPolicy.actions(
            plan: plan, existingWaypointIDs: ["first"], existingWaypointNames: [],
            currentRouteProgress: 0, maximum: 2
        )

        XCTAssertEqual(actions.map { $0.candidate.id }, ["second", "third"])
    }

    func testCarPlayPlannedStopsExcludeBreaksAndFuelBehindVehicle() {
        func candidate(_ id: String, _ progress: Double) -> BreakCandidate {
            .init(id: id, name: "Stop \(id)", coordinate: .init(latitude: 49, longitude: 8),
                  progress: progress, detourMetres: 500, isOpen: true)
        }
        let behind = candidate("behind", 0.3)
        let ahead = candidate("ahead", 0.7)
        let result = RouteScenarioResult(
            id: "route", routeTitle: "Route", scenario: .init(id: "normal", name: "Normal",
            targetSpeedKmh: 130), distanceMetres: 500_000, drivingTime: 18_000,
            totalTime: 19_000, fuel: .init(litres: 30, cost: 55,
            averageConsumptionLPer100km: 6), toll: .noToll(source: "Test"),
            breaks: [.init(id: "behind-break", candidate: behind, afterDriving: 7_200,
                           duration: 900, routeProgress: 0.3, explanation: "Pause")],
            fuelStops: [
                .init(id: "behind-fuel", candidate: behind, afterDistanceMetres: 150_000,
                      routeProgress: 0.3, explanation: "Tanken"),
                .init(id: "ahead-fuel", candidate: ahead, afterDistanceMetres: 350_000,
                      routeProgress: 0.7, explanation: "Tanken"),
            ], unlimitedFraction: 0.2
        )

        let actions = CarPlayPlannedStopPolicy.actions(
            plan: .init(createdAt: Date(), results: [result], note: ""),
            existingWaypointIDs: [], existingWaypointNames: [], currentRouteProgress: 0.5
        )

        XCTAssertEqual(actions.map(\.candidate.id), ["ahead"])
        XCTAssertEqual(actions.first?.purpose, .fuelOnly)
    }

    func testCarPlayKeepsRebasedRemainingStopUsingInstalledRouteProgress() throws {
        let candidate = BreakCandidate(
            id: "remaining", name: "Raststätte voraus",
            coordinate: .init(latitude: 49, longitude: 8),
            progress: 0.4, installedRouteProgress: 0.82,
            detourMetres: 500, isOpen: true
        )
        let result = RouteScenarioResult(
            id: "route", routeTitle: "Reststrecke", scenario: .target(130),
            distanceMetres: 120_000, drivingTime: 5_000, totalTime: 5_900,
            fuel: .init(litres: 8, cost: 14, averageConsumptionLPer100km: 6.7),
            toll: .unknown(reason: "Test"),
            breaks: [.init(id: "break", candidate: candidate, afterDriving: 2_000,
                           duration: 900, routeProgress: 0.4, explanation: "Pause")],
            fuelStops: [], unlimitedFraction: 0
        )

        let action = try XCTUnwrap(CarPlayPlannedStopPolicy.actions(
            plan: .init(createdAt: Date(), results: [result], note: ""),
            existingWaypointIDs: [], existingWaypointNames: [],
            currentRouteProgress: 0.7
        ).first)
        XCTAssertEqual(action.insertionRouteProgress, 0.82, accuracy: 0.001)
    }

    func testCarPlayMakesImmediateRestAndFuelNeedsExplicit() {
        let candidate = BreakCandidate(
            id: "stop", name: "Autohof", coordinate: .init(), progress: 0,
            detourMetres: 0, isOpen: true, supportsFuel: true
        )
        let rest = CarPlayPlannedStopAction(
            candidate: candidate, purpose: .breakAndFuel,
            insertionRouteProgress: 0, afterDriving: 0, afterDistanceMetres: 0
        )
        let fuel = CarPlayPlannedStopAction(
            candidate: candidate, purpose: .fuelOnly,
            insertionRouteProgress: 0, afterDriving: nil, afterDistanceMetres: 0
        )
        XCTAssertEqual(CarPlayPlannedStopDetailPolicy.text(for: rest), "Pause jetzt einlegen")
        XCTAssertEqual(
            CarPlayPlannedStopDetailPolicy.text(for: fuel),
            "Bei nächster Gelegenheit tanken"
        )
    }

    func testPhoneAndCarPlayShareStrictForwardStopVisibility() {
        XCTAssertFalse(PlannedRouteStopVisibilityPolicy.isAhead(0.49, current: 0.5))
        XCTAssertFalse(PlannedRouteStopVisibilityPolicy.isAhead(0.5, current: 0.5))
        XCTAssertTrue(PlannedRouteStopVisibilityPolicy.isAhead(0.6, current: 0.5))
        XCTAssertFalse(PlannedRouteStopVisibilityPolicy.isAhead(.nan, current: 0.5))
        XCTAssertFalse(PlannedRouteStopVisibilityPolicy.isAhead(0.6, current: .infinity))
    }

    func testRouteSearchResultBecomesInvalidWhenRouteGeometryChanges() {
        let searchedRoute = UUID()
        XCTAssertTrue(RouteSearchSelectionPolicy.accepts(
            resultRouteGeneration: searchedRoute,
            currentRouteGeneration: searchedRoute
        ))
        XCTAssertFalse(RouteSearchSelectionPolicy.accepts(
            resultRouteGeneration: searchedRoute,
            currentRouteGeneration: UUID()
        ))
        XCTAssertTrue(RouteSearchSelectionPolicy.accepts(
            resultRouteGeneration: nil,
            currentRouteGeneration: UUID()
        ), "Direct non-search stop additions remain supported")
    }

    func testFinalCueHasEnoughHighSpeedReactionTime() {
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 320, speedKmh: 200), .final)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 350, speedKmh: 200), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 190, speedKmh: 120), .final)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 210, speedKmh: 120), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 80, speedKmh: 50), .final)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 90, speedKmh: 50), .prepare)
    }

    func testManeuverDiagnosticsDetectMissingFinalCue() {
        XCTAssertTrue(ManeuverDiagnosticPolicy.missedFinalCue(stages: [.early, .prepare]))
        XCTAssertFalse(ManeuverDiagnosticPolicy.missedFinalCue(stages: [.early, .final]))
        XCTAssertFalse(ManeuverDiagnosticPolicy.missedFinalCue(stages: [.early, .prepare, .now]))
        XCTAssertFalse(ManeuverDiagnosticPolicy.deliveredDecisiveCue(stages: [.early, .prepare]))
        XCTAssertTrue(ManeuverDiagnosticPolicy.deliveredDecisiveCue(stages: [.final]))
        XCTAssertTrue(ManeuverDiagnosticPolicy.deliveredDecisiveCue(stages: [.now]))
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .routeTransition
        ))
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .arrival
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .userStopped
        ), "An explicit stop must not be diagnosed as a missed turn")
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .recoveryQueued
        ), "A queued recovery is judged by actual audio completion, not as immediately missed")
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
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early, .prepare, .final]
        ), "A completed final distance cue must not be repeated behind the junction")
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early, .prepare], inFlightStages: [.now]
        ), "An immediate cue still playing at the junction must not be interrupted and repeated")
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early], inFlightStages: [.final]
        ), "An actionable final cue already in flight is decisive")
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early], inFlightStages: [.prepare]
        ), "A non-decisive preparation cue must not mask a missing final cue")
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

    func testDiagnosticStoreNotifiesViewsAfterAppendAndClear() throws {
        let suite = "DriveDiagnosticNotificationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: DriveDiagnosticStore.didChange, object: nil, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        DriveDiagnosticStore.append(.navigationStarted, detail: "Test", defaults: defaults)
        DriveDiagnosticStore.clear(defaults: defaults)

        XCTAssertEqual(notifications, 2)
        XCTAssertTrue(DriveDiagnosticStore.load(defaults: defaults).isEmpty)
    }

    func testBoundedDiagnosticsRetainCurrentLongTripStart() throws {
        let suite = "DriveDiagnosticLongTripTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        DriveDiagnosticStore.append(.navigationStarted, detail: "Urlaubsfahrt", defaults: defaults)
        for index in 0..<120 {
            DriveDiagnosticStore.append(
                .maneuverAnnounced, detail: "Manöver \(index)", defaults: defaults
            )
        }
        DriveDiagnosticStore.append(.arrivalReached, detail: "Ziel", defaults: defaults)

        let events = DriveDiagnosticStore.load(defaults: defaults)
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(events.first?.kind, .navigationStarted)
        XCTAssertNotNil(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(events.last?.kind, .arrivalReached)
    }

    func testBoundedDiagnosticsRetainEarlySafetyFailureAndRecoveryOnLongTrip() throws {
        let start = DriveDiagnosticEvent(kind: .navigationStarted, detail: "Urlaubsfahrt")
        let failure = DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Kurz kein Netz")
        let recovery = DriveDiagnosticEvent(kind: .rerouteSucceeded, detail: "Route wieder da")
        let missed = DriveDiagnosticEvent(kind: .maneuverFinalCueMissed, detail: "Ausfahrt")
        var events = [start, failure, recovery, missed]
        events += (0..<140).map {
            DriveDiagnosticEvent(kind: .maneuverAnnounced, detail: "Manöver \($0)")
        }
        events.append(.init(kind: .arrivalReached, detail: "Ziel"))

        let bounded = DriveDiagnosticStore.bounded(events)
        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: bounded))

        XCTAssertEqual(bounded.count, 100)
        XCTAssertEqual(bounded.first?.kind, .navigationStarted)
        XCTAssertTrue(bounded.contains { $0.id == failure.id })
        XCTAssertTrue(bounded.contains { $0.id == recovery.id })
        XCTAssertTrue(bounded.contains { $0.id == missed.id })
        XCTAssertEqual(summary.rerouteFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
        XCTAssertEqual(summary.missedFinalCues, 1)
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(bounded.last?.kind, .arrivalReached)
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
        XCTAssertEqual(summary.rerouteRequests, 0)
        XCTAssertEqual(summary.rerouteFailures, 0)
        XCTAssertEqual(summary.rejectedLocations, 1)
        XCTAssertEqual(summary.arrivals, 0)
        XCTAssertEqual(summary.maneuverAnnouncements, 1)
        XCTAssertEqual(summary.resolvedRouteIssues, 0)
    }

    func testDiagnosticSummaryOnlyWarnsForClusteredGPSFailures() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        let spread = [
            DriveDiagnosticEvent(kind: .navigationStarted, date: start, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(60), detail: "GPS"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(3_600), detail: "GPS"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(7_200), detail: "GPS"),
        ]
        let clustered = [
            DriveDiagnosticEvent(kind: .navigationStarted, date: start, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(10), detail: "GPS"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(25), detail: "GPS"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(50), detail: "GPS"),
        ]

        XCTAssertEqual(try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: spread)).quality, .good)
        let warning = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: clustered))
        XCTAssertEqual(warning.quality, .attention)
        XCTAssertEqual(warning.rejectedLocations, 3)
        XCTAssertTrue(warning.recommendation.contains("GPS"))
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

    func testDiagnosticSummaryFlagsUnrecoveredSpeechDeliveryFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .speechDeliveryFailed, detail: "Ausfahrt"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.speechDeliveryFailures, 1)
        XCTAssertTrue(summary.recommendation.contains("Audiosystem"))
    }

    func testDiagnosticSummaryClearsSpeechFailureAfterSuccessfulRetry() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .speechDeliveryFailed, detail: "Ausfahrt"),
            DriveDiagnosticEvent(kind: .maneuverAnnounced, detail: "Ausfahrt"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.speechDeliveryFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
    }

    func testDiagnosticSummaryClearsRecoveredBreakReminderSpeechFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "Pausenerinnerung · plan · GPS ±8 m · 100 km/h"
            ),
            DriveDiagnosticEvent(
                kind: .breakReminderShown,
                detail: "Pausenerinnerung · plan · Pause einplanen"
            ),
            DriveDiagnosticEvent(
                kind: .breakReminderAnnounced,
                detail: "Pausenerinnerung · plan"
            ),
            DriveDiagnosticEvent(
                kind: .fuelReminderShown,
                detail: "Tankhinweis · soon · In 10 Kilometern tanken"
            ),
            DriveDiagnosticEvent(
                kind: .fuelReminderAnnounced,
                detail: "Tankhinweis · gesprochen · In 10 Kilometern tanken"
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.speechDeliveryFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
        XCTAssertEqual(summary.breakRemindersShown, 1)
        XCTAssertEqual(summary.breakRemindersAnnounced, 1)
        XCTAssertEqual(summary.fuelRemindersShown, 1)
        XCTAssertEqual(summary.fuelRemindersAnnounced, 1)
    }

    func testDifferentLaterManeuverDoesNotHideSpeechFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "now · Ausfahrt rechts nehmen · GPS ±8 m · 100 km/h"
            ),
            DriveDiagnosticEvent(
                kind: .maneuverAnnounced,
                detail: "prepare · 300 m · Links abbiegen"
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.speechDeliveryFailures, 1)
    }

    func testDiagnosticSummaryClearsRecoveredFuelReminderSpeechFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "Tankhinweis · In etwa 10 Kilometern tanken. · GPS ±8 m · 100 km/h"
            ),
            DriveDiagnosticEvent(
                kind: .fuelReminderAnnounced,
                detail: "Tankhinweis · gesprochen · In etwa 10 Kilometern tanken."
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.speechDeliveryFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
        XCTAssertEqual(summary.fuelRemindersAnnounced, 1)
    }

    func testMatchingRetriedManeuverClearsOnlyItsSpeechFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "now · Ausfahrt rechts nehmen · GPS ±8 m · 100 km/h"
            ),
            DriveDiagnosticEvent(
                kind: .maneuverAnnounced,
                detail: "now · 20 m · Ausfahrt rechts nehmen"
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.speechDeliveryFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
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

    func testDiagnosticSummaryClearsOfflineDepartureAfterRejoiningCache() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .offlineRouteDeparture, detail: "Korridor verlassen"),
            DriveDiagnosticEvent(kind: .offlineRouteRejoined, detail: "Korridor erreicht"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.offlineRouteDepartures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
    }

    func testDiagnosticSummaryClearsFailedRerouteAfterStableOnlineRejoin() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .rerouteRequested, detail: "Falsche Abfahrt"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Kein Netz"),
            DriveDiagnosticEvent(kind: .routeRejoined, detail: "Ursprüngliche Route erreicht"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.rerouteFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
        XCTAssertTrue(summary.recommendation.contains("automatisch behoben"))
    }

    func testDiagnosticSummaryKeepsFailureAfterLatestOnlineRejoinOpen() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .routeRejoined, detail: "Ursprüngliche Route erreicht"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Später erneut kein Netz"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.rerouteFailures, 1)
        XCTAssertEqual(summary.resolvedRouteIssues, 0)
    }

    func testOfflineRejoinDoesNotHideFailedOnlineReroute() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Kein Netz"),
            DriveDiagnosticEvent(kind: .offlineRouteDeparture, detail: "Korridor verlassen"),
            DriveDiagnosticEvent(kind: .offlineRouteRejoined, detail: "Korridor erreicht"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.rerouteFailures, 1)
        XCTAssertEqual(summary.offlineRouteDepartures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
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

    func testNavigationLocationPolicySafelyAcceptsBoundedBufferedFixes() {
        let now = Date()
        let buffered = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                                  horizontalAccuracy: 5, verticalAccuracy: 5,
                                  timestamp: now.addingTimeInterval(-60))
        let tooOld = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                                horizontalAccuracy: 5, verticalAccuracy: 5,
                                timestamp: now.addingTimeInterval(-121))

        XCTAssertFalse(NavigationLocationPolicy.accepts(buffered, after: nil, now: now))
        XCTAssertTrue(NavigationLocationPolicy.accepts(
            buffered, after: nil, now: now,
            maximumAge: NavigationLocationBatchPolicy.maximumBufferedSampleAge
        ))
        XCTAssertFalse(NavigationLocationPolicy.accepts(
            tooOld, after: nil, now: now,
            maximumAge: NavigationLocationBatchPolicy.maximumBufferedSampleAge
        ))
    }

    func testNavigationLocationPolicyAcceptsNormalMovement() {
        let now = Date()
        let first = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                               horizontalAccuracy: 8, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-2))
        let next = CLLocation(coordinate: .init(latitude: 50.0005, longitude: 8), altitude: 0,
                              horizontalAccuracy: 8, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-1))
        XCTAssertTrue(NavigationLocationPolicy.accepts(next, after: first, now: now))
    }

    func testLocationDiagnosticThrottleRetainsARealFailureBurst() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(NavigationLocationDiagnosticPolicy.shouldLog(
            lastLoggedAt: nil, now: start
        ))
        XCTAssertFalse(NavigationLocationDiagnosticPolicy.shouldLog(
            lastLoggedAt: start, now: start.addingTimeInterval(19)
        ))
        XCTAssertTrue(NavigationLocationDiagnosticPolicy.shouldLog(
            lastLoggedAt: start, now: start.addingTimeInterval(20)
        ))
        XCTAssertTrue(NavigationLocationDiagnosticPolicy.shouldLog(
            lastLoggedAt: start, now: start.addingTimeInterval(-1)
        ), "A clock correction must not suppress diagnostics indefinitely")
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
        XCTAssertTrue(NavigationArrivalPolicy.mayCompleteTrip(hasOpenRequiredWaypoints: false))
        XCTAssertFalse(NavigationArrivalPolicy.mayCompleteTrip(
            hasOpenRequiredWaypoints: true
        ), "Arrival must not silently skip a mandatory pass or user-selected stop")
        let firstFix = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(NavigationArrivalPolicy.hasSettled(
            since: firstFix, at: firstFix.addingTimeInterval(3.9)
        ), "A short buffered GPS burst must not complete the trip")
        XCTAssertTrue(NavigationArrivalPolicy.hasSettled(
            since: firstFix, at: firstFix.addingTimeInterval(4)
        ))
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

    func testLockedDestinationUsesTripTitleInsteadOfContradictoryPlacemark() {
        XCTAssertEqual(DestinationSubtitlePolicy.subtitle(
            name: "Hochheim am Main",
            lockedRouteTitle: "Heimfahrt über Wurzenpass",
            locality: nil,
            administrativeArea: nil,
            country: "Schweiz",
            fallbackTitle: "Schweiz"
        ), "Heimfahrt über Wurzenpass")
    }

    func testDestinationSubtitleBuildsUsefulUniquePlaceHierarchy() {
        XCTAssertEqual(DestinationSubtitlePolicy.subtitle(
            name: "Café",
            lockedRouteTitle: nil,
            locality: "Mainz",
            administrativeArea: "Rheinland-Pfalz",
            country: "Deutschland",
            fallbackTitle: "Café, Mainz"
        ), "Mainz · Rheinland-Pfalz · Deutschland")
    }

    func testDestinationSubtitleRejectsUnverifiedCountryOnlyPlacemark() {
        XCTAssertEqual(DestinationSubtitlePolicy.subtitle(
            name: "Café Maldaner",
            lockedRouteTitle: nil,
            locality: "Schweiz",
            administrativeArea: nil,
            country: "Schweiz",
            fallbackTitle: "Schweiz"
        ), "Ausgewähltes Ziel")
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

    func testStepSelectionDoesNotTreatParallelRampAsMissedExit() {
        let beforeExit = [
            NavigationStepMetric(distanceFromRoute: 72, remainingOnStep: 650),
            NavigationStepMetric(distanceFromRoute: 5, remainingOnStep: 900,
                                 courseDifferenceDegrees: 2),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: beforeExit, transitionRadius: 12
        ), 0, "A closer parallel ramp must not hide the upcoming exit")

        let afterExit = [
            NavigationStepMetric(distanceFromRoute: 72, remainingOnStep: 60),
            NavigationStepMetric(distanceFromRoute: 5, remainingOnStep: 900,
                                 courseDifferenceDegrees: 2),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: afterExit, transitionRadius: 12
        ), 1, "The missed-step fallback must still advance near the junction")
    }

    func testLiveMetricEvaluationIsBoundedOnVeryLongRoute() {
        XCTAssertEqual(
            NavigationStepSelectionPolicy.metricEvaluationIndices(
                current: 400, stepCount: 1_000
            ),
            400..<481
        )
        XCTAssertEqual(
            NavigationStepSelectionPolicy.metricEvaluationIndices(
                current: 980, stepCount: 1_000
            ),
            980..<1_000
        )
        XCTAssertEqual(
            NavigationStepSelectionPolicy.metricEvaluationIndices(
                current: 0, stepCount: 0
            ),
            0..<0
        )
    }

    func testLiveFullRecoveryRequiresBothLongGapAndMeaningfulDisplacement() {
        let start = Date(timeIntervalSince1970: 1_000)
        let previous = CLLocation(
            coordinate: .init(latitude: 50.0, longitude: 8.0),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            timestamp: start
        )
        func location(latitude: Double, after seconds: TimeInterval) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: latitude, longitude: 8.0),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                timestamp: start.addingTimeInterval(seconds)
            )
        }

        XCTAssertFalse(NavigationLiveRecoveryPolicy.allowsFullRouteMatch(
            previous: previous, current: location(latitude: 50.03, after: 30)
        ), "A normal live update must keep the bounded fast path")
        XCTAssertFalse(NavigationLiveRecoveryPolicy.allowsFullRouteMatch(
            previous: previous, current: location(latitude: 50.001, after: 180)
        ), "A stationary pause must not scan the complete route")
        XCTAssertTrue(NavigationLiveRecoveryPolicy.allowsFullRouteMatch(
            previous: previous, current: location(latitude: 50.03, after: 180)
        ), "A long moving GPS gap must be able to recover beyond the bounded step window")
        XCTAssertFalse(NavigationLiveRecoveryPolicy.allowsFullRouteMatch(
            previous: nil, current: location(latitude: 50.03, after: 180)
        ))
    }

    func testNavigationPersistenceUsesShortCrashSafeCheckpoints() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: nil, now: start
        ))
        XCTAssertFalse(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(29.9)
        ))
        XCTAssertTrue(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(30)
        ))
        XCTAssertTrue(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(-1)
        ), "Clock rollback must start a fresh checkpoint window")
        XCTAssertFalse(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(59.9), interval: 60
        ))
        XCTAssertTrue(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(60), interval: 60
        ))
        XCTAssertTrue(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(-1), interval: 60
        ), "Route and offline progress must checkpoint after clock rollback")
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

    func testOfflineResumeEstimateStartsAtPersistedStepInsteadOfWholeTrip() {
        let estimate = OfflineGuidanceResumeEstimatePolicy.estimate(
            stepDistances: [10_000, 20_000, 30_000, 40_000],
            currentIndex: 2,
            routeDistance: 100_000,
            routeTravelTime: 5_000
        )

        XCTAssertEqual(estimate.distance, 70_000, accuracy: 0.001)
        XCTAssertEqual(estimate.travelTime, 3_500, accuracy: 0.001)
    }

    func testOfflineResumeEstimateAtEndDoesNotRestoreFullRouteTotals() {
        let estimate = OfflineGuidanceResumeEstimatePolicy.estimate(
            stepDistances: [1_000, 2_000], currentIndex: 2,
            routeDistance: 3_000, routeTravelTime: 180
        )

        XCTAssertEqual(estimate.distance, 0)
        XCTAssertEqual(estimate.travelTime, 0)
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

    func testOfflineResumeStartsNearPersistedTripProgress() {
        let steps = (0..<10).map { index in
            OfflineGuidanceStep(
                instruction: "Schritt \(index)", distance: 1_000,
                coordinates: [
                    .init(latitude: 50, longitude: 8 + Double(index) * 0.01),
                    .init(latitude: 50, longitude: 8 + Double(index + 1) * 0.01),
                ]
            )
        }

        XCTAssertEqual(OfflineGuidanceResumePolicy.stepIndex(
            steps: steps, persistedProgress: 0.72
        ), 7)
        XCTAssertEqual(OfflineGuidanceResumePolicy.stepIndex(
            steps: steps, persistedProgress: nil
        ), 0)
    }

    func testOfflineResumeKeepsSmallBackwardSafetyAllowance() {
        let steps = (0..<5).map { index in
            OfflineGuidanceStep(
                instruction: "Schritt \(index)", distance: 1_000,
                coordinates: [.init(latitude: 50, longitude: 8),
                              .init(latitude: 50, longitude: 8.01)]
            )
        }

        XCTAssertEqual(OfflineGuidanceResumePolicy.stepIndex(
            steps: steps, persistedProgress: 0.405
        ), 1, "A checkpoint just beyond a junction must retain the preceding guidance step")
        XCTAssertEqual(OfflineGuidanceResumePolicy.stepIndex(
            steps: steps, persistedProgress: 2
        ), 4)
    }

    func testOfflineProgressUsesCachedDistanceWhenLiveLegsAreUnavailable() throws {
        XCTAssertEqual(try XCTUnwrap(OfflineRouteProgressPolicy.progress(
            liveRouteDistance: 0, cachedRouteDistance: 100_000,
            remainingDistance: 40_000
        )), 0.6, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(OfflineRouteProgressPolicy.progress(
            liveRouteDistance: 120_000, cachedRouteDistance: 100_000,
            remainingDistance: 30_000
        )), 0.75, accuracy: 0.000_1)
        XCTAssertNil(OfflineRouteProgressPolicy.progress(
            liveRouteDistance: 0, cachedRouteDistance: 0,
            remainingDistance: 0
        ))
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
        XCTAssertTrue(OfflineRouteRecoveryPolicy.shouldAttempt(
            lastAttempt: now.addingTimeInterval(1), now: now
        ), "Clock rollback must allow online recovery to restart")
    }

    func testOfflineInitialRecoveryWaitsForPositionInsideRouteCorridor() {
        XCTAssertFalse(OfflineInitialPositionMatchPolicy.isReliable(
            distanceFromRoute: 2_000, horizontalAccuracy: 20,
            speedMetresPerSecond: 25
        ))
        XCTAssertTrue(OfflineInitialPositionMatchPolicy.isReliable(
            distanceFromRoute: 35, horizontalAccuracy: 10,
            speedMetresPerSecond: 12
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
        XCTAssertTrue(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: false, attemptInProgress: false,
            lastAttempt: now.addingTimeInterval(1), now: now
        ), "Clock rollback must not strand a persisted trip")
        XCTAssertFalse(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: true, attemptInProgress: false, lastAttempt: nil, now: now
        ))
        XCTAssertFalse(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: false, attemptInProgress: true, lastAttempt: nil, now: now
        ))
    }

    func testTripRestorePrefersFreshOnlineThenOfflineBeforeStaleLiveRoute() {
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: true, hasMatchingLiveRoute: true,
            hasMatchingOfflineRoute: true
        ), .online)
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: false, hasMatchingLiveRoute: true,
            hasMatchingOfflineRoute: true
        ), .offline)
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: false, hasMatchingLiveRoute: true,
            hasMatchingOfflineRoute: false
        ), .staleLive)
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: false, hasMatchingLiveRoute: false,
            hasMatchingOfflineRoute: false
        ), .unavailable)
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: false, hasMatchingLiveRoute: false,
            hasMatchingOfflineRoute: true
        ), .offline)
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
        XCTAssertFalse(DestinationActivationRollbackPolicy.isCurrent(
            request: older, current: latest
        ))
        XCTAssertTrue(DestinationActivationRollbackPolicy.isCurrent(
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

    func testRouteOptionScopeKeepsWaypointRulesOutOfGlobalPreferences() {
        XCTAssertNil(RouteOptionScopePolicy.waypointID("  "))
        XCTAssertTrue(RouteOptionScopePolicy.mutatesGlobalSettings(waypointID: nil))
        XCTAssertTrue(RouteOptionScopePolicy.mutatesGlobalSettings(waypointID: ""))
        XCTAssertEqual(RouteOptionScopePolicy.waypointID("  slovenia  "), "slovenia")
        XCTAssertFalse(RouteOptionScopePolicy.mutatesGlobalSettings(
            waypointID: "slovenia"
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

    func testRouteSearchFallsBackToPersistedProgressDuringGPSGap() {
        XCTAssertEqual(RouteSearchPolicy.currentProgress(
            projected: 0.72, persisted: 0.45, navigationActive: true
        ), 0.72)
        XCTAssertEqual(RouteSearchPolicy.currentProgress(
            projected: nil, persisted: 0.45, navigationActive: true
        ), 0.45)
        XCTAssertEqual(RouteSearchPolicy.currentProgress(
            projected: nil, persisted: 0.45, navigationActive: false
        ), 0)
        XCTAssertEqual(RouteSearchPolicy.currentProgress(
            projected: 1.4, persisted: nil, navigationActive: true
        ), 1)
    }

    func testRouteSearchUsesProgressOfInstalledRerouteBeforeOriginalTripProgress() {
        let installed = RouteSearchPolicy.installedRouteProgress(
            totalDistance: 200_000,
            remainingDistance: 200_000,
            navigationActive: true
        )

        XCTAssertEqual(installed, 0)
        XCTAssertEqual(RouteSearchPolicy.currentProgress(
            projected: installed,
            persisted: 0.8,
            navigationActive: true
        ), 0, "A fresh route from the current position must be searched from its beginning")
    }

    func testInstalledRouteProgressTracksCurrentGeometryAndRejectsInvalidState() {
        XCTAssertEqual(RouteSearchPolicy.installedRouteProgress(
            totalDistance: 200_000, remainingDistance: 50_000, navigationActive: true
        ) ?? -1, 0.75, accuracy: 0.001)
        XCTAssertEqual(RouteSearchPolicy.installedRouteProgress(
            totalDistance: 200_000, remainingDistance: 0, navigationActive: true
        ), 1)
        XCTAssertNil(RouteSearchPolicy.installedRouteProgress(
            totalDistance: 200_000, remainingDistance: 50_000, navigationActive: false
        ))
        XCTAssertNil(RouteSearchPolicy.installedRouteProgress(
            totalDistance: 0, remainingDistance: 0, navigationActive: true
        ))
    }

    func testSpeedLimitSelectionUsesCurrentVisitAtRouteCrossing() {
        let crossing = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        let points = [
            .init(latitude: 50, longitude: 7.99),
            crossing,
            .init(latitude: 50.01, longitude: 8),
            crossing,
            .init(latitude: 50, longitude: 8.01),
        ]

        let early = SpeedLimitSelectionPolicy.index(
            near: crossing, points: points, availableLimitCount: points.count,
            expectedProgress: 0.2
        )
        let late = SpeedLimitSelectionPolicy.index(
            near: crossing, points: points, availableLimitCount: points.count,
            expectedProgress: 0.8
        )

        XCTAssertEqual(early, 1)
        XCTAssertEqual(late, 3)
    }

    func testSpeedLimitSelectionNeverIndexesBeyondProviderResponse() {
        let points = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.01),
        ]
        XCTAssertNil(SpeedLimitSelectionPolicy.index(
            near: points[1], points: points, availableLimitCount: 1,
            expectedProgress: 1
        ))
    }

    func testRouteSearchAheadCheckUsesDistanceProgress() {
        XCTAssertTrue(RouteSearchPolicy.isAhead(
            candidateProgress: 0.498, currentProgress: 0.50,
            totalRouteDistance: 100_000
        ))
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.40, currentProgress: 0.50,
            totalRouteDistance: 100_000
        ))
        XCTAssertTrue(RouteSearchPolicy.isAhead(
            candidateProgress: 0.75, currentProgress: 0.50,
            totalRouteDistance: 100_000
        ))
    }

    func testRouteSearchBackwardToleranceDoesNotScaleToManyKilometres() {
        XCTAssertTrue(RouteSearchPolicy.isAhead(
            candidateProgress: 0.4997, currentProgress: 0.50,
            totalRouteDistance: 800_000
        ), "Small GPS/projection drift remains acceptable")
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.4975, currentProgress: 0.50,
            totalRouteDistance: 800_000
        ), "A stop two kilometres behind must never create an Autobahn return trip")
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.48, currentProgress: 0.50,
            totalRouteDistance: 800_000
        ), "A continental route must not turn two percent into 16 km behind")
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.5, currentProgress: 0.5,
            totalRouteDistance: 0
        ))
    }

    func testRouteSearchSelectionRejectsResultPassedWhileListWasOpen() {
        XCTAssertTrue(RouteSearchPolicy.isAhead(
            candidateProgress: 0.55, currentProgress: 0.54,
            totalRouteDistance: 400_000
        ))
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.55, currentProgress: 0.62,
            totalRouteDistance: 400_000
        ), "A stop selected after driving well past it must not route the car backwards")
    }

    func testRouteSearchSelectionDoesNotMoveBackAtRepeatedJunction() {
        let reconciled = RouteSearchPolicy.installedProgress(
            projected: 0.42,
            distanceEstimate: 0.58
        )
        let current = RouteSearchPolicy.currentProgress(
            projected: reconciled,
            persisted: 0.80,
            navigationActive: true
        )

        XCTAssertEqual(current, 0.58)
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.50,
            currentProgress: current,
            totalRouteDistance: 400_000
        ), "A stop beside an earlier visit to the same junction is already behind the car")
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

    func testLongRouteSearchDoesNotQueryManyKilometresBehindVehicle() throws {
        let route = (0...100).map {
            CLLocationCoordinate2D(latitude: 45 + Double($0) / 10, longitude: 8)
        }
        let remaining = RouteSearchPolicy.remainingRouteCoordinates(
            route, currentProgress: 0.5
        )
        let first = try XCTUnwrap(remaining.first)
        let firstProgress = try XCTUnwrap(
            RouteGeometryProgress.nearestProgress(of: first, on: route)
        ).progress
        XCTAssertGreaterThanOrEqual(firstProgress, 0.49)
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

    func testRouteSearchBatchLimitsRemainSmallAndBounded() {
        XCTAssertEqual(NavigationSearchBatchPolicy.timeoutNanoseconds, 8_000_000_000)
        XCTAssertEqual(NavigationSearchBatchPolicy.maximumConcurrentRouteSearches, 5)
        XCTAssertEqual(NavigationSearchBatchPolicy.maximumConcurrentAmenitySearches, 8)
    }

    func testDirectionsDeadlinePrecedesRerouteWatchdog() {
        XCTAssertLessThan(
            NavigationDirectionsTimeoutPolicy.routeCalculation,
            NavigationRerouteWatchdogPolicy.timeout
        )
        XCTAssertLessThan(
            NavigationDirectionsTimeoutPolicy.detourCalculation,
            NavigationDirectionsTimeoutPolicy.routeCalculation
        )
        XCTAssertEqual(
            NavigationDirectionsTimeoutPolicy.nanoseconds(for: 8),
            8_000_000_000
        )
    }

    func testRouteComparisonPublishesOnlyForCurrentEligibleRoute() {
        let route = UUID()
        XCTAssertTrue(RouteComparisonPublicationPolicy.mayPublish(
            requestRoute: route, currentRoute: route, stillEligible: true
        ))
        XCTAssertFalse(RouteComparisonPublicationPolicy.mayPublish(
            requestRoute: route, currentRoute: UUID(), stillEligible: true
        ))
        XCTAssertFalse(RouteComparisonPublicationPolicy.mayPublish(
            requestRoute: route, currentRoute: route, stillEligible: false
        ))
    }

    func testRouteSearchRejectsExcessiveOrInvalidDrivingDetours() {
        XCTAssertTrue(RouteSearchPolicy.acceptsDetour(4_500))
        XCTAssertTrue(RouteSearchPolicy.acceptsDetour(20_000))
        XCTAssertFalse(RouteSearchPolicy.acceptsDetour(20_001))
        XCTAssertFalse(RouteSearchPolicy.acceptsDetour(.infinity))
        XCTAssertFalse(RouteSearchPolicy.acceptsDetour(-1))
    }

    func testRouteSearchScalesAcceptableDetourToTripLength() {
        XCTAssertEqual(RouteSearchPolicy.maximumDetour(remainingRouteDistance: 20_000), 3_000)
        XCTAssertEqual(RouteSearchPolicy.maximumDetour(remainingRouteDistance: 200_000), 10_000)
        XCTAssertEqual(RouteSearchPolicy.maximumDetour(remainingRouteDistance: 800_000), 20_000)
        XCTAssertTrue(RouteSearchPolicy.acceptsDetour(
            2_900, remainingRouteDistance: 20_000
        ))
        XCTAssertFalse(RouteSearchPolicy.acceptsDetour(
            3_100, remainingRouteDistance: 20_000
        ))
    }

    func testRouteSearchProgressNeverMovesBackAtRouteCrossing() {
        XCTAssertEqual(RouteSearchPolicy.installedProgress(
            projected: 0.42, distanceEstimate: 0.50
        ), 0.50)
        XCTAssertEqual(RouteSearchPolicy.installedProgress(
            projected: 0.58, distanceEstimate: 0.50
        ), 0.58)
        XCTAssertEqual(RouteSearchPolicy.installedProgress(
            projected: nil, distanceEstimate: 0.50
        ), 0.50)
        XCTAssertNil(RouteSearchPolicy.installedProgress(
            projected: .infinity, distanceEstimate: nil
        ))
    }

    func testRouteSearchRanksSmallUsefulDetourAheadOfEarlierLargeDetour() {
        let earlyLargeDetour = RouteSearchPolicy.rankingScore(
            detourMetres: 8_000, candidateProgress: 0.25,
            currentProgress: 0.20, remainingRouteDistance: 200_000
        )
        let laterSmallDetour = RouteSearchPolicy.rankingScore(
            detourMetres: 500, candidateProgress: 0.30,
            currentProgress: 0.20, remainingRouteDistance: 200_000
        )
        XCTAssertLessThan(laterSmallDetour, earlyLargeDetour)
        XCTAssertEqual(RouteSearchPolicy.rankingScore(
            detourMetres: .infinity, candidateProgress: 0.3,
            currentProgress: 0.2, remainingRouteDistance: 100_000
        ), .greatestFiniteMagnitude)
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

    func testRouteSearchDetourAnchorsFollowDrivingDirection() throws {
        let route = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.1)
        ]
        let anchors = try XCTUnwrap(RouteSearchPolicy.detourAnchors(
            routeCoordinates: route, progress: 0.5
        ))
        XCTAssertLessThan(anchors.entry.longitude, anchors.exit.longitude)
        XCTAssertEqual(anchors.baselineMetres, 2_000, accuracy: 5)
    }

    func testRouteSearchShortlistSpreadsDrivingChecksAcrossRouteSections() {
        let candidates = [
            (name: "Early far", progress: 0.10, distance: 900.0),
            (name: "Early best", progress: 0.105, distance: 120.0),
            (name: "Early duplicate", progress: 0.11, distance: 300.0),
            (name: "Middle", progress: 0.35, distance: 250.0),
            (name: "Later", progress: 0.70, distance: 180.0),
        ]

        let shortlist = RouteSearchPolicy.diverseShortlist(
            candidates, maximum: 3,
            progress: { $0.progress }, airDistance: { $0.distance }
        )

        XCTAssertEqual(shortlist.map(\.name), ["Early best", "Middle", "Later"])
    }

    func testRouteSearchShortlistHonoursRequestLimitAndEmptyLimit() {
        let candidates = (0..<10).map { (progress: Double($0) / 10, distance: Double($0)) }
        XCTAssertEqual(RouteSearchPolicy.diverseShortlist(
            candidates, maximum: 4,
            progress: { $0.progress }, airDistance: { $0.distance }
        ).count, 4)
        XCTAssertTrue(RouteSearchPolicy.diverseShortlist(
            candidates, maximum: 0,
            progress: { $0.progress }, airDistance: { $0.distance }
        ).isEmpty)
    }

    func testRouteSearchSubtractsDistanceDrivenAnywayFromDetour() throws {
        XCTAssertEqual(try XCTUnwrap(RouteSearchPolicy.additionalDistance(
            viaDistance: 2_750, baselineDistance: 2_000
        )), 750, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(RouteSearchPolicy.additionalDistance(
            viaDistance: 1_900, baselineDistance: 2_000
        )), 0, accuracy: 0.1)
        XCTAssertNil(RouteSearchPolicy.additionalDistance(
            viaDistance: .infinity, baselineDistance: 2_000
        ))
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

    func testRouteSearchCanMergeSameNamedPoiCoordinateDrift() {
        let first = CLLocationCoordinate2D(latitude: 50.0000, longitude: 8.0000)
        let nearby = CLLocationCoordinate2D(latitude: 50.0005, longitude: 8.0000)
        XCTAssertTrue(DestinationSearchRankingPolicy.isDuplicate(
            name: "McDonald’s", coordinate: first,
            existingName: "McDonalds", existingCoordinate: nearby,
            toleranceMetres: 80
        ))
        XCTAssertFalse(DestinationSearchRankingPolicy.isDuplicate(
            name: "McDonald’s", coordinate: first,
            existingName: "McDonalds", existingCoordinate: nearby,
            toleranceMetres: 40
        ))
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

    func testDriveUsageCountsPlausibleMovement() throws {
        let start = CLLocation(coordinate: .init(latitude: 49.8, longitude: 8.3),
                               altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                               course: 0, speed: 14, timestamp: Date(timeIntervalSince1970: 1_000))
        let end = CLLocation(coordinate: .init(latitude: 49.801, longitude: 8.3),
                             altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: 0, speed: 14, timestamp: Date(timeIntervalSince1970: 1_010))
        let segment = try XCTUnwrap(DriveUsageSegmentPolicy.segment(previous: start, current: end))
        XCTAssertGreaterThan(segment.distanceMetres, 100)
        XCTAssertEqual(segment.movingTime, 10)
    }

    func testDriveUsageRejectsStationaryJitterAndLongGaps() {
        let start = CLLocation(coordinate: .init(latitude: 49.8, longitude: 8.3),
                               altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                               course: 0, speed: 0, timestamp: Date(timeIntervalSince1970: 1_000))
        let jitter = CLLocation(coordinate: .init(latitude: 49.800001, longitude: 8.3),
                                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                course: 0, speed: 0, timestamp: Date(timeIntervalSince1970: 1_010))
        let late = CLLocation(coordinate: .init(latitude: 49.9, longitude: 8.3),
                              altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                              course: 0, speed: 20, timestamp: Date(timeIntervalSince1970: 1_500))
        XCTAssertNil(DriveUsageSegmentPolicy.segment(previous: start, current: jitter))
        XCTAssertNil(DriveUsageSegmentPolicy.segment(previous: start, current: late))
    }

    func testDriveUsageDoesNotCountWholeStoppedIntervalWhenMovementJustResumed() throws {
        let start = CLLocation(
            coordinate: .init(latitude: 49.8, longitude: 8.3), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0,
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let resumed = CLLocation(
            coordinate: .init(latitude: 49.80009, longitude: 8.3), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 10,
            timestamp: Date(timeIntervalSince1970: 1_060)
        )
        let segment = try XCTUnwrap(DriveUsageSegmentPolicy.segment(
            previous: start, current: resumed
        ))
        XCTAssertGreaterThan(segment.distanceMetres, 9)
        XCTAssertLessThan(segment.movingTime, 2)
        XCTAssertNotEqual(segment.movingTime, 60)
    }

    func testDriveUsageStatisticsAccumulateTrips() {
        var statistics = DriveUsageStatistics()
        statistics.recordTrip(distanceMetres: 12_500, movingTime: 3_600,
                              endedAt: Date(timeIntervalSince1970: 2_000))
        statistics.recordTrip(distanceMetres: 7_500, movingTime: 1_800,
                              endedAt: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(statistics.totalDistanceMetres, 20_000)
        XCTAssertEqual(statistics.totalMovingTime, 5_400)
        XCTAssertEqual(statistics.completedNavigations, 2)
        XCTAssertEqual(statistics.lastTripDistanceMetres, 7_500)
    }

    func testUsageTripTransitionFinalizesOnlyAReplacedMatchingTrip() {
        let previous = UUID()
        let next = UUID()

        XCTAssertTrue(DriveUsageTripTransitionPolicy.shouldFinalize(
            sessionTripID: previous, previousTripID: previous, nextTripID: next
        ))
        XCTAssertFalse(DriveUsageTripTransitionPolicy.shouldFinalize(
            sessionTripID: previous, previousTripID: previous, nextTripID: previous
        ))
        XCTAssertFalse(DriveUsageTripTransitionPolicy.shouldFinalize(
            sessionTripID: UUID(), previousTripID: previous, nextTripID: next
        ))
        XCTAssertFalse(DriveUsageTripTransitionPolicy.shouldFinalize(
            sessionTripID: previous, previousTripID: previous, nextTripID: nil
        ))
    }

    func testUsageSessionSurvivesPauseWithoutPersistingLocations() throws {
        let suite = "DriveUsageSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DriveUsageSessionStore(defaults: defaults)
        let expected = DriveUsageSessionState(
            tripID: UUID(), distanceMetres: 428_000, movingTime: 14_400
        )
        store.save(expected)

        XCTAssertEqual(store.load(), expected)
        let encoded = try XCTUnwrap(defaults.data(forKey: store.key))
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("latitude"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("longitude"))
        store.clear()
        XCTAssertEqual(store.load(), DriveUsageSessionState())
    }

    func testRouteOverviewRejectsRemoteVehicleFixButKeepsNearbyDeviation() throws {
        let route = MKMapRect(
            origin: MKMapPoint(.init(latitude: 50.0, longitude: 8.0)),
            size: .init(width: 5_000, height: 5_000)
        )
        let nearby = CLLocationCoordinate2D(latitude: 50.05, longitude: 8.05)
        let remote = CLLocationCoordinate2D(latitude: 48.14, longitude: 11.58)

        XCTAssertNotNil(RouteOverviewMapRectPolicy.vehicleCoordinate(nearby, near: route))
        XCTAssertNil(RouteOverviewMapRectPolicy.vehicleCoordinate(remote, near: route))
        XCTAssertNil(RouteOverviewMapRectPolicy.vehicleCoordinate(
            .init(latitude: .nan, longitude: 8), near: route
        ))
        XCTAssertEqual(
            RouteOverviewMapRectPolicy.vehicleCoordinate(remote, near: nil)?.longitude,
            remote.longitude
        )
    }
}
