import XCTest
import CoreLocation
@testable import Kies_Drive

@MainActor
final class RoutePersistenceTests: XCTestCase {
    func testRouteCalculationSnapshotTracksConstraintsButIgnoresLiveProgress() throws {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        var lock = ActiveRouteLock(
            id: UUID(), title: "Trip", destinationName: "Ziel",
            destination: .init(latitude: 50, longitude: 8),
            waypoints: [.init(
                id: "pass", name: "Pass", coordinate: .init(latitude: 49, longitude: 9),
                required: true, optionsAfter: .init(avoidTolls: true, avoidHighways: true)
            )],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 5_000, corridorPoints: nil, visitedWaypointIDs: [],
            lastRouteProgress: 0.1, status: .active,
            createdAt: createdAt, updatedAt: createdAt
        )
        let original = try XCTUnwrap(RouteCalculationConstraintSnapshot(lock))

        lock.lastRouteProgress = 0.8
        lock.updatedAt = createdAt.addingTimeInterval(60)
        XCTAssertEqual(RouteCalculationConstraintSnapshot(lock), original)

        lock.waypoints[0].optionsAfter = .init(avoidTolls: false, avoidHighways: false)
        XCTAssertNotEqual(RouteCalculationConstraintSnapshot(lock), original)
        lock.waypoints[0].optionsAfter = .init(avoidTolls: true, avoidHighways: true)
        lock.visitedWaypointIDs = ["pass"]
        XCTAssertNotEqual(RouteCalculationConstraintSnapshot(lock), original)
    }

    func testStopSelectionSurvivesLossOfTransientStationState() {
        let lockedFuel = LockedWaypoint(
            id: "fuel-1", name: "Autohof",
            coordinate: .init(latitude: 50, longitude: 8),
            required: true, optionsAfter: nil, kind: .fuelStop
        )
        XCTAssertTrue(RouteStopSelectionPolicy.contains(
            stopID: "fuel-1", transientStationIDs: [], lockedWaypoints: [lockedFuel]
        ))
        XCTAssertTrue(RouteStopSelectionPolicy.contains(
            stopID: "fuel-1", transientStationIDs: ["fuel-1"], lockedWaypoints: []
        ))
        XCTAssertFalse(RouteStopSelectionPolicy.contains(
            stopID: "fuel-1", transientStationIDs: [], lockedWaypoints: [
                .init(id: "fuel-1", name: "Pflichtpunkt",
                      coordinate: .init(latitude: 50, longitude: 8),
                      required: true, optionsAfter: nil, kind: .routeConstraint)
            ]
        ), "A mandatory corridor anchor must never become a removable fuel stop")
    }

    func testCompletedLockedStationCannotReturnFromTransientState() {
        XCTAssertEqual(RouteWaypointRoutingPolicy.source(
            hasActiveLock: true,
            remainingLockedWaypointCount: 0,
            transientStationCount: 1
        ), .direct)
    }

    func testUnlockedStationStillCreatesMultiLegRoute() {
        XCTAssertEqual(RouteWaypointRoutingPolicy.source(
            hasActiveLock: false,
            remainingLockedWaypointCount: 0,
            transientStationCount: 1
        ), .transientStations)
    }

    func testFreshPublicInstallationHasNoPersonalRouteLock() {
        let suite = "FreshPublicRouteLock-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertNil(RouteLockStore(defaults: defaults).activeLock)
    }

    func testPersistedProgressDisambiguatesLaterVisitAtRouteCrossing() throws {
        let corridor = [
            DriveCoordinate(latitude: 50.0, longitude: 8.0),
            DriveCoordinate(latitude: 50.0, longitude: 8.1),
            DriveCoordinate(latitude: 50.1, longitude: 8.1),
            DriveCoordinate(latitude: 50.0, longitude: 8.1),
            DriveCoordinate(latitude: 50.0, longitude: 8.2),
        ]
        let crossing = DriveCoordinate(latitude: 50.0, longitude: 8.1)
        let early = try XCTUnwrap(RouteCorridorRestorePolicy.forwardNearBestMatch(
            for: crossing, in: corridor, previousProgress: nil
        ))
        let late = try XCTUnwrap(RouteCorridorRestorePolicy.forwardNearBestMatch(
            for: crossing, in: corridor, previousProgress: 0.7
        ))

        XCTAssertEqual(early.index, 1)
        XCTAssertEqual(late.index, 3)
    }

    func testOfflineRouteFileStoreRoundTripsAndClearsAtomically() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("KiesDriveOfflineCacheTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = OfflineRouteCacheStore(fileURL: directory.appendingPathComponent("route.json"))
        let route = CachedRoute(
            destinationName: "Hochheim",
            tripID: UUID(),
            destinationCoordinate: .init(latitude: 50.01, longitude: 8.35),
            legs: [.init(
                distance: 12_000, travelTime: 900,
                steps: [.init(instructions: "Rechts abbiegen", distance: 300,
                              coordinates: [.init(latitude: 50, longitude: 8),
                                            .init(latitude: 50.01, longitude: 8.1)])],
                coordinates: [.init(latitude: 50, longitude: 8),
                              .init(latitude: 50.01, longitude: 8.1)]
            )],
            stations: [], savedAt: Date(timeIntervalSince1970: 1_000),
            navigationProgress: 0.42
        )

        XCTAssertTrue(store.save(route))
        XCTAssertEqual(store.load()?.destinationName, "Hochheim")
        XCTAssertEqual(store.load()?.tripID, route.tripID)
        XCTAssertEqual(store.load()?.legs.first?.steps.first?.instructions, "Rechts abbiegen")
        XCTAssertEqual(store.load()?.navigationProgress, 0.42)
        store.clear()
        XCTAssertNil(store.load())
    }

    func testOfflineProgressIsMonotonicAndGeometrySpecific() {
        let route = CachedRoute(
            destinationName: "Home", destinationCoordinate: nil,
            legs: [], stations: [], savedAt: Date(), navigationProgress: 0.6
        )

        XCTAssertEqual(route.updatingNavigationProgress(0.4).navigationProgress, 0.6)
        XCTAssertEqual(route.updatingNavigationProgress(0.75).navigationProgress, 0.75)
        XCTAssertEqual(route.updatingNavigationProgress(2).navigationProgress, 1)
    }

    func testOfflineCacheProgressIsRetainedOnlyForSameTrip() {
        let tripID = UUID()
        let route = CachedRoute(
            destinationName: "Ziel", tripID: tripID,
            destinationCoordinate: .init(latitude: 50, longitude: 8),
            legs: [], stations: [], savedAt: Date(), navigationProgress: 0.62
        )

        XCTAssertEqual(OfflineRouteCacheWritePolicy.retainedProgress(
            existing: route, currentTripID: tripID, preservingProgress: true
        ), 0.62)
        XCTAssertNil(OfflineRouteCacheWritePolicy.retainedProgress(
            existing: route, currentTripID: UUID(), preservingProgress: true
        ))
        XCTAssertNil(OfflineRouteCacheWritePolicy.retainedProgress(
            existing: route, currentTripID: tripID, preservingProgress: false
        ))
    }

    func testOfflineRouteIdentityRequiresExactActiveTrip() {
        let tripID = UUID()
        XCTAssertTrue(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: tripID, activeTripID: tripID, active: true
        ))
        XCTAssertFalse(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: nil, activeTripID: tripID, active: true
        ), "A preview cache must be rebound after the trip lock is persisted")
        XCTAssertFalse(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: tripID, activeTripID: UUID(), active: true
        ))
        XCTAssertFalse(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: tripID, activeTripID: tripID, active: false
        ))
    }

    func testRouteLockTransactionCanRestoreEmptySnapshot() {
        let suite = "RouteLockTransaction-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RouteLockStore(defaults: defaults)
        store.save(.croatiaSplit())
        XCTAssertNotNil(store.activeLock)

        store.replace(with: nil)

        XCTAssertNil(store.activeLock)
        XCTAssertNil(RouteLockStore(defaults: defaults).activeLock)
    }

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
            progress: { $0.longitude }
        )

        XCTAssertEqual(lock.waypoints.map(\.id), ["first", "fuel", "last"])
        XCTAssertEqual(lock.waypoints[1].optionsAfter, avoidMotorway)
        XCTAssertFalse(lock.visitedWaypointIDs?.contains("fuel") == true)
        lock.removeWaypoint(id: "fuel")
        XCTAssertEqual(lock.waypoints.map(\.id), ["first", "last"])
    }

    func testKnownRouteProgressDisambiguatesStopAtRouteCrossing() {
        let now = Date(timeIntervalSince1970: 1)
        var lock = ActiveRouteLock(
            id: UUID(), title: "Trip", destinationName: "Home",
            destination: .init(latitude: 0, longitude: 100),
            waypoints: [
                .init(id: "first", name: "First", coordinate: .init(latitude: 0, longitude: 20),
                      required: true, optionsAfter: nil),
                .init(id: "last", name: "Last", coordinate: .init(latitude: 0, longitude: 80),
                      required: true, optionsAfter: nil),
            ],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 5_000, corridorPoints: nil, visitedWaypointIDs: [],
            status: .active, createdAt: now, updatedAt: now
        )
        lock.insertWaypoint(
            .init(id: "poi", name: "POI", coordinate: .init(latitude: 0, longitude: 20),
                  required: true, optionsAfter: nil),
            knownProgress: 0.5,
            progress: { $0.longitude / 100 }
        )

        XCTAssertEqual(lock.waypoints.map(\.id), ["first", "poi", "last"])
    }

    func testKnownProgressAlsoOrdersFuelAndBreakStopsAtCrossing() {
        let now = Date(timeIntervalSince1970: 1)
        var lock = ActiveRouteLock(
            id: UUID(), title: "Trip", destinationName: "Home",
            destination: .init(latitude: 0, longitude: 100),
            waypoints: [
                .init(id: "early", name: "Early", coordinate: .init(latitude: 0, longitude: 20),
                      required: true, optionsAfter: nil),
                .init(id: "late", name: "Late", coordinate: .init(latitude: 0, longitude: 80),
                      required: true, optionsAfter: nil),
            ],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 5_000, corridorPoints: nil, visitedWaypointIDs: [],
            status: .active, createdAt: now, updatedAt: now
        )
        lock.insertWaypoint(
            .init(id: "fuel", name: "Fuel", coordinate: .init(latitude: 0, longitude: 20),
                  required: true, optionsAfter: nil, kind: .fuelStop),
            knownProgress: 0.55,
            progress: { $0.longitude / 100 }
        )
        lock.insertWaypoint(
            .init(id: "break", name: "Break", coordinate: .init(latitude: 0, longitude: 20),
                  required: true, optionsAfter: nil, kind: .userStop),
            knownProgress: 0.65,
            progress: { $0.longitude / 100 }
        )

        XCTAssertEqual(lock.waypoints.map(\.id), ["early", "fuel", "break", "late"])
    }

    func testEquivalentRouteStopDetectionHandlesSearchDriftWithoutBlockingNearbyPlaces() {
        let now = Date(timeIntervalSince1970: 1)
        let lock = ActiveRouteLock(
            id: UUID(), title: "Trip", destinationName: "Home",
            destination: .init(latitude: 50, longitude: 8.5),
            waypoints: [.init(
                id: "poi-1", name: "Café Central",
                coordinate: .init(latitude: 50, longitude: 8),
                required: true, optionsAfter: nil
            )],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 5_000, corridorPoints: nil, visitedWaypointIDs: [],
            status: .active, createdAt: now, updatedAt: now
        )

        XCTAssertTrue(lock.containsEquivalentStop(
            name: "CAFE CENTRAL", coordinate: .init(latitude: 50.0003, longitude: 8)
        ))
        XCTAssertFalse(lock.containsEquivalentStop(
            name: "Tankstelle nebenan", coordinate: .init(latitude: 50.0003, longitude: 8)
        ))
        XCTAssertTrue(lock.containsEquivalentStop(
            name: "Anderer Kartenname", coordinate: .init(latitude: 50.00005, longitude: 8)
        ))
    }

    func testOnlyRouteConstraintsBecomeTollEvidenceAnchors() throws {
        let constraint = LockedWaypoint(
            id: "pass", name: "Wurzenpass", coordinate: .init(latitude: 46.5, longitude: 13.7),
            required: true, optionsAfter: nil, kind: .routeConstraint
        )
        let restaurant = LockedWaypoint(
            id: "poi-1", name: "McDonald’s", coordinate: .init(latitude: 47, longitude: 13),
            required: true, optionsAfter: nil, kind: .userStop
        )
        let fuel = LockedWaypoint(
            id: "fuel-1", name: "Tankstelle", coordinate: .init(latitude: 48, longitude: 12),
            required: true, optionsAfter: nil, kind: .fuelStop
        )

        XCTAssertTrue(constraint.isTollEvidenceAnchor)
        XCTAssertFalse(restaurant.isTollEvidenceAnchor)
        XCTAssertFalse(fuel.isTollEvidenceAnchor)
        XCTAssertFalse(constraint.isRemovableComfortStop)
        XCTAssertTrue(restaurant.isRemovableComfortStop)
        XCTAssertTrue(fuel.isRemovableComfortStop)

        // A lock written before the kind field existed must still decode and
        // retain its historic meaning as a mandatory route constraint.
        let legacy = """
        {"id":"legacy","name":"Grenze","coordinate":{"latitude":46,"longitude":15},"required":true,"optionsAfter":null}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LockedWaypoint.self, from: legacy)
        XCTAssertNil(decoded.kind)
        XCTAssertTrue(decoded.isTollEvidenceAnchor)
    }

    func testWaypointVisitRequiresNextPointAndRoadLevelProximity() {
        let waypoints = [
            LockedWaypoint(id: "first", name: "First",
                           coordinate: .init(latitude: 50, longitude: 8), required: true,
                           optionsAfter: nil),
            LockedWaypoint(id: "later", name: "Later",
                           coordinate: .init(latitude: 51, longitude: 9), required: true,
                           optionsAfter: nil),
        ]
        let besideLaterPoint = CLLocation(
            coordinate: .init(latitude: 51, longitude: 9), altitude: 0,
            horizontalAccuracy: 8, verticalAccuracy: 5, timestamp: Date()
        )
        XCTAssertNil(RouteWaypointVisitPolicy.reachedWaypointID(
            waypoints: waypoints, visitedIDs: [], location: besideLaterPoint
        ))

        let besideParallelRoad = CLLocation(
            coordinate: .init(latitude: 50.0015, longitude: 8), altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: 5, timestamp: Date()
        )
        XCTAssertNil(RouteWaypointVisitPolicy.reachedWaypointID(
            waypoints: waypoints, visitedIDs: [], location: besideParallelRoad
        ))

        let onRequiredRoad = CLLocation(
            coordinate: .init(latitude: 50.0003, longitude: 8), altitude: 0,
            horizontalAccuracy: 10, verticalAccuracy: 5, timestamp: Date()
        )
        XCTAssertEqual(RouteWaypointVisitPolicy.reachedWaypointID(
            waypoints: waypoints, visitedIDs: [], location: onRequiredRoad
        ), "first")
    }

    func testWaypointVisitRejectsCrossingRoadWithOppositeCourse() {
        let waypoints = [
            LockedWaypoint(id: "motorway", name: "Autobahn-Punkt",
                           coordinate: .init(latitude: 50, longitude: 8), required: true,
                           optionsAfter: nil)
        ]
        let wrongRoad = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 6, verticalAccuracy: 5,
            course: 180, speed: 20, timestamp: Date()
        )
        let matchingRoad = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 6, verticalAccuracy: 5,
            course: 5, speed: 20, timestamp: Date()
        )

        XCTAssertNil(RouteWaypointVisitPolicy.reachedWaypointID(
            waypoints: waypoints, visitedIDs: [], location: wrongRoad,
            expectedCourseDegrees: 0
        ))
        XCTAssertEqual(RouteWaypointVisitPolicy.reachedWaypointID(
            waypoints: waypoints, visitedIDs: [], location: matchingRoad,
            expectedCourseDegrees: 0
        ), "motorway")
    }

    func testDriveThroughConstraintNeedsCourseButParkedStopDoesNot() {
        let stopped = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 6, verticalAccuracy: 5,
            course: -1, speed: 0, timestamp: Date()
        )
        let constraint = LockedWaypoint(
            id: "bridge", name: "Brückenpunkt",
            coordinate: .init(latitude: 50, longitude: 8), required: true,
            optionsAfter: nil, kind: .routeConstraint
        )
        let fuel = LockedWaypoint(
            id: "fuel", name: "Tankstelle",
            coordinate: .init(latitude: 50, longitude: 8), required: true,
            optionsAfter: nil, kind: .fuelStop
        )

        XCTAssertNil(RouteWaypointVisitPolicy.reachedWaypointID(
            waypoints: [constraint], visitedIDs: [], location: stopped,
            expectedCourseDegrees: 0
        ))
        XCTAssertEqual(RouteWaypointVisitPolicy.reachedWaypointID(
            waypoints: [fuel], visitedIDs: [], location: stopped,
            expectedCourseDegrees: 0
        ), "fuel")
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

    func testCurrentSegmentKeepsOptionsFromLastVisitedMandatoryPoint() {
        let lock = ActiveRouteLock.croatiaSplit(now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(RouteWaypointOptionsPolicy.currentOptions(
            defaultOptions: lock.defaultOptions,
            waypoints: lock.waypoints,
            visitedIDs: ["sentilj"]
        ), .init(avoidTolls: true, avoidHighways: true))

        XCTAssertEqual(RouteWaypointOptionsPolicy.currentOptions(
            defaultOptions: lock.defaultOptions,
            waypoints: lock.waypoints,
            visitedIDs: ["sentilj", "macelj"]
        ), .init(avoidTolls: false, avoidHighways: false))
    }

    func testCurrentSegmentDoesNotApplyOutOfOrderWaypointOptions() {
        let lock = ActiveRouteLock.croatiaSplit(now: Date(timeIntervalSince1970: 1))

        XCTAssertEqual(RouteWaypointOptionsPolicy.currentOptions(
            defaultOptions: lock.defaultOptions,
            waypoints: lock.waypoints,
            visitedIDs: ["macelj"]
        ), lock.defaultOptions)
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

    func testCorruptPrimaryRecoversPreviousActiveTripCheckpoint() throws {
        let suite = "RoutePersistenceRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RouteLockStore(defaults: defaults)
        var lock = ActiveRouteLock.croatiaSplit(now: Date(timeIntervalSince1970: 1))
        store.save(lock)
        lock.title = "Aktualisierter Titel"
        store.save(lock)
        defaults.set(Data("not-json".utf8), forKey: "drive.activeRouteLock.v1")

        let recovered = RouteLockStore(defaults: defaults).activeLock

        XCTAssertEqual(recovered?.id, lock.id)
        XCTAssertEqual(recovered?.title, "Kroatien")
        XCTAssertEqual(recovered?.waypoints.count, 2)
    }

    func testSemanticallyInvalidPrimaryRecoversValidCheckpoint() throws {
        let suite = "RoutePersistenceSemanticRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RouteLockStore(defaults: defaults)
        var lock = ActiveRouteLock.croatiaSplit(now: Date(timeIntervalSince1970: 1))
        store.save(lock)
        lock.title = "Valid checkpoint"
        store.save(lock)
        lock.destination = .init(latitude: 143, longitude: 16.44)
        defaults.set(try JSONEncoder().encode(lock), forKey: "drive.activeRouteLock.v1")

        let recovered = RouteLockStore(defaults: defaults).activeLock

        XCTAssertEqual(recovered?.id, lock.id)
        XCTAssertEqual(try XCTUnwrap(recovered?.destination.latitude), 43.5081, accuracy: 0.0001)
    }

    func testRouteLockValidationRejectsAmbiguousWaypointIdentityAndProgress() {
        var lock = ActiveRouteLock.croatiaSplit(now: Date(timeIntervalSince1970: 1))
        XCTAssertTrue(ActiveRouteLockValidationPolicy.isValid(lock))

        lock.waypoints[1] = LockedWaypoint(
            id: lock.waypoints[0].id, name: "Duplikat",
            coordinate: lock.waypoints[1].coordinate, required: true,
            optionsAfter: nil, kind: .routeConstraint
        )
        XCTAssertFalse(ActiveRouteLockValidationPolicy.isValid(lock))

        lock = ActiveRouteLock.croatiaSplit(now: Date(timeIntervalSince1970: 1))
        lock.lastRouteProgress = 1.1
        XCTAssertFalse(ActiveRouteLockValidationPolicy.isValid(lock))
    }

    func testCompletedTripNeverFallsBackToActiveCheckpoint() throws {
        let suite = "RoutePersistenceCompletedRecovery.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = RouteLockStore(defaults: defaults)
        var lock = ActiveRouteLock.croatiaSplit(now: Date(timeIntervalSince1970: 1))
        store.save(lock)
        lock.title = "Checkpoint"
        store.save(lock)
        store.finish()

        XCTAssertNil(RouteLockStore(defaults: defaults).activeLock)
        XCTAssertNil(defaults.data(forKey: "drive.activeRouteLock.v1.backup"))
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

    func testRestoreNeverAutoCompletesRealStopsAlreadyBehindCurrentPosition() {
        let lock = ActiveRouteLock(
            id: UUID(), title: "Nordfahrt", destinationName: "Ziel",
            destination: .init(latitude: 5, longitude: 0),
            waypoints: [
                .init(id: "constraint", name: "Passstraße",
                      coordinate: .init(latitude: 1, longitude: 0), required: true,
                      optionsAfter: nil, kind: .routeConstraint),
                .init(id: "food", name: "Restaurant",
                      coordinate: .init(latitude: 1.2, longitude: 0), required: true,
                      optionsAfter: nil, kind: .userStop),
                .init(id: "fuel", name: "Tankstelle",
                      coordinate: .init(latitude: 1.4, longitude: 0), required: true,
                      optionsAfter: nil, kind: .fuelStop),
            ],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 8_000,
            corridorPoints: (0...5).map { .init(latitude: Double($0), longitude: 0) },
            visitedWaypointIDs: [], status: .active, createdAt: Date(), updatedAt: Date()
        )

        XCTAssertEqual(
            lock.passedWaypointIDs(at: .init(latitude: 2.1, longitude: 0)),
            ["constraint"]
        )
    }

    func testMissedRealStopKeepsEveryLaterRouteConstraintMandatory() {
        let lock = ActiveRouteLock(
            id: UUID(), title: "Nordfahrt", destinationName: "Ziel",
            destination: .init(latitude: 5, longitude: 0),
            waypoints: [
                .init(id: "first-pass", name: "Erster Pass",
                      coordinate: .init(latitude: 1, longitude: 0), required: true,
                      optionsAfter: nil, kind: .routeConstraint),
                .init(id: "food", name: "Restaurant",
                      coordinate: .init(latitude: 2, longitude: 0), required: true,
                      optionsAfter: nil, kind: .userStop),
                .init(id: "second-pass", name: "Zweiter Pass",
                      coordinate: .init(latitude: 3, longitude: 0), required: true,
                      optionsAfter: .init(avoidTolls: false, avoidHighways: true),
                      kind: .routeConstraint),
            ],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 8_000,
            corridorPoints: (0...5).map { .init(latitude: Double($0), longitude: 0) },
            visitedWaypointIDs: [], status: .active,
            createdAt: Date(), updatedAt: Date()
        )

        XCTAssertEqual(
            lock.passedWaypointIDs(at: .init(latitude: 4.1, longitude: 0)),
            ["first-pass"],
            "Returning to a missed real stop must not remove later road constraints"
        )
    }

    func testRestoreDoesNotSkipWaypointAtAmbiguousRouteCrossing() {
        let now = Date(timeIntervalSince1970: 1)
        let crossingRoute = [
            DriveCoordinate(latitude: 50.0000, longitude: 8.0000),
            DriveCoordinate(latitude: 50.0000, longitude: 8.0100),
            DriveCoordinate(latitude: 50.0100, longitude: 8.0100),
            DriveCoordinate(latitude: 50.0100, longitude: 8.0000),
            DriveCoordinate(latitude: 50.0000, longitude: 8.0000),
            DriveCoordinate(latitude: 50.0000, longitude: 7.9900),
        ]
        let lock = ActiveRouteLock(
            id: UUID(), title: "Crossing", destinationName: "Home",
            destination: .init(latitude: 50, longitude: 7.99),
            waypoints: [.init(id: "required", name: "Required",
                              coordinate: crossingRoute[2], required: true, optionsAfter: nil)],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 2_000, corridorPoints: crossingRoute,
            visitedWaypointIDs: [], status: .active, createdAt: now, updatedAt: now
        )

        XCTAssertTrue(lock.passedWaypointIDs(at: crossingRoute[0]).isEmpty)
        XCTAssertEqual(RouteCorridorRestorePolicy.earliestNearBestMatch(
            for: crossingRoute[0], in: crossingRoute
        )?.index, 0)
    }

    func testCommittedWaypointProgressIsStableAndDeduplicated() {
        XCTAssertEqual(
            RouteWaypointProgressPolicy.merging(
                existing: ["first", "second"], newlyPassed: ["second", "fourth", "third"]
            ),
            ["first", "second", "fourth", "third"]
        )
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
        XCTAssertNil(cache.tripID)
        XCTAssertNil(cache.legs.first?.coordinates)
        XCTAssertNil(cache.legs.first?.steps.first?.coordinates)
    }
}
