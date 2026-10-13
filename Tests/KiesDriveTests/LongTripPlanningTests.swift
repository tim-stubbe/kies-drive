import XCTest
import CoreLocation
@testable import Kies_Drive

final class LongTripPlanningTests: XCTestCase {
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
        XCTAssertEqual(projection.progress, 0.5, accuracy: 0.01)
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

    func testComparisonOnlyCalculatesTollSavingsForKnownPrices() {
        let scenario = SpeedScenario.target(150)
        let fuel = FuelEstimate(litres: 40, cost: 70, averageConsumptionLPer100km: 7)
        let baseline = RouteScenarioResult(id: "a", routeTitle: "A", scenario: scenario, distanceMetres: 500_000, drivingTime: 18_000, totalTime: 19_200, fuel: fuel, toll: .known(amount: 24, currency: "EUR", source: "provider"), breaks: [], fuelStops: [], unlimitedFraction: 0)
        let unknown = RouteScenarioResult(id: "b", routeTitle: "B", scenario: scenario, distanceMetres: 520_000, drivingTime: 19_000, totalTime: 20_200, fuel: fuel, toll: .unknown(reason: "missing"), breaks: [], fuelStops: [], unlimitedFraction: 0)
        let free = RouteScenarioResult(id: "c", routeTitle: "C", scenario: scenario, distanceMetres: 520_000, drivingTime: 19_000, totalTime: 20_200, fuel: fuel, toll: .noToll(source: "provider"), breaks: [], fuelStops: [], unlimitedFraction: 0)

        XCTAssertNil(RouteComparisonDelta(from: baseline, to: unknown).tollSavings)
        XCTAssertEqual(RouteComparisonDelta(from: baseline, to: free).tollSavings, 24)
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
            id: "holiday", title: "Urlaubsroute", distanceMetres: 700_000,
            mapKitExpectedTravelTime: 5 * 3600, unlimitedMotorwayFraction: 0,
            typicalUnlimitedSpeedKmh: 130, toll: .unknown(reason: "test"),
            breakCandidates: [restArea, fuel]
        )
        let vehicle = VehicleProfile(baseConsumptionLPer100km: 10, fuelPricePerLitre: 1.8,
                                     tankCapacityLitres: 50, usableTankFraction: 0.8)
        let result = RouteComparison(fuelModel: .init(), breakPlanner: .init())
            .compare(routes: [route], scenarios: [.target(130)], vehicle: vehicle)
            .results[0]

        XCTAssertEqual(result.fuelStops.first?.candidate?.id, "fuel")
        XCTAssertEqual(result.breaks.first?.candidate?.id, "fuel",
                       "A safe nearby fuel stop should also serve as the planned rest break")
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
