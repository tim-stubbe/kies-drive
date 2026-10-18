import Foundation
import Combine
import CoreLocation
import ImageIO

struct OfflineMapBounds: Codable, Equatable {
    let north: Double
    let south: Double
    let east: Double
    let west: Double

    var isValid: Bool {
        (-90...90).contains(north) && (-90...90).contains(south) &&
        (-180...180).contains(east) && (-180...180).contains(west) &&
        north > south && east > west
    }

    func contains(_ coordinate: CLLocationCoordinate2D) -> Bool {
        coordinate.latitude <= north && coordinate.latitude >= south &&
        coordinate.longitude <= east && coordinate.longitude >= west
    }
}

enum OfflineMapCoveragePolicy {
    /// Following the car only needs coverage at the current fix. A complete
    /// route overview, however, must not switch to an offline package if any
    /// visible route geometry lies outside its declared bounds; missing XYZ
    /// tiles would otherwise replace the useful online map with blank areas.
    static func canUse(bounds: OfflineMapBounds,
                       currentCoordinate: CLLocationCoordinate2D?,
                       routeCoordinates: [CLLocationCoordinate2D],
                       showsRouteOverview: Bool) -> Bool {
        if let currentCoordinate, !bounds.contains(currentCoordinate) { return false }
        // Before the first trustworthy GPS fix, route geometry is the only
        // evidence for which map area is needed. Require complete coverage in
        // that state as well; otherwise the app could launch into blank local
        // tiles merely because it cannot yet prove where the car is.
        if (showsRouteOverview || currentCoordinate == nil), !routeCoordinates.isEmpty,
           !routeCoordinates.allSatisfy(bounds.contains) { return false }
        return true
    }
}

enum OfflineMapCameraPolicy {
    static func shouldFitOverview(showsOverview: Bool, showedOverviewPreviously: Bool,
                                  routeGeometryChanged: Bool) -> Bool {
        showsOverview && (!showedOverviewPreviously || routeGeometryChanged)
    }
}

enum OfflineTileCoordinatePolicy {
    static func isValid(z: Int, x: Int, y: Int) -> Bool {
        guard (0...22).contains(z), x >= 0, y >= 0 else { return false }
        let axisTileCount = 1 << z
        return x < axisTileCount && y < axisTileCount
    }

    static func center(z: Int, x: Int, y: Int) -> CLLocationCoordinate2D? {
        guard isValid(z: z, x: x, y: y) else { return nil }
        let tiles = pow(2.0, Double(z))
        let longitude = (Double(x) + 0.5) / tiles * 360 - 180
        let mercatorY = .pi * (1 - 2 * (Double(y) + 0.5) / tiles)
        let latitude = atan(sinh(mercatorY)) * 180 / .pi
        return .init(latitude: latitude, longitude: longitude)
    }
}

enum OfflineTileFilePolicy {
    static func tileURL(z: Int, x: Int, y: Int,
                        packageDirectory: URL, manifest: OfflineMapManifest,
                        fileManager: FileManager = .default) -> URL? {
        guard (manifest.minimumZoom...manifest.maximumZoom).contains(z),
              OfflineTileCoordinatePolicy.isValid(z: z, x: x, y: y) else { return nil }
        let tilesRoot = packageDirectory.appendingPathComponent("tiles", isDirectory: true)
            .resolvingSymlinksInPath().standardizedFileURL
        let candidate = tilesRoot
            .appendingPathComponent(String(z), isDirectory: true)
            .appendingPathComponent(String(x), isDirectory: true)
            .appendingPathComponent("\(y).png")
            .resolvingSymlinksInPath().standardizedFileURL
        let rootPath = tilesRoot.path.hasSuffix("/") ? tilesRoot.path : tilesRoot.path + "/"
        guard candidate.path.hasPrefix(rootPath),
              let values = try? candidate.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]
              ), values.isRegularFile == true, values.isSymbolicLink != true,
              fileManager.fileExists(atPath: candidate.path) else { return nil }
        return candidate
    }
}

struct OfflineMapManifest: Codable, Identifiable, Equatable {
    static let supportedFormat = "raster-xyz-v1"

    let id: String
    let name: String
    let bounds: OfflineMapBounds
    let minimumZoom: Int
    let maximumZoom: Int
    let format: String
    let attribution: String
    let createdAt: Date?

    var isValid: Bool {
        !id.isEmpty && id.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil &&
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        bounds.isValid && (0...22).contains(minimumZoom) &&
        minimumZoom <= maximumZoom && maximumZoom <= 22 &&
        format == Self.supportedFormat &&
        !attribution.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}

struct InstalledOfflineMapPackage: Identifiable, Equatable {
    let manifest: OfflineMapManifest
    let directoryURL: URL
    let byteCount: Int64

    var id: String { manifest.id }
}

enum OfflineMapPackageError: LocalizedError {
    case missingManifest
    case invalidManifest
    case missingTiles
    case invalidTiles
    case packageAlreadyExists

    var errorDescription: String? {
        switch self {
        case .missingManifest: "Im gewählten Ordner fehlt manifest.json."
        case .invalidManifest: "Das Kartenpaket hat ungültige oder nicht unterstützte Metadaten."
        case .missingTiles: "Im Kartenpaket fehlt der Ordner tiles mit Kartenkacheln."
        case .invalidTiles: "Das Kartenpaket enthält keine gültige PNG-Kachel im angegebenen Zoombereich."
        case .packageAlreadyExists: "Ein Kartenpaket mit dieser Kennung ist bereits installiert."
        }
    }
}

@MainActor
final class OfflineMapPackageStore: ObservableObject {
    static let shared = OfflineMapPackageStore()

    @Published private(set) var packages: [InstalledOfflineMapPackage] = []
    @Published var activePackageID: String? {
        didSet { defaults.set(activePackageID, forKey: activePackageKey) }
    }

    private let fileManager: FileManager
    private let rootURL: URL
    private let defaults: UserDefaults
    private let activePackageKey = "drive.offlineMap.activePackageID"

    init(fileManager: FileManager = .default, rootURL: URL? = nil, defaults: UserDefaults = .standard) {
        self.fileManager = fileManager
        self.defaults = defaults
        self.rootURL = rootURL ?? Self.defaultRootURL(fileManager: fileManager)
        self.activePackageID = defaults.string(forKey: activePackageKey)
        reload()
    }

    var activePackage: InstalledOfflineMapPackage? {
        packages.first { $0.id == activePackageID }
    }

    func reload() {
        try? fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        let directories = (try? fileManager.contentsOfDirectory(
            at: rootURL,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        packages = directories.compactMap { try? Self.readPackage(at: $0, fileManager: fileManager) }
            .sorted { $0.manifest.name.localizedStandardCompare($1.manifest.name) == .orderedAscending }
        if let activePackageID, !packages.contains(where: { $0.id == activePackageID }) {
            self.activePackageID = nil
        }
    }

    @discardableResult
    func install(from sourceURL: URL) throws -> InstalledOfflineMapPackage {
        let source = try Self.readPackage(at: sourceURL, fileManager: fileManager)
        let destination = rootURL.appendingPathComponent(source.manifest.id, isDirectory: true)
        guard !fileManager.fileExists(atPath: destination.path) else {
            throw OfflineMapPackageError.packageAlreadyExists
        }
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.copyItem(at: sourceURL, to: destination)
        reload()
        activePackageID = source.manifest.id
        return packages.first(where: { $0.id == source.manifest.id }) ?? source
    }

    func remove(_ package: InstalledOfflineMapPackage) throws {
        // Only installed package URLs discovered below our private root are removable.
        let rootPath = rootURL.standardizedFileURL.path + "/"
        guard package.directoryURL.standardizedFileURL.path.hasPrefix(rootPath) else { return }
        try fileManager.removeItem(at: package.directoryURL)
        reload()
    }

    func tileURL(z: Int, x: Int, y: Int, package: InstalledOfflineMapPackage) -> URL? {
        OfflineTileFilePolicy.tileURL(
            z: z, x: x, y: y, packageDirectory: package.directoryURL,
            manifest: package.manifest, fileManager: fileManager
        )
    }

    private static func readPackage(at url: URL, fileManager: FileManager) throws -> InstalledOfflineMapPackage {
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw OfflineMapPackageError.missingManifest }
        let manifest = try JSONDecoder.offlineMaps.decode(OfflineMapManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.isValid else { throw OfflineMapPackageError.invalidManifest }
        let tilesURL = url.appendingPathComponent("tiles", isDirectory: true)
        let tileRootValues = try? tilesURL.resourceValues(
            forKeys: [.isDirectoryKey, .isSymbolicLinkKey]
        )
        guard tileRootValues?.isDirectory == true,
              tileRootValues?.isSymbolicLink != true else {
            throw OfflineMapPackageError.missingTiles
        }
        guard containsValidTile(in: tilesURL, manifest: manifest, fileManager: fileManager) else {
            throw OfflineMapPackageError.invalidTiles
        }
        return InstalledOfflineMapPackage(
            manifest: manifest,
            directoryURL: url,
            byteCount: directorySize(at: url, fileManager: fileManager)
        )
    }

    private static func containsValidTile(in tilesURL: URL, manifest: OfflineMapManifest,
                                          fileManager: FileManager) -> Bool {
        guard let enumerator = fileManager.enumerator(
            at: tilesURL,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            options: [.skipsHiddenFiles]
        ) else { return false }
        let pngSignature = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let rootComponents = tilesURL.resolvingSymlinksInPath().pathComponents
        for case let tileURL as URL in enumerator {
            guard tileURL.pathExtension.lowercased() == "png",
                  let values = try? tileURL.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
                  values.isRegularFile == true, values.isSymbolicLink != true else { continue }
            let tileComponents = tileURL.resolvingSymlinksInPath().pathComponents
            guard tileComponents.starts(with: rootComponents) else { continue }
            let relative = tileComponents.dropFirst(rootComponents.count)
            guard relative.count == 3,
                  let zoom = Int(relative[relative.startIndex]),
                  let x = Int(relative[relative.index(after: relative.startIndex)]),
                  let y = Int(tileURL.deletingPathExtension().lastPathComponent),
                  (manifest.minimumZoom...manifest.maximumZoom).contains(zoom),
                  OfflineTileCoordinatePolicy.isValid(z: zoom, x: x, y: y),
                  let center = OfflineTileCoordinatePolicy.center(z: zoom, x: x, y: y),
                  manifest.bounds.contains(center),
                  let data = try? Data(contentsOf: tileURL, options: .mappedIfSafe),
                  data.count > pngSignature.count, data.prefix(pngSignature.count) == pngSignature,
                  let source = CGImageSourceCreateWithData(data as CFData, nil),
                  CGImageSourceGetCount(source) == 1,
                  CGImageSourceCreateImageAtIndex(source, 0, nil) != nil else { continue }
            return true
        }
        return false
    }

    private static func directorySize(at url: URL, fileManager: FileManager) -> Int64 {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        return enumerator.compactMap { $0 as? URL }.reduce(0) { total, fileURL in
            let values = try? fileURL.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            return total + (values?.isRegularFile == true ? Int64(values?.fileSize ?? 0) : 0)
        }
    }

    private static func defaultRootURL(fileManager: FileManager) -> URL {
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("KiesDrive/OfflineMaps", isDirectory: true)
    }
}

private extension JSONDecoder {
    static var offlineMaps: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
