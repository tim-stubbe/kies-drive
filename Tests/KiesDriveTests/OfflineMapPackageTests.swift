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
        try FileManager.default.createDirectory(at: source.appendingPathComponent("tiles/8/132"), withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
        try? FileManager.default.removeItem(at: source)
    }

    func testInstallActivateResolveAndRemovePackage() throws {
        try writeManifest(id: "alpen-2026")
        let tile = source.appendingPathComponent("tiles/8/132/87.png")
        try validPNG().write(to: tile)
        let store = OfflineMapPackageStore(rootURL: root, defaults: defaults)

        let installed = try store.install(from: source)

        XCTAssertEqual(installed.manifest.name, "Alpen")
        XCTAssertEqual(store.activePackageID, "alpen-2026")
        XCTAssertNotNil(store.tileURL(z: 8, x: 132, y: 87, package: installed))
        XCTAssertNil(store.tileURL(z: 7, x: 132, y: 87, package: installed))
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

        try Data([1, 2, 3]).write(to: source.appendingPathComponent("tiles/8/132/87.png"))
        XCTAssertThrowsError(try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source))

        try FileManager.default.createDirectory(at: source.appendingPathComponent("tiles/7/66"),
                                                withIntermediateDirectories: true)
        try validPNG().write(to: source.appendingPathComponent("tiles/7/66/43.png"))
        XCTAssertThrowsError(try OfflineMapPackageStore(rootURL: root, defaults: defaults).install(from: source))
    }

    func testCoverageFallsBackOutsidePackageAndForIncompleteOverview() {
        let bounds = OfflineMapBounds(north: 48, south: 45, east: 17, west: 8)
        XCTAssertTrue(OfflineMapCoveragePolicy.canUse(
            bounds: bounds,
            currentCoordinate: .init(latitude: 47, longitude: 12),
            routeCoordinates: [], showsRouteOverview: false
        ))
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
    }

    func testTileResolverRejectsSymlinkEscapingInstalledPackage() throws {
        try writeManifest(id: "alpen-safe")
        let tile = source.appendingPathComponent("tiles/8/132/87.png")
        try validPNG().write(to: tile)
        let store = OfflineMapPackageStore(rootURL: root, defaults: defaults)
        let installed = try store.install(from: source)
        let installedTile = try XCTUnwrap(store.tileURL(z: 8, x: 132, y: 87, package: installed))
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-\(UUID().uuidString).png")
        defer { try? FileManager.default.removeItem(at: outside) }
        try validPNG().write(to: outside)
        try FileManager.default.removeItem(at: installedTile)
        try FileManager.default.createSymbolicLink(at: installedTile, withDestinationURL: outside)

        XCTAssertNil(store.tileURL(z: 8, x: 132, y: 87, package: installed))
    }

    func testImportRejectsSymlinkedTileRoot() throws {
        try FileManager.default.removeItem(at: source.appendingPathComponent("tiles"))
        let outside = FileManager.default.temporaryDirectory
            .appendingPathComponent("outside-tiles-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: outside) }
        try FileManager.default.createDirectory(
            at: outside.appendingPathComponent("8/132"), withIntermediateDirectories: true
        )
        try validPNG().write(to: outside.appendingPathComponent("8/132/87.png"))
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
