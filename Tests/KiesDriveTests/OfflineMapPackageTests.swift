import XCTest
@testable import Kies_Drive

@MainActor
final class OfflineMapPackageTests: XCTestCase {
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
