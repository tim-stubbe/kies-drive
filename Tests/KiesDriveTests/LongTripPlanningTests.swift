import XCTest
import CoreLocation
@testable import Kies_Drive

final class LongTripPlanningTests: XCTestCase {
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

    func testTollLookupCacheOnlyReusesSameNearbyTrip() {
        let loadedAt = Date(timeIntervalSince1970: 10_000)
        let snapshot = TollLookupSnapshot(
            routeIdentity: "hochheim|wurzenpass", origin: .init(latitude: 50, longitude: 8),
            cost: .known(amount: 27.4, currency: "EUR", source: "Provider"), loadedAt: loadedAt
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

    func testSpeedScenarioAppliesDistanceShareInsteadOfTimeShare() {
        let route = RoutePlanningInput(
            id: "distance-share", title: "Route", distanceMetres: 600_000,
            mapKitExpectedTravelTime: 6 * 3600, unlimitedMotorwayFraction: 0.5,
            typicalUnlimitedSpeedKmh: 130, toll: .unknown(reason: "test"), breakCandidates: []
        )
        let result = RouteComparison(fuelModel: .init(), breakPlanner: .init())
            .compare(routes: [route], scenarios: [.target(200)], vehicle: .init()).results[0]
        let expected = 6 * 3600 - (300_000 / (130 / 3.6)) + (300_000 / (200 / 3.6))
        XCTAssertEqual(result.drivingTime, expected, accuracy: 1)
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

    func testBreaksFollowTwoHourDrivingIntervals() {
        let candidates = [
            BreakCandidate(id: "two-hours", name: "First", coordinate: .init(), progress: 0.4, detourMetres: 100, isOpen: true),
            BreakCandidate(id: "four-hours", name: "Second", coordinate: .init(), progress: 0.8, detourMetres: 100, isOpen: true),
        ]
        let breaks = BreakPlanner().plan(drivingTime: 5 * 3600, candidates: candidates)
        XCTAssertEqual(breaks[0].afterDriving, 2 * 3600, accuracy: 1)
        XCTAssertEqual(breaks[1].afterDriving, 4 * 3600, accuracy: 1)
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
    }

    func testShortTripDoesNotAddBreak() {
        XCTAssertTrue(BreakPlanner().plan(drivingTime: 90 * 60, candidates: []).isEmpty)
    }

    func testComparisonOnlyCalculatesTollSavingsForKnownPrices() throws {
        let scenario = SpeedScenario.target(150)
        let fuel = FuelEstimate(litres: 40, cost: 70, averageConsumptionLPer100km: 7)
        let baseline = RouteScenarioResult(id: "a", routeTitle: "A", scenario: scenario, distanceMetres: 500_000, drivingTime: 18_000, totalTime: 19_200, fuel: fuel, toll: .known(amount: 24, currency: "EUR", source: "provider"), breaks: [], fuelStops: [], unlimitedFraction: 0)
        let unknown = RouteScenarioResult(id: "b", routeTitle: "B", scenario: scenario, distanceMetres: 520_000, drivingTime: 19_000, totalTime: 20_200, fuel: fuel, toll: .unknown(reason: "missing"), breaks: [], fuelStops: [], unlimitedFraction: 0)
        let free = RouteScenarioResult(id: "c", routeTitle: "C", scenario: scenario, distanceMetres: 520_000, drivingTime: 19_000, totalTime: 20_200, fuel: fuel, toll: .noToll(source: "provider"), breaks: [], fuelStops: [], unlimitedFraction: 0)

        XCTAssertNil(RouteComparisonDelta(from: baseline, to: unknown).tollSavings)
        let delta = RouteComparisonDelta(from: baseline, to: free)
        XCTAssertEqual(delta.tollSavings, 24)
        XCTAssertEqual(try XCTUnwrap(delta.totalCostDifference), -24, accuracy: 0.001)
    }

    func testComparisonNeverCombinesDifferentTollCurrencies() {
        let scenario = SpeedScenario.target(150)
        let fuel = FuelEstimate(litres: 40, cost: 70, averageConsumptionLPer100km: 7)
        let euro = RouteScenarioResult(id: "eur", routeTitle: "EUR", scenario: scenario,
                                       distanceMetres: 1, drivingTime: 1, totalTime: 1, fuel: fuel,
                                       toll: .known(amount: 20, currency: "EUR", source: "provider"),
                                       breaks: [], fuelStops: [], unlimitedFraction: 0)
        let francs = RouteScenarioResult(id: "chf", routeTitle: "CHF", scenario: scenario,
                                         distanceMetres: 1, drivingTime: 1, totalTime: 1, fuel: fuel,
                                         toll: .known(amount: 20, currency: "CHF", source: "provider"),
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
}
