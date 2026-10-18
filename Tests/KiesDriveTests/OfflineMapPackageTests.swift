import XCTest
import CoreLocation
@testable import Kies_Drive

@MainActor
final class OfflineMapPackageTests: XCTestCase {
    func testOfflineOverviewDoesNotOverrideManualZoomOnEveryUpdate() {
        XCTAssertTrue(OfflineMapCameraPolicy.shouldFitOverview(
            showsOverview: true, showedOverviewPreviously: false, routeGeometryChanged: false
        ))
        XCTAssertFalse(OfflineMapCameraPolicy.shouldFitOverview(
            showsOverview: true, showedOverviewPreviously: true, routeGeometryChanged: false
        ))
        XCTAssertTrue(OfflineMapCameraPolicy.shouldFitOverview(
            showsOverview: true, showedOverviewPreviously: true, routeGeometryChanged: true
        ))
        XCTAssertFalse(OfflineMapCameraPolicy.shouldFitOverview(
            showsOverview: false, showedOverviewPreviously: true, routeGeometryChanged: true
        ))
    }

    private var root: URL!
    private var source: URL!
    private var defaults: UserDefaults!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        source = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defaults = try XCTUnwrap(UserDefaults(suiteName: "OfflineMapPackageTests.\(UUID().uuidString)"))
        try FileManager.default.createDirectory(at: source.appendingPathComponent("tiles/8/136"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: source)
    }

    func testInstallActivateResolveAndRemovePackage() throws {
        try writeManifest(id: "alpen-2026")
        let tile = source.appendingPathComponent("tiles/8/136/89.png")
        try validPNG().write(to: tile)
        let store = OfflineMapPackageStore(rootURL: root, defaults: defaults)

        let installed = try store.install(from: source)

        XCTAssertEqual(installed.manifest.name, "Alpen")
        XCTAssertEqual(store.activePackageID, "alpen-2026")
        XCTAssertNotNil(store.tileURL(z: 8, x: 136, y: 89, package: installed))
        XCTAssertNil(store.tileURL(z: 7, x: 136, y: 89, package: installed))
        XCTAssertGreaterThan(installed.byteCount, 3)
        try store.remove(installed)
        XCTAssertTrue(store.packages.isEmpty)
        XCTAssertNil(store.activePackageID)
    }

    func testRejectsUnsafeIdentifierAndMissingTiles() throws {
        try writeManifest(id: "../escape")
        XCTAssertThrowsError(try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source))

        try FileManager.default.removeItem(at: source.appendingPathComponent("tiles"))
        try writeManifest(id: "safe")
        XCTAssertThrowsError(try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source))
    }

    func testRejectsEmptyCorruptAndOutOfRangeTilePackages() throws {
        try writeManifest(id: "empty")
        XCTAssertThrowsError(try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source))

        try Data([1, 2, 3]).write(to: source.appendingPathComponent("tiles/8/136/89.png"))
        XCTAssertThrowsError(try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source))

        try FileManager.default.createDirectory(at: source.appendingPathComponent("tiles/7/66"),
                                                withIntermediateDirectories: true)
        try validPNG().write(to: source.appendingPathComponent("tiles/7/66/43.png"))
        XCTAssertThrowsError(try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source))
    }

    func testRejectsTileOutsideDeclaredGeographicBounds() throws {
        try writeManifest(id: "wrong-region")
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("tiles/8/132"), withIntermediateDirectories: true
        )
        try validPNG().write(to: source.appendingPathComponent("tiles/8/132/87.png"))

        XCTAssertThrowsError(
            try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source)
        )
    }

    func testRejectsPngSignatureWithoutDecodableImage() throws {
        try writeManifest(id: "broken-png")
        let signatureOnly = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 1, 2, 3, 4])
        try signatureOnly.write(to: source.appendingPathComponent("tiles/8/136/89.png"))

        XCTAssertThrowsError(
            try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source)
        )
    }

    func testRejectsPackageWhenAnyTileIsCorrupt() throws {
        try writeManifest(id: "partly-broken")
        try validPNG().write(to: source.appendingPathComponent("tiles/8/136/89.png"))
        try FileManager.default.createDirectory(
            at: source.appendingPathComponent("tiles/8/135"), withIntermediateDirectories: true
        )
        try Data([1, 2, 3]).write(to: source.appendingPathComponent("tiles/8/135/89.png"))

        XCTAssertThrowsError(
            try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source)
        )
        XCTAssertTrue((try FileManager.default.contentsOfDirectory(atPath: root.path)).isEmpty)
    }

    func testSuccessfulImportLeavesNoStagingDirectory() throws {
        try writeManifest(id: "atomic-map")
        try validPNG().write(to: source.appendingPathComponent("tiles/8/136/89.png"))

        _ = try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source)

        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: root.path), ["atomic-map"])
    }

    func testCoverageFallsBackOutsidePackageAndForIncompleteOverview() {
        let bounds = OfflineMapBounds(north: 48, south: 45, east: 17, west: 8)
        XCTAssertTrue(OfflineMapCoveragePolicy.canUse(
            bounds: bounds,
            currentCoordinate: .init(latitude: 47, longitude: 12),
            routeCoordinates: [], showsRouteOverview: false
        ))
        XCTAssertEqual(OfflineMapCoveragePolicy.state(
            bounds: bounds, currentCoordinate: nil,
            routeCoordinates: [], showsRouteOverview: false
        ), .awaitingLocation)
        XCTAssertEqual(OfflineMapCoveragePolicy.state(
            bounds: bounds, currentCoordinate: .init(latitude: 50, longitude: 8.3),
            routeCoordinates: [], showsRouteOverview: false
        ), .currentLocationOutsideBounds)
        XCTAssertEqual(OfflineMapCoveragePolicy.state(
            bounds: bounds, currentCoordinate: .init(latitude: 47, longitude: 12),
            routeCoordinates: [.init(latitude: 50, longitude: 8.3)],
            showsRouteOverview: true
        ), .routeOutsideBounds)
        XCTAssertFalse(OfflineMapCoveragePolicy.canUse(
            bounds: bounds,
            currentCoordinate: .init(latitude: 50, longitude: 8.3),
            routeCoordinates: [], showsRouteOverview: false
        ))
        XCTAssertFalse(OfflineMapCoveragePolicy.canUse(
            bounds: bounds,
            currentCoordinate: .init(latitude: 47, longitude: 12),
            routeCoordinates: [
                .init(latitude: 47, longitude: 12),
                .init(latitude: 50, longitude: 8.3),
            ], showsRouteOverview: true
        ))
        XCTAssertFalse(OfflineMapCoveragePolicy.canUse(
            bounds: bounds,
            currentCoordinate: nil,
            routeCoordinates: [
                .init(latitude: 47, longitude: 12),
                .init(latitude: 50, longitude: 8.3),
            ], showsRouteOverview: false
        ), "Before the first GPS fix an incompletely covered restored route must use the normal map")
        XCTAssertTrue(OfflineMapCoveragePolicy.canUse(
            bounds: bounds,
            currentCoordinate: nil,
            routeCoordinates: [
                .init(latitude: 47, longitude: 12),
                .init(latitude: 46, longitude: 13),
            ], showsRouteOverview: false
        ))
    }

    func testXYZTileCoordinatesStayInsideZoomGrid() {
        XCTAssertTrue(OfflineTileCoordinatePolicy.isValid(z: 8, x: 132, y: 87))
        XCTAssertTrue(OfflineTileCoordinatePolicy.isValid(z: 0, x: 0, y: 0))
        XCTAssertFalse(OfflineTileCoordinatePolicy.isValid(z: 8, x: 256, y: 87))
        XCTAssertFalse(OfflineTileCoordinatePolicy.isValid(z: 8, x: 132, y: 256))
        XCTAssertFalse(OfflineTileCoordinatePolicy.isValid(z: 8, x: -1, y: 87))
        XCTAssertFalse(OfflineTileCoordinatePolicy.isValid(z: 23, x: 0, y: 0))
        let centre = OfflineTileCoordinatePolicy.center(z: 8, x: 136, y: 89)
        XCTAssertEqual(centre?.latitude ?? 0, 47.5, accuracy: 1)
        XCTAssertEqual(centre?.longitude ?? 0, 11.95, accuracy: 0.1)
        XCTAssertEqual(
            OfflineTileCoordinatePolicy.tile(
                containing: .init(latitude: 47.5, longitude: 11.95), zoom: 8
            ),
            .init(z: 8, x: 136, y: 89)
        )
        XCTAssertNil(OfflineTileCoordinatePolicy.tile(
            containing: .init(latitude: 95, longitude: 11.95), zoom: 8
        ))
    }

    func testOfflineLookaheadStartsAtCarAndOnlySamplesRouteAhead() {
        let route = (0...12).map {
            CLLocationCoordinate2D(latitude: 50, longitude: 8 + Double($0) * 0.01)
        }
        let current = CLLocationCoordinate2D(latitude: 50, longitude: 8.052)

        let lookahead = OfflineRouteLookaheadPolicy.coordinates(
            from: current, route: route, lookaheadMetres: 4_000, intervalMetres: 1_000
        )

        XCTAssertEqual(lookahead.first?.latitude, current.latitude)
        XCTAssertEqual(lookahead.first?.longitude, current.longitude)
        XCTAssertTrue(lookahead.dropFirst().allSatisfy { $0.longitude >= 8.05 })
        XCTAssertTrue(lookahead.count <= 6)
    }

    func testOfflineLookaheadWithoutRouteStillChecksCurrentTile() {
        let current = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        let lookahead = OfflineRouteLookaheadPolicy.coordinates(from: current, route: [])
        XCTAssertEqual(lookahead.count, 1)
        XCTAssertEqual(lookahead[0].latitude, current.latitude)
        XCTAssertEqual(lookahead[0].longitude, current.longitude)
    }

    func testOfflineLookaheadUsesInstalledProgressAtRouteCrossing() {
        // The route visits the same coordinate near its beginning and near its
        // end. Spatial matching alone selects the first occurrence and checks
        // tiles behind the car; installed progress must select the later arm.
        let route = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8.00),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.01),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.02),
            CLLocationCoordinate2D(latitude: 50.01, longitude: 8.02),
            CLLocationCoordinate2D(latitude: 50.02, longitude: 8.02),
            CLLocationCoordinate2D(latitude: 50.02, longitude: 8.01),
            CLLocationCoordinate2D(latitude: 50.02, longitude: 8.00),
            CLLocationCoordinate2D(latitude: 50.01, longitude: 8.00),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.00),
            CLLocationCoordinate2D(latitude: 49.99, longitude: 8.00),
        ]
        let current = CLLocationCoordinate2D(latitude: 50, longitude: 8.00)

        let unbound = OfflineRouteLookaheadPolicy.coordinates(
            from: current, route: route, lookaheadMetres: 4_000, intervalMetres: 500
        )
        let bound = OfflineRouteLookaheadPolicy.coordinates(
            from: current, route: route, routeProgress: 0.9,
            lookaheadMetres: 4_000, intervalMetres: 500
        )

        XCTAssertTrue(unbound.dropFirst().contains { $0.longitude > 8.005 })
        XCTAssertTrue(bound.dropFirst().allSatisfy { $0.longitude <= 8.000_001 })
        XCTAssertTrue(bound.dropFirst().contains { $0.latitude < 50 })
    }

    func testOfflineLookaheadIgnoresInvalidProgress() {
        let route = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.02),
        ]
        let current = route[0]
        let invalid = OfflineRouteLookaheadPolicy.coordinates(
            from: current, route: route, routeProgress: .nan
        )
        let baseline = OfflineRouteLookaheadPolicy.coordinates(from: current, route: route)
        XCTAssertEqual(invalid.count, baseline.count)
        for (lhs, rhs) in zip(invalid, baseline) {
            XCTAssertEqual(lhs.latitude, rhs.latitude, accuracy: 0.000_001)
            XCTAssertEqual(lhs.longitude, rhs.longitude, accuracy: 0.000_001)
        }
    }

    func testRuntimeCoverageRequiresRealBaseTiles() throws {
        try writeManifest(id: "runtime-coverage")
        try validPNG().write(to: source.appendingPathComponent("tiles/8/136/89.png"))
        let store = OfflineMapPackageStore(rootURL: root, defaults: defaults)
        let package = try store.install(from: source)

        XCTAssertTrue(store.hasBaseTiles(
            covering: [.init(latitude: 47.5, longitude: 11.95)], package: package
        ))
        XCTAssertFalse(store.hasBaseTiles(
            covering: [
                .init(latitude: 47.5, longitude: 11.95),
                .init(latitude: 47.5, longitude: 13.5),
            ],
            package: package
        ))
        XCTAssertFalse(store.hasBaseTiles(covering: [], package: package))
    }

    func testDrivingCoverageRequiresStreetLevelNeighbourhood() throws {
        try writeManifest(id: "driving-coverage")
        try validPNG().write(to: source.appendingPathComponent("tiles/8/136/89.png"))
        let coordinate = CLLocationCoordinate2D(latitude: 47.5, longitude: 11.95)
        let navigationTiles = OfflineTileCoordinatePolicy.neighbourhood(
            containing: coordinate, zoom: 14
        )
        XCTAssertEqual(navigationTiles.count, 9)
        for tile in navigationTiles {
            let directory = source.appendingPathComponent(
                "tiles/\(tile.z)/\(tile.x)", isDirectory: true
            )
            try FileManager.default.createDirectory(
                at: directory, withIntermediateDirectories: true
            )
            try validPNG().write(to: directory.appendingPathComponent("\(tile.y).png"))
        }
        let store = OfflineMapPackageStore(rootURL: root, defaults: defaults)
        let package = try store.install(from: source)

        XCTAssertTrue(store.hasNavigationTiles(around: coordinate, package: package))
        let missing = try XCTUnwrap(navigationTiles.first)
        let installedTile = try XCTUnwrap(store.tileURL(
            z: missing.z, x: missing.x, y: missing.y, package: package
        ))
        try FileManager.default.removeItem(at: installedTile)
        let refreshedStore = OfflineMapPackageStore(rootURL: root, defaults: defaults)
        let refreshedPackage = try XCTUnwrap(refreshedStore.activePackage)
        XCTAssertFalse(refreshedStore.hasNavigationTiles(
            around: coordinate, package: refreshedPackage
        ))
    }

    func testRuntimeCoverageCacheExpiresAndDetectsRemovedTile() throws {
        try writeManifest(id: "runtime-expiry")
        try validPNG().write(to: source.appendingPathComponent("tiles/8/136/89.png"))
        var checkTime = Date(timeIntervalSince1970: 1_000)
        let store = OfflineMapPackageStore(
            rootURL: root, defaults: defaults, now: { checkTime }
        )
        let package = try store.install(from: source)
        let coordinate = CLLocationCoordinate2D(latitude: 47.5, longitude: 11.95)

        XCTAssertTrue(store.hasBaseTiles(covering: [coordinate], package: package))
        let installedTile = try XCTUnwrap(store.tileURL(z: 8, x: 136, y: 89, package: package))
        try FileManager.default.removeItem(at: installedTile)
        XCTAssertTrue(store.hasBaseTiles(covering: [coordinate], package: package),
                      "Rapid UI refreshes should reuse the recent disk check")

        checkTime.addTimeInterval(3)
        XCTAssertFalse(store.hasBaseTiles(covering: [coordinate], package: package),
                       "A short expiry keeps fallback responsive to damaged packages")
    }

    func testRuntimeCoverageCacheExpiresAndDetectsCorruptTile() throws {
        try writeManifest(id: "runtime-corruption")
        try validPNG().write(to: source.appendingPathComponent("tiles/8/136/89.png"))
        var checkTime = Date(timeIntervalSince1970: 1_000)
        let store = OfflineMapPackageStore(
            rootURL: root, defaults: defaults, now: { checkTime }
        )
        let package = try store.install(from: source)
        let coordinate = CLLocationCoordinate2D(latitude: 47.5, longitude: 11.95)

        XCTAssertTrue(store.hasBaseTiles(covering: [coordinate], package: package))
        let installedTile = try XCTUnwrap(store.tileURL(z: 8, x: 136, y: 89, package: package))
        try Data(repeating: 0x41, count: 64).write(to: installedTile)
        XCTAssertTrue(store.hasBaseTiles(covering: [coordinate], package: package),
                      "Rapid UI refreshes should reuse the recent disk check")

        checkTime.addTimeInterval(3)
        XCTAssertFalse(store.hasBaseTiles(covering: [coordinate], package: package),
                       "A damaged tile must make the app fall back to the online map")
    }

    func testRuntimeCoverageCacheRechecksDiskAfterClockRollback() throws {
        try writeManifest(id: "runtime-clock-rollback")
        try validPNG().write(to: source.appendingPathComponent("tiles/8/136/89.png"))
        var checkTime = Date(timeIntervalSince1970: 1_000)
        let store = OfflineMapPackageStore(
            rootURL: root, defaults: defaults, now: { checkTime }
        )
        let package = try store.install(from: source)
        let coordinate = CLLocationCoordinate2D(latitude: 47.5, longitude: 11.95)

        XCTAssertTrue(store.hasBaseTiles(covering: [coordinate], package: package))
        let installedTile = try XCTUnwrap(store.tileURL(z: 8, x: 136, y: 89, package: package))
        try FileManager.default.removeItem(at: installedTile)
        checkTime.addTimeInterval(-30)

        XCTAssertFalse(store.hasBaseTiles(covering: [coordinate], package: package),
                       "Clock rollback must invalidate positive tile coverage")
    }

    func testTileResolverRejectsSymlinkEscapingInstalledPackage() throws {
        try writeManifest(id: "alpen-safe")
        let tile = source.appendingPathComponent("tiles/8/136/89.png")
        try validPNG().write(to: tile)
        let store = OfflineMapPackageStore(rootURL: root, defaults: defaults)
        let installed = try store.install(from: source)
        let installedTile = try XCTUnwrap(store.tileURL(z: 8, x: 136, y: 89, package: installed))
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outside) }
        try validPNG().write(to: outside)
        try FileManager.default.removeItem(at: installedTile)
        try FileManager.default.createSymbolicLink(at: installedTile, withDestinationURL: outside)

        XCTAssertNil(store.tileURL(z: 8, x: 136, y: 89, package: installed))
    }

    func testImportRejectsSymlinkedTileRoot() throws {
        try FileManager.default.removeItem(at: source.appendingPathComponent("tiles"))
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-tiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("8/136"), withIntermediateDirectories: true
        )
        try validPNG().write(to: outside.appendingPathComponent("8/136/89.png"))
        try FileManager.default.createSymbolicLink(
            at: source.appendingPathComponent("tiles"), withDestinationURL: outside
        )
        try writeManifest(id: "linked-root")

        XCTAssertThrowsError(
            try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source)
        )
    }

    private func validPNG() -> Data {
        Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mNk+A8AAQUBAScY42YAAAAASUVORK5CYII=")!
    }

    private func writeManifest(id: String) throws {
        let json = """
        {
          "id": "\(id)",
          "name": "Alpen",
          "bounds": {"north": 48.0, "south": 45.0, "east": 17.0, "west": 8.0},
          "minimumZoom": 8,
          "maximumZoom": 16,
          "format": "raster-xyz-v1",
          "attribution": "Eigene Kartendaten",
          "createdAt": "2026-10-13T10:00:00Z"
        }
        """
        try Data(json.utf8).write(to: source.appendingPathComponent("manifest.json"))
    }
}
