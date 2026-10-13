import XCTest
import CoreLocation
@testable import Kies_Drive

@MainActor
final class RoutePersistenceTests: XCTestCase {
    func testInsertedStopKeepsRouteOrderAndInheritedSegmentRules() {
        let now = Date(timeIntervalSince1970: 1)
        let avoidMotorway = LockedRouteOptions(avoidTolls: false, avoidHighways: true)
        var lock = ActiveRouteLock(
            id: UUID(), title: "Trip", destinationName: "Home",
            destination: .init(latitude: 0, longitude: 100),
            waypoints: [
                .init(id: "first", name: "First", coordinate: .init(latitude: 0, longitude: 20),
                      required: true, optionsAfter: avoidMotorway),
                .init(id: "last", name: "Last", coordinate: .init(latitude: 0, longitude: 80),
                      required: true, optionsAfter: nil),
            ],
            defaultOptions: .init(avoidTolls: true, avoidHighways: false),
            corridorWidthMetres: 5_000, corridorPoints: nil, visitedWaypointIDs: ["fuel"],
            status: .active, createdAt: now, updatedAt: now
        )
        lock.insertWaypoint(
            .init(id: "fuel", name: "Fuel", coordinate: .init(latitude: 0, longitude: 50),
                  required: true, optionsAfter: nil),
            progress: { Int($0.longitude) }
        )

        XCTAssertEqual(lock.waypoints.map(\.id), ["first", "fuel", "last"])
        XCTAssertEqual(lock.waypoints[1].optionsAfter, avoidMotorway)
        XCTAssertFalse(lock.visitedWaypointIDs?.contains("fuel") == true)
        lock.removeWaypoint(id: "fuel")
        XCTAssertEqual(lock.waypoints.map(\.id), ["first", "last"])
    }

    func testHochheimPresetForcesRoadPointOnWurzenpass() {
        let lock = ActiveRouteLock.hochheimViaWurzenpass(now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(lock.destinationName, "Hochheim am Main")
        XCTAssertEqual(lock.waypoints.map(\.id), ["a1-dugopolje", "wurzenpass-road", "katschberg-b99", "obertauern-b99"])
        XCTAssertTrue(lock.waypoints[0].required)
        XCTAssertEqual(lock.waypoints[0].coordinate.latitude, 43.59603, accuracy: 0.0001)
        XCTAssertEqual(lock.waypoints[1].coordinate.latitude, 46.521944, accuracy: 0.0001)
        XCTAssertEqual(lock.waypoints[2].coordinate.latitude, 47.0583, accuracy: 0.0001)
        XCTAssertTrue(lock.waypoints[2].optionsAfter?.avoidHighways == true)
        XCTAssertEqual(lock.waypoints[3].coordinate.latitude, 47.2494, accuracy: 0.0001)
    }

    func testCroatiaPresetKeepsMandatorySloveniaRules() {
        let lock = ActiveRouteLock.croatiaSplit(now: Date(timeIntervalSince1970: 1))
        XCTAssertEqual(lock.title, "Kroatien")
        XCTAssertEqual(lock.destinationName, "Split, Kroatien")
        XCTAssertEqual(lock.waypoints.map(\.id), ["sentilj", "macelj"])
        XCTAssertTrue(lock.waypoints[0].required)
        XCTAssertEqual(lock.waypoints[0].optionsAfter, .init(avoidTolls: true, avoidHighways: true))
        XCTAssertEqual(lock.waypoints[1].optionsAfter, .init(avoidTolls: false, avoidHighways: false))
    }

    func testActiveTripSurvivesStoreRecreationWithSegmentRules() throws {
        let suite = "RoutePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = RouteLockStore(defaults: defaults)
        let lock = ActiveRouteLock(
            id: UUID(), title: "Kroatien", destinationName: "Split",
            destination: .init(latitude: 43.508, longitude: 16.44),
            waypoints: [.init(
                id: "slovenia", name: "Slowenien", coordinate: .init(latitude: 46.05, longitude: 14.5),
                required: true, optionsAfter: .init(avoidTolls: false, avoidHighways: true))],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 5_000, corridorPoints: [.init(latitude: 46.1, longitude: 14.6)],
            visitedWaypointIDs: [],
            status: .active, createdAt: Date(), updatedAt: Date())
        first.save(lock)

        let restored = RouteLockStore(defaults: defaults).activeLock
        XCTAssertEqual(restored?.title, "Kroatien")
        XCTAssertEqual(restored?.waypoints.first?.optionsAfter?.avoidHighways, true)
        XCTAssertEqual(restored?.waypoints.first?.required, true)
        XCTAssertEqual(restored?.corridorPoints?.count, 1)
    }

    func testFinishedTripIsNotRestored() throws {
        let suite = "RoutePersistenceTests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RouteLockStore(defaults: defaults)
        store.save(.init(
            id: UUID(), title: "Test", destinationName: "Ziel",
            destination: .init(latitude: 1, longitude: 2), waypoints: [],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 1_000, corridorPoints: nil,
            visitedWaypointIDs: [],
            status: .active, createdAt: Date(), updatedAt: Date()))
        store.finish()
        XCTAssertNil(RouteLockStore(defaults: defaults).activeLock)
    }

    func testRestoreMarksOnlyWaypointsAlreadyPassedInsideCorridor() {
        let lock = ActiveRouteLock(
            id: UUID(), title: "Nordfahrt", destinationName: "Ziel",
            destination: .init(latitude: 5, longitude: 0),
            waypoints: [
                .init(id: "one", name: "Eins", coordinate: .init(latitude: 1, longitude: 0), required: true, optionsAfter: nil),
                .init(id: "two", name: "Zwei", coordinate: .init(latitude: 3, longitude: 0), required: true, optionsAfter: nil),
            ],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 8_000,
            corridorPoints: (0...5).map { .init(latitude: Double($0), longitude: 0) },
            visitedWaypointIDs: [], status: .active, createdAt: Date(), updatedAt: Date())

        XCTAssertEqual(lock.passedWaypointIDs(at: .init(latitude: 2.1, longitude: 0)), ["one"])
        XCTAssertEqual(lock.passedWaypointIDs(at: .init(latitude: 2.1, longitude: 1)), [])
    }

    func testSparseCorridorAcceptsRoadBetweenStoredAnchors() {
        let corridor = [
            DriveCoordinate(latitude: 50, longitude: 8),
            DriveCoordinate(latitude: 50, longitude: 8.4),
        ]
        let route = (0...20).map {
            CLLocationCoordinate2D(latitude: 50.001, longitude: 8 + Double($0) * 0.02)
        }

        XCTAssertTrue(RouteCorridorPolicy.contains(route: route, corridor: corridor,
                                                   widthMetres: 2_000))
    }

    func testCorridorRejectsSubstantialDeparture() {
        let corridor = [
            DriveCoordinate(latitude: 50, longitude: 8),
            DriveCoordinate(latitude: 50, longitude: 8.4),
        ]
        let route = (0...20).map {
            CLLocationCoordinate2D(latitude: 50.2, longitude: 8 + Double($0) * 0.02)
        }

        XCTAssertFalse(RouteCorridorPolicy.contains(route: route, corridor: corridor,
                                                    widthMetres: 2_000))
    }

    func testOldOfflineCacheWithoutGeometryStillDecodes() throws {
        let json = #"{"destinationName":"Ziel","legs":[{"distance":1000,"travelTime":60,"steps":[]}],"stations":[],"savedAt":0}"#
        let cache = try JSONDecoder().decode(CachedRoute.self, from: Data(json.utf8))
        XCTAssertEqual(cache.destinationName, "Ziel")
        XCTAssertNil(cache.legs.first?.coordinates)
        XCTAssertNil(cache.legs.first?.steps.first?.coordinates)
    }
}
