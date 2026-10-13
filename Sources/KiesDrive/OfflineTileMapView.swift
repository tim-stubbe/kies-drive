import SwiftUI
import MapKit
import ImageIO
import UniformTypeIdentifiers

/// MapKit renderer for user-supplied raster XYZ packages. The tile overlay
/// replaces Apple's online basemap while route geometry and location remain
/// native MapKit overlays/annotations.
struct OfflineTileMapView: View {
    let package: InstalledOfflineMapPackage
    let routes: [MKPolyline]
    let currentLocation: CLLocation?
    let destination: MKMapItem?
    let followsLocation: Bool
    let showsRouteOverview: Bool

    var body: some View {
        OfflinePlatformMap(
            package: package,
            routes: routes,
            currentLocation: currentLocation,
            destination: destination,
            followsLocation: followsLocation,
            showsRouteOverview: showsRouteOverview
        )
        .overlay(alignment: .topTrailing) {
            Label("Offline", systemImage: "arrow.down.circle.fill")
                .font(.caption.bold()).foregroundStyle(Color(red: 0.05, green: 0.24, blue: 0.19))
                .padding(.horizontal, 9).padding(.vertical, 6)
                .background(Color(red: 0.96, green: 0.93, blue: 0.84).opacity(0.96), in: Capsule())
                .padding(.top, 116).padding(.trailing, 14)
        }
        .overlay(alignment: .bottomLeading) {
            Text(package.manifest.attribution)
                .font(.caption2).foregroundStyle(.secondary)
                .padding(.horizontal, 7).padding(.vertical, 4)
                .background(.ultraThinMaterial, in: Capsule())
                .padding(.leading, 8).padding(.bottom, 205)
                .accessibilityLabel("Kartendaten: \(package.manifest.attribution)")
        }
    }
}

private final class LocalXYZTileOverlay: MKTileOverlay {
    private let package: InstalledOfflineMapPackage
    private static let missingTileData: Data = {
        let data = NSMutableData()
        guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: 256, height: 256, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return Data() }
        context.setFillColor(CGColor(red: 0.94, green: 0.92, blue: 0.86, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: 256, height: 256))
        context.setStrokeColor(CGColor(gray: 0.75, alpha: 1))
        context.setLineWidth(2)
        context.stroke(CGRect(x: 1, y: 1, width: 254, height: 254))
        guard let image = context.makeImage(),
              let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else {
            return Data()
        }
        CGImageDestinationAddImage(destination, image, nil)
        CGImageDestinationFinalize(destination)
        return data as Data
    }()

    init(package: InstalledOfflineMapPackage) {
        self.package = package
        super.init(urlTemplate: nil)
        canReplaceMapContent = true
        tileSize = CGSize(width: 256, height: 256)
        minimumZ = package.manifest.minimumZoom
        maximumZ = package.manifest.maximumZoom
    }

    override func loadTile(at path: MKTileOverlayPath, result: @escaping (Data?, (any Error)?) -> Void) {
        let url = package.directoryURL
            .appendingPathComponent("tiles", isDirectory: true)
            .appendingPathComponent(String(path.z), isDirectory: true)
            .appendingPathComponent(String(path.x), isDirectory: true)
            .appendingPathComponent("\(path.y).png")
        do { result(try Data(contentsOf: url, options: .mappedIfSafe), nil) }
        catch { result(Self.missingTileData, nil) }
    }
}

private final class OfflineMapCoordinator: NSObject, MKMapViewDelegate {
    private var packageID: String?
    private var lastOverview = false

    func update(_ mapView: MKMapView, package: InstalledOfflineMapPackage, routes: [MKPolyline],
                currentLocation: CLLocation?, destination: MKMapItem?, followsLocation: Bool,
                showsRouteOverview: Bool) {
        if packageID != package.id {
            mapView.removeOverlays(mapView.overlays)
            mapView.addOverlay(LocalXYZTileOverlay(package: package), level: .aboveLabels)
            packageID = package.id
        }

        mapView.removeOverlays(mapView.overlays.filter { $0 is MKPolyline })
        routes.forEach { mapView.addOverlay($0, level: .aboveRoads) }
        mapView.removeAnnotations(mapView.annotations.filter { !($0 is MKUserLocation) })
        if let destination {
            let pin = MKPointAnnotation()
            pin.title = destination.name ?? "Ziel"
            pin.coordinate = destination.placemark.coordinate
            mapView.addAnnotation(pin)
        }

        if showsRouteOverview, (!lastOverview || routes.count > 0) {
            let rect = routes.reduce(MKMapRect.null) { $0.union($1.boundingMapRect) }
            if !rect.isNull, !rect.isEmpty {
                mapView.setVisibleMapRect(rect, edgePadding: .init(top: 150, left: 45, bottom: 210, right: 45), animated: lastOverview)
            }
        } else if followsLocation, let currentLocation {
            let heading = currentLocation.course >= 0 ? currentLocation.course : 0
            let camera = MKMapCamera(lookingAtCenter: currentLocation.coordinate,
                                     fromDistance: 750, pitch: 58, heading: heading)
            mapView.setCamera(camera, animated: false)
        } else if packageID == package.id, routes.isEmpty, currentLocation == nil {
            let bounds = package.manifest.bounds
            let center = CLLocationCoordinate2D(latitude: (bounds.north + bounds.south) / 2,
                                                longitude: (bounds.east + bounds.west) / 2)
            mapView.setRegion(.init(center: center,
                                    span: .init(latitudeDelta: bounds.north - bounds.south,
                                                longitudeDelta: bounds.east - bounds.west)), animated: false)
        }
        lastOverview = showsRouteOverview
    }

    func mapView(_ mapView: MKMapView, rendererFor overlay: any MKOverlay) -> MKOverlayRenderer {
        if let tiles = overlay as? MKTileOverlay { return MKTileOverlayRenderer(tileOverlay: tiles) }
        if let line = overlay as? MKPolyline {
            let renderer = MKPolylineRenderer(polyline: line)
            renderer.strokeColor = .systemBlue
            renderer.lineWidth = 6
            renderer.lineCap = .round
            renderer.lineJoin = .round
            return renderer
        }
        return MKOverlayRenderer(overlay: overlay)
    }
}

#if os(iOS)
private struct OfflinePlatformMap: UIViewRepresentable {
    let package: InstalledOfflineMapPackage
    let routes: [MKPolyline]
    let currentLocation: CLLocation?
    let destination: MKMapItem?
    let followsLocation: Bool
    let showsRouteOverview: Bool

    func makeCoordinator() -> OfflineMapCoordinator { OfflineMapCoordinator() }
    func makeUIView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.showsUserLocation = true
        view.showsCompass = true
        view.pointOfInterestFilter = .excludingAll
        return view
    }
    func updateUIView(_ view: MKMapView, context: Context) {
        context.coordinator.update(view, package: package, routes: routes, currentLocation: currentLocation,
                                   destination: destination, followsLocation: followsLocation,
                                   showsRouteOverview: showsRouteOverview)
    }
}
#else
private struct OfflinePlatformMap: NSViewRepresentable {
    let package: InstalledOfflineMapPackage
    let routes: [MKPolyline]
    let currentLocation: CLLocation?
    let destination: MKMapItem?
    let followsLocation: Bool
    let showsRouteOverview: Bool

    func makeCoordinator() -> OfflineMapCoordinator { OfflineMapCoordinator() }
    func makeNSView(context: Context) -> MKMapView {
        let view = MKMapView()
        view.delegate = context.coordinator
        view.showsUserLocation = true
        view.showsCompass = true
        view.pointOfInterestFilter = .excludingAll
        return view
    }
    func updateNSView(_ view: MKMapView, context: Context) {
        context.coordinator.update(view, package: package, routes: routes, currentLocation: currentLocation,
                                   destination: destination, followsLocation: followsLocation,
                                   showsRouteOverview: showsRouteOverview)
    }
}
#endif
