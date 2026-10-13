import Foundation
import Combine
import CoreLocation

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
        guard z >= package.manifest.minimumZoom, z <= package.manifest.maximumZoom,
              x >= 0, y >= 0 else { return nil }
        let url = package.directoryURL
            .appendingPathComponent("tiles", isDirectory: true)
            .appendingPathComponent(String(z), isDirectory: true)
            .appendingPathComponent(String(x), isDirectory: true)
            .appendingPathComponent("\(y).png")
        return fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private static func readPackage(at url: URL, fileManager: FileManager) throws -> InstalledOfflineMapPackage {
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard fileManager.fileExists(atPath: manifestURL.path) else { throw OfflineMapPackageError.missingManifest }
        let manifest = try JSONDecoder.offlineMaps.decode(OfflineMapManifest.self, from: Data(contentsOf: manifestURL))
        guard manifest.isValid else { throw OfflineMapPackageError.invalidManifest }
        var isDirectory: ObjCBool = false
        let tilesURL = url.appendingPathComponent("tiles", isDirectory: true)
        guard fileManager.fileExists(atPath: tilesURL.path, isDirectory: &isDirectory), isDirectory.boolValue else {
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
                  (manifest.minimumZoom...manifest.maximumZoom).contains(zoom), x >= 0, y >= 0,
                  let data = try? Data(contentsOf: tileURL, options: .mappedIfSafe),
                  data.count > pngSignature.count, data.prefix(pngSignature.count) == pngSignature else { continue }
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
