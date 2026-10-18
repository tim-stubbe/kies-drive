import XCTest
import CoreLocation
@testable import Kies_Drive

final class LongTripPlanningTests: XCTestCase {
    func testStaleBreakCardIsRejectedAfterPlanRefresh() {
        let candidate = BreakCandidate(
            id: "rest", name: "Rastplatz", coordinate: .init(latitude: 50, longitude: 8),
            progress: 0.5, detourMetres: 100, isOpen: true
        )
        let oldBreak = PlannedBreak(
            id: "break-1", candidate: candidate, afterDriving: 7_200,
            duration: 1_200, routeProgress: 0.5,
            explanation: "Alter Plan"
        )
        let currentBreak = PlannedBreak(
            id: "break-1", candidate: candidate, afterDriving: 8_000,
            duration: 1_200, routeProgress: 0.6,
            explanation: "Neuer Plan"
        )
        let result = RouteScenarioResult(
            id: "route", routeTitle: "Route", scenario: .target(150),
            distanceMetres: 100_000, drivingTime: 9_000, totalTime: 10_200,
            fuel: .init(litres: 7, cost: 12, averageConsumptionLPer100km: 7),
            toll: .unknown(reason: "Nicht geprüft"), breaks: [currentBreak],
            fuelStops: [], unlimitedFraction: 0
        )
        let plan = LongTripPlan(createdAt: Date(), results: [result], note: "")

        XCTAssertFalse(PlannedStopSelectionPolicy.acceptsBreak(oldBreak, currentPlan: plan))
        XCTAssertTrue(PlannedStopSelectionPolicy.acceptsBreak(currentBreak, currentPlan: plan))
        XCTAssertFalse(PlannedStopSelectionPolicy.acceptsBreak(currentBreak, currentPlan: nil))
    }

    func testSingleRoutePlanExplainsWhyTollComparisonIsUnavailable() {
        let route = RoutePlanningInput(
            id: "fixed", title: "Feste Route", distanceMetres: 100_000,
            mapKitExpectedTravelTime: 4_000, unlimitedMotorwayFraction: 0,
            typicalUnlimitedSpeedKmh: 130,
            toll: .unknown(reason: "Noch nicht belegt"), breakCandidates: []
        )
        let plan = RouteComparison(fuelModel: .init(), breakPlanner: .init()).compare(
            routes: [route], scenarios: [.target(130)], vehicle: .init()
        )
        XCTAssertTrue(plan.note.contains("allen Pflichtpunkten und Routenvorgaben"))
    }

    func testRemainingRouteKeepsUnverifiedStopsAheadOnInstalledGeometry() throws {
        let route = RoutePlanningInput(
            id: "remaining", title: "Reststrecke", distanceMetres: 400_000,
            mapKitExpectedTravelTime: 5 * 3600,
            unlimitedMotorwayFraction: 0, typicalUnlimitedSpeedKmh: 130,
            toll: .unknown(reason: "Test"), breakCandidates: [],
            installedRouteStartProgress: 0.6
        )
        let vehicle = VehicleProfile(
            baseConsumptionLPer100km: 8, fuelPricePerLitre: 1.8,
            tankCapacityLitres: 50, initialFuelFraction: 0.35
        )
        let result = try XCTUnwrap(RouteComparison(
            fuelModel: .init(), breakPlanner: .init()
        ).compare(
            routes: [route], scenarios: [.target(130)], vehicle: vehicle,
            alreadyDrivenSinceBreak: 90 * 60
        ).results.first)

        let fuelStop = try XCTUnwrap(result.fuelStops.first)
        XCTAssertNil(fuelStop.candidate)
        XCTAssertGreaterThan(fuelStop.insertionRouteProgress, 0.6)
        XCTAssertTrue(PlannedRouteStopVisibilityPolicy.isAhead(
            fuelStop.insertionRouteProgress, current: 0.6
        ))
        let plannedBreak = try XCTUnwrap(result.breaks.first)
        XCTAssertGreaterThanOrEqual(plannedBreak.insertionRouteProgress, 0.6)
    }

    func testTwoRealRoutesDoNotClaimComparisonIsUnavailable() {
        func route(_ id: String) -> RoutePlanningInput {
            .init(id: id, title: id, distanceMetres: 100_000,
                  mapKitExpectedTravelTime: 4_000, unlimitedMotorwayFraction: 0,
                  typicalUnlimitedSpeedKmh: 130,
                  toll: .unknown(reason: "Test"), breakCandidates: [])
        }
        let plan = RouteComparison(fuelModel: .init(), breakPlanner: .init()).compare(
            routes: [route("standard"), route("avoid")],
            scenarios: [.target(130)], vehicle: .init()
        )
        XCTAssertFalse(plan.note.contains("Ein Mautvergleich erscheint nur"))
    }

    func testVehicleAndSpeedInputsRecoverFromCorruptedStoredValues() {
        let profile = VehicleProfile(
            name: " ", baseConsumptionLPer100km: .nan,
            referenceSpeedKmh: .infinity, fuelPricePerLitre: -1,
            tankCapacityLitres: .infinity, usableTankFraction: 4,
            initialFuelFraction: -.infinity
        ).sanitized

        XCTAssertEqual(profile.name, "Mein Fahrzeug")
        XCTAssertEqual(profile.baseConsumptionLPer100km, 6.5)
        XCTAssertEqual(profile.referenceSpeedKmh, 100)
        XCTAssertEqual(profile.fuelPricePerLitre, 1.75)
        XCTAssertEqual(profile.tankCapacityLitres, 50)
        XCTAssertEqual(profile.usableTankFraction, 0.85)
        XCTAssertEqual(profile.initialFuelFraction, 1)
        XCTAssertEqual(SpeedScenario.target(.nan).targetSpeedKmh, 150)
        XCTAssertEqual(SpeedScenario.target(500).targetSpeedKmh, 220)
        XCTAssertEqual(DriveSettings.sanitizedNumber(
            NSNumber(value: Double.nan), fallback: 6.5, range: 1...40
        ), 6.5)
        XCTAssertEqual(DriveSettings.sanitizedNumber(
            NSNumber(value: 7.2), fallback: 6.5, range: 1...40
        ), 7.2)
    }

    func testBreakReminderStateWritesOnlyRealChanges() {
        XCTAssertNil(DrivingRestReminderStatePolicy.changedRawValues(
            current: [], stages: []
        ))
        XCTAssertEqual(DrivingRestReminderStatePolicy.changedRawValues(
            current: [], stages: [.plan]
        ), [NavigationBreakReminderPolicy.Stage.plan.rawValue])
        XCTAssertNil(DrivingRestReminderStatePolicy.changedRawValues(
            current: [NavigationBreakReminderPolicy.Stage.plan.rawValue],
            stages: [.plan]
        ))
        XCTAssertEqual(DrivingRestReminderStatePolicy.changedRawValues(
            current: [NavigationBreakReminderPolicy.Stage.plan.rawValue],
            stages: []
        ), [])
    }

    func testDeferredBreakSpeechPromotesToNewestUrgency() {
        XCTAssertEqual(DrivingRestReminderStatePolicy.stageToRetry(
            pending: .plan, newlyDue: .soon
        ), .soon)
        XCTAssertEqual(DrivingRestReminderStatePolicy.stageToRetry(
            pending: .plan, newlyDue: .due
        ), .due)
        XCTAssertEqual(DrivingRestReminderStatePolicy.stageToRetry(
            pending: .soon, newlyDue: nil
        ), .soon)
        XCTAssertEqual(DrivingRestReminderStatePolicy.stageToRetry(
            pending: nil, newlyDue: .plan
        ), .plan)
        XCTAssertNil(DrivingRestReminderStatePolicy.stageToRetry(
            pending: nil, newlyDue: nil
        ))
    }

    func testBreakReminderTextCanBeRebuiltForDeferredSpeech() {
        XCTAssertEqual(NavigationBreakReminderTextPolicy.text(
            stage: .plan, plannedName: "Autohof Süd"
        ), "In etwa 30 Minuten Pause bei Autohof Süd einplanen.")
        XCTAssertEqual(NavigationBreakReminderTextPolicy.text(
            stage: .soon, plannedName: nil
        ), "Bitte in etwa 10 Minuten eine Pause einlegen.")
        XCTAssertEqual(NavigationBreakReminderTextPolicy.text(
            stage: .due, plannedName: "Wird bewusst nicht genannt"
        ), "Bitte bei der nächsten sicheren Möglichkeit Pause einlegen.")
    }

    func testPendingSpokenBreakReminderSurvivesStateRoundTrip() throws {
        let state = DrivingRestState(
            tripID: UUID(), continuousDriving: 5_000,
            deliveredReminderRawValues: [NavigationBreakReminderPolicy.Stage.plan.rawValue],
            pendingSpokenReminderRawValue: NavigationBreakReminderPolicy.Stage.plan.rawValue
        )
        let restored = try JSONDecoder().decode(
            DrivingRestState.self, from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(restored, state)
    }

    func testPendingSpokenFuelReminderSurvivesStateRoundTrip() throws {
        let state = DrivingFuelState(
            deliveredReminderKeys: ["station:0"],
            pendingSpokenReminderKey: "station:0",
            pendingSpokenReminderText: "In etwa 30 Kilometern tanken."
        )
        let decoded = try JSONDecoder().decode(
            DrivingFuelState.self, from: JSONEncoder().encode(state)
        )
        XCTAssertEqual(decoded, state)
        XCTAssertTrue(NavigationFuelReminderSpeechDeliveryPolicy.shouldClearPending(
            pendingKey: decoded.pendingSpokenReminderKey,
            completedKey: "station:0"
        ))
        XCTAssertFalse(NavigationFuelReminderSpeechDeliveryPolicy.shouldClearPending(
            pendingKey: "station:2", completedKey: "station:1"
        ))
        XCTAssertFalse(NavigationFuelReminderSpeechDeliveryPolicy.shouldClearPending(
            pendingKey: "station:2", completedKey: nil
        ))

        var muted = decoded
        muted.clearPendingSpeech()
        XCTAssertNil(muted.pendingSpokenReminderKey)
        XCTAssertNil(muted.pendingSpokenReminderText)
        XCTAssertEqual(muted.deliveredReminderKeys, state.deliveredReminderKeys)
    }

    func testPendingFuelSpeechMustStillBelongToAheadStopAfterReroute() {
        let stop = PlannedFuelStop(
            id: "fuel-stop", candidate: nil,
            afterDistanceMetres: 180_000, routeProgress: 0.65,
            explanation: "Geplanter Tankstopp"
        )
        let key = NavigationFuelReminderPolicy.key(
            stopID: NavigationFuelReminderPolicy.reminderID(for: stop), stage: .soon
        )

        XCTAssertTrue(NavigationFuelReminderSpeechDeliveryPolicy.isRelevant(
            pendingKey: key, stops: [stop], currentProgress: 0.4
        ))
        XCTAssertFalse(NavigationFuelReminderSpeechDeliveryPolicy.isRelevant(
            pendingKey: key, stops: [], currentProgress: 0.4
        ), "A stop removed by rerouting must never be announced")
        XCTAssertFalse(NavigationFuelReminderSpeechDeliveryPolicy.isRelevant(
            pendingKey: key, stops: [stop], currentProgress: 0.8
        ), "A stop already passed while speech was interrupted must never be announced")
        XCTAssertFalse(NavigationFuelReminderSpeechDeliveryPolicy.isRelevant(
            pendingKey: "different-stop:1", stops: [stop], currentProgress: 0.4
        ))
    }

    func testDeferredFuelSpeechPromotesOnlyForCurrentNearestStop() {
        let stopID = "station:fuel-a"
        let planKey = NavigationFuelReminderPolicy.key(stopID: stopID, stage: .plan)
        XCTAssertEqual(NavigationFuelReminderSpeechDeliveryPolicy.stageToRetry(
            pendingKey: planKey, stopID: stopID, newlyDue: .soon
        ), .soon)
        XCTAssertEqual(NavigationFuelReminderSpeechDeliveryPolicy.stageToRetry(
            pendingKey: planKey, stopID: stopID, newlyDue: .due
        ), .due)
        XCTAssertEqual(NavigationFuelReminderSpeechDeliveryPolicy.stageToRetry(
            pendingKey: planKey, stopID: stopID, newlyDue: nil
        ), .plan)
        XCTAssertNil(NavigationFuelReminderSpeechDeliveryPolicy.stageToRetry(
            pendingKey: planKey, stopID: "station:new-nearest", newlyDue: nil
        ), "A later stop must not speak after a new nearer stop is planned")
    }

    func testPendingBreakSpeechClearsOnlyAfterMatchingCompletion() {
        let plan = NavigationBreakReminderPolicy.Stage.plan.rawValue
        XCTAssertFalse(NavigationBreakReminderSpeechDeliveryPolicy.shouldClearPending(
            pendingRawValue: plan, completed: nil
        ), "Cancellation must leave the reminder retryable")
        XCTAssertFalse(NavigationBreakReminderSpeechDeliveryPolicy.shouldClearPending(
            pendingRawValue: plan, completed: .soon
        ), "An older callback must not clear a newer pending reminder")
        XCTAssertTrue(NavigationBreakReminderSpeechDeliveryPolicy.shouldClearPending(
            pendingRawValue: plan, completed: .plan
        ))
    }

    func testFuelReminderEscalatesWithoutRepeatingDeliveredStages() {
        let stopID = "fuel-a"
        XCTAssertEqual(NavigationFuelReminderPolicy.stage(
            distanceMetres: 25_000, deliveredKeys: [], stopID: stopID
        ), .plan)
        let deliveredPlan = [NavigationFuelReminderPolicy.key(stopID: stopID, stage: .plan)]
        XCTAssertEqual(NavigationFuelReminderPolicy.stage(
            distanceMetres: 8_000, deliveredKeys: Set(deliveredPlan), stopID: stopID
        ), .soon)
        let deliveredSoon = Set(deliveredPlan + [
            NavigationFuelReminderPolicy.key(stopID: stopID, stage: .soon)
        ])
        XCTAssertEqual(NavigationFuelReminderPolicy.stage(
            distanceMetres: 1_000, deliveredKeys: deliveredSoon, stopID: stopID
        ), .due)
        XCTAssertNil(NavigationFuelReminderPolicy.stage(
            distanceMetres: 40_000, deliveredKeys: [], stopID: stopID
        ))
        let sparseDue = NavigationFuelReminderPolicy.keysThrough(stopID: stopID, stage: .due)
        XCTAssertNil(NavigationFuelReminderPolicy.stage(
            distanceMetres: 8_000, deliveredKeys: sparseDue, stopID: stopID
        ), "A sparse jump directly to due must consume obsolete earlier stages")
    }

    func testFuelReminderUsesInstalledRouteDistanceAndPersistsDelivery() throws {
        let stop = PlannedFuelStop(
            id: "fuel", candidate: nil, afterDistanceMetres: 80_000,
            routeProgress: 0.6, explanation: "Tanken"
        )
        XCTAssertEqual(NavigationFuelReminderPolicy.remainingDistance(
            stop: stop, currentProgress: 0.5, installedRouteDistance: 200_000
        ), 20_000, accuracy: 0.1)

        let state = DrivingFuelState(deliveredReminderKeys: ["fuel:0"])
        XCTAssertEqual(try JSONDecoder().decode(
            DrivingFuelState.self, from: JSONEncoder().encode(state)
        ), state)
    }

    func testFuelReminderIdentitySurvivesRefreshWithoutSuppressingLaterStop() {
        let first = PlannedFuelStop(
            id: "fuel-1", candidate: nil, afterDistanceMetres: 80_000,
            routeProgress: 0.4, explanation: "Erster Stopp",
            installedRouteProgress: 0.4
        )
        let refreshedLater = PlannedFuelStop(
            id: "fuel-1", candidate: nil, afterDistanceMetres: 90_000,
            routeProgress: 0.5, explanation: "Späterer Stopp",
            installedRouteProgress: 0.75
        )
        XCTAssertNotEqual(
            NavigationFuelReminderPolicy.reminderID(for: first),
            NavigationFuelReminderPolicy.reminderID(for: refreshedLater)
        )

        let station = BreakCandidate(
            id: "provider-station", name: "Tankstelle", coordinate: .init(),
            progress: 0.4, installedRouteProgress: 0.4,
            detourMetres: 100, isOpen: true, supportsFuel: true
        )
        let shiftedSameStation = BreakCandidate(
            id: "provider-station", name: "Tankstelle", coordinate: .init(),
            progress: 0.42, installedRouteProgress: 0.42,
            detourMetres: 120, isOpen: true, supportsFuel: true
        )
        XCTAssertEqual(
            NavigationFuelReminderPolicy.reminderID(for: .init(
                id: "fuel-1", candidate: station, afterDistanceMetres: 80_000,
                routeProgress: 0.4, explanation: ""
            )),
            NavigationFuelReminderPolicy.reminderID(for: .init(
                id: "fuel-1", candidate: shiftedSameStation, afterDistanceMetres: 82_000,
                routeProgress: 0.42, explanation: ""
            ))
        )
    }

    func testBreakCandidateShortlistIsBoundedAndDistributed() {
        let candidates = (0..<18).map { index in
            BreakCandidate(id: "candidate-\(index)", name: "Halt \(index)", coordinate: .init(),
                           progress: Double(index) / 18, detourMetres: Double(1_000 - index),
                           isOpen: true, supportsFuel: index.isMultiple(of: 3))
        }

        let result = BreakCandidateSelectionPolicy.shortlist(candidates, maximum: 6)

        XCTAssertEqual(result.count, 6)
        XCTAssertEqual(result.map { Int($0.progress * 6) }, Array(0..<6))
        XCTAssertEqual(result.map(\.id), ["candidate-0", "candidate-3", "candidate-6",
                                           "candidate-9", "candidate-12", "candidate-15"])
    }

    func testBreakCandidateShortlistRedistributesAcrossRemainingJourney() {
        let candidates = (0..<6).map { index in
            let progress = 0.52 + Double(index) * 0.09
            return BreakCandidate(
                id: "remaining-\(index)", name: "Halt \(index)", coordinate: .init(),
                progress: progress, timeProgress: progress,
                detourMetres: 100, isOpen: true
            )
        }

        let wholeRouteBuckets = BreakCandidateSelectionPolicy.shortlist(candidates, maximum: 6)
        let remainingRouteBuckets = BreakCandidateSelectionPolicy.shortlist(
            candidates, maximum: 6,
            startingDistanceProgress: 0.5,
            startingTimeProgress: 0.5
        )

        XCTAssertLessThan(wholeRouteBuckets.count, candidates.count)
        XCTAssertEqual(remainingRouteBuckets.count, candidates.count,
                       "Useful stops must remain distributed after substantial trip progress")
        XCTAssertEqual(Set(remainingRouteBuckets.map(\.id)), Set(candidates.map(\.id)))
    }

    func testFuelStationsStayDistributedAcrossRemainingRoute() {
        XCTAssertEqual(FuelStationDistributionPolicy.bucket(
            progress: 0.70, currentProgress: 0.70, bucketCount: 12
        ), 0)
        XCTAssertEqual(FuelStationDistributionPolicy.bucket(
            progress: 0.85, currentProgress: 0.70, bucketCount: 12
        ), 6)
        XCTAssertEqual(FuelStationDistributionPolicy.bucket(
            progress: 0.99, currentProgress: 0.70, bucketCount: 12
        ), 11)
        XCTAssertNil(FuelStationDistributionPolicy.bucket(
            progress: 0.69, currentProgress: 0.70, bucketCount: 12
        ))
        XCTAssertNil(FuelStationDistributionPolicy.bucket(
            progress: 0.9, currentProgress: 0.7, bucketCount: 0
        ))
    }

    func testBreakCandidateShortlistPrefersUsefulOpenFuelStop() {
        let closed = BreakCandidate(id: "closed", name: "Closed", coordinate: .init(),
                                    progress: 0.4, detourMetres: 10, isOpen: false,
                                    supportsFuel: true)
        let rest = BreakCandidate(id: "rest", name: "Rest", coordinate: .init(),
                                  progress: 0.42, detourMetres: 100, isOpen: true)
        let fuel = BreakCandidate(id: "fuel", name: "Fuel", coordinate: .init(),
                                  progress: 0.44, detourMetres: 400,
                                  detourIsEstimated: false, isOpen: true, supportsFuel: true)

        let result = BreakCandidateSelectionPolicy.shortlist([closed, rest, fuel], maximum: 1)

        XCTAssertEqual(result.map(\.id), ["fuel"])
        XCTAssertFalse(result[0].detourIsEstimated)
    }

    func testFuelStationSelectionIsStableAcrossOpeningPriceAndRouteDistance() {
        func station(_ id: String, open: Bool?, price: Double) -> FuelStation {
            FuelStation(id: id, name: id, brand: id, street: "", place: "",
                        lat: 50, lon: 8, price: price, open: open, distanceKm: 1)
        }
        let open = station("open", open: true, price: 1.90)
        let unknown = station("unknown", open: nil, price: 1.70)
        let closed = station("closed", open: false, price: 1.60)
        XCTAssertTrue(FuelStationSelectionPolicy.isPreferred(
            open, corridorDistance: 900, over: unknown, corridorDistance: 100
        ))
        XCTAssertTrue(FuelStationSelectionPolicy.isPreferred(
            unknown, corridorDistance: 900, over: closed, corridorDistance: 100
        ))

        let near = station("near", open: true, price: 1.80)
        let far = station("far", open: true, price: 1.80)
        XCTAssertTrue(FuelStationSelectionPolicy.isPreferred(
            near, corridorDistance: 100, over: far, corridorDistance: 900
        ))
        XCTAssertFalse(FuelStationSelectionPolicy.isPreferred(
            far, corridorDistance: 900, over: near, corridorDistance: 100
        ))
    }

    func testFuelStationQueriesScaleWithRemainingDistanceButStayBounded() {
        XCTAssertEqual(FuelStationQueryPolicy.sampleCount(remainingDistanceMetres: 20_000), 2)
        XCTAssertEqual(FuelStationQueryPolicy.sampleCount(remainingDistanceMetres: 400_000), 2)
        XCTAssertEqual(FuelStationQueryPolicy.sampleCount(remainingDistanceMetres: 600_000), 3)
        XCTAssertEqual(FuelStationQueryPolicy.sampleCount(remainingDistanceMetres: 2_000_000), 6)
        XCTAssertEqual(FuelStationQueryPolicy.sampleCount(remainingDistanceMetres: .infinity), 2)
        XCTAssertEqual(FuelStationQueryPolicy.maximumSampleCount, 6)
        XCTAssertEqual(FuelStationQueryPolicy.maximumResultsPerSample, 24)
        XCTAssertEqual(FuelStationQueryPolicy.requestTimeout, 8)
        XCTAssertEqual(SpeedLimitQueryPolicy.requestTimeout, 10)
    }

    func testFuelPlannerContinuesAfterMandatoryDepartureRefuel() {
        let vehicle = VehicleProfile(
            baseConsumptionLPer100km: 10,
            fuelPricePerLitre: 1.8,
            tankCapacityLitres: 50,
            usableTankFraction: 0.8,
            initialFuelFraction: 0.1
        )

        let stops = FuelStopPlanner().plan(
            distanceMetres: 900_000,
            consumptionLPer100km: 10,
            vehicle: vehicle,
            candidates: []
        )

        XCTAssertGreaterThan(stops.count, 1, "The remainder must still be planned after refuelling at departure")
        XCTAssertEqual(stops.first?.afterDistanceMetres, 0)
        XCTAssertEqual(stops.first?.routeProgress, 0)
        XCTAssertTrue(stops.first?.explanation.contains("vor Abfahrt tanken") == true)
        XCTAssertTrue(stops.dropFirst().allSatisfy { $0.afterDistanceMetres > 0 })
    }

    func testTollLookupCacheOnlyReusesSameNearbyTrip() {
        let loadedAt = Date(timeIntervalSince1970: 10_000)
        let snapshot = TollLookupSnapshot(
            routeIdentity: "hochheim|wurzenpass", origin: .init(latitude: 50, longitude: 8),
            cost: .known(amount: 27.4, currency: "EUR", source: "Provider", sourceURL: nil), loadedAt: loadedAt
        )
        XCTAssertEqual(TollLookupCachePolicy.reusable(
            snapshot, routeIdentity: "hochheim|wurzenpass",
            origin: .init(latitude: 50.02, longitude: 8), now: loadedAt.addingTimeInterval(300)
        ), snapshot.cost)
        XCTAssertNil(TollLookupCachePolicy.reusable(
            snapshot, routeIdentity: "hochheim|anderer-pass",
            origin: .init(latitude: 50.02, longitude: 8), now: loadedAt.addingTimeInterval(300)
        ))
        XCTAssertNil(TollLookupCachePolicy.reusable(
            snapshot, routeIdentity: "hochheim|wurzenpass",
            origin: .init(latitude: 50.2, longitude: 8), now: loadedAt.addingTimeInterval(300)
        ))
        XCTAssertNil(TollLookupCachePolicy.reusable(
            snapshot, routeIdentity: "hochheim|wurzenpass",
            origin: .init(latitude: 50.02, longitude: 8), now: loadedAt.addingTimeInterval(1_000)
        ))

        let unknown = TollLookupSnapshot(
            routeIdentity: "hochheim|wurzenpass", origin: .init(latitude: 50, longitude: 8),
            cost: .unknown(reason: "Provider nicht erreichbar"), loadedAt: loadedAt
        )
        XCTAssertNotNil(TollLookupCachePolicy.reusable(
            unknown, routeIdentity: "hochheim|wurzenpass",
            origin: .init(latitude: 50, longitude: 8), now: loadedAt.addingTimeInterval(119)
        ))
        XCTAssertNil(TollLookupCachePolicy.reusable(
            unknown, routeIdentity: "hochheim|wurzenpass",
            origin: .init(latitude: 50, longitude: 8), now: loadedAt.addingTimeInterval(121)
        ))
    }

    func testTollLookupHasBoundedTransportDeadline() {
        XCTAssertEqual(TollLookupRequestPolicy.timeout, 20)
    }

    func testTollRouteIdentityChangesForMaterialRerouteToSameDestination() {
        let destination = CLLocationCoordinate2D(latitude: 50.01, longitude: 8.35)
        let direct = TollRouteIdentityPolicy.identity(
            destination: destination,
            via: [.init(latitude: 48.0, longitude: 11.0)],
            distanceMetres: 500_000,
            routeAnchors: [
                .init(latitude: 48, longitude: 11),
                .init(latitude: 49, longitude: 9),
                destination,
            ]
        )
        let diverted = TollRouteIdentityPolicy.identity(
            destination: destination,
            via: [.init(latitude: 48.0, longitude: 11.0)],
            distanceMetres: 535_000,
            routeAnchors: [
                .init(latitude: 48, longitude: 11),
                .init(latitude: 49, longitude: 10),
                destination,
            ]
        )

        XCTAssertNotEqual(direct, diverted)
    }

    func testTollRouteIdentityIgnoresMetreLevelGeometryNoise() {
        let destination = CLLocationCoordinate2D(latitude: 50.01, longitude: 8.35)
        let first = TollRouteIdentityPolicy.identity(
            destination: destination, via: [], distanceMetres: 500_020,
            routeAnchors: [.init(latitude: 49.0001, longitude: 9.0001), destination]
        )
        let noisy = TollRouteIdentityPolicy.identity(
            destination: .init(latitude: 50.0101, longitude: 8.3501),
            via: [], distanceMetres: 500_080,
            routeAnchors: [.init(latitude: 49.0002, longitude: 9.0002),
                           .init(latitude: 50.0101, longitude: 8.3501)]
        )

        XCTAssertEqual(first, noisy)
    }

    func testTollVariantsBindToTheirActualRouteGeometry() {
        XCTAssertFalse(TollVariantRoutePolicy.usesComparisonRoute(
            requestAvoidsTolls: false, mainRouteAvoidsTolls: false,
            comparisonAvailable: true
        ))
        XCTAssertTrue(TollVariantRoutePolicy.usesComparisonRoute(
            requestAvoidsTolls: true, mainRouteAvoidsTolls: false,
            comparisonAvailable: true
        ))
        XCTAssertTrue(TollVariantRoutePolicy.usesComparisonRoute(
            requestAvoidsTolls: false, mainRouteAvoidsTolls: true,
            comparisonAvailable: true
        ))
        XCTAssertFalse(TollVariantRoutePolicy.usesComparisonRoute(
            requestAvoidsTolls: true, mainRouteAvoidsTolls: true,
            comparisonAvailable: false
        ))
    }

    func testTollLookupPrefersLockedDestinationOverBadPlacemarkMetadata() {
        XCTAssertEqual(TollDestinationLabelPolicy.label(
            lockedDestinationName: "Hochheim am Main",
            mapItemName: "Hochheim am Main",
            enteredText: "Hochheim am Main",
            placemarkTitle: "Schweiz"
        ), "Hochheim am Main")
        XCTAssertEqual(TollDestinationLabelPolicy.label(
            lockedDestinationName: nil,
            mapItemName: nil,
            enteredText: "Split, Kroatien",
            placemarkTitle: "Unbekannter Ort"
        ), "Split, Kroatien")
    }

    func testTollComparisonPublishesOnlyCompleteVariantPair() {
        let standard = TollLookupBatchItem(
            avoidTolls: false, routeIdentity: "route|standard",
            cost: .known(amount: 24, currency: "EUR", source: "Provider", sourceURL: nil), fetched: true
        )
        let avoiding = TollLookupBatchItem(
            avoidTolls: true, routeIdentity: "route|avoid",
            cost: .unknown(reason: "Noch nicht eindeutig"), fetched: true
        )

        XCTAssertFalse(TollLookupBatchPolicy.complete([standard]))
        XCTAssertFalse(TollLookupBatchPolicy.complete([standard, standard]))
        XCTAssertTrue(TollLookupBatchPolicy.complete([avoiding, standard]))
        XCTAssertEqual(TollLookupBatchPolicy.requestedVariants(
            mainRouteAvoidsTolls: false, comparisonAvailable: false
        ), Set([false]))
        XCTAssertEqual(TollLookupBatchPolicy.requestedVariants(
            mainRouteAvoidsTolls: true, comparisonAvailable: false
        ), Set([true]))
        XCTAssertEqual(TollLookupBatchPolicy.requestedVariants(
            mainRouteAvoidsTolls: true, comparisonAvailable: true
        ), Set([false, true]))
        XCTAssertTrue(TollLookupBatchPolicy.complete([standard], expected: [false]))
        XCTAssertTrue(TollLookupBatchPolicy.complete([avoiding], expected: [true]))
    }

    func testSupersededTollLookupNeverStartsProviderRequests() {
        let route = UUID()
        let request = UUID()
        XCTAssertTrue(TollLookupBatchPolicy.mayStartRequests(
            route: route, currentRoute: route,
            request: request, currentRequest: request
        ))
        XCTAssertFalse(TollLookupBatchPolicy.mayStartRequests(
            route: route, currentRoute: UUID(),
            request: request, currentRequest: request
        ))
        XCTAssertFalse(TollLookupBatchPolicy.mayStartRequests(
            route: route, currentRoute: route,
            request: request, currentRequest: UUID()
        ))
    }

    func testRouteProjectionMeasuresBetweenSparseGeometryPoints() throws {
        let route = [
            CLLocationCoordinate2D(latitude: 50.0, longitude: 8.0),
            CLLocationCoordinate2D(latitude: 50.0, longitude: 8.2)
        ]
        let projection = try XCTUnwrap(RouteGeometryProgress.nearestProgress(
            of: .init(latitude: 50.01, longitude: 8.1), on: route
        ))
        XCTAssertEqual(projection.progress, 0.5, accuracy: 0.02)
        XCTAssertLessThan(projection.distance, 1_200)
    }

    func testRouteProjectionRangeDisambiguatesRepeatedCrossing() throws {
        let route = [
            CLLocationCoordinate2D(latitude: 50.0, longitude: 8.0),
            CLLocationCoordinate2D(latitude: 50.0, longitude: 8.1),
            CLLocationCoordinate2D(latitude: 50.1, longitude: 8.1),
            CLLocationCoordinate2D(latitude: 50.0, longitude: 8.1),
            CLLocationCoordinate2D(latitude: 50.0, longitude: 8.2)
        ]
        let coordinate = CLLocationCoordinate2D(latitude: 50.0, longitude: 8.1)

        let early = try XCTUnwrap(RouteGeometryProgress.nearestProgress(
            of: coordinate, on: route, progressRange: 0...0.4
        ))
        let late = try XCTUnwrap(RouteGeometryProgress.nearestProgress(
            of: coordinate, on: route, progressRange: 0.6...1
        ))

        XCTAssertLessThan(early.progress, 0.4)
        XCTAssertGreaterThan(late.progress, 0.6)
        XCTAssertLessThan(early.distance, 1)
        XCTAssertLessThan(late.distance, 1)
    }

    func testHigherTargetSpeedOnlyChangesUnlimitedShareAndUsesMoreFuel() {
        let route = RoutePlanningInput(
            id: "holiday", title: "Route", distanceMetres: 600_000,
            mapKitExpectedTravelTime: 6 * 3600, unlimitedMotorwayFraction: 0.5,
            typicalUnlimitedSpeedKmh: 130, toll: .unknown(reason: "test"), breakCandidates: []
        )
        let plan = RouteComparison(fuelModel: .init(), breakPlanner: .init())
            .compare(routes: [route], scenarios: [.target(150), .target(200)], vehicle: .init())

        XCTAssertEqual(plan.results.count, 2)
        XCTAssertLessThan(plan.results[1].drivingTime, plan.results[0].drivingTime)
        XCTAssertGreaterThan(plan.results[1].fuel.litres, plan.results[0].fuel.litres)
        XCTAssertGreaterThan(plan.results[1].drivingTime, 3 * 3600, "Limited/traffic time must be preserved")
        XCTAssertGreaterThan(plan.results[1].fuel.averageConsumptionLPer100km,
                             plan.results[0].fuel.averageConsumptionLPer100km)
    }

    func testUnlimitedShareUsesDistanceAndTreatsMissingLimitsConservatively() {
        let points = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.01),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.11)
        ]
        let limits = [
            SpeedLimitResult(maxspeed: nil, unlimited: true),
            SpeedLimitResult(maxspeed: nil, unlimited: false)
        ]
        let fraction = SpeedScenarioPolicy.unlimitedDistanceFraction(points: points, limits: limits)
        XCTAssertEqual(fraction, 1.0 / 11.0, accuracy: 0.02)

        let missing = SpeedScenarioPolicy.unlimitedDistanceFraction(points: points, limits: [limits[0]])
        XCTAssertEqual(missing, 1.0 / 11.0, accuracy: 0.02,
                       "A missing second limit must not make the long segment unrestricted")
    }

    func testUnlimitedShareRejectsConflictingProviderEvidence() {
        let points = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.01),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.02),
        ]
        let limits = [
            SpeedLimitResult(maxspeed: 120, unlimited: true),
            SpeedLimitResult(maxspeed: nil, unlimited: true),
        ]

        XCTAssertEqual(
            SpeedScenarioPolicy.unlimitedDistanceFraction(points: points, limits: limits),
            0.5,
            accuracy: 0.02,
            "A contradictory numeric limit must not be treated as unrestricted"
        )
    }

    func testUnlimitedShareExcludesAlreadyDrivenFastSections() {
        let points = [
            CLLocationCoordinate2D(latitude: 50.00, longitude: 8),
            CLLocationCoordinate2D(latitude: 50.01, longitude: 8),
            CLLocationCoordinate2D(latitude: 50.02, longitude: 8),
        ]
        let limits = [
            SpeedLimitResult(maxspeed: nil, unlimited: true),
            SpeedLimitResult(maxspeed: 100, unlimited: false),
        ]
        XCTAssertEqual(SpeedScenarioPolicy.unlimitedDistanceFraction(
            points: points, limits: limits, fromProgress: 0.5
        ), 0, accuracy: 0.001)
        XCTAssertEqual(SpeedScenarioPolicy.unlimitedDistanceFraction(
            points: points, limits: limits, fromProgress: 0.25
        ), 1.0 / 3.0, accuracy: 0.02)
        XCTAssertEqual(SpeedScenarioPolicy.unlimitedDistanceFraction(
            points: points, limits: limits, fromProgress: 1
        ), 0, accuracy: 0.001)
    }

    func testSpeedScenarioAppliesDistanceShareInsteadOfTimeShare() {
        let route = RoutePlanningInput(
            id: "distance-share", title: "Route", distanceMetres: 600_000,
            mapKitExpectedTravelTime: 6 * 3600, unlimitedMotorwayFraction: 0.5,
            typicalUnlimitedSpeedKmh: 130, toll: .unknown(reason: "test"), breakCandidates: []
        )
        let result = RouteComparison(fuelModel: .init(), breakPlanner: .init())
            .compare(routes: [route], scenarios: [.target(200)], vehicle: .init()).results[0]
        let freeFlow = 300_000 / (100 / 3.6) + 300_000 / (130 / 3.6)
        let trafficFactor = 6 * 3600 / freeFlow
        let baselineUnlimited = 300_000 / (130 / 3.6) * trafficFactor
        let limited = 6 * 3600 - baselineUnlimited
        let attainableTarget = 130 + (200 - 130) / (trafficFactor * trafficFactor)
        let congestionDelay = baselineUnlimited - 300_000 / (130 / 3.6)
        let expected = limited + 300_000 / (attainableTarget / 3.6) + congestionDelay
        XCTAssertEqual(result.drivingTime, expected, accuracy: 1)
    }

    func testSpeedScenarioAlwaysReservesRealisticTimeForLimitedRoads() {
        let timing = SpeedScenarioPolicy.timing(
            distanceMetres: 600_000,
            mapKitExpectedTravelTime: 4 * 3600,
            unlimitedFraction: 0.9,
            typicalUnlimitedSpeedKmh: 130,
            targetSpeedKmh: 200
        )
        let minimumLimitedTime = 60_000 / (130 / 3.6)
        XCTAssertGreaterThanOrEqual(timing.limitedTime, minimumLimitedTime)
        XCTAssertGreaterThan(timing.totalTime, timing.adjustedUnlimitedTime)
    }

    func testSpeedScenarioPreservesTrafficTimeOnLimitedShare() {
        let timing = SpeedScenarioPolicy.timing(
            distanceMetres: 600_000,
            mapKitExpectedTravelTime: 8 * 3600,
            unlimitedFraction: 0.5,
            typicalUnlimitedSpeedKmh: 130,
            targetSpeedKmh: 200
        )
        let freeFlow = 300_000 / (100 / 3.6) + 300_000 / (130 / 3.6)
        let trafficFactor = 8 * 3600 / freeFlow
        let baselineUnlimitedTime = 300_000 / (130 / 3.6) * trafficFactor
        XCTAssertEqual(timing.limitedTime, 8 * 3600 - baselineUnlimitedTime, accuracy: 1)
        XCTAssertGreaterThan(timing.trafficFactor, 1)
        XCTAssertGreaterThan(
            timing.adjustedUnlimitedTime,
            300_000 / (200 / 3.6),
            "Traffic must also constrain the nominally unrestricted section"
        )
    }

    func testSpeedScenarioComparisonUsesSameRouteAndToleratesDecodedSpeedNoise() {
        let routeA = RoutePlanningInput(
            id: "a", title: "Schnellste Route", distanceMetres: 500_000,
            mapKitExpectedTravelTime: 18_000, unlimitedMotorwayFraction: 0.4,
            typicalUnlimitedSpeedKmh: 130, toll: .unknown(reason: "test"), breakCandidates: []
        )
        let routeB = RoutePlanningInput(
            id: "b", title: "Mautfreie Route", distanceMetres: 520_000,
            mapKitExpectedTravelTime: 19_000, unlimitedMotorwayFraction: 0.2,
            typicalUnlimitedSpeedKmh: 130, toll: .noToll(source: "test", sourceURL: nil), breakCandidates: []
        )
        let plan = RouteComparison(fuelModel: .init(), breakPlanner: .init()).compare(
            routes: [routeA, routeB],
            scenarios: [.target(150.000_01), .target(199.999_99)],
            vehicle: .init()
        )

        let comparison = SpeedScenarioComparisonPolicy.comparison(
            in: plan, configuredSpeed: 150, referenceSpeed: 200
        )

        XCTAssertEqual(comparison?.baseline.routeTitle, "Schnellste Route")
        XCTAssertEqual(comparison?.alternative.routeTitle, "Schnellste Route")
        XCTAssertEqual(comparison?.eligibleDistanceMetres ?? 0, 200_000, accuracy: 1)
    }

    func testConfiguredReferenceSpeedStillComparesAgainstSafeFallback() {
        let scenarios = SpeedScenarioPolicy.scenarios(configuredSpeed: 200.000_01)
        XCTAssertEqual(scenarios.map { Int($0.targetSpeedKmh.rounded()) }, [200, 150])

        let route = RoutePlanningInput(
            id: "route", title: "Route", distanceMetres: 400_000,
            mapKitExpectedTravelTime: 14_000, unlimitedMotorwayFraction: 0.4,
            typicalUnlimitedSpeedKmh: 130,
            toll: .unknown(reason: "test"), breakCandidates: []
        )
        let plan = RouteComparison(fuelModel: .init(), breakPlanner: .init()).compare(
            routes: [route], scenarios: scenarios, vehicle: .init()
        )
        let comparison = SpeedScenarioComparisonPolicy.comparison(
            in: plan, configuredSpeed: 200.000_01, referenceSpeed: 200
        )
        XCTAssertEqual(comparison?.baseline.scenario.targetSpeedKmh ?? 0, 200, accuracy: 0.1)
        XCTAssertEqual(comparison?.alternative.scenario.targetSpeedKmh ?? 0, 150, accuracy: 0.1)
    }

    func testScenarioMatchingSanitizesConfiguredAndDecodedSpeedValues() {
        XCTAssertTrue(SpeedScenarioPolicy.matchesTarget(
            scenarioSpeed: 199.999_99, configuredSpeed: 200
        ))
        XCTAssertTrue(SpeedScenarioPolicy.matchesTarget(
            scenarioSpeed: 220, configuredSpeed: 500
        ))
        XCTAssertTrue(SpeedScenarioPolicy.matchesTarget(
            scenarioSpeed: 150, configuredSpeed: .nan
        ))
        XCTAssertFalse(SpeedScenarioPolicy.matchesTarget(
            scenarioSpeed: .infinity, configuredSpeed: 150
        ))
    }

    func testBreakPlannerPrefersOpenLowDetourStopNearWindow() {
        let candidates = [
            BreakCandidate(id: "closed", name: "Closed", coordinate: .init(latitude: 0, longitude: 0), progress: 0.34, detourMetres: 50, isOpen: false),
            BreakCandidate(id: "far", name: "Far", coordinate: .init(latitude: 0, longitude: 0), progress: 0.34, detourMetres: 8_000, isOpen: true),
            BreakCandidate(id: "best", name: "Best", coordinate: .init(latitude: 0, longitude: 0), progress: 0.38, detourMetres: 300, isOpen: true),
        ]
        let breaks = BreakPlanner().plan(drivingTime: 5 * 3600, candidates: candidates)

        XCTAssertEqual(breaks.count, 2)
        XCTAssertEqual(breaks.first?.candidate?.id, "best")
        XCTAssertNil(breaks.last?.candidate, "A later pause must never point backwards along the route")
        XCTAssertEqual(Set(breaks.compactMap { $0.candidate?.id }).count, 1, "A stop must not be suggested twice")
    }

    func testOpeningStatusIsUsedOnlyForNearTermArrival() {
        XCTAssertFalse(PlannedStopOpeningStatusPolicy.mayUse(
            isOpen: false, secondsUntilArrival: 20 * 60
        ))
        XCTAssertTrue(PlannedStopOpeningStatusPolicy.mayUse(
            isOpen: false, secondsUntilArrival: 3 * 3600
        ))
        XCTAssertFalse(PlannedStopOpeningStatusPolicy.mayUse(
            isOpen: false, secondsUntilArrival: nil
        ))
        XCTAssertTrue(PlannedStopOpeningStatusPolicy.mayUse(
            isOpen: nil, secondsUntilArrival: 5 * 60
        ))
        XCTAssertTrue(PlannedStopOpeningStatusPolicy.mayUse(
            isOpen: true, secondsUntilArrival: 5 * 60
        ))
    }

    func testBreakPlannerCanUseCurrentlyClosedStopHoursAhead() {
        let candidate = BreakCandidate(
            id: "later", name: "Raststätte später", coordinate: .init(),
            progress: 0.4, detourMetres: 100, isOpen: false
        )
        let planned = BreakPlanner().plan(
            drivingTime: 5 * 3600, candidates: [candidate]
        )

        XCTAssertEqual(planned.first?.candidate?.id, "later")
        XCTAssertTrue(planned.first?.explanation.contains("Öffnungsstatus") == true)
    }

    func testRouteTravelTimeProgressAccountsForSlowLegs() {
        let segments: [(distance: Double, travelTime: TimeInterval)] = [
            (100_000, 3 * 3600),
            (100_000, 1 * 3600),
        ]

        XCTAssertEqual(RouteTravelTimeProgress.value(
            distanceProgress: 0.5, segments: segments
        ), 0.75, accuracy: 0.001)
        XCTAssertEqual(RouteTravelTimeProgress.value(
            distanceProgress: 0.75, segments: segments
        ), 0.875, accuracy: 0.001)
        XCTAssertEqual(RouteTravelTimeProgress.distanceProgress(
            timeProgress: 0.75, segments: segments
        ), 0.5, accuracy: 0.001)
        XCTAssertEqual(RouteTravelTimeProgress.distanceProgress(
            timeProgress: 0.875, segments: segments
        ), 0.75, accuracy: 0.001)
    }

    func testBreakAmenitySearchTargetsDrivingTimeWindows() {
        let segments: [(distance: Double, travelTime: TimeInterval)] = [
            (100_000, 3 * 3600),
            (300_000, 3 * 3600),
        ]

        let progresses = BreakAmenitySearchPolicy.distanceProgresses(
            drivingTime: 6 * 3600,
            alreadyDrivenSinceBreak: 0,
            segments: segments,
            maximum: 4
        )

        XCTAssertEqual(progresses.count, 2)
        XCTAssertEqual(progresses[0], 1.0 / 6.0, accuracy: 0.001)
        XCTAssertEqual(progresses[1], 0.5, accuracy: 0.001)
    }

    func testBreakAmenitySearchAccountsForTimeAlreadyDrivenAndStaysBounded() {
        let segments: [(distance: Double, travelTime: TimeInterval)] = [(1_200_000, 12 * 3600)]
        let progresses = BreakAmenitySearchPolicy.distanceProgresses(
            drivingTime: 12 * 3600,
            alreadyDrivenSinceBreak: 90 * 60,
            segments: segments,
            maximum: 4
        )

        XCTAssertEqual(progresses.count, 4)
        XCTAssertEqual(progresses[0], 0.5 / 12, accuracy: 0.001)
        XCTAssertEqual(progresses[1], 2.5 / 12, accuracy: 0.001)
        XCTAssertTrue(progresses.allSatisfy { $0 >= 0 && $0 < 1 })
        XCTAssertTrue(BreakAmenitySearchPolicy.distanceProgresses(
            drivingTime: 90 * 60, alreadyDrivenSinceBreak: 0,
            segments: [(150_000, 90 * 60)], maximum: 4
        ).isEmpty)
    }

    func testBreakAmenitySearchNeverQueriesPassedRouteAfterProgress() {
        let segments: [(distance: Double, travelTime: TimeInterval)] = [
            (1_200_000, 12 * 3600)
        ]
        let progresses = BreakAmenitySearchPolicy.distanceProgresses(
            drivingTime: 12 * 3600,
            alreadyDrivenSinceBreak: 0,
            segments: segments,
            maximum: 4,
            startingTimeProgress: 0.5
        )

        XCTAssertEqual(progresses.count, 2)
        XCTAssertEqual(progresses[0], 2.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(progresses[1], 5.0 / 6.0, accuracy: 0.001)
        XCTAssertTrue(progresses.allSatisfy { $0 > 0.5 })
    }

    func testRouteGeometryInterpolatesCoordinateAtProgress() throws {
        let route = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50, longitude: 9),
        ]
        let midpoint = try XCTUnwrap(RouteGeometryProgress.coordinate(at: 0.5, on: route))
        XCTAssertEqual(midpoint.latitude, 50, accuracy: 0.0001)
        XCTAssertEqual(midpoint.longitude, 8.5, accuracy: 0.0001)
    }

    func testBreakPlannerChoosesByExpectedDrivingTimeNotDistanceShare() {
        let candidates = [
            BreakCandidate(
                id: "geometrically-near", name: "Zu spät", coordinate: .init(),
                progress: 0.4, timeProgress: 0.7,
                detourMetres: 50, isOpen: true
            ),
            BreakCandidate(
                id: "time-near", name: "Zeitlich passend", coordinate: .init(),
                progress: 0.6, timeProgress: 0.4,
                detourMetres: 200, isOpen: true
            ),
        ]

        let breaks = BreakPlanner().plan(drivingTime: 5 * 3600, candidates: candidates)

        XCTAssertEqual(breaks.first?.candidate?.id, "time-near")
        XCTAssertEqual(breaks.first?.afterDriving ?? 0, 2 * 3600, accuracy: 1)
        XCTAssertEqual(breaks.first?.routeProgress ?? 0, 0.6, accuracy: 0.001)
    }

    func testBreaksFollowTwoHourDrivingIntervals() {
        let candidates = [
            BreakCandidate(id: "two-hours", name: "First", coordinate: .init(), progress: 0.4, detourMetres: 100, isOpen: true),
            BreakCandidate(id: "four-hours", name: "Second", coordinate: .init(), progress: 0.8, detourMetres: 100, isOpen: true),
        ]
        let breaks = BreakPlanner().plan(drivingTime: 5 * 3600, candidates: candidates)
        XCTAssertEqual(breaks[0].afterDriving, 2 * 3600, accuracy: 1)
        XCTAssertEqual(breaks[1].afterDriving, 4 * 3600, accuracy: 1)
    }

    func testBreakPlannerAccountsForDrivingBeforeRestoredRoute() {
        let breaks = BreakPlanner().plan(
            drivingTime: 5 * 3600, candidates: [],
            alreadyDrivenSinceBreak: 90 * 60
        )

        XCTAssertEqual(breaks.map(\.afterDriving), [30 * 60, 150 * 60, 270 * 60])
    }

    func testRemainingStopProjectionCannotSnapToCompletedRouteLoop() throws {
        let range = try XCTUnwrap(RemainingRoutePlanningPolicy.projectionRange(
            distanceProgress: 0.60,
            totalDistance: 400_000
        ))

        XCTAssertGreaterThan(range.lowerBound, 0.599)
        XCTAssertFalse(range.contains(0.20))
        XCTAssertTrue(range.contains(0.80))
        XCTAssertNil(RemainingRoutePlanningPolicy.projectionRange(
            distanceProgress: 0.5,
            totalDistance: 0
        ))
    }

    func testBreakPlannerRequestsImmediateBreakAtContinuousDrivingLimit() {
        let breaks = BreakPlanner().plan(
            drivingTime: 60 * 60, candidates: [],
            alreadyDrivenSinceBreak: 2 * 60 * 60
        )

        XCTAssertEqual(breaks.count, 1)
        XCTAssertEqual(breaks[0].afterDriving, 0, accuracy: 1)
        XCTAssertEqual(breaks[0].routeProgress, 0, accuracy: 0.001)
    }

    func testLongTripPlanRefreshesImmediatelyAfterPassingConcreteStop() {
        let candidate = BreakCandidate(
            id: "rest-a", name: "Raststätte", coordinate: .init(),
            progress: 0.4, installedRouteProgress: 0.64,
            detourMetres: 200, isOpen: true
        )
        let result = RouteScenarioResult(
            id: "route-150", routeTitle: "Route",
            scenario: .target(150), distanceMetres: 300_000,
            drivingTime: 10_000, totalTime: 11_200,
            fuel: .init(litres: 20, cost: 36, averageConsumptionLPer100km: 6.7),
            toll: .unknown(reason: "Test"),
            breaks: [.init(
                id: "break-1", candidate: candidate, afterDriving: 3_000,
                duration: 1_200, routeProgress: 0.4, explanation: "Test"
            )], fuelStops: [], unlimitedFraction: 0.5,
            plannedStopDetourMetres: 200, additionalFuelStopTime: 0
        )

        XCTAssertFalse(LongTripPlanRefreshPolicy.hasPassedConcreteStop(
            result, currentInstalledProgress: 0.63
        ))
        XCTAssertTrue(LongTripPlanRefreshPolicy.hasPassedConcreteStop(
            result, currentInstalledProgress: 0.65
        ))
    }

    func testUnverifiedImmediateBreakDoesNotCauseContinuousReplanning() {
        let result = RouteScenarioResult(
            id: "route-150", routeTitle: "Route",
            scenario: .target(150), distanceMetres: 100_000,
            drivingTime: 3_600, totalTime: 4_800,
            fuel: .init(litres: 8, cost: 14, averageConsumptionLPer100km: 8),
            toll: .unknown(reason: "Test"),
            breaks: [.init(
                id: "break-1", candidate: nil, afterDriving: 0,
                duration: 1_200, routeProgress: 0, explanation: "Jetzt pausieren",
                installedRouteProgress: 0.7
            )], fuelStops: [], unlimitedFraction: 0,
            plannedStopDetourMetres: 0, additionalFuelStopTime: 0
        )

        XCTAssertFalse(LongTripPlanRefreshPolicy.hasPassedConcreteStop(
            result, currentInstalledProgress: 0.8
        ))
    }

    func testDrivingRestPolicyCountsMovementAndResetsAfterRealPause() {
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 10_000)
        var state = DrivingRestPolicy.updated(
            .init(), tripID: tripID, at: start, speedMetresPerSecond: 20
        )
        state = DrivingRestPolicy.updated(
            state, tripID: tripID, at: start.addingTimeInterval(60),
            speedMetresPerSecond: 20
        )
        XCTAssertEqual(state.continuousDriving, 60, accuracy: 0.001)

        state = DrivingRestPolicy.updated(
            state, tripID: tripID, at: start.addingTimeInterval(120),
            speedMetresPerSecond: 0
        )
        state = DrivingRestPolicy.updated(
            state, tripID: tripID, at: start.addingTimeInterval(1_321),
            speedMetresPerSecond: 0
        )
        XCTAssertEqual(state.continuousDriving, 0)
        XCTAssertNotNil(state.stationarySince)
    }

    func testConfirmedBreakResetsDrivingTimeAndReminderHistory() {
        let tripID = UUID()
        let date = Date(timeIntervalSince1970: 18_000)
        let existing = DrivingRestState(
            tripID: tripID,
            continuousDriving: 110 * 60,
            lastSampleAt: date.addingTimeInterval(-60),
            deliveredReminderRawValues: [
                NavigationBreakReminderPolicy.Stage.plan.rawValue,
                NavigationBreakReminderPolicy.Stage.soon.rawValue,
            ]
        )

        let state = DrivingRestPolicy.confirmedBreak(existing, tripID: tripID, at: date)

        XCTAssertEqual(state.continuousDriving, 0)
        XCTAssertEqual(state.lastSampleAt, date)
        XCTAssertEqual(state.stationarySince, date)
        XCTAssertTrue(state.deliveredReminderRawValues.isEmpty)
    }

    func testManualBreakConfirmationRequiresFreshStationaryFix() {
        let now = Date(timeIntervalSince1970: 19_000)
        XCTAssertTrue(DrivingRestConfirmationPolicy.mayConfirm(
            sampleAt: now.addingTimeInterval(-10),
            reliableSpeedMetresPerSecond: 0, now: now
        ))
        XCTAssertFalse(DrivingRestConfirmationPolicy.mayConfirm(
            sampleAt: now.addingTimeInterval(-10),
            reliableSpeedMetresPerSecond: 15, now: now
        ))
        XCTAssertFalse(DrivingRestConfirmationPolicy.mayConfirm(
            sampleAt: now.addingTimeInterval(-31),
            reliableSpeedMetresPerSecond: 0, now: now
        ))
        XCTAssertFalse(DrivingRestConfirmationPolicy.mayConfirm(
            sampleAt: nil, reliableSpeedMetresPerSecond: nil, now: now
        ))
    }

    func testDrivingRestPolicyDoesNotInventMovementAcrossLongUnknownGap() {
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 20_000)
        let existing = DrivingRestState(
            tripID: tripID, continuousDriving: 900,
            lastSampleAt: start, stationarySince: nil
        )

        let state = DrivingRestPolicy.updated(
            existing, tripID: tripID, at: start.addingTimeInterval(3_600),
            speedMetresPerSecond: 25
        )

        XCTAssertEqual(state.continuousDriving, 900)
    }

    func testDrivingRestPolicyRebasesAfterClockRollbackWithoutLosingFatigue() {
        let tripID = UUID()
        let futureSample = Date(timeIntervalSince1970: 10_100)
        let correctedTime = Date(timeIntervalSince1970: 10_000)
        let existing = DrivingRestState(
            tripID: tripID, continuousDriving: 90 * 60,
            lastSampleAt: futureSample, stationarySince: nil
        )

        var state = DrivingRestPolicy.updated(
            existing, tripID: tripID, at: correctedTime,
            speedMetresPerSecond: 20
        )
        XCTAssertEqual(state.continuousDriving, 90 * 60)
        XCTAssertEqual(state.lastSampleAt, correctedTime)
        XCTAssertNil(state.stationarySince)

        state = DrivingRestPolicy.updated(
            state, tripID: tripID, at: correctedTime.addingTimeInterval(60),
            speedMetresPerSecond: 20
        )
        XCTAssertEqual(state.continuousDriving, 91 * 60)
    }

    func testPausedNavigationCountsAsRestOnlyWhenVehicleWasObservedStationary() {
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 20_000)
        let existing = DrivingRestState(
            tripID: tripID, continuousDriving: 7_000,
            lastSampleAt: start, stationarySince: nil
        )
        let pause = start.addingTimeInterval(60)
        var state = DrivingRestPolicy.paused(
            existing, tripID: tripID, at: pause, speedMetresPerSecond: 0
        )
        XCTAssertEqual(state.stationarySince, pause)
        state = DrivingRestPolicy.updated(
            state, tripID: tripID, at: pause.addingTimeInterval(20 * 60),
            speedMetresPerSecond: 20
        )
        XCTAssertEqual(state.continuousDriving, 0)

        let movingPause = DrivingRestPolicy.paused(
            existing, tripID: tripID, at: pause, speedMetresPerSecond: 20
        )
        XCTAssertNil(movingPause.stationarySince)
        XCTAssertEqual(movingPause.continuousDriving, 7_000)
    }

    func testBreakReminderStagesOnlyWhenJourneyCrossesDrivingLimit() {
        XCTAssertNil(NavigationBreakReminderPolicy.stage(
            continuousDriving: 90 * 60, remainingTravelTime: 30 * 60, delivered: []
        ), "Arriving exactly at the limit must not create an unnecessary stop warning")
        XCTAssertEqual(NavigationBreakReminderPolicy.stage(
            continuousDriving: 90 * 60, remainingTravelTime: 31 * 60, delivered: []
        ), .plan)
        XCTAssertEqual(NavigationBreakReminderPolicy.stage(
            continuousDriving: 110 * 60, remainingTravelTime: 11 * 60, delivered: [.plan]
        ), .soon)
        XCTAssertEqual(NavigationBreakReminderPolicy.stage(
            continuousDriving: 120 * 60, remainingTravelTime: 60, delivered: [.plan, .soon]
        ), .due)
    }

    func testBreakReminderNeverRepeatsDeliveredStage() {
        XCTAssertNil(NavigationBreakReminderPolicy.stage(
            continuousDriving: 95 * 60, remainingTravelTime: 60 * 60, delivered: [.plan]
        ))
        XCTAssertEqual(NavigationBreakReminderPolicy.stage(
            continuousDriving: 111 * 60, remainingTravelTime: 60 * 60, delivered: [.plan]
        ), .soon)
    }

    func testBreakReminderSelectsOnlyAPlannedStopAheadOfVehicle() {
        func planned(_ name: String, progress: Double) -> PlannedBreak {
            let candidate = BreakCandidate(
                id: name, name: name,
                coordinate: .init(latitude: 50, longitude: 8),
                progress: progress, detourMetres: 100, isOpen: true
            )
            return PlannedBreak(
                id: name, candidate: candidate, afterDriving: 0,
                duration: 900, routeProgress: progress, explanation: "Pause"
            )
        }
        let breaks = [planned("Schon vorbei", progress: 0.3),
                      planned("Nächster Rastplatz", progress: 0.62),
                      planned("Später", progress: 0.8)]

        XCTAssertEqual(NavigationBreakReminderPolicy.nextPlannedStopName(
            breaks: breaks, currentRouteProgress: 0.5
        ), "Nächster Rastplatz")
        XCTAssertNil(NavigationBreakReminderPolicy.nextPlannedStopName(
            breaks: breaks, currentRouteProgress: 0.9
        ))
        XCTAssertNil(NavigationBreakReminderPolicy.nextPlannedStopName(
            breaks: breaks, currentRouteProgress: .nan
        ))
    }

    func testBreakReminderUsesInstalledProgressForRebasedRemainingRoute() {
        let candidate = BreakCandidate(
            id: "ahead", name: "Raststätte voraus", coordinate: .init(),
            progress: 0.25, installedRouteProgress: 0.8,
            detourMetres: 100, isOpen: true
        )
        let planned = PlannedBreak(
            id: "break", candidate: candidate, afterDriving: 1_800,
            duration: 900, routeProgress: 0.25, explanation: "Pause"
        )

        XCTAssertEqual(NavigationBreakReminderPolicy.nextPlannedStopName(
            breaks: [planned], currentRouteProgress: 0.7
        ), "Raststätte voraus")
        XCTAssertNil(NavigationBreakReminderPolicy.nextPlannedStopName(
            breaks: [planned], currentRouteProgress: 0.85
        ))
    }

    func testDrivingRestPolicyDoesNotTreatUnknownGapAsObservedBreak() {
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 25_000)
        let existing = DrivingRestState(
            tripID: tripID, continuousDriving: 7_000,
            lastSampleAt: start, stationarySince: nil
        )
        let firstObservedStop = start.addingTimeInterval(3_600)

        var state = DrivingRestPolicy.updated(
            existing, tripID: tripID, at: firstObservedStop,
            speedMetresPerSecond: 0
        )
        XCTAssertEqual(state.continuousDriving, 7_000)
        XCTAssertEqual(state.stationarySince, firstObservedStop)

        state = DrivingRestPolicy.updated(
            state, tripID: tripID,
            at: firstObservedStop.addingTimeInterval(20 * 60 - 1),
            speedMetresPerSecond: 0
        )
        XCTAssertEqual(state.continuousDriving, 7_000)

        state = DrivingRestPolicy.updated(
            state, tripID: tripID,
            at: firstObservedStop.addingTimeInterval(20 * 60),
            speedMetresPerSecond: 0
        )
        XCTAssertEqual(state.continuousDriving, 0)
    }

    func testDrivingRestPolicyCountsProlongedStopAndGoAsDriving() {
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 27_000)
        var state = DrivingRestState(
            tripID: tripID, continuousDriving: 90 * 60,
            lastSampleAt: start, stationarySince: nil
        )

        // Roughly 4.3 km/h: crawling traffic, not a restorative pause.
        for minute in 1...21 {
            state = DrivingRestPolicy.updated(
                state, tripID: tripID,
                at: start.addingTimeInterval(TimeInterval(minute * 60)),
                speedMetresPerSecond: 1.2
            )
        }

        XCTAssertNil(state.stationarySince)
        XCTAssertEqual(state.continuousDriving, 111 * 60, accuracy: 0.001)
    }

    func testDrivingRestPolicyCountsShortStationaryStopUntilMovementResumes() {
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 28_000)
        var state = DrivingRestState(
            tripID: tripID, continuousDriving: 90 * 60,
            lastSampleAt: start, stationarySince: nil
        )

        for minute in 1...10 {
            state = DrivingRestPolicy.updated(
                state, tripID: tripID,
                at: start.addingTimeInterval(TimeInterval(minute * 60)),
                speedMetresPerSecond: 0
            )
        }
        state = DrivingRestPolicy.updated(
            state, tripID: tripID, at: start.addingTimeInterval(11 * 60),
            speedMetresPerSecond: 15
        )

        XCTAssertNil(state.stationarySince)
        XCTAssertEqual(state.continuousDriving, 101 * 60, accuracy: 0.001,
                       "A ten-minute stop is not a qualifying fatigue break")
    }

    func testDrivingRestStateStorePersistsWithoutLocationData() throws {
        let suite = "KiesDriveTests.DrivingRest.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DrivingRestStateStore(defaults: defaults)
        let expected = DrivingRestState(
            tripID: UUID(), continuousDriving: 2_400,
            lastSampleAt: Date(timeIntervalSince1970: 30_000),
            stationarySince: nil
        )

        store.save(expected)
        XCTAssertEqual(store.load(), expected)
        store.clear()
        XCTAssertEqual(store.load(), DrivingRestState())
    }

    func testDrivingRestStateRestoresDeliveredReminderStagesAndLegacyData() throws {
        let suite = "KiesDriveTests.DrivingRest.Reminders.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DrivingRestStateStore(defaults: defaults)
        let expected = DrivingRestState(
            tripID: UUID(), continuousDriving: 7_200,
            deliveredReminderRawValues: [
                NavigationBreakReminderPolicy.Stage.plan.rawValue,
                NavigationBreakReminderPolicy.Stage.soon.rawValue
            ]
        )
        store.save(expected)
        XCTAssertEqual(store.load(), expected)

        let legacy = "{\"continuousDriving\":5400}".data(using: .utf8)
        defaults.set(legacy, forKey: store.key)
        XCTAssertEqual(store.load().continuousDriving, 5_400)
        XCTAssertEqual(store.load().deliveredReminderRawValues, [])
    }

    func testDrivingFuelPolicyTracksDistanceAfterConfirmedTankLevel() {
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 40_000)
        let first = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                               horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: start)
        let second = CLLocation(coordinate: .init(latitude: 50.009, longitude: 8), altitude: 0,
                                horizontalAccuracy: 5, verticalAccuracy: 5,
                                timestamp: start.addingTimeInterval(60))
        var state = DrivingFuelPolicy.confirmed(.init(), tripID: tripID,
                                                fraction: 1, location: first)
        state = DrivingFuelPolicy.updated(state, tripID: tripID,
                                          initialFuelFraction: 0.5, location: second)

        XCTAssertGreaterThan(state.distanceSinceObservationMetres, 900)
        XCTAssertLessThan(DrivingFuelPolicy.estimatedFraction(
            state, tripID: tripID, tankCapacityLitres: 50,
            consumptionLPer100km: 10, fallback: 0.5
        ), 1)
    }

    func testDrivingFuelPolicyAcceptsPartialTankCorrection() {
        let tripID = UUID()
        let state = DrivingFuelPolicy.confirmed(
            .init(), tripID: tripID, fraction: 0.45, location: nil
        )

        XCTAssertEqual(state.observedFuelFraction, 0.45, accuracy: 0.001)
        XCTAssertEqual(DrivingFuelPolicy.estimatedFraction(
            state, tripID: tripID, tankCapacityLitres: 50,
            consumptionLPer100km: 8, fallback: 1
        ), 0.45, accuracy: 0.001)
    }

    func testDrivingFuelPolicyFallsBackFromCorruptedNumericState() {
        let tripID = UUID()
        let corrupted = DrivingFuelState(
            tripID: tripID, observedFuelFraction: .infinity,
            distanceSinceObservationMetres: .nan,
            lastCoordinate: nil, lastSampleAt: nil
        )
        XCTAssertEqual(DrivingFuelPolicy.estimatedFraction(
            corrupted, tripID: tripID, tankCapacityLitres: 50,
            consumptionLPer100km: 8, fallback: 0.4
        ), 0.4, accuracy: 0.001)
        XCTAssertEqual(DrivingFuelPolicy.estimatedFraction(
            corrupted, tripID: tripID, tankCapacityLitres: .infinity,
            consumptionLPer100km: 8, fallback: .nan
        ), 0, accuracy: 0.001)
    }

    func testDrivingFuelPolicyDoesNotInventDistanceAcrossUnknownGap() {
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 50_000)
        let first = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                               horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: start)
        let farLater = CLLocation(coordinate: .init(latitude: 51, longitude: 9), altitude: 0,
                                  horizontalAccuracy: 5, verticalAccuracy: 5,
                                  timestamp: start.addingTimeInterval(3_600))
        var state = DrivingFuelPolicy.confirmed(.init(), tripID: tripID,
                                                fraction: 0.8, location: first)
        state = DrivingFuelPolicy.updated(state, tripID: tripID,
                                          initialFuelFraction: 1, location: farLater)
        XCTAssertEqual(state.distanceSinceObservationMetres, 0)
    }

    func testDrivingFuelPolicyIgnoresStationaryGPSJitter() {
        let tripID = UUID()
        let start = Date(timeIntervalSince1970: 55_000)
        let origin = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 6, verticalAccuracy: 5,
            course: 0, speed: 0, timestamp: start
        )
        var state = DrivingFuelPolicy.confirmed(
            .init(), tripID: tripID, fraction: 0.5, location: origin
        )
        for second in 1...60 {
            let longitude = second.isMultiple(of: 2) ? 8.00008 : 7.99992
            let jitter = CLLocation(
                coordinate: .init(latitude: 50, longitude: longitude), altitude: 0,
                horizontalAccuracy: 6, verticalAccuracy: 5,
                course: 0, speed: 0,
                timestamp: start.addingTimeInterval(TimeInterval(second))
            )
            state = DrivingFuelPolicy.updated(
                state, tripID: tripID, initialFuelFraction: 0.5, location: jitter
            )
        }

        XCTAssertEqual(state.distanceSinceObservationMetres, 0)
        XCTAssertEqual(DrivingFuelPolicy.estimatedFraction(
            state, tripID: tripID, tankCapacityLitres: 50,
            consumptionLPer100km: 8, fallback: 1
        ), 0.5, accuracy: 0.001)
    }

    func testDrivingFuelStateStorePersistsAggregateWithoutLocation() throws {
        let suite = "KiesDriveTests.DrivingFuel.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DrivingFuelStateStore(defaults: defaults)
        let expected = DrivingFuelState(
            tripID: UUID(), observedFuelFraction: 0.75,
            distanceSinceObservationMetres: 12_000,
            lastCoordinate: .init(latitude: 50, longitude: 8),
            lastSampleAt: Date(timeIntervalSince1970: 60_000)
        )
        store.save(expected)
        var persisted = expected
        persisted.lastCoordinate = nil
        persisted.lastSampleAt = nil
        XCTAssertEqual(store.load(), persisted)
        let data = try XCTUnwrap(defaults.data(forKey: store.key))
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("latitude"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("longitude"))
        store.clear()
        XCTAssertEqual(store.load(), DrivingFuelState())
    }

    func testDrivingFuelStateStoreMigratesLegacySavedCoordinateImmediately() throws {
        let suite = "KiesDriveTests.DrivingFuelMigration.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DrivingFuelStateStore(defaults: defaults)
        let legacy = DrivingFuelState(
            tripID: UUID(), observedFuelFraction: 0.6,
            distanceSinceObservationMetres: 42_000,
            lastCoordinate: .init(latitude: 50.1, longitude: 8.6),
            lastSampleAt: Date(timeIntervalSince1970: 60_000)
        )
        defaults.set(try JSONEncoder().encode(legacy), forKey: store.key)

        let migrated = store.load()

        XCTAssertNil(migrated.lastCoordinate)
        XCTAssertNil(migrated.lastSampleAt)
        XCTAssertEqual(migrated.distanceSinceObservationMetres, 42_000)
        let data = try XCTUnwrap(defaults.data(forKey: store.key))
        let encoded = try XCTUnwrap(String(data: data, encoding: .utf8))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("latitude"))
        XCTAssertFalse(encoded.localizedCaseInsensitiveContains("longitude"))
    }

    func testRemainingRoutePlanningDropsPassedStopsAndRebasesAheadStops() {
        let candidates = [
            BreakCandidate(id: "passed", name: "Vorbei", coordinate: .init(),
                           progress: 0.3, timeProgress: 0.2,
                           detourMetres: 100, isOpen: true),
            BreakCandidate(id: "ahead", name: "Voraus", coordinate: .init(),
                           progress: 0.7, timeProgress: 0.8,
                           detourMetres: 200, isOpen: true),
            BreakCandidate(id: "distance-only", name: "Ohne Zeitwert", coordinate: .init(),
                           progress: 0.6, detourMetres: 300, isOpen: true),
        ]

        let remaining = RemainingRoutePlanningPolicy.rebasedCandidates(
            candidates, distanceProgress: 0.4, timeProgress: 0.3
        )

        XCTAssertEqual(remaining.map(\.id), ["ahead", "distance-only"])
        XCTAssertEqual(remaining[0].progress, 0.5, accuracy: 0.001)
        XCTAssertEqual(remaining[0].installedRouteProgress ?? -1, 0.7, accuracy: 0.001)
        XCTAssertEqual(remaining[0].timeProgress ?? 0, 5.0 / 7.0, accuracy: 0.001)
        XCTAssertEqual(remaining[1].progress, 1.0 / 3.0, accuracy: 0.001)
        XCTAssertEqual(remaining[1].installedRouteProgress ?? -1, 0.6, accuracy: 0.001)
        XCTAssertEqual(remaining[1].timeProgress ?? 0, 1.0 / 3.0, accuracy: 0.001)
    }

    func testRemainingRoutePlanningKeepsPhysicalStopAheadAfterTrafficEtaImproves() {
        let aheadButOldTimeLooksPassed = BreakCandidate(
            id: "ahead", name: "Raststätte voraus", coordinate: .init(),
            progress: 0.65, timeProgress: 0.35,
            detourMetres: 200, isOpen: true, supportsFuel: true
        )

        let remaining = RemainingRoutePlanningPolicy.rebasedCandidates(
            [aheadButOldTimeLooksPassed], distanceProgress: 0.4, timeProgress: 0.5
        )

        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].progress, 5.0 / 12.0, accuracy: 0.001)
        XCTAssertEqual(remaining[0].timeProgress ?? -1, 5.0 / 12.0, accuracy: 0.001)
        let planned = PlannedBreak(
            id: "break", candidate: remaining[0], afterDriving: 1_000,
            duration: 900, routeProgress: remaining[0].progress,
            explanation: "Rastplatz"
        )
        XCTAssertEqual(planned.insertionRouteProgress, 0.65, accuracy: 0.001)
    }

    func testRemainingRoutePlanningStillDropsPhysicallyPassedStopDespiteEtaDrift() {
        let passedButTimeLooksAhead = BreakCandidate(
            id: "passed", name: "Raststätte zurück", coordinate: .init(),
            progress: 0.35, timeProgress: 0.7,
            detourMetres: 100, isOpen: true
        )

        XCTAssertTrue(RemainingRoutePlanningPolicy.rebasedCandidates(
            [passedButTimeLooksAhead], distanceProgress: 0.4, timeProgress: 0.3
        ).isEmpty)
    }

    func testRemainingRouteFuelEstimateAccountsForDistanceAlreadyDriven() {
        let fraction = RemainingRoutePlanningPolicy.estimatedFuelFraction(
            departureFraction: 0.8, tankCapacityLitres: 50,
            consumptionLPer100km: 10, travelledDistanceMetres: 200_000
        )

        XCTAssertEqual(fraction, 0.4, accuracy: 0.001)
        XCTAssertEqual(RemainingRoutePlanningPolicy.estimatedFuelFraction(
            departureFraction: 0.2, tankCapacityLitres: 50,
            consumptionLPer100km: 10, travelledDistanceMetres: 200_000
        ), 0)
    }

    func testBreakPlannerDoesNotCallARemoteStopOptimal() {
        let remote = BreakCandidate(id: "remote", name: "Much later", coordinate: .init(),
                                    progress: 0.9, detourMetres: 50, isOpen: true)
        let breaks = BreakPlanner().plan(drivingTime: 3 * 3600, candidates: [remote])
        XCTAssertEqual(breaks.count, 1)
        XCTAssertNil(breaks.first?.candidate)
        XCTAssertEqual(breaks.first?.routeProgress ?? 0, 2.0 / 3.0, accuracy: 0.001)
    }

    func testBreakPlannerRejectsStopTooLateForContinuousDrivingLimit() {
        let tooLate = BreakCandidate(id: "late", name: "Zu spät", coordinate: .init(),
                                     progress: 0.8, detourMetres: 20, isOpen: true)
        let breaks = BreakPlanner().plan(drivingTime: 3 * 3600, candidates: [tooLate])
        XCTAssertNil(breaks.first?.candidate)
        XCTAssertEqual(breaks.first?.afterDriving ?? 0, 2 * 3600, accuracy: 1)
    }

    func testBreakPlannerDoesNotChooseAnUnhelpfullyEarlyStop() {
        let tooEarly = BreakCandidate(id: "early", name: "Zu früh", coordinate: .init(),
                                      progress: 0.2, detourMetres: 20, isOpen: true)
        let breaks = BreakPlanner().plan(drivingTime: 5 * 3600, candidates: [tooEarly])
        XCTAssertNil(breaks.first?.candidate)
        XCTAssertEqual(breaks.first?.afterDriving ?? 0, 2 * 3600, accuracy: 1)
    }

    func testBreakPlannerAlignsUnverifiedFuelStopInsideSafeWindow() {
        let fuelStop = PlannedFuelStop(
            id: "fuel-1", candidate: nil, afterDistanceMetres: 180_000,
            routeProgress: 0.37,
            explanation: "Tankstopp vor der Reserve nötig; konkrete Station noch nicht verifiziert."
        )

        let breaks = BreakPlanner().plan(drivingTime: 5 * 3600, candidates: [],
                                         plannedFuelStops: [fuelStop])

        XCTAssertEqual(breaks.first?.routeProgress ?? 0, 0.37, accuracy: 0.001)
        XCTAssertNil(breaks.first?.candidate)
        XCTAssertTrue(breaks.first?.explanation.contains("Tank- und Pausenstopp") == true)
    }

    func testBreakPlannerDoesNotAttachUnverifiedFuelStopToUnrelatedRestArea() {
        let unverifiedFuelStop = PlannedFuelStop(
            id: "fuel-1", candidate: nil, afterDistanceMetres: 180_000,
            routeProgress: 0.37,
            explanation: "Tankstopp vor der Reserve nötig; konkrete Station noch nicht verifiziert."
        )
        let nearbyRestArea = BreakCandidate(
            id: "rest-1", name: "Rastplatz ohne belegte Tankstelle", coordinate: .init(),
            progress: 0.4, detourMetres: 100, isOpen: true, supportsFuel: false
        )

        let breaks = BreakPlanner().plan(
            drivingTime: 5 * 3600, candidates: [nearbyRestArea],
            plannedFuelStops: [unverifiedFuelStop]
        )

        XCTAssertNil(breaks.first?.candidate)
        XCTAssertEqual(breaks.first?.routeProgress ?? 0, 0.37, accuracy: 0.001)
        XCTAssertEqual(breaks.first?.afterDriving ?? 0, 0.37 * 5 * 3600, accuracy: 1)
        XCTAssertTrue(breaks.first?.explanation.contains("konkrete Station noch nicht verifiziert") == true)
    }

    func testBreakPlannerNeverDelaysSafetyBreakForLateFuelStop() {
        let lateFuelStop = PlannedFuelStop(
            id: "fuel-1", candidate: nil, afterDistanceMetres: 250_000,
            routeProgress: 0.5,
            explanation: "Tankstopp vor der Reserve nötig; konkrete Station noch nicht verifiziert."
        )

        let breaks = BreakPlanner().plan(drivingTime: 5 * 3600, candidates: [],
                                         plannedFuelStops: [lateFuelStop])

        XCTAssertEqual(breaks.first?.afterDriving ?? 0, 2 * 3600, accuracy: 1)
        XCTAssertFalse(breaks.first?.explanation.contains("Tank- und Pausenstopp") == true)
    }

    func testRouteSearchSamplesByDistanceInsteadOfPointDensity() {
        let clustered = (0...8).map {
            CLLocationCoordinate2D(latitude: 0, longitude: Double($0) * 0.001)
        } + [CLLocationCoordinate2D(latitude: 0, longitude: 10)]
        let samples = RouteGeometryProgress.evenlySpaced(clustered, maximum: 3)

        XCTAssertEqual(samples.count, 3)
        XCTAssertEqual(samples[0].longitude, 0, accuracy: 0.001)
        XCTAssertEqual(samples[1].longitude, 5, accuracy: 0.05)
        XCTAssertEqual(samples[2].longitude, 10, accuracy: 0.001)
    }

    func testBreakPlannerResetsLimitAtActualEarlyStop() {
        let candidates = [
            BreakCandidate(id: "early", name: "Früher Halt", coordinate: .init(),
                           progress: 0.3, detourMetres: 100, isOpen: true),
            BreakCandidate(id: "late", name: "Später Halt", coordinate: .init(),
                           progress: 0.75, detourMetres: 100, isOpen: true)
        ]
        let drivingTime = 6 * 3600.0
        let breaks = BreakPlanner().plan(drivingTime: drivingTime, candidates: candidates)
        let times = breaks.map(\.afterDriving)
        let legs = zip([0.0] + times, times + [drivingTime]).map { $1 - $0 }
        XCTAssertTrue(legs.allSatisfy { $0 <= 2 * 3600 + 10 * 60 })
        XCTAssertFalse(breaks.contains { $0.candidate?.id == "late" },
                       "A later stop must be measured from the actual early break")
    }

    func testBreakPlannerKeepsUnknownOpeningStatusHonest() {
        let unknown = BreakCandidate(id: "unknown", name: "Rastplatz", coordinate: .init(),
                                     progress: 2.0 / 3.0, detourMetres: 100, isOpen: nil)
        let stop = BreakPlanner().plan(drivingTime: 3 * 3600, candidates: [unknown]).first

        XCTAssertEqual(stop?.candidate?.id, "unknown")
        XCTAssertTrue(stop?.explanation.contains("Öffnungsstatus") == true)
        XCTAssertFalse(stop?.explanation.contains("Geöffneter Halt") == true)
    }

    func testFuelStationWithoutOpeningDataRemainsUnverified() {
        let station = FuelStation(id: "station", name: "Autohof", brand: "", street: "",
                                  place: "", lat: 50, lon: 8, price: 1.75,
                                  open: nil, distanceKm: 1)
        let candidate = BreakCandidateFactory.fuelStation(station, progress: 0.5, detourMetres: 200)
        XCTAssertNil(candidate.isOpen)
        let planned = BreakPlanner(maximumContinuousDriving: 2 * 60 * 60)
            .plan(drivingTime: 4 * 60 * 60, candidates: [candidate]).first
        XCTAssertTrue(planned?.explanation.contains("Öffnungsstatus") == true)
    }

    func testRouteProgressUsesDistanceRatherThanPointCount() {
        let coordinates = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.001),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.011),
        ]
        let progress = RouteGeometryProgress.cumulativeFractions(coordinates)
        XCTAssertEqual(progress.first, 0)
        XCTAssertEqual(progress.last, 1)
        XCTAssertEqual(progress[1], 1.0 / 11.0, accuracy: 0.01)
    }

    func testCandidateIsReprojectedForEachComparedRoute() throws {
        let route = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.1),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.2)
        ]
        let projection = try XCTUnwrap(RouteGeometryProgress.nearestProgress(
            of: .init(latitude: 50.001, longitude: 8.11), on: route
        ))
        XCTAssertEqual(projection.progress, 0.55, accuracy: 0.01)
        XCTAssertLessThan(projection.distance, 9_000)
    }

    func testUnknownTollNeverTurnsIntoInventedZero() async throws {
        let cost = try await UnknownTollProvider().tollCost(
            for: .init(routeID: "route", distanceMetres: 100_000, countries: ["DE"]),
            vehicle: .init()
        )
        XCTAssertNil(cost.amount)
        guard case .unknown = cost else { return XCTFail("Expected unknown toll cost") }
    }

    func testVerifiedTollSourceLinkSurvivesPlanEncoding() throws {
        let expected = TollCost.known(
            amount: 27.4, currency: "EUR", source: "Official provider",
            sourceURL: "https://example.test/tolls/2026"
        )
        let data = try JSONEncoder().encode(expected)
        XCTAssertEqual(try JSONDecoder().decode(TollCost.self, from: data), expected)

        let noToll = TollCost.noToll(
            source: "Official provider",
            sourceURL: "https://example.test/toll-free/2026"
        )
        XCTAssertEqual(
            try JSONDecoder().decode(TollCost.self, from: JSONEncoder().encode(noToll)),
            noToll
        )
    }

    func testTollEvidenceRequiresPlausibleAmountAndHTTPSSource() {
        XCTAssertNotNil(TollEvidenceValidator.validate(
            status: "known", amount: 27.4, currency: "EUR", source: "Official toll provider",
            sourceURL: "https://example.test/tolls"
        ))
        XCTAssertNil(TollEvidenceValidator.validate(
            status: "known", amount: 27.4, currency: "EUR", source: "Search result", sourceURL: nil
        ))
        XCTAssertNil(TollEvidenceValidator.validate(
            status: "known", amount: .infinity, currency: "EUR", source: "Provider",
            sourceURL: "https://example.test/tolls"
        ))
        XCTAssertNil(TollEvidenceValidator.validate(
            status: "known", amount: 27.4, currency: "EUR", source: "Provider",
            sourceURL: "http://example.test/tolls"
        ))
        XCTAssertNil(TollEvidenceValidator.validate(
            status: "known", amount: 0, currency: "EUR", source: "Search result",
            sourceURL: "https://example.test/tolls"
        ), "Zero toll needs explicit verified no_toll evidence")
        XCTAssertNil(TollEvidenceValidator.validate(
            status: "known", amount: 27.4, currency: "Euro", source: "Provider",
            sourceURL: "https://example.test/tolls"
        ))
        XCTAssertNil(TollEvidenceValidator.validate(
            status: "known", amount: 27.4, currency: "ABC", source: "Provider",
            sourceURL: "https://example.test/tolls"
        ), "Three letters alone are not proof of a real currency")
        XCTAssertNil(TollEvidenceValidator.validate(
            status: "known", amount: 27.4, currency: "XXX", source: "Provider",
            sourceURL: "https://example.test/tolls"
        ), "ISO's no-currency placeholder must never label a payable toll")
        XCTAssertEqual(TollEvidenceValidator.validate(
            status: "known", amount: 27.4, currency: " eur ", source: "Provider",
            sourceURL: "https://example.test/tolls"
        )?.currency, "EUR")
        XCTAssertTrue(TollEvidenceValidator.validatesNoToll(
            status: "no_toll", source: "Official provider",
            sourceURL: "https://example.test/toll-free"
        ))
        XCTAssertFalse(TollEvidenceValidator.validatesNoToll(
            status: "unknown", source: "Search",
            sourceURL: "https://example.test/toll-free"
        ))
    }

    func testTollEvidenceSourceMustAppearInReturnedSearchResults() {
        XCTAssertNotNil(TollEvidenceValidator.validate(
            status: "known", amount: 27.4, currency: "EUR",
            source: "Official provider", sourceURL: "https://example.test/tolls#price",
            corroboratingSourceURLs: ["https://EXAMPLE.test/tolls"]
        ))
        XCTAssertNil(TollEvidenceValidator.validate(
            status: "known", amount: 27.4, currency: "EUR",
            source: "Invented provider", sourceURL: "https://invented.test/tolls",
            corroboratingSourceURLs: ["https://example.test/tolls"]
        ))
        XCTAssertTrue(TollEvidenceValidator.validatesNoToll(
            status: "no_toll", source: "Official provider",
            sourceURL: "https://example.test/toll-free",
            corroboratingSourceURLs: ["https://example.test/toll-free#result"]
        ))
        XCTAssertFalse(TollEvidenceValidator.validatesNoToll(
            status: "no_toll", source: "Invented provider",
            sourceURL: "https://invented.test/toll-free",
            corroboratingSourceURLs: []
        ))
    }

    func testShortTripDoesNotAddBreak() {
        XCTAssertTrue(BreakPlanner().plan(drivingTime: 90 * 60, candidates: []).isEmpty)
    }

    func testComparisonOnlyCalculatesTollSavingsForKnownPrices() throws {
        let scenario = SpeedScenario.target(150)
        let fuel = FuelEstimate(litres: 40, cost: 70, averageConsumptionLPer100km: 7)
        let baseline = RouteScenarioResult(id: "a", routeTitle: "A", scenario: scenario, distanceMetres: 500_000, drivingTime: 18_000, totalTime: 19_200, fuel: fuel, toll: .known(amount: 24, currency: "EUR", source: "provider", sourceURL: nil), breaks: [], fuelStops: [], unlimitedFraction: 0)
        let unknown = RouteScenarioResult(id: "b", routeTitle: "B", scenario: scenario, distanceMetres: 520_000, drivingTime: 19_000, totalTime: 20_200, fuel: fuel, toll: .unknown(reason: "missing"), breaks: [], fuelStops: [], unlimitedFraction: 0)
        let free = RouteScenarioResult(id: "c", routeTitle: "C", scenario: scenario, distanceMetres: 520_000, drivingTime: 19_000, totalTime: 20_200, fuel: fuel, toll: .noToll(source: "provider", sourceURL: nil), breaks: [], fuelStops: [], unlimitedFraction: 0)

        XCTAssertNil(RouteComparisonDelta(from: baseline, to: unknown).tollSavings)
        let delta = RouteComparisonDelta(from: baseline, to: free)
        XCTAssertEqual(delta.tollSavings, 24)
        XCTAssertEqual(try XCTUnwrap(delta.totalCostDifference), -24, accuracy: 0.001)
    }

    func testTwoConfirmedTollFreeRoutesDoNotInventEuroEvidence() throws {
        let scenario = SpeedScenario.target(150)
        let baseline = RouteScenarioResult(
            id: "a", routeTitle: "A", scenario: scenario,
            distanceMetres: 1, drivingTime: 1, totalTime: 1,
            fuel: .init(litres: 10, cost: 20, averageConsumptionLPer100km: 7),
            toll: .noToll(source: "provider-a", sourceURL: nil),
            breaks: [], fuelStops: [], unlimitedFraction: 0
        )
        let alternative = RouteScenarioResult(
            id: "b", routeTitle: "B", scenario: scenario,
            distanceMetres: 1, drivingTime: 1, totalTime: 1,
            fuel: .init(litres: 11, cost: 22.5, averageConsumptionLPer100km: 7),
            toll: .noToll(source: "provider-b", sourceURL: nil),
            breaks: [], fuelStops: [], unlimitedFraction: 0
        )

        let delta = RouteComparisonDelta(from: baseline, to: alternative)
        XCTAssertNil(delta.tollSavings)
        XCTAssertNil(delta.tollCurrency)
        XCTAssertEqual(try XCTUnwrap(delta.totalCostDifference), 2.5, accuracy: 0.001)
    }

    func testComparisonNeverCombinesDifferentTollCurrencies() {
        let scenario = SpeedScenario.target(150)
        let fuel = FuelEstimate(litres: 40, cost: 70, averageConsumptionLPer100km: 7)
        let euro = RouteScenarioResult(id: "eur", routeTitle: "EUR", scenario: scenario,
                                       distanceMetres: 1, drivingTime: 1, totalTime: 1, fuel: fuel,
                                       toll: .known(amount: 20, currency: "EUR", source: "provider", sourceURL: nil),
                                       breaks: [], fuelStops: [], unlimitedFraction: 0)
        let francs = RouteScenarioResult(id: "chf", routeTitle: "CHF", scenario: scenario,
                                         distanceMetres: 1, drivingTime: 1, totalTime: 1, fuel: fuel,
                                         toll: .known(amount: 20, currency: "CHF", source: "provider", sourceURL: nil),
                                         breaks: [], fuelStops: [], unlimitedFraction: 0)
        let delta = RouteComparisonDelta(from: euro, to: francs)
        XCTAssertNil(delta.tollSavings)
        XCTAssertNil(delta.totalCostDifference)
    }

    func testFuelStopsStayBeforeReserveAndPreferRouteCandidate() {
        let candidates = [
            BreakCandidate(id: "station", name: "Route station", coordinate: .init(),
                           progress: 0.48, detourMetres: 200, isOpen: true, supportsFuel: true)
        ]
        let vehicle = VehicleProfile(baseConsumptionLPer100km: 10, fuelPricePerLitre: 1.8,
                                     tankCapacityLitres: 50, usableTankFraction: 0.8)
        let stops = FuelStopPlanner().plan(distanceMetres: 700_000, consumptionLPer100km: 10,
                                           vehicle: vehicle, candidates: candidates)
        XCTAssertEqual(stops.count, 1)
        XCTAssertEqual(stops.first?.candidate?.id, "station")
        XCTAssertLessThan(stops.first?.afterDistanceMetres ?? .infinity, 400_000)
    }

    func testFuelPlannerTreatsDistantClosedStatusAsStale() {
        let candidate = BreakCandidate(
            id: "later-fuel", name: "Tankstelle später", coordinate: .init(),
            progress: 0.48, detourMetres: 200, isOpen: false, supportsFuel: true
        )
        let vehicle = VehicleProfile(
            baseConsumptionLPer100km: 10, fuelPricePerLitre: 1.8,
            tankCapacityLitres: 50, usableTankFraction: 0.8
        )
        let distant = FuelStopPlanner().plan(
            distanceMetres: 700_000, consumptionLPer100km: 10,
            vehicle: vehicle, candidates: [candidate], routeTravelTime: 7 * 3600
        )
        let near = FuelStopPlanner().plan(
            distanceMetres: 700_000, consumptionLPer100km: 10,
            vehicle: vehicle, candidates: [candidate], routeTravelTime: 30 * 60
        )

        XCTAssertEqual(distant.first?.candidate?.id, "later-fuel")
        XCTAssertTrue(distant.first?.explanation.contains("Öffnungsstatus") == true)
        XCTAssertNil(near.first?.candidate)
    }

    func testFuelPlannerRejectsNonFiniteTripAndVehicleInputs() {
        let validVehicle = VehicleProfile(
            baseConsumptionLPer100km: 10, fuelPricePerLitre: 1.8,
            tankCapacityLitres: 50, usableTankFraction: 0.8
        )
        XCTAssertTrue(FuelStopPlanner().plan(
            distanceMetres: .infinity, consumptionLPer100km: 10,
            vehicle: validVehicle, candidates: []
        ).isEmpty)
        let invalidVehicle = VehicleProfile(
            baseConsumptionLPer100km: 10, fuelPricePerLitre: 1.8,
            tankCapacityLitres: .infinity, usableTankFraction: 0.8
        )
        XCTAssertTrue(FuelStopPlanner().plan(
            distanceMetres: 700_000, consumptionLPer100km: 10,
            vehicle: invalidVehicle, candidates: []
        ).isEmpty)
    }

    func testFuelPlannerRejectsStationBeyondSafeRange() {
        let tooLate = BreakCandidate(id: "late", name: "Zu spät", coordinate: .init(),
                                     progress: 0.62, detourMetres: 50, isOpen: true, supportsFuel: true)
        let vehicle = VehicleProfile(baseConsumptionLPer100km: 10, fuelPricePerLitre: 1.8,
                                     tankCapacityLitres: 50, usableTankFraction: 0.8)
        let stops = FuelStopPlanner().plan(distanceMetres: 700_000, consumptionLPer100km: 10,
                                           vehicle: vehicle, candidates: [tooLate])
        XCTAssertNil(stops.first?.candidate)
        XCTAssertLessThan(stops.first?.afterDistanceMetres ?? .infinity, 400_000)
    }

    func testFuelPlannerUsesActualDepartureFuelForFirstStop() {
        let earlyStation = BreakCandidate(
            id: "early", name: "Frühe Tankstelle", coordinate: .init(),
            progress: 0.18, detourMetres: 100, isOpen: true, supportsFuel: true
        )
        let vehicle = VehicleProfile(
            baseConsumptionLPer100km: 10, fuelPricePerLitre: 1.8,
            tankCapacityLitres: 50, usableTankFraction: 0.8,
            initialFuelFraction: 0.5
        )

        let stops = FuelStopPlanner().plan(
            distanceMetres: 700_000, consumptionLPer100km: 10,
            vehicle: vehicle, candidates: [earlyStation]
        )

        XCTAssertEqual(stops.first?.candidate?.id, "early")
        XCTAssertLessThan(stops.first?.afterDistanceMetres ?? .infinity, 150_000)
    }

    func testFuelPlannerMeasuresEveryLegFromActualPreviousStop() {
        let candidates = [
            BreakCandidate(id: "first", name: "Erster Halt", coordinate: .init(),
                           progress: 0.36, detourMetres: 100, isOpen: true, supportsFuel: true),
            BreakCandidate(id: "unsafe-second", name: "Zu weit", coordinate: .init(),
                           progress: 0.82, detourMetres: 50, isOpen: true, supportsFuel: true)
        ]
        let vehicle = VehicleProfile(baseConsumptionLPer100km: 10, fuelPricePerLitre: 1.8,
                                     tankCapacityLitres: 50, usableTankFraction: 0.8)
        let stops = FuelStopPlanner().plan(distanceMetres: 1_000_000, consumptionLPer100km: 10,
                                           vehicle: vehicle, candidates: candidates)
        XCTAssertEqual(stops.first?.candidate?.id, "first")
        XCTAssertFalse(stops.contains { $0.candidate?.id == "unsafe-second" })
        let distances = zip([0.0] + stops.map(\.afterDistanceMetres),
                            stops.map(\.afterDistanceMetres) + [1_000_000])
            .map { $1 - $0 }
        XCTAssertTrue(distances.allSatisfy { $0 <= 400_000 })
    }

    func testFuelPlannerNeverTreatsPlainRestAreaAsFuelStation() {
        let restArea = BreakCandidate(id: "rest", name: "Rastplatz", coordinate: .init(),
                                      progress: 0.48, detourMetres: 50, isOpen: true)
        let station = BreakCandidate(id: "fuel", name: "Tankstelle", coordinate: .init(),
                                     progress: 0.5, detourMetres: 400, isOpen: true, supportsFuel: true)
        let vehicle = VehicleProfile(baseConsumptionLPer100km: 10, fuelPricePerLitre: 1.8,
                                     tankCapacityLitres: 50, usableTankFraction: 0.8)
        let stops = FuelStopPlanner().plan(distanceMetres: 700_000, consumptionLPer100km: 10,
                                           vehicle: vehicle, candidates: [restArea, station])
        XCTAssertEqual(stops.first?.candidate?.id, "fuel")
    }

    func testComparisonCombinesBreakWithNearbyPlannedFuelStop() {
        let restArea = BreakCandidate(id: "rest", name: "Rastplatz", coordinate: .init(),
                                      progress: 0.4, detourMetres: 50, isOpen: true)
        let fuel = BreakCandidate(id: "fuel", name: "Autohof", coordinate: .init(),
                                  progress: 0.35, detourMetres: 200, isOpen: true,
                                  supportsFuel: true)
        let route = RoutePlanningInput(
            id: "holiday", title: "Urlaubsroute", distanceMetres: 450_000,
            mapKitExpectedTravelTime: 5 * 3600, unlimitedMotorwayFraction: 0,
            typicalUnlimitedSpeedKmh: 130, toll: .unknown(reason: "test"),
            breakCandidates: [restArea, fuel]
        )
        let vehicle = VehicleProfile(baseConsumptionLPer100km: 10, fuelPricePerLitre: 1.8,
                                     tankCapacityLitres: 35, usableTankFraction: 0.8)
        let result = RouteComparison(fuelModel: .init(), breakPlanner: .init())
            .compare(routes: [route], scenarios: [.target(130)], vehicle: vehicle)
            .results[0]

        XCTAssertEqual(result.fuelStops.first?.candidate?.id, "fuel")
        XCTAssertEqual(result.breaks.first?.candidate?.id, "fuel",
                       "A safe nearby fuel stop should also serve as the planned rest break")
        XCTAssertEqual(result.plannedStopDetourMetres, 200, accuracy: 0.01,
                       "A combined stop must count its detour only once")
        XCTAssertEqual(result.additionalFuelStopTime, 0,
                       "Refuelling during the planned rest break must not add a second dwell time")
        XCTAssertGreaterThan(result.totalDistanceMetres, route.distanceMetres)
    }

    func testSeparateFuelStopAddsDetourFuelDrivingAndServiceTime() {
        let fuelStop = BreakCandidate(id: "fuel", name: "Tankstelle", coordinate: .init(),
                                      progress: 0.48, detourMetres: 2_000, isOpen: true,
                                      supportsFuel: true)
        let route = RoutePlanningInput(
            id: "fuel-trip", title: "Fahrt", distanceMetres: 180_000,
            mapKitExpectedTravelTime: 108 * 60, unlimitedMotorwayFraction: 0,
            typicalUnlimitedSpeedKmh: 130, toll: .unknown(reason: "test"),
            breakCandidates: [fuelStop]
        )
        let vehicle = VehicleProfile(baseConsumptionLPer100km: 10, fuelPricePerLitre: 1.8,
                                     tankCapacityLitres: 20, usableTankFraction: 0.8)
        let baselineFuel = FuelModel().estimate(distanceMetres: route.distanceMetres,
                                                effectiveSpeedKmh: route.distanceMetres / route.mapKitExpectedTravelTime * 3.6,
                                                profile: vehicle)
        let result = RouteComparison(fuelModel: .init(), breakPlanner: .init())
            .compare(routes: [route], scenarios: [.target(130)], vehicle: vehicle).results[0]

        XCTAssertTrue(result.breaks.isEmpty)
        XCTAssertEqual(result.plannedStopDetourMetres, 2_000, accuracy: 0.01)
        XCTAssertEqual(result.totalDistanceMetres, 182_000, accuracy: 0.01)
        XCTAssertEqual(result.additionalFuelStopTime, 10 * 60, accuracy: 0.01)
        XCTAssertEqual(result.drivingTime, route.mapKitExpectedTravelTime + 144, accuracy: 1)
        XCTAssertEqual(result.totalTime, result.drivingTime + 10 * 60, accuracy: 1)
        XCTAssertGreaterThan(result.fuel.litres, baselineFuel.litres)
    }

    func testSegmentedFuelModelDoesNotApplyFastTargetToLimitedDistance() {
        let profile = VehicleProfile(baseConsumptionLPer100km: 7, referenceSpeedKmh: 100,
                                     fuelPricePerLitre: 1.8, tankCapacityLitres: 50,
                                     usableTankFraction: 0.85)
        let model = FuelModel()
        let segmented = model.estimate(segments: [(400_000, 90), (100_000, 200)], profile: profile)
        let falselyFastEverywhere = model.estimate(distanceMetres: 500_000, effectiveSpeedKmh: 200,
                                                   profile: profile)
        XCTAssertLessThan(segmented.litres, falselyFastEverywhere.litres)
        XCTAssertGreaterThan(segmented.litres, model.estimate(distanceMetres: 500_000,
                                                              effectiveSpeedKmh: 90,
                                                              profile: profile).litres)
    }

    func testFuelModelDoesNotRewardStopAndGoTraffic() {
        let profile = VehicleProfile(baseConsumptionLPer100km: 7, referenceSpeedKmh: 100,
                                     fuelPricePerLitre: 1.8, tankCapacityLitres: 50,
                                     usableTankFraction: 0.85)
        let model = FuelModel()
        let reference = model.estimate(distanceMetres: 100_000, effectiveSpeedKmh: 100,
                                       profile: profile)
        let congestion = model.estimate(distanceMetres: 100_000, effectiveSpeedKmh: 30,
                                        profile: profile)
        let severeCongestion = model.estimate(distanceMetres: 100_000, effectiveSpeedKmh: 10,
                                              profile: profile)

        XCTAssertGreaterThan(congestion.litres, reference.litres)
        XCTAssertGreaterThan(severeCongestion.litres, congestion.litres)
    }
}
