import SwiftUI
import MapKit
import Combine
import KiesDriveCore
import UniformTypeIdentifiers
import CoreImage
import CoreImage.CIFilterBuiltins
import Contacts
#if os(iOS)
import UIKit
#endif

struct DriveContentView: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var settings = DriveSettings.shared
    @StateObject private var account = AccountSessionStore.shared
    @StateObject private var location = LocationService.shared
    @StateObject private var planner = RoutePlanner.shared
    @StateObject private var offlineMaps = OfflineMapPackageStore.shared
    @State private var position: MapCameraPosition = .automatic
    @State private var showSettings = false
    @State private var showJarvis = false
    @State private var selectedStation: FuelStation?
    @State private var stationRouteUpdateID: String?
    @State private var showRouteDetails = false
    @State private var isFollowingLocation = true
    @State private var isShowingRouteOverview = false
    @State private var lastReliableCameraHeading: CLLocationDirection?
    @State private var didCenterInitialLocation = false
    @State private var showFavorites = false
    @State private var favorites = DriveFavoriteStore.load()
    @State private var recentDestinations = RecentDestinationStore.load()

    private var isSimulatorNavigationPreview: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--navigation-preview")
        #else
        false
        #endif
    }

    private var isSimulatorSearchPreview: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--search-preview")
        #else
        false
        #endif
    }

    private var isSimulatorRouteDetailsPreview: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--route-details-preview")
        #else
        false
        #endif
    }

    private var isSimulatorRouteOverviewPreview: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--route-overview-preview")
        #else
        false
        #endif
    }

    private var isSimulatorStationPreview: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--station-preview")
        #else
        false
        #endif
    }

    private var isSimulatorSettingsPreview: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--settings-preview")
        #else
        false
        #endif
    }

    private var isSimulatorOfflineMapPreview: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--offline-map-preview")
        #else
        false
        #endif
    }

    private var isSimulatorAccountPreview: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--account-preview")
        #else
        false
        #endif
    }

    private var isSimulatorLocationDeniedPreview: Bool {
        #if targetEnvironment(simulator)
        ProcessInfo.processInfo.arguments.contains("--location-denied-preview")
        #else
        false
        #endif
    }

    private var showsNavigationUI: Bool { planner.isNavigating || isSimulatorNavigationPreview }

    private var bypassesAccountForSimulatorPreview: Bool {
        #if targetEnvironment(simulator)
        return ProcessInfo.processInfo.arguments.contains { $0.hasSuffix("-preview") }
        #else
        return false
        #endif
    }

    @ViewBuilder
    var body: some View {
        Group {
            if isSimulatorAccountPreview || (account.session == nil && !bypassesAccountForSimulatorPreview) {
                AccountWelcomeView()
            } else {
                #if os(iOS)
                mobileBody
                #else
                desktopBody
                #endif
            }
        }
        .sheet(isPresented: Binding(
            get: { account.session != nil && account.shouldOfferTwoFactorSetup },
            set: { if !$0 { account.dismissTwoFactorSetupOffer() } }
        )) {
            FirstLoginSecurityView()
        }
    }

    private var desktopBody: some View {
        NavigationSplitView {
            routePanel
                .navigationTitle("Kies Drive")
                .toolbar {
                    Button { showJarvis = true } label: { Label("Jarvis", systemImage: "sparkles") }
                    Button { showSettings = true } label: { Label("Einstellungen", systemImage: "gear") }
                }
        } detail: {
            map
        }
        .onAppear {
            location.start()
        }
        .sheet(isPresented: $showSettings) { DriveSettingsView(planner: planner) }
        .sheet(isPresented: $showJarvis) { JarvisDriveView(route: planner.route, destination: planner.destination) }
    }

    #if os(iOS)
    private var mobileBody: some View {
        ZStack {
            map
                .ignoresSafeArea()

            VStack(spacing: 12) {
                if showsNavigationUI {
                    if isShowingRouteOverview {
                        compactNavigationInstructionCard
                    } else {
                        navigationInstructionCard
                    }
                } else {
                    mobileHeader
                }
                if isSimulatorLocationDeniedPreview ||
                    NavigationLocationAuthorizationPolicy.requiresSystemSettings(location.authorization) {
                    locationPermissionCard
                }
                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.top, 8)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            mobileBottomCard
                // The navigation chrome intentionally keeps its warm ivory
                // palette in both system appearances. Without a local light
                // scheme, semantic labels turn white in Dark Mode and lose
                // all contrast against the ivory surface.
                .environment(\.colorScheme, .light)
        }
        .onAppear {
            UIApplication.shared.isIdleTimerDisabled = true
            location.setNavigationActive(planner.isNavigating)
            location.start()
            #if targetEnvironment(simulator)
            if isSimulatorNavigationPreview {
                position = .camera(.init(centerCoordinate: .init(latitude: 50.0143, longitude: 8.3522),
                                         distance: 1_200, heading: 48, pitch: 58))
            } else {
                position = .region(.init(center: .init(latitude: 50.0143, longitude: 8.3522),
                                         latitudinalMeters: 18_000, longitudinalMeters: 18_000))
            }
            if isSimulatorSearchPreview { installSimulatorSearchPreview() }
            if isSimulatorRouteDetailsPreview {
                installSimulatorRouteDetailsPreview()
                showRouteDetails = true
            }
            if isSimulatorRouteOverviewPreview { showCompleteRoute() }
            if isSimulatorStationPreview {
                selectedStation = FuelStation(
                    id: "preview-station", name: "HEM Hochheim", brand: "HEM",
                    street: "Frankfurter Straße 80", place: "Hochheim am Main",
                    lat: 50.014, lon: 8.352, price: 1.719, open: true, distanceKm: 1.4
                )
            }
            if isSimulatorSettingsPreview { showSettings = true }
            if isSimulatorOfflineMapPreview {
                offlineMaps.reload()
                offlineMaps.activePackageID = offlineMaps.packages.first?.id
            }
            didCenterInitialLocation = true
            #endif
        }
        .onChange(of: scenePhase) { _, phase in
            // Keep the screen awake only while Kies Drive is actually visible.
            // Backgrounding the app restores the user's normal lock timeout.
            UIApplication.shared.isIdleTimerDisabled = phase == .active
        }
        .onDisappear {
            UIApplication.shared.isIdleTimerDisabled = false
        }
        .onReceive(location.$location) { newValue in
            guard let newValue else { return }
            // Respect manual pan/zoom. Following resumes only when the user
            // explicitly taps the location button again.
            if planner.isNavigating && isFollowingLocation { followCurrentLocation(using: newValue) }
            if !planner.isNavigating && !didCenterInitialLocation {
                didCenterInitialLocation = true
                position = .region(.init(center: newValue.coordinate, latitudinalMeters: 18_000, longitudinalMeters: 18_000))
            }
        }
        .onChange(of: planner.isNavigating) { _, navigating in
            location.setNavigationActive(navigating)
            if navigating { followCurrentLocation() }
        }
        .sheet(isPresented: $showSettings) { DriveSettingsView(planner: planner) }
        .sheet(isPresented: $showJarvis) { JarvisDriveView(route: planner.route, destination: planner.destination) }
        .sheet(isPresented: $showFavorites) { favoritesSheet }
        .sheet(item: $selectedStation) { station in stationDetailSheet(station) }
        .sheet(isPresented: $showRouteDetails) {
            NavigationStack {
                mobileRouteDetails
                    .navigationTitle("Routendetails")
                    .navigationBarTitleDisplayMode(.inline)
                    .toolbar { Button("Fertig") { showRouteDetails = false } }
            }
            // Route detail cards use the deliberate ivory/forest palette.
            // Keep their semantic text dark and readable when the phone is
            // otherwise using Dark Mode.
            .preferredColorScheme(.light)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }

    private var locationPermissionCard: some View {
        HStack(spacing: 12) {
            Image(systemName: "location.slash.fill")
                .font(.title2).foregroundStyle(Color.kiesBrass)
            VStack(alignment: .leading, spacing: 3) {
                Text("Standortzugriff fehlt").font(.subheadline.bold())
                Text("Aktiviere den Standort, damit Navigation und Ansagen funktionieren.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer(minLength: 4)
            Button {
                guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
                UIApplication.shared.open(url)
            } label: {
                Text("Öffnen")
                    .font(.subheadline.bold())
                    .foregroundStyle(Color.kiesIvory)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(Color.kiesForest,
                                in: Capsule(style: .continuous))
            }
            .buttonStyle(.plain)
        }
        .padding(14)
        .foregroundStyle(Color.kiesForest)
        .background(Color.kiesIvory.opacity(0.97),
                    in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .environment(\.colorScheme, .light)
        .shadow(color: .black.opacity(0.16), radius: 10, y: 4)
    }

    private var mobileRouteDetails: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 18) {
                routeSearchCard
                routeOverviewCard
                if let plan = planner.longTripPlan { longTripCards(plan) }
                if !planner.stations.isEmpty { routeFuelCard }
                if !planner.legs.isEmpty { routeStepsCard }
            }
            .padding(16)
        }
        .background(Color.kiesCanvas.ignoresSafeArea())
        .sheet(item: $selectedStation) { station in stationDetailSheet(station) }
    }

    private var routeSearchCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Auf der Route suchen", systemImage: "magnifyingglass")
                .font(.headline).foregroundStyle(Color.kiesForest)
            HStack {
                TextField("Café, Restaurant, Tankstelle …", text: $planner.routeSearchQuery)
                    .textFieldStyle(.plain)
                    .onSubmit { Task { await planner.searchAlongRoute(planner.routeSearchQuery) } }
                Button { Task { await planner.searchAlongRoute(planner.routeSearchQuery) } } label: {
                    Image(systemName: "arrow.right.circle.fill").font(.title2).foregroundStyle(Color.kiesForest)
                }
            }
            .padding(12).background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 14))
            if planner.isSearchingAlongRoute {
                ProgressView("Echten Fahrweg prüfen …")
                    .font(.caption).tint(Color.kiesForest)
            }
            ForEach(planner.routeSearchResults.prefix(4)) { result in
                let item = result.mapItem
                HStack(spacing: 11) {
                    Image(systemName: "mappin.circle.fill").foregroundStyle(Color.kiesBrass)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(item.name ?? "Zwischenstopp").font(.subheadline.weight(.semibold))
                        Text("\(item.placemark.title ?? "") · \(result.detourIsEstimated ? "ca. " : "")\(formatDistance(result.detourMetres)) Umweg")
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button("Hinzufügen") {
                        guard let start = location.location?.coordinate else { return }
                        Task {
                            await planner.addRouteStop(
                                item, from: start, settings: settings,
                                knownRouteProgress: result.routeProgress,
                                expectedRouteGeneration: result.routeGeneration
                            )
                        }
                    }.buttonStyle(.bordered).tint(Color.kiesForest)
                }
            }
            ForEach(planner.removableRouteStops) { stop in
                HStack {
                    Label(stop.name, systemImage: "mappin.and.ellipse")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                    Spacer()
                    Button(role: .destructive) {
                        guard let start = location.location?.coordinate else { return }
                        Task { await planner.removeRouteStop(id: stop.id, from: start, settings: settings) }
                    } label: { Image(systemName: "minus.circle.fill") }
                        .buttonStyle(.plain)
                }
            }
        }
        .driveCard()
    }

    private var routeOverviewCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label(planner.destination?.name ?? planner.destinationText, systemImage: "flag.checkered")
                    .font(.headline).foregroundStyle(Color.kiesForest).lineLimit(1)
                Spacer()
                if settings.avoidTolls { Image(systemName: "eurosign.slash").foregroundStyle(Color.kiesBrass) }
            }
            HStack(spacing: 0) {
                routeOverviewMetric(formatDistance(planner.totalDistance), "Strecke")
                Divider().frame(height: 36)
                routeOverviewMetric(formatTime(planner.totalTravelTime), "Fahrzeit")
                Divider().frame(height: 36)
                routeOverviewMetric("\(planner.longTripPlan?.results.first?.breaks.count ?? 0)", "Pausen")
            }
        }
        .driveCard()
    }

    private func routeOverviewMetric(_ value: String, _ label: String) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.headline).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }.frame(maxWidth: .infinity)
    }

    private func longTripCards(_ plan: LongTripPlan) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Reiseplanung", systemImage: "sparkles")
                .font(.headline).foregroundStyle(Color.kiesForest)
            if planner.isNavigating {
                ViewThatFits(in: .horizontal) {
                    HStack {
                        tripConfirmationButtons
                    }
                    VStack(alignment: .leading) {
                        tripConfirmationButtons
                    }
                }
            }
            ForEach(plan.results.prefix(3)) { result in
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text("\(result.routeTitle) · \(result.scenario.name)").font(.subheadline.weight(.semibold))
                        Spacer()
                        Text(formatTime(result.totalTime)).font(.subheadline.bold()).monospacedDigit()
                    }
                    Text(String(format: "%.1f l · %.2f € Kraftstoff", result.fuel.litres, result.fuel.cost))
                        .font(.caption).foregroundStyle(.secondary)
                    if result.plannedStopDetourMetres > 0 || result.additionalFuelStopTime > 0 {
                        Text("Inklusive \(formatDistance(result.plannedStopDetourMetres)) Halt-Umweg" +
                             (result.additionalFuelStopTime > 0 ? " und \(formatTime(result.additionalFuelStopTime)) Tankzeit" : ""))
                            .font(.caption2).foregroundStyle(.secondary)
                    }
                    ForEach(result.breaks.filter {
                        PlannedRouteStopVisibilityPolicy.isAhead(
                            $0.insertionRouteProgress,
                            current: planner.currentInstalledRouteProgress
                        )
                    }) { stop in
                        VStack(alignment: .leading, spacing: 7) {
                            HStack(alignment: .top, spacing: 9) {
                                Image(systemName: "cup.and.saucer.fill").foregroundStyle(Color.kiesBrass)
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(stop.candidate?.name ?? "Optimale Pause").font(.caption.weight(.semibold))
                                    Text("Nach \(formatTime(stop.afterDriving)) · bei ca. \(formatDistance(result.distanceMetres * stop.routeProgress)) · \(formatTime(stop.duration)) Pause")
                                        .font(.caption2.weight(.semibold))
                                        .foregroundStyle(Color.kiesForest)
                                    Text(stop.explanation).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                                }
                            }
                            if let candidate = stop.candidate {
                                let isPlanned = planner.activeRouteLock?.waypoints.contains(where: {
                                    $0.id == candidate.id || $0.name == candidate.name
                                }) == true
                                Button {
                                    guard let start = location.location?.coordinate else {
                                        planner.errorMessage = "Standort ist noch nicht verfügbar."
                                        return
                                    }
                                    Task { await planner.addPlannedBreak(stop, from: start, settings: settings) }
                                } label: {
                                    Label(isPlanned ? "Pause eingeplant" : "Pause zur Route hinzufügen",
                                          systemImage: isPlanned ? "checkmark.circle.fill" : "plus.circle.fill")
                                        .font(.caption.weight(.semibold))
                                }
                                .buttonStyle(.bordered)
                                .tint(Color.kiesForest)
                                .disabled(isPlanned)
                            }
                        }
                    }
                    ForEach(result.fuelStops.filter {
                        PlannedRouteStopVisibilityPolicy.isAhead(
                            $0.insertionRouteProgress,
                            current: planner.currentInstalledRouteProgress
                        )
                    }) { stop in
                        HStack(alignment: .top, spacing: 9) {
                            Image(systemName: "fuelpump.fill").foregroundStyle(Color.kiesBrass)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(stop.candidate?.name ?? "Tankstopp erforderlich").font(.caption.weight(.semibold))
                                Text("Bei ca. \(formatDistance(stop.afterDistanceMetres))")
                                    .font(.caption2.weight(.semibold))
                                    .foregroundStyle(Color.kiesForest)
                                Text(stop.explanation).font(.caption2).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }
                }
                .padding(12).background(.white.opacity(0.62), in: RoundedRectangle(cornerRadius: 14))
            }
        }
        .driveCard()
    }

    @ViewBuilder
    private var tripConfirmationButtons: some View {
        Button {
            planner.confirmFullTank(settings: settings)
        } label: {
            Label("Vollgetankt", systemImage: "fuelpump.circle.fill")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(Color.kiesForest)
        .accessibilityHint("Setzt die Tankplanung ab dem aktuellen Standort auf hundert Prozent")

        Button {
            planner.confirmRestBreak(settings: settings)
        } label: {
            Label("Pause beendet", systemImage: "cup.and.saucer.fill")
                .font(.caption.weight(.semibold))
        }
        .buttonStyle(.bordered)
        .tint(Color.kiesForest)
        .accessibilityHint("Setzt die ununterbrochene Fahrzeit zurück und plant spätere Pausen neu")
    }

    private var routeFuelCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Tanken entlang der Route", systemImage: "fuelpump.fill")
                .font(.headline).foregroundStyle(Color.kiesForest)
            ForEach(planner.stations.prefix(5)) { station in
                Button { selectedStation = station } label: {
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(station.brand.isEmpty ? station.name : station.brand).font(.subheadline.weight(.semibold))
                            Text("\(station.place) · \(station.distanceKm, specifier: "%.1f") km")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Text(String(format: "%.3f €", station.price)).font(.subheadline.bold()).monospacedDigit()
                        Image(systemName: "chevron.right").font(.caption.bold()).foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .driveCard()
    }

    private var routeStepsCard: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Nächste Schritte", systemImage: "list.bullet")
                .font(.headline).foregroundStyle(Color.kiesForest)
            ForEach(Array(planner.legs.flatMap(\.steps).filter { !$0.instructions.isEmpty }.prefix(8).enumerated()), id: \.offset) { _, step in
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: NavigationManeuverPresentation(step.instructions).direction.symbolName)
                        .frame(width: 24).foregroundStyle(Color.kiesBrass)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.instructions).font(.subheadline)
                        Text(formatDistance(step.distance)).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .driveCard()
    }

    private var mobileHeader: some View {
        VStack(spacing: 10) {
            HStack {
                HStack(spacing: 9) {
                    Image(systemName: "location.north.circle.fill")
                        .font(.title2).foregroundStyle(Color.kiesBrass)
                    VStack(alignment: .leading, spacing: 0) {
                        Text("KIES").font(.caption2.weight(.bold)).tracking(2.4)
                        Text("DRIVE").font(.headline.weight(.semibold))
                    }
                }
                Spacer()
                Button { showJarvis = true } label: { Image(systemName: "sparkles") }
                Button { showSettings = true } label: { Image(systemName: "person.crop.circle") }
            }
            .foregroundStyle(.white)
            .padding(.horizontal, 16).frame(height: 54)
            .background(Color.kiesForest.opacity(0.96), in: RoundedRectangle(cornerRadius: 19, style: .continuous))

            mobileSearchCard
                .environment(\.colorScheme, .light)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
    }

    private func followCurrentLocation(using currentLocation: CLLocation? = nil) {
        if isShowingRouteOverview { UISelectionFeedbackGenerator().selectionChanged() }
        isFollowingLocation = true
        isShowingRouteOverview = false
        guard let currentLocation = currentLocation ?? location.location else {
            position = .userLocation(followsHeading: true, fallback: .automatic)
            return
        }
        let liveHeading = NavigationMotionPolicy.reliableCourse(for: currentLocation)
            ?? location.heading.flatMap { heading in
                if heading.trueHeading >= 0 { return heading.trueHeading }
                return heading.magneticHeading >= 0 ? heading.magneticHeading : nil
            }
        if let liveHeading { lastReliableCameraHeading = liveHeading }
        let heading = liveHeading ?? lastReliableCameraHeading ?? 0
        let speed = NavigationMotionPolicy.reliableSpeed(for: currentLocation)
        let center = NavigationFollowCameraPolicy.center(
            from: currentLocation.coordinate,
            headingDegrees: heading,
            speedMetresPerSecond: speed
        )
        position = .camera(MapCamera(
            centerCoordinate: center,
            distance: NavigationFollowCameraPolicy.distance(speedMetresPerSecond: speed),
            heading: heading,
            pitch: 58
        ))
    }

    private var mobileSearchCard: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Wohin möchtest du?", text: $planner.destinationText)
                    .textInputAutocapitalization(.words)
                    .submitLabel(.search)
                    .onSubmit { Task { await planner.searchDestination(near: location.location?.coordinate) } }
                if !planner.destinationText.isEmpty {
                    Button { planner.destinationText = ""; planner.suggestions = [] } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                    }
                }
            }
            .font(.title3)
            .padding(.horizontal, 14)
            .frame(height: 52)

            if !planner.suggestions.isEmpty {
                Divider()
                ForEach(Array(planner.suggestions.prefix(4)), id: \.self) { item in
                    Button {
                        selectDestination(item)
                    } label: {
                        HStack(spacing: 12) {
                            Image(systemName: "mappin.circle.fill").font(.title2).foregroundStyle(.blue)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.name ?? "Ziel").fontWeight(.semibold).foregroundStyle(.primary)
                                Text(DestinationSubtitlePolicy.subtitle(
                                    name: item.name,
                                    lockedRouteTitle: nil,
                                    locality: item.placemark.locality,
                                    administrativeArea: item.placemark.administrativeArea,
                                    country: item.placemark.country,
                                    fallbackTitle: item.placemark.title
                                ))
                                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                            }
                            Spacer()
                        }
                        .padding(.horizontal, 14).padding(.vertical, 10)
                    }
                    .buttonStyle(.plain)
                }
            } else if planner.destinationText.isEmpty && !recentDestinations.isEmpty {
                Divider()
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        ForEach(recentDestinations.prefix(5)) { recent in
                            Button {
                                let item = MKMapItem(placemark: MKPlacemark(coordinate: recent.coordinate))
                                item.name = recent.name
                                selectDestination(item)
                            } label: {
                                Label(recent.name, systemImage: "clock.arrow.circlepath")
                                    .font(.caption.weight(.semibold))
                                    .foregroundStyle(Color.kiesForest)
                                    .padding(.horizontal, 11).padding(.vertical, 8)
                                    .background(Color.kiesForest.opacity(0.08), in: Capsule())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                }
            }
        }
        .background(Color.kiesIvory.opacity(0.96), in: RoundedRectangle(cornerRadius: 18, style: .continuous))
    }

    @ViewBuilder
    private var mobileBottomCard: some View {
        if showsNavigationUI {
            VStack(spacing: 12) {
                Capsule().fill(Color.kiesForest.opacity(0.16)).frame(width: 36, height: 4)
                HStack(spacing: 0) {
                    navigationMetric(isSimulatorNavigationPreview ? "18:42" : formatArrival(navigationRemainingTime), "Ankunft", emphasized: true)
                    Divider().frame(height: 38)
                    navigationMetric(isSimulatorNavigationPreview ? "1:18" : formatTime(navigationRemainingTime), "Fahrzeit")
                    Divider().frame(height: 38)
                    navigationMetric(isSimulatorNavigationPreview ? "112 km" : formatDistance(navigationRemainingDistance), "Strecke")
                }
                HStack {
                    Button("Auf Route suchen", systemImage: "magnifyingglass") { showRouteDetails = true }
                        .font(.subheadline.weight(.semibold)).foregroundStyle(Color.kiesForest)
                    Spacer()
                    Button("Beenden", systemImage: "xmark.circle.fill", role: .destructive) { planner.completeActiveTrip() }
                        .font(.subheadline.weight(.semibold))
                }
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 14)
            .background(Color.kiesIvory)
        } else if planner.route != nil {
            VStack(spacing: 12) {
                Capsule().fill(.tertiary).frame(width: 36, height: 5)
                if planner.alternatives.count > 1 {
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 8) {
                            ForEach(Array(planner.alternatives.prefix(3).enumerated()), id: \.offset) { index, route in
                                Button {
                                    planner.selectAlternative(at: index, settings: settings)
                                    showCompleteRoute()
                                } label: {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(index == 0 ? "Schnellste" : "Alternative \(index + 1)")
                                            .font(.caption.weight(.bold))
                                        Text("\(formatTime(route.expectedTravelTime)) · \(formatDistance(route.distance))")
                                            .font(.caption2)
                                    }
                                    .foregroundStyle(planner.selectedAlternativeIndex == index ? Color.kiesIvory : Color.kiesForest)
                                    .padding(.horizontal, 11).padding(.vertical, 7)
                                    .background(planner.selectedAlternativeIndex == index ? Color.kiesForest : Color.kiesForest.opacity(0.08),
                                                in: RoundedRectangle(cornerRadius: 11))
                                }
                                .buttonStyle(.plain)
                            }
                        }
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(planner.destination?.name ?? "Route").font(.headline).lineLimit(1)
                        Text("\(formatTime(planner.totalTravelTime)) · \(formatDistance(planner.totalDistance))")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { saveCurrentDestinationAsFavorite() } label: {
                        Image(systemName: isCurrentDestinationFavorite ? "heart.fill" : "heart")
                            .font(.title3).foregroundStyle(Color.kiesBrass)
                    }
                    .buttonStyle(.plain)
                    Button("Los") {
                        planner.startNavigation()
                        followCurrentLocation()
                    }
                    .font(.headline).buttonStyle(.borderedProminent).controlSize(.large)
                }
                Button("Route, Pausen und Kosten anzeigen") { showRouteDetails = true }
                    .font(.subheadline.weight(.semibold))
            }
            .padding(.horizontal, 18).padding(.top, 8).padding(.bottom, 12)
            .background(Color.kiesIvory)
        } else if planner.destination != nil {
            VStack(alignment: .leading, spacing: 14) {
                Capsule().fill(Color.kiesForest.opacity(0.18)).frame(width: 38, height: 5).frame(maxWidth: .infinity)
                HStack(spacing: 12) {
                    Image(systemName: "mappin.and.ellipse")
                        .font(.title2).foregroundStyle(Color.kiesBrass)
                        .frame(width: 44, height: 44).background(Color.kiesForest.opacity(0.08), in: Circle())
                    VStack(alignment: .leading, spacing: 3) {
                        Text(planner.destination?.name ?? planner.destinationText).font(.headline).lineLimit(1)
                        Text(destinationSubtitle)
                            .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                    }
                    Spacer()
                    Button { saveCurrentDestinationAsFavorite() } label: {
                        Image(systemName: isCurrentDestinationFavorite ? "heart.fill" : "heart")
                            .font(.title3).foregroundStyle(Color.kiesBrass)
                    }.buttonStyle(.plain)
                }
                Button {
                    guard let start = location.location?.coordinate else {
                        planner.errorMessage = "Standort ist noch nicht verfügbar."
                        return
                    }
                    Task { await calculateRouteAndShowOverview(from: start) }
                } label: {
                    Label(planner.isLoading ? "Route wird berechnet …" : "Route planen",
                          systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                        .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
                }
                .buttonStyle(.borderedProminent).tint(Color.kiesForest).controlSize(.large)
                .disabled(planner.isLoading)
            }
            .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 16)
            .background(Color.kiesIvory)
        } else {
            idleDriveCard
        }
    }

    private func navigationMetric(_ value: String, _ label: String, emphasized: Bool = false) -> some View {
        VStack(spacing: 2) {
            Text(value).font(.system(size: 21, weight: .bold, design: .rounded)).monospacedDigit()
                .foregroundStyle(emphasized ? Color.kiesForest : .primary)
            Text(label).font(.caption2.weight(.medium)).foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
    }

    private var navigationRemainingDistance: Double {
        planner.remainingDistanceMetres > 0 ? planner.remainingDistanceMetres : planner.totalDistance
    }

    private var navigationRemainingTime: TimeInterval {
        planner.remainingTravelTime > 0 ? planner.remainingTravelTime : planner.totalTravelTime
    }

    private var idleDriveCard: some View {
        VStack(alignment: .leading, spacing: 16) {
            Capsule().fill(Color.kiesForest.opacity(0.18)).frame(width: 38, height: 5).frame(maxWidth: .infinity)
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Bereit zur Fahrt?").font(.title2.weight(.semibold))
                    Text("Ein Ziel wählen oder in der Nähe suchen").font(.subheadline).foregroundStyle(.secondary)
                }
                Spacer()
                Image(systemName: "car.side.fill").font(.title2).foregroundStyle(Color.kiesBrass)
            }
            HStack(spacing: 10) {
                driveQuickAction("Zuhause", icon: "house.fill") { navigateHome() }
                driveQuickAction("Favoriten", icon: "heart.fill") { showFavorites = true }
                driveQuickAction("Tanken", icon: "fuelpump.fill") { searchNearby("Tankstelle") }
                driveQuickAction("Essen", icon: "fork.knife") { searchNearby("Restaurant") }
            }
        }
        .padding(.horizontal, 18).padding(.top, 10).padding(.bottom, 18)
        .background(Color.kiesIvory)
    }

    private func driveQuickAction(_ title: String, icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 7) {
                Image(systemName: icon).font(.headline).frame(width: 42, height: 42)
                    .foregroundStyle(Color.kiesIvory)
                    .background(Color.kiesForest, in: Circle())
                Text(title).font(.caption2.weight(.semibold)).foregroundStyle(Color.kiesForest)
            }
            .frame(maxWidth: .infinity)
        }
        .buttonStyle(.plain)
    }

    private func searchNearby(_ query: String) {
        planner.destinationText = query
        Task { await planner.searchDestination(near: location.location?.coordinate) }
    }

    private func calculateRouteAndShowOverview(from start: CLLocationCoordinate2D) async {
        await planner.calculate(from: start, settings: settings)
        guard planner.route != nil else { return }
        rememberCurrentDestination()
        showCompleteRoute()
    }

    private func selectDestination(_ item: MKMapItem) {
        planner.destination = item
        planner.destinationText = item.name ?? item.placemark.title ?? "Ziel"
        planner.suggestions = []
    }

    private func rememberCurrentDestination() {
        guard let item = planner.destination else { return }
        let coordinate = item.placemark.coordinate
        recentDestinations = RecentDestinationStore.record(.init(
            name: item.name ?? planner.destinationText,
            subtitle: destinationSubtitle(for: item),
            latitude: coordinate.latitude, longitude: coordinate.longitude
        ))
    }

    private func installSimulatorSearchPreview() {
        planner.destinationText = "Café"
        let previews: [(String, CLLocationCoordinate2D)] = [
            ("Café Maldaner", .init(latitude: 50.082, longitude: 8.241)),
            ("Die Hütte", .init(latitude: 50.013, longitude: 8.353)),
            ("Café Prego", .init(latitude: 50.014, longitude: 8.430)),
        ]
        planner.suggestions = previews.map { name, coordinate in
            let address = CNMutablePostalAddress()
            address.city = "Wiesbaden"
            address.state = "Hessen"
            address.country = "Deutschland"
            let item = MKMapItem(placemark: MKPlacemark(
                coordinate: coordinate, postalAddress: address
            ))
            item.name = name
            return item
        }
    }

    private func installSimulatorRouteDetailsPreview() {
        planner.destinationText = "Raiffeisenstraße 10"
        planner.installHochheimViaWurzenpassTripLock()
    }

    private func navigateHome() {
        guard !settings.homeAddress.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            showSettings = true
            return
        }
        planner.destinationText = settings.homeAddress
        Task { await planner.searchDestination(near: location.location?.coordinate) }
    }

    private var isCurrentDestinationFavorite: Bool {
        guard let coordinate = planner.destination?.placemark.coordinate else { return false }
        return favorites.contains { abs($0.latitude - coordinate.latitude) < 0.00001 && abs($0.longitude - coordinate.longitude) < 0.00001 }
    }

    private func saveCurrentDestinationAsFavorite() {
        guard let item = planner.destination else { return }
        let coordinate = item.placemark.coordinate
        if let index = favorites.firstIndex(where: { abs($0.latitude - coordinate.latitude) < 0.00001 && abs($0.longitude - coordinate.longitude) < 0.00001 }) {
            favorites.remove(at: index)
        } else {
            favorites.append(.init(name: item.name ?? planner.destinationText,
                                   subtitle: destinationSubtitle(for: item),
                                   latitude: coordinate.latitude, longitude: coordinate.longitude))
        }
        DriveFavoriteStore.save(favorites)
    }

    private var destinationSubtitle: String {
        guard let item = planner.destination else { return "Ausgewähltes Ziel" }
        return destinationSubtitle(for: item)
    }

    private func destinationSubtitle(for item: MKMapItem) -> String {
        let lockTitle: String?
        if let lock = planner.activeRouteLock,
           NavigationDestinationIdentityPolicy.matches(
            lock.destination.clLocationCoordinate, item.placemark.coordinate
           ) {
            lockTitle = lock.title
        } else {
            lockTitle = nil
        }
        return DestinationSubtitlePolicy.subtitle(
            name: item.name,
            lockedRouteTitle: lockTitle,
            locality: item.placemark.locality,
            administrativeArea: item.placemark.administrativeArea,
            country: item.placemark.country,
            fallbackTitle: item.placemark.title
        )
    }

    private var favoritesSheet: some View {
        NavigationStack {
            Group {
                if favorites.isEmpty {
                    ContentUnavailableView("Noch keine Favoriten", systemImage: "heart",
                                           description: Text("Tippe bei einem gewählten Ziel auf das Herz."))
                } else {
                    List {
                        ForEach(favorites) { favorite in
                            Button {
                                let item = MKMapItem(placemark: MKPlacemark(coordinate: favorite.coordinate))
                                item.name = favorite.name
                                planner.destination = item
                                planner.destinationText = favorite.name
                                showFavorites = false
                            } label: {
                                Label {
                                    VStack(alignment: .leading) {
                                        Text(favorite.name).foregroundStyle(.primary)
                                        Text(favorite.subtitle).font(.caption).foregroundStyle(.secondary)
                                    }
                                } icon: { Image(systemName: "heart.fill").foregroundStyle(Color.kiesBrass) }
                            }
                        }
                        .onDelete { offsets in
                            favorites.remove(atOffsets: offsets)
                            DriveFavoriteStore.save(favorites)
                        }
                    }
                }
            }
            .navigationTitle("Favoriten")
            .toolbar { Button("Fertig") { showFavorites = false } }
        }
    }

    private var navigationInstructionCard: some View {
        let previewInstruction = "Ausfahrt 12 rechts Richtung Wiesbaden auf die A66"
        let display = NavigationInstructionDisplayPolicy.display(
            instruction: isSimulatorNavigationPreview ? previewInstruction : (planner.nextManeuverInstruction ?? planner.nextInstruction),
            distance: isSimulatorNavigationPreview ? 450 : planner.nextManeuverDistance,
            upcomingInstructions: isSimulatorNavigationPreview
                ? [previewInstruction, "Links halten", "Geradeaus"]
                : planner.upcomingManeuverInstructions,
            guidanceReliable: isSimulatorNavigationPreview || planner.isManeuverGuidanceReliable,
            recalculating: planner.isRecalculating
        )
        let maneuver = NavigationManeuverPresentation(display.instruction)
        let followingInstruction = display.upcomingInstructions.dropFirst().first
        return VStack(alignment: .leading, spacing: 10) {
            if !display.upcomingInstructions.isEmpty {
                HStack(spacing: 18) {
                    ForEach(Array(display.upcomingInstructions.prefix(5).enumerated()), id: \.offset) { index, instruction in
                        Image(systemName: NavigationManeuverPresentation(instruction).direction.symbolName)
                            .font(.system(size: 25, weight: .bold))
                            .foregroundStyle(index == 0 ? .white : .white.opacity(0.28))
                    }
                    Spacer()
                }
            }
            HStack(spacing: 14) {
                Image(systemName: display.guidanceUnavailable
                      ? "exclamationmark.triangle.fill" : maneuver.direction.symbolName)
                    .font(.system(size: 42, weight: .bold)).frame(width: 54)
                VStack(alignment: .leading, spacing: 2) {
                    HStack {
                        if let distance = display.distance {
                            Text(formatDistance(distance)).font(.title.bold())
                        }
                        Spacer()
                        if let exit = maneuver.exitLabel {
                            Text(exit).font(.subheadline.bold())
                                .lineLimit(1).minimumScaleFactor(0.8).fixedSize(horizontal: true, vertical: false)
                                .padding(.horizontal, 10).padding(.vertical, 5)
                                .background(.white.opacity(0.14), in: Capsule())
                        }
                    }
                    Text(maneuver.destinationLabel.map { "Richtung \($0)" } ?? maneuver.instruction)
                        .font(.system(size: 22, weight: .bold)).lineLimit(2).minimumScaleFactor(0.75)
                    if let road = maneuver.roadLabel {
                        Text(road)
                            .font(.caption.bold()).monospacedDigit()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.blue, in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                Spacer()
                Button {
                    settings.voiceGuidance.toggle()
                    planner.setVoiceGuidanceEnabled(settings.voiceGuidance)
                } label: {
                    Image(systemName: settings.voiceGuidance ? "speaker.wave.2.fill" : "speaker.slash.fill")
                        .font(.title3.bold()).frame(width: 42, height: 42)
                        .background(.white.opacity(0.18), in: Circle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(settings.voiceGuidance ? "Sprachansagen ausschalten" : "Sprachansagen einschalten")
            }
            if display.guidanceUnavailable && !planner.isRecalculating {
                Label("Keine alte Abbiegung verwenden", systemImage: "shield.lefthalf.filled")
                    .font(.caption.weight(.semibold)).opacity(0.9)
            } else if planner.isRecalculating {
                Label("Neue Route wird gesucht", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption.weight(.semibold)).opacity(0.9)
            } else if planner.isUsingOfflineGuidance {
                Label("Gespeicherte Route · offline", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                    .font(.caption.weight(.semibold)).opacity(0.9)
            }
            if let reminder = planner.breakReminderText {
                Label(reminder, systemImage: "cup.and.saucer.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.kiesBrass)
            }
            if let followingInstruction {
                Divider().overlay(.white.opacity(0.2))
                HStack(spacing: 12) {
                    Image(systemName: NavigationManeuverPresentation(followingInstruction).direction.symbolName)
                    Text("Danach: \(followingInstruction)")
                        .font(.subheadline.weight(.semibold)).lineLimit(1)
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
        .foregroundStyle(.white).padding(14)
        .background(Color.kiesForest.opacity(0.96), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
    }


    private var compactNavigationInstructionCard: some View {
        let previewInstruction = "Rechts abbiegen auf Raiffeisenstraße"
        let display = NavigationInstructionDisplayPolicy.display(
            instruction: isSimulatorNavigationPreview
                ? previewInstruction : (planner.nextManeuverInstruction ?? planner.nextInstruction),
            distance: planner.nextManeuverDistance,
            upcomingInstructions: planner.upcomingManeuverInstructions,
            guidanceReliable: isSimulatorNavigationPreview || planner.isManeuverGuidanceReliable,
            recalculating: planner.isRecalculating
        )
        let maneuver = NavigationManeuverPresentation(display.instruction)
        return HStack(spacing: 14) {
            Image(systemName: display.guidanceUnavailable
                  ? "exclamationmark.triangle.fill" : maneuver.direction.symbolName)
                .font(.system(size: 38, weight: .bold)).frame(width: 48)
            Text(display.instruction)
                .font(.system(size: 20, weight: .bold)).lineLimit(2).minimumScaleFactor(0.76)
            Spacer(minLength: 4)
            Button {
                settings.voiceGuidance.toggle()
                planner.setVoiceGuidanceEnabled(settings.voiceGuidance)
            } label: {
                Image(systemName: settings.voiceGuidance ? "speaker.wave.2.fill" : "speaker.slash.fill")
                    .font(.title3.bold()).frame(width: 42, height: 42)
                    .background(.white.opacity(0.18), in: Circle())
            }
            .buttonStyle(.plain)
        }
        .foregroundStyle(.white).padding(14)
        .background(Color.kiesForest.opacity(0.96), in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 12, y: 5)
    }

    private func stationDetailSheet(_ station: FuelStation) -> some View {
        let isVia = planner.isRouteStopSelected(id: station.id)
        let isUpdating = stationRouteUpdateID == station.id
        return NavigationStack {
            VStack(alignment: .leading, spacing: 20) {
                HStack(alignment: .top) {
                    Image(systemName: "fuelpump.fill")
                        .font(.title2).foregroundStyle(Color.kiesIvory)
                        .frame(width: 52, height: 52).background(Color.kiesForest, in: Circle())
                    VStack(alignment: .leading, spacing: 4) {
                        Text(station.brand.isEmpty ? station.name : station.brand)
                            .font(.title2.bold()).foregroundStyle(Color.kiesForest)
                        Text([station.street, station.place].filter { !$0.isEmpty }.joined(separator: ", "))
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Aktueller Serverpreis · \(settings.fuel.label)")
                            .font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                        Text(station.price.formatted(.number.locale(Locale(identifier: "de_DE"))
                            .precision(.fractionLength(3))) + " €")
                            .font(.system(size: 38, weight: .bold, design: .rounded)).monospacedDigit()
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 3) {
                        Text(station.open == false ? "Geschlossen" : "Geöffnet")
                            .font(.subheadline.bold()).foregroundStyle(station.open == false ? .red : .green)
                        Text(String(format: "%.1f km von der Route", station.distanceKm))
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
                Button {
                    guard let start = location.location?.coordinate else {
                        planner.errorMessage = "Standort ist noch nicht verfügbar."
                        return
                    }
                    stationRouteUpdateID = station.id
                    Task {
                        await planner.toggleWaypoint(station, from: start, settings: settings)
                        stationRouteUpdateID = nil
                        selectedStation = nil
                    }
                } label: {
                    if isUpdating {
                        HStack { ProgressView(); Text("Route wird aktualisiert …") }
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
                    } else {
                        Label(isVia ? "Von der Route entfernen" : "Als Zwischenstopp hinzufügen",
                              systemImage: isVia ? "minus.circle.fill" : "plus.circle.fill")
                            .font(.headline).frame(maxWidth: .infinity).padding(.vertical, 5)
                    }
                }
                .buttonStyle(.borderedProminent).tint(Color.kiesForest).controlSize(.large)
                .disabled(planner.route == nil || isUpdating)
                Spacer()
            }
            .padding(22).background(Color.kiesIvory.ignoresSafeArea())
            .navigationTitle("Tankstelle")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Fertig") { selectedStation = nil } }
        }
        .preferredColorScheme(.light)
        .presentationDetents([.height(370), .medium])
        .presentationDragIndicator(.visible)
    }
    #endif

    private func showCompleteRoute() {
        #if os(iOS)
        UISelectionFeedbackGenerator().selectionChanged()
        isFollowingLocation = false
        isShowingRouteOverview = true
        #endif
        let routeRect: MKMapRect?
        #if targetEnvironment(simulator)
        routeRect = planner.completeDisplayMapRect ?? simulatorPreviewPolyline.boundingMapRect
        #else
        routeRect = planner.completeDisplayMapRect
        #endif
        let vehicleCoordinate = RouteOverviewMapRectPolicy.vehicleCoordinate(
            location.location?.coordinate, near: routeRect
        )
        let requiredCoordinates = [
            vehicleCoordinate,
            planner.destination?.placemark.coordinate,
        ].compactMap { $0 } + (planner.activeRouteLock?.waypoints
            .filter {
                $0.required &&
                    !(planner.activeRouteLock?.visitedWaypointIDs?.contains($0.id) ?? false)
            }
            .map(\.coordinate.clLocationCoordinate) ?? [])
        if let rect = RouteOverviewMapRectPolicy.including(
            routeRect, coordinates: requiredCoordinates
        ) {
            // MapKit fits against the full screen, although instruction and
            // ETA cards cover part of it. Extra breathing room keeps both
            // ends of the route inside the actually visible map area.
            position = .rect(rect.insetBy(dx: -rect.size.width * 0.18,
                                           dy: -rect.size.height * 0.34))
        }
    }

    private var routePanel: some View {
        List {
            Section("Ziel") {
                TextField("Adresse oder Ort", text: $planner.destinationText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { Task { await planner.searchDestination(near: location.location?.coordinate) } }
                Button("Ziel suchen", systemImage: "magnifyingglass") {
                    Task { await planner.searchDestination(near: location.location?.coordinate) }
                }
                ForEach(planner.suggestions, id: \.self) { item in
                    Button {
                        planner.destination = item
                        planner.destinationText = item.name ?? item.placemark.title ?? "Ziel"
                        planner.suggestions = []
                    } label: {
                        VStack(alignment: .leading) {
                            Text(item.name ?? "Ziel")
                            Text(item.placemark.title ?? "").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
                Button("Route berechnen", systemImage: "arrow.triangle.turn.up.right.diamond.fill") {
                    guard let start = location.location?.coordinate else { planner.errorMessage = "Standort ist noch nicht verfügbar."; return }
                    Task {
                        await planner.calculate(from: start, settings: settings)
                        showCompleteRoute()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(planner.destination == nil || planner.isLoading)
            }

            if !planner.legs.isEmpty {
                Section("Auf Route suchen") {
                    HStack {
                        TextField("z. B. McDonald’s", text: $planner.routeSearchQuery)
                            .onSubmit { Task { await planner.searchAlongRoute(planner.routeSearchQuery) } }
                        Button("Suchen") { Task { await planner.searchAlongRoute(planner.routeSearchQuery) } }
                    }
                    if planner.isSearchingAlongRoute { ProgressView("Echten Fahrweg prüfen …") }
                    ForEach(planner.routeSearchResults) { result in
                        let item = result.mapItem
                        HStack {
                            VStack(alignment: .leading) {
                                Text(item.name ?? "Zwischenstopp")
                                Text("\(item.placemark.title ?? "") · \(result.detourIsEstimated ? "ca. " : "")\(formatDistance(result.detourMetres)) Umweg")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Hinzufügen", systemImage: "plus.circle.fill") {
                                guard let start = location.location?.coordinate else { return }
                                Task {
                                    await planner.addRouteStop(
                                        item, from: start, settings: settings,
                                        knownRouteProgress: result.routeProgress,
                                        expectedRouteGeneration: result.routeGeneration
                                    )
                                }
                            }
                        }
                    }
                    ForEach(planner.removableRouteStops) { stop in
                        HStack {
                            Label(stop.name, systemImage: "mappin.and.ellipse")
                            Spacer()
                            Button("Entfernen", role: .destructive) {
                                guard let start = location.location?.coordinate else { return }
                                Task { await planner.removeRouteStop(id: stop.id, from: start, settings: settings) }
                            }
                        }
                    }
                }
                Section("Route") {
                    Label(formatDistance(planner.totalDistance), systemImage: "road.lanes")
                    Label(formatTime(planner.totalTravelTime), systemImage: "clock")
                    if settings.avoidTolls { Label("Mautstraßen werden vermieden", systemImage: "eurosign.slash") }
                    if !planner.transientViaStations.isEmpty {
                        Section {
                            ForEach(planner.transientViaStations) { via in
                                Label("Zwischenstopp: \(via.brand.isEmpty ? via.name : via.brand)", systemImage: "fuelpump.fill")
                            }
                            Button("Zwischenstopps entfernen", systemImage: "xmark.circle") {
                                guard let start = location.location?.coordinate else { return }
                                Task {
                                    for via in planner.transientViaStations {
                                        await planner.toggleWaypoint(via, from: start, settings: settings)
                                    }
                                }
                            }
                        }
                    }
                    Button("Navigation in Kies Drive starten", systemImage: "location.fill") {
                        planner.startNavigation()
                        #if os(iOS)
                        position = .userLocation(followsHeading: true, fallback: .automatic)
                        #endif
                    }
                }
                if let plan = planner.longTripPlan {
                    Section("Langstreckenvergleich") {
                        ForEach(plan.results) { result in
                            VStack(alignment: .leading, spacing: 5) {
                                Text("\(result.routeTitle) · \(result.scenario.name)").font(.headline)
                                Text("\(formatDistance(result.totalDistanceMetres)) · \(formatTime(result.totalTime)) inkl. \(result.breaks.count) Pause(n)")
                                Text(String(format: "%.1f l · %.2f € Kraftstoff · %.1f l/100 km", result.fuel.litres, result.fuel.cost, result.fuel.averageConsumptionLPer100km))
                                switch result.toll {
                                case .known(let amount, let currency, let source):
                                    Text("Maut: \(NSDecimalNumber(decimal: amount).stringValue) \(currency) · \(source)")
                                case .noToll(let source):
                                    Text("Keine Maut · \(source)")
                                case .unknown(let reason):
                                    Text("Mautkosten unbekannt · \(reason)").foregroundStyle(.secondary)
                                }
                                ForEach(result.breaks) { stop in
                                    Label(stop.candidate?.name ?? "Pausenort entlang der Route suchen", systemImage: "cup.and.saucer.fill")
                                    Text("Nach \(formatTime(stop.afterDriving)) · bei ca. \(formatDistance(result.distanceMetres * stop.routeProgress)) · \(formatTime(stop.duration)) Pause")
                                        .font(.caption.weight(.semibold))
                                        .foregroundStyle(Color.kiesForest)
                                    Text(stop.explanation).font(.caption).foregroundStyle(.secondary)
                                    if stop.candidate != nil {
                                        Button("Als Zwischenstopp übernehmen") {
                                            guard let start = location.location?.coordinate else { return }
                                            Task { await planner.addPlannedBreak(stop, from: start, settings: settings) }
                                        }
                                        .buttonStyle(.bordered)
                                    }
                                }
                            }
                        }
                        comparisonSummary(plan)
                        Text(plan.note).font(.caption).foregroundStyle(.secondary)
                    }
                }
                Section("Fahrhinweise") {
                    ForEach(Array(planner.legs.enumerated()), id: \.offset) { legIndex, leg in
                        ForEach(Array(leg.steps.dropFirst().enumerated()), id: \.offset) { _, step in
                            VStack(alignment: .leading, spacing: 3) {
                                Text(step.instructions.isEmpty ? "Weiter" : step.instructions)
                                Text(formatDistance(step.distance)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        if legIndex == 0 && planner.legs.count > 1 {
                            Label("Zwischenstopp erreicht", systemImage: "fuelpump.fill").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }

            Section("Tankstellen auf der Strecke") {
                Picker("Kraftstoff", selection: $settings.fuel) {
                    ForEach(FuelKind.allCases) { Text($0.label).tag($0) }
                }
                .onChange(of: settings.fuel) { _, fuel in
                    Task { await planner.reloadStopPlanning(fuel: fuel, settings: settings) }
                }
                if settings.fuel == .superplus {
                    Text("* Keine eigene SuperPlus-Preisquelle verfügbar - angezeigt wird der Super-(E5)-Preis als Näherung.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if planner.route != nil && planner.stations.isEmpty && !planner.isLoading {
                    Text("Keine geöffneten Tankstellen mit Preis in Routennähe gefunden.").foregroundStyle(.secondary)
                }
                ForEach(planner.stations) { station in
                    let isVia = planner.isRouteStopSelected(id: station.id)
                    HStack {
                        Button { selectedStation = station; position = .region(.init(center: station.coordinate, latitudinalMeters: 8_000, longitudinalMeters: 8_000)) } label: {
                            HStack {
                                VStack(alignment: .leading) {
                                    Text(station.brand.isEmpty ? station.name : station.brand)
                                    Text("\(station.street), \(station.place)").font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Text(String(format: "%.3f €", station.price)).bold().monospacedDigit()
                            }
                        }
                        .buttonStyle(.plain)
                        Button {
                            guard let start = location.location?.coordinate else { return }
                            Task { await planner.toggleWaypoint(station, from: start, settings: settings) }
                        } label: {
                            Image(systemName: isVia ? "checkmark.circle.fill" : "plus.circle")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(isVia ? .green : .accentColor)
                        .disabled(planner.route == nil)
                        .help(isVia ? "Als Zwischenstopp entfernen" : "Als Zwischenstopp zur Route hinzufügen")
                    }
                }
            }
            if let error = planner.errorMessage {
                Section {
                    Text(error).foregroundStyle(.red)
                    if let offline = planner.usableOfflineRoute {
                        offlineRouteView(offline)
                    }
                }
            }
        }
        .overlay { if planner.isLoading || planner.isRecalculating { ProgressView(planner.isRecalculating ? "Route wird neu berechnet …" : "Route und Preise werden geladen …").padding().background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14)) } }
    }

    @ViewBuilder
    private var map: some View {
        if let package = applicableOfflinePackage {
            OfflineTileMapView(
                package: package,
                routes: visibleRoutePolylines,
                currentLocation: location.location,
                destination: planner.destination,
                followsLocation: isFollowingLocation,
                showsRouteOverview: isShowingRouteOverview,
                onUserInteraction: {
                    isFollowingLocation = false
                    isShowingRouteOverview = false
                }
            )
        } else if showsNavigationUI {
            mapBase.mapStyle(.standard(elevation: .realistic, showsTraffic: true))
        } else {
            switch settings.mapAppearance {
            case .standard: mapBase.mapStyle(.standard(elevation: .realistic, showsTraffic: true))
            case .hybrid: mapBase.mapStyle(.hybrid(elevation: .realistic, showsTraffic: true))
            }
        }
    }

    private var visibleRoutePolylines: [MKPolyline] {
        let live = planner.legs.map(\.polyline)
        return live.isEmpty ? planner.offlinePolylines : live
    }

    private var applicableOfflinePackage: InstalledOfflineMapPackage? {
        guard let package = offlineMaps.activePackage else { return nil }
        let needsRouteCoverage = isShowingRouteOverview || location.location == nil
        let routeCoordinates: [CLLocationCoordinate2D] = needsRouteCoverage
            ? visibleRoutePolylines.flatMap { polyline -> [CLLocationCoordinate2D] in
                guard polyline.pointCount > 0 else { return [] }
                let points = polyline.points()
                return (0..<polyline.pointCount).map { points[$0].coordinate }
            }
            : []
        return OfflineMapCoveragePolicy.canUse(
            bounds: package.manifest.bounds,
            currentCoordinate: location.location?.coordinate,
            routeCoordinates: routeCoordinates,
            showsRouteOverview: isShowingRouteOverview
        ) ? package : nil
    }

    private var mapBase: some View {
        Map(position: $position) {
            #if targetEnvironment(simulator)
            Annotation("Vorschau", coordinate: .init(latitude: 50.0143, longitude: 8.3522), anchor: .center) {
                Image(systemName: isSimulatorNavigationPreview ? "car.fill" : "location.north.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(10)
                    .background(Color.kiesForest, in: Circle())
                    .overlay(Circle().stroke(Color.kiesIvory, lineWidth: 3))
                    .shadow(color: .black.opacity(0.25), radius: 5, y: 3)
            }
            if isSimulatorNavigationPreview {
                MapPolyline(simulatorPreviewPolyline)
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveLabels)
                MapPolyline(simulatorPreviewPolyline)
                    .stroke(Color.kiesRouteBlue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveLabels)
            }
            #else
            if planner.isNavigating, let coordinate = location.location?.coordinate {
                Annotation("Mein Auto", coordinate: coordinate, anchor: .center) {
                    Image(systemName: "car.fill")
                        .font(.system(size: 17, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(9)
                        .background(.blue.gradient, in: Circle())
                        .overlay(Circle().stroke(.white, lineWidth: 2))
                        .shadow(radius: 4)
                }
            } else {
                UserAnnotation()
            }
            #endif
            if let destination = planner.destination { Marker(item: destination) }
            ForEach(Array(planner.legs.enumerated()), id: \.offset) { _, leg in
                MapPolyline(leg.polyline)
                    .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveLabels)
                MapPolyline(leg.polyline)
                    .stroke(.blue, style: StrokeStyle(lineWidth: 5, lineCap: .round, lineJoin: .round))
                    .mapOverlayLevel(level: .aboveLabels)
            }
            if planner.legs.isEmpty {
                ForEach(Array(planner.offlinePolylines.enumerated()), id: \.offset) { _, polyline in
                    MapPolyline(polyline)
                        .stroke(.white.opacity(0.9), style: StrokeStyle(lineWidth: 7, lineCap: .round, lineJoin: .round))
                        .mapOverlayLevel(level: .aboveLabels)
                    MapPolyline(polyline)
                        .stroke(Color.kiesRouteBlue.opacity(0.8), style: StrokeStyle(lineWidth: 5, dash: [8, 5]))
                        .mapOverlayLevel(level: .aboveLabels)
                }
            }
            if !isShowingRouteOverview {
                ForEach(Array(planner.stations.prefix(showsNavigationUI ? 12 : 24))) { station in
                    Annotation(station.brand.isEmpty ? station.name : station.brand, coordinate: station.coordinate) {
                        Button { selectedStation = station } label: {
                            VStack(spacing: 2) {
                                Image(systemName: "fuelpump.fill").padding(8).background(.green, in: Circle()).foregroundStyle(.white)
                                Text(station.price.formatted(.number.locale(Locale(identifier: "de_DE"))
                                    .precision(.fractionLength(3))))
                                    .font(.caption.bold()).padding(.horizontal, 5)
                                    .background(.regularMaterial, in: Capsule())
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        #if os(iOS)
        .onMapCameraChange(frequency: .onEnd) { _ in
            if position.positionedByUser {
                isFollowingLocation = false
                isShowingRouteOverview = false
            }
        }
        #endif
        .mapControls {
            MapCompass(); MapScaleView()
            #if os(macOS)
            MapUserLocationButton()
            #endif
        }
        .overlay(alignment: .bottomTrailing) {
            #if os(iOS)
            if showsNavigationUI {
                VStack(spacing: 10) {
                    Button {
                        if isShowingRouteOverview {
                            followCurrentLocation()
                        } else {
                            showCompleteRoute()
                        }
                    } label: {
                        Image(systemName: "map.fill")
                            .font(.title3.bold()).padding(13)
                            .foregroundStyle(isShowingRouteOverview ? .blue : .primary)
                            .background(.ultraThickMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    }
                    .accessibilityLabel(isShowingRouteOverview ? "Zur Fahrzeugansicht zurückkehren" : "Gesamte Route anzeigen")
                    Button {
                        isShowingRouteOverview = false
                        followCurrentLocation()
                    } label: {
                        Image(systemName: isFollowingLocation ? "location.fill" : "location")
                            .font(.title3.bold()).padding(13)
                            .foregroundStyle(isFollowingLocation ? .blue : .primary)
                            .background(.ultraThickMaterial, in: Circle())
                            .shadow(color: .black.opacity(0.2), radius: 6, y: 3)
                    }
                    .accessibilityLabel("Navigation auf mein Auto zentrieren")
                }
                // Die untere ETA-Karte liegt als Safe-Area-Inset über der
                // Karte; genügend Abstand hält beide Knöpfe immer sichtbar.
                .padding(.trailing, 14).padding(.bottom, 190)
            } else {
                VStack(spacing: 10) {
                    Button { centerIdleMap() } label: {
                        Image(systemName: "location.fill")
                            .font(.title3.bold()).padding(13)
                            .foregroundStyle(Color.kiesForest)
                            .background(Color.kiesIvory.opacity(0.96), in: Circle())
                            .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
                    }
                    .accessibilityLabel("Karte auf meinen Standort zentrieren")
                    Button {
                        settings.mapAppearance = settings.mapAppearance == .standard ? .hybrid : .standard
                    } label: {
                        Image(systemName: settings.mapAppearance == .standard ? "square.3.layers.3d" : "map")
                            .font(.title3.bold()).padding(13)
                            .foregroundStyle(Color.kiesForest)
                            .background(Color.kiesIvory.opacity(0.96), in: Circle())
                            .shadow(color: .black.opacity(0.18), radius: 7, y: 3)
                    }
                    .accessibilityLabel(settings.mapAppearance == .standard ? "Hybridkarte anzeigen" : "Standardkarte anzeigen")
                }
                .padding(.trailing, 14).padding(.bottom, 220)
            }
            #endif
        }
        .overlay(alignment: .topLeading) {
            if !isShowingRouteOverview,
               let coordinate = location.location?.coordinate,
               let limit = planner.currentSpeedLimit(near: coordinate) {
                speedLimitSign(limit).padding()
            }
        }
        .overlay(alignment: .bottomLeading) {
            #if os(iOS)
            if isSimulatorNavigationPreview && !isShowingRouteOverview {
                VStack(spacing: 8) {
                    ZStack {
                        Circle().fill(.white).frame(width: 56, height: 56)
                        Circle().stroke(.red, lineWidth: 5).frame(width: 52, height: 52)
                        Text("100").font(.system(size: 17, weight: .heavy)).foregroundStyle(.black)
                    }
                    Text("84").font(.title2.bold()).monospacedDigit()
                        .frame(width: 58, height: 48)
                        .background(.ultraThickMaterial, in: RoundedRectangle(cornerRadius: 16))
                }
                .padding(.leading, 14).padding(.bottom, 190)
            }
            #endif
        }
        .overlay(alignment: .top) {
            #if os(macOS)
            HStack {
                if settings.avoidTolls { Label("Vignetten/Maut vermeiden", systemImage: "checkmark.shield.fill") }
                Picker("Karte", selection: $settings.mapAppearance) {
                    ForEach(DriveMapAppearance.allCases) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .frame(maxWidth: 280)
            }
            .padding(9).background(.regularMaterial, in: Capsule()).padding()
            #endif
        }
        .overlay(alignment: .bottom) {
            #if os(macOS)
            VStack(spacing: 8) {
                if planner.speedWarning {
                    Label("Zu schnell - Tempolimit beachten", systemImage: "exclamationmark.triangle.fill")
                        .padding(9).background(.red, in: Capsule()).foregroundStyle(.white)
                }
                if let announcement = planner.lastAnnouncement {
                    Label(announcement, systemImage: "speaker.wave.2.fill")
                        .padding(9).background(.regularMaterial, in: Capsule())
                }
            }
            .padding()
            #endif
        }
    }

    private var simulatorPreviewPolyline: MKPolyline {
        var coordinates = [
            CLLocationCoordinate2D(latitude: 50.001, longitude: 8.315),
            CLLocationCoordinate2D(latitude: 50.008, longitude: 8.332),
            CLLocationCoordinate2D(latitude: 50.0143, longitude: 8.3522),
            CLLocationCoordinate2D(latitude: 50.020, longitude: 8.375),
            CLLocationCoordinate2D(latitude: 50.027, longitude: 8.402),
        ]
        return MKPolyline(coordinates: &coordinates, count: coordinates.count)
    }

    private func centerIdleMap() {
        #if targetEnvironment(simulator)
        position = .region(.init(center: .init(latitude: 50.0143, longitude: 8.3522),
                                 latitudinalMeters: 18_000, longitudinalMeters: 18_000))
        #else
        guard let coordinate = location.location?.coordinate else { return }
        position = .region(.init(center: coordinate, latitudinalMeters: 18_000, longitudinalMeters: 18_000))
        #endif
    }

    /// Zeigt die zuletzt zwischengespeicherte Route (Ziel, Fahrhinweise,
    /// Tankstellen) an, damit unterwegs auch ohne Verbindung noch eine
    /// Orientierung möglich ist. Die vereinfachte Routenlinie bleibt lokal
    /// sichtbar; die eigentlichen Apple-Kartenkacheln sind nicht offline
    /// exportierbar und werden deshalb nicht fälschlich als verfügbar beworben.
    @ViewBuilder
    private func offlineRouteView(_ cached: CachedRoute) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Zwischengespeicherte Route (offline)", systemImage: "icloud.slash")
                .font(.headline)
            Text("Ziel: \(cached.destinationName)")
            ForEach(Array(cached.legs.enumerated()), id: \.offset) { _, leg in
                Label("\(formatDistance(leg.distance)) · \(formatTime(leg.travelTime))", systemImage: "road.lanes")
                ForEach(Array(leg.steps.enumerated()), id: \.offset) { _, step in
                    Text(step.instructions.isEmpty ? "Weiter" : step.instructions)
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            if !cached.stations.isEmpty {
                Text("Tankstellen (zuletzt bekannt):").font(.caption).bold()
                ForEach(cached.stations) { station in
                    Text("\(station.brand.isEmpty ? station.name : station.brand): \(String(format: "%.3f €", station.price))")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Stand: \(cached.savedAt.formatted(date: .abbreviated, time: .shortened))")
                .font(.caption2).foregroundStyle(.secondary)
        }
    }

    /// Rundes, deutsches Tempolimit-Schild - weißer Grund mit rotem Ring,
    /// bei "kein Limit" (freie Autobahn) ein durchgestrichenes Schild.
    @ViewBuilder
    private func speedLimitSign(_ limit: SpeedLimitResult) -> some View {
        ZStack {
            Circle().fill(.white).frame(width: 56, height: 56)
            if limit.unlimited {
                Circle().strokeBorder(.black, lineWidth: 3)
                Text("120").font(.system(size: 16, weight: .bold)).foregroundStyle(.black)
                Rectangle().fill(.black).frame(width: 56, height: 4).rotationEffect(.degrees(-35))
            } else if let maxspeed = limit.maxspeed {
                Circle().strokeBorder(.red, lineWidth: 5)
                Text("\(maxspeed)").font(.system(size: 20, weight: .bold)).foregroundStyle(.black)
            }
        }
        .shadow(radius: 3)
    }

    private func formatDistance(_ metres: Double) -> String { metres >= 1000 ? String(format: "%.1f km", metres / 1000) : "\(Int(metres)) m" }
    private func formatTime(_ seconds: TimeInterval) -> String { let m = Int(seconds / 60); return m >= 60 ? "\(m / 60) Std. \(m % 60) Min." : "\(m) Min." }
    private func formatArrival(_ seconds: TimeInterval) -> String {
        Date().addingTimeInterval(seconds).formatted(date: .omitted, time: .shortened)
    }

    @ViewBuilder
    private func comparisonSummary(_ plan: LongTripPlan) -> some View {
        if let comparison = SpeedScenarioComparisonPolicy.comparison(
            in: plan, configuredSpeed: settings.targetSpeedKmh
        ) {
            let delta = comparison.delta
            let baseSpeed = Int(comparison.baseline.scenario.targetSpeedKmh.rounded())
            let alternativeSpeed = Int(comparison.alternative.scenario.targetSpeedKmh.rounded())
            let eligibleKilometres = comparison.eligibleDistanceMetres / 1_000
            let eligiblePercent = Int((comparison.baseline.unlimitedFraction * 100).rounded())
            VStack(alignment: .leading, spacing: 4) {
                Text("\(alternativeSpeed) statt \(baseSpeed) km/h").font(.headline)
                Text("Fahrzeit \(signedTime(delta.timeDifference)) · Verbrauch \(signed(delta.fuelDifferenceLitres, unit: "l"))")
                Text("Kraftstoffkosten \(signed(delta.fuelCostDifference, unit: "€"))")
                Text("Wirkt nur auf ca. \(eligibleKilometres, format: .number.precision(.fractionLength(0))) km (\(eligiblePercent) %) erkannte, geeignete Abschnitte ohne Tempolimit. Verkehr und alle übrigen Straßen bleiben in der ETA berücksichtigt.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }

        let selectedSpeed = settings.targetSpeedKmh
        let routeOptions = plan.results.filter { $0.scenario.targetSpeedKmh == selectedSpeed }
        if routeOptions.count >= 2 {
            let delta = RouteComparisonDelta(from: routeOptions[0], to: routeOptions[1])
            VStack(alignment: .leading, spacing: 4) {
                Text("\(routeOptions[0].routeTitle) → \(routeOptions[1].routeTitle)").font(.headline)
                Text("\(signedTime(delta.timeDifference)) · \(signed(delta.distanceDifferenceMetres / 1_000, unit: "km")) · \(signed(delta.fuelCostDifference, unit: "€ Kraftstoff"))")
                if let savings = delta.tollSavings {
                    let currency = delta.tollCurrency ?? "EUR"
                    Text("Mautersparnis der Alternative: \(NSDecimalNumber(decimal: savings).doubleValue, format: .currency(code: currency))")
                    if let total = delta.totalCostDifference {
                        Text("Gesamtkosten der Alternative: \(signed(total, unit: "€"))")
                            .fontWeight(.semibold)
                    }
                } else {
                    Text("Maut- und Gesamtersparnis nicht berechenbar: keine verifizierten Preise.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func signed(_ value: Double, unit: String) -> String {
        String(format: "%@%.1f %@", value > 0 ? "+" : "", value, unit)
    }

    private func signedTime(_ seconds: TimeInterval) -> String {
        let minutes = Int((seconds / 60).rounded())
        return "\(minutes > 0 ? "+" : "")\(minutes) Min."
    }
}

struct DriveSettingsView: View {
    @ObservedObject var planner: RoutePlanner
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var settings = DriveSettings.shared
    @ObservedObject private var account = AccountSessionStore.shared
    @State private var connectionStatus: ConnectionStatus = .idle
    @State private var diagnosticEvents = DriveDiagnosticStore.load()
    @State private var accountProfile: AccountProfile?
    @State private var showTwoFactorSetup = false
    @State private var confirmAccountDeletion = false
    @StateObject private var offlineMaps = OfflineMapPackageStore.shared
    @State private var showOfflineMapImporter = false
    @State private var offlineMapImportError: String?
    @State private var currentFuelPercent = 100.0
    @State private var fuelLevelWasConfirmed = false

    fileprivate enum ConnectionStatus {
        case idle, testing, success, failed(String)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Kies-Konto") {
                    if let email = account.email {
                        LabeledContent("Angemeldet als", value: email)
                    } else {
                        Text("Bitte melde dich an, um Kies Drive zu verwenden.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Button {
                        connectionStatus = .testing
                        Task {
                            do {
                                try await DriveAPI.testConnection()
                                connectionStatus = .success
                            } catch {
                                connectionStatus = .failed(error.localizedDescription)
                            }
                        }
                    } label: {
                        Label(connectionStatus.isTesting ? "Verbindung wird geprüft …" : "Verbindung testen",
                              systemImage: "antenna.radiowaves.left.and.right")
                    }
                    .disabled(connectionStatus.isTesting || !settings.isReady)

                    Button("Abmelden", role: .destructive) {
                        Task {
                            await DriveAPI.logout()
                            dismiss()
                        }
                    }
                    .disabled(account.session == nil)

                    if accountProfile?.twoFactorEnabled == true {
                        Label("Zwei-Faktor-Authentifizierung aktiv", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                    } else {
                        Button("Zwei-Faktor-Authentifizierung einrichten") {
                            showTwoFactorSetup = true
                        }
                        .disabled(account.session == nil)
                    }

                    Button("Konto vollständig löschen", role: .destructive) {
                        confirmAccountDeletion = true
                    }
                    .disabled(account.session == nil)

                    switch connectionStatus {
                    case .idle:
                        EmptyView()
                    case .testing:
                        ProgressView()
                    case .success:
                        Label("Kies-Drive-Server und Anmeldung funktionieren.", systemImage: "checkmark.circle.fill")
                            .foregroundStyle(.green)
                    case .failed(let message):
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .foregroundStyle(.red)
                    }
                }
                Section("Route") {
                    TextField("Adresse für Zuhause", text: $settings.homeAddress)
                        .textContentType(.fullStreetAddress)
                    Toggle("Vignetten und Maut vermeiden", isOn: $settings.avoidTolls)
                        .onChange(of: settings.avoidTolls) { _, _ in applyRouteOptions() }
                    Toggle("Autobahnen vermeiden", isOn: $settings.avoidHighways)
                        .onChange(of: settings.avoidHighways) { _, _ in applyRouteOptions() }
                    Toggle("Sprachansagen", isOn: $settings.voiceGuidance)
                        .onChange(of: settings.voiceGuidance) { _, enabled in
                            planner.setVoiceGuidanceEnabled(enabled)
                        }
                    Picker("Kraftstoff", selection: $settings.fuel) {
                        ForEach(FuelKind.allCases) { Text($0.label).tag($0) }
                    }
                    .onChange(of: settings.fuel) { _, fuel in
                        guard !planner.legs.isEmpty else { return }
                        Task { await planner.reloadStopPlanning(fuel: fuel, settings: settings) }
                    }
                    Picker("Kartendarstellung", selection: $settings.mapAppearance) { ForEach(DriveMapAppearance.allCases) { Text($0.label).tag($0) } }
                }
                Section("Langstrecke & Fahrzeug") {
                    Stepper("Zieltempo auf geeigneten freien Abschnitten: \(Int(settings.targetSpeedKmh)) km/h", value: $settings.targetSpeedKmh, in: 100...220, step: 10)
                        .onChange(of: settings.targetSpeedKmh) { _, _ in planner.refreshLongTripPlan(settings: settings) }
                    LabeledContent("Normverbrauch") {
                        TextField("l/100 km", value: $settings.consumptionLPer100km, format: .number.precision(.fractionLength(1)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                            .onChange(of: settings.consumptionLPer100km) { _, _ in planner.refreshLongTripPlan(settings: settings) }
                    }
                    LabeledContent("Tankgröße") {
                        TextField("Liter", value: $settings.tankCapacityL, format: .number.precision(.fractionLength(0)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                            .onChange(of: settings.tankCapacityL) { _, _ in
                                planner.refreshLongTripPlan(settings: settings)
                            }
                    }
                    Stepper(
                        "Tank bei Abfahrt: \(Int(settings.departureFuelPercent)) %",
                        value: $settings.departureFuelPercent, in: 0...100, step: 5
                    )
                    .onChange(of: settings.departureFuelPercent) { _, _ in
                        planner.refreshLongTripPlan(settings: settings)
                    }
                    if planner.isNavigating || planner.activeRouteLock != nil {
                        Stepper(
                            "Tankstand jetzt: \(Int(currentFuelPercent)) %",
                            value: $currentFuelPercent, in: 0...100, step: 5
                        )
                        Button {
                            planner.confirmFuelLevel(currentFuelPercent / 100, settings: settings)
                            currentFuelPercent = planner.estimatedFuelFraction(settings: settings) * 100
                            fuelLevelWasConfirmed = true
                        } label: {
                            Label(
                                fuelLevelWasConfirmed ? "Tankstand übernommen" : "Aktuellen Tankstand übernehmen",
                                systemImage: fuelLevelWasConfirmed ? "checkmark.circle.fill" : "fuelpump"
                            )
                        }
                        .accessibilityHint("Berechnet Reichweite und Tankstopps ab dem aktuellen Standort neu")
                    }
                    LabeledContent("Kraftstoffpreis") {
                        TextField("€/l", value: $settings.fuelPricePerLitre, format: .number.precision(.fractionLength(2)))
                            .multilineTextAlignment(.trailing).frame(width: 90)
                            .onChange(of: settings.fuelPricePerLitre) { _, _ in planner.refreshLongTripPlan(settings: settings) }
                    }
                    Text("Das Zieltempo wird nur auf Streckenanteile ohne bekanntes Limit angewendet. MapKit-Verkehr, begrenzte Abschnitte und Pausen bleiben berücksichtigt.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Offline-Zwischenspeicher") {
                    if let cache = planner.offlineRoute {
                        LabeledContent("Gespeichert", value: cache.savedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Routenlinie", value: cache.legs.contains { ($0.coordinates?.count ?? 0) > 1 } ? "verfügbar" : "älterer Cache")
                    }
                    Button("Zwischengespeicherte Route löschen", role: .destructive) { planner.clearOfflineCache() }
                        .disabled(planner.offlineRoute == nil)
                }
                Section("Lokale Karten") {
                    if offlineMaps.packages.isEmpty {
                        ContentUnavailableView(
                            "Noch keine Kartenpakete",
                            systemImage: "map",
                            description: Text("Importiere einen Ordner mit manifest.json und tiles/z/x/y.png. So können eigene, lizenzierte Standardkarten später vollständig lokal angezeigt werden.")
                        )
                    } else {
                        Picker("Aktive Karte", selection: $offlineMaps.activePackageID) {
                            Text("Apple-Karte (online)").tag(String?.none)
                            ForEach(offlineMaps.packages) { package in
                                Text(package.manifest.name).tag(Optional(package.id))
                            }
                        }
                        ForEach(offlineMaps.packages) { package in
                            VStack(alignment: .leading, spacing: 3) {
                                HStack {
                                    Text(package.manifest.name).font(.headline)
                                    Spacer()
                                    Text(ByteCountFormatter.string(fromByteCount: package.byteCount, countStyle: .file))
                                        .foregroundStyle(.secondary)
                                }
                                Text("Zoom \(package.manifest.minimumZoom)–\(package.manifest.maximumZoom) · \(package.manifest.attribution)")
                                    .font(.caption).foregroundStyle(.secondary)
                                Button("Kartenpaket löschen", role: .destructive) {
                                    do { try offlineMaps.remove(package) }
                                    catch { offlineMapImportError = error.localizedDescription }
                                }
                            }
                        }
                    }
                    Button("Kartenpaket importieren …") { showOfflineMapImporter = true }
                    Text("Kies Drive lädt nicht ungefragt massenhaft Kartenkacheln. Pakete stammen aus einer von dir kontrollierten Quelle, zum Beispiel einem Export auf deinem TrueNAS, und müssen die Lizenz/Attribution nennen.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Section("Fahrstatistik") {
                    if planner.usageSessionState.distanceMetres > 0 ||
                        planner.usageSessionState.movingTime > 0 {
                        LabeledContent(
                            planner.isNavigating ? "Aktuelle Fahrt" : "Pausierter Trip",
                            value: usageDistance(planner.usageSessionState.distanceMetres)
                        )
                        LabeledContent(
                            "Davon in Bewegung",
                            value: usageDuration(planner.usageSessionState.movingTime)
                        )
                    }
                    LabeledContent("Gefahren", value: usageDistance(planner.usageStatistics.totalDistanceMetres))
                    LabeledContent("In Bewegung", value: usageDuration(planner.usageStatistics.totalMovingTime))
                    LabeledContent("Navigationsfahrten", value: "\(planner.usageStatistics.completedNavigations)")
                    if let endedAt = planner.usageStatistics.lastTripEndedAt {
                        LabeledContent("Letzte Fahrt", value: endedAt.formatted(date: .abbreviated, time: .shortened))
                        LabeledContent("Letzte Strecke", value: usageDistance(planner.usageStatistics.lastTripDistanceMetres))
                    }
                    Text("Der aktuelle Trip bleibt auch bei einer Pause oder einem Neustart erhalten. Gezählt wird ausschließlich plausible Bewegung während einer aktiven Kies-Drive-Navigation; ein Standortverlauf wird nicht gespeichert.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Fahrstatistik zurücksetzen", role: .destructive) {
                        planner.clearUsageStatistics()
                    }
                    .disabled(planner.usageStatistics.completedNavigations == 0)
                }
                Section("Navigationsqualität") {
                    let latestSummary = DriveDiagnosticSummary.latestSession(in: diagnosticEvents)
                    if let latestSummary {
                        LabeledContent("Letzte Fahrt", value: latestSummary.quality.rawValue)
                        Text(latestSummary.recommendation)
                            .font(.caption).foregroundStyle(.secondary)
                        if latestSummary.resolvedRouteIssues > 0 {
                            LabeledContent("Automatisch behoben", value: "\(latestSummary.resolvedRouteIssues)")
                        }
                        if latestSummary.quality != .good {
                            Text("Offen: \(latestSummary.rerouteFailures) fehlgeschlagene Neuberechnung(en), \(latestSummary.rejectedLocations) verworfene GPS-Messung(en), \(latestSummary.missedFinalCues) verpasste Endansage(n), \(latestSummary.speechDeliveryFailures) Audiofehler, \(latestSummary.offlineRouteDepartures) Offline-Abweichung(en).")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        LabeledContent("Ereignisse dieser Fahrt", value: "\(latestSummary.eventCount)")
                        LabeledContent("Neuberechnungen", value: "\(latestSummary.rerouteRequests)")
                        LabeledContent("Fehlgeschlagen", value: "\(latestSummary.rerouteFailures)")
                        LabeledContent("GPS-Ausreißer verworfen", value: "\(latestSummary.rejectedLocations)")
                        LabeledContent("Ziel sicher erkannt", value: "\(latestSummary.arrivals)")
                        LabeledContent("Gesprochene Fahrhinweise", value: "\(latestSummary.maneuverAnnouncements)")
                        LabeledContent("Nicht beendete Fahransagen", value: "\(latestSummary.speechDeliveryFailures)")
                        LabeledContent("Letzte Ansage verpasst", value: "\(latestSummary.missedFinalCues)")
                    } else {
                        LabeledContent("Letzte Fahrt", value: "Noch keine Daten")
                    }
                    LabeledContent("Ereignisse im lokalen Archiv", value: "\(diagnosticEvents.count)")
                    Text("Die Diagnose bleibt lokal auf diesem Gerät und enthält keine vollständige Standortspur.")
                        .font(.caption).foregroundStyle(.secondary)
                    ShareLink(item: DriveDiagnosticReport.text(
                        events: diagnosticEvents, appVersion: DriveSettings.appVersionString
                    )) {
                        Label("Diagnosebericht teilen", systemImage: "square.and.arrow.up")
                    }
                    .disabled(diagnosticEvents.isEmpty)
                    Button("Diagnose zurücksetzen", role: .destructive) {
                        DriveDiagnosticStore.clear()
                        diagnosticEvents = []
                    }
                }
                Section("Über") {
                    LabeledContent("App-Version", value: DriveSettings.appVersionString)
                }
                Section { Text("Interne Schlüssel für Tankpreise und Zusatzdienste bleiben ausschließlich auf deinem TrueNAS-Server. Deine Anmeldung wird automatisch im Apple-Schlüsselbund geschützt.").font(.caption).foregroundStyle(.secondary) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(.hidden)
            .background(Color.kiesCanvas)
            .tint(Color.kiesForest)
            .navigationTitle("Einstellungen")
            .toolbar { Button("Fertig") { dismiss() } }
            .task { accountProfile = try? await DriveAPI.account() }
            .onAppear {
                diagnosticEvents = DriveDiagnosticStore.load()
                currentFuelPercent = planner.estimatedFuelFraction(settings: settings) * 100
            }
            .onReceive(NotificationCenter.default.publisher(for: DriveDiagnosticStore.didChange)) { _ in
                diagnosticEvents = DriveDiagnosticStore.load()
            }
            .sheet(isPresented: $showTwoFactorSetup, onDismiss: {
                Task { accountProfile = try? await DriveAPI.account() }
            }) { TwoFactorSetupView() }
            .fileImporter(isPresented: $showOfflineMapImporter, allowedContentTypes: [.folder]) { result in
                do {
                    let url = try result.get()
                    let scoped = url.startAccessingSecurityScopedResource()
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    try offlineMaps.install(from: url)
                } catch {
                    offlineMapImportError = error.localizedDescription
                }
            }
            .alert("Kartenpaket konnte nicht importiert werden", isPresented: Binding(
                get: { offlineMapImportError != nil },
                set: { if !$0 { offlineMapImportError = nil } }
            )) {
                Button("OK", role: .cancel) { offlineMapImportError = nil }
            } message: {
                Text(offlineMapImportError ?? "Unbekannter Fehler")
            }
            .alert("Konto wirklich löschen?", isPresented: $confirmAccountDeletion) {
                Button("Abbrechen", role: .cancel) {}
                Button("Endgültig löschen", role: .destructive) {
                    Task {
                        try? await DriveAPI.deleteAccount()
                        dismiss()
                    }
                }
            } message: {
                Text("Dein Konto, Remote-Befehle und gespeicherte Serverdaten werden endgültig entfernt. Lokale Routen auf diesem Gerät bleiben erhalten.")
            }
        }
        #if os(macOS)
        .frame(minWidth: 420, minHeight: 420)
        #endif
        .environment(\.colorScheme, .light)
    }

    private func applyRouteOptions() {
        guard !planner.legs.isEmpty,
              let current = LocationService.shared.location?.coordinate else {
            planner.updateLockedRouteOptions(
                waypointID: nil, avoidTolls: settings.avoidTolls,
                avoidHighways: settings.avoidHighways
            )
            return
        }
        Task {
            await planner.updateRouteOptionsAndRecalculate(
                waypointID: nil, avoidTolls: settings.avoidTolls,
                avoidHighways: settings.avoidHighways,
                from: current, settings: settings
            )
        }
    }

    private func usageDistance(_ metres: CLLocationDistance) -> String {
        String(format: "%.1f km", metres / 1_000)
    }

    private func usageDuration(_ interval: TimeInterval) -> String {
        let minutes = Int(interval / 60)
        let hours = minutes / 60
        let remainder = minutes % 60
        return hours > 0 ? "\(hours) Std. \(remainder) Min." : "\(minutes) Min."
    }
}

private struct TwoFactorSetupView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var setup: TwoFactorSetup?
    @State private var code = ""
    @State private var message: String?
    @State private var isWorking = false
    @State private var recoveryCodes: [String] = []

    var body: some View {
        NavigationStack {
            Form {
                Section("Authenticator verbinden") {
                    if !recoveryCodes.isEmpty {
                        Label("Zwei-Faktor-Schutz ist aktiv", systemImage: "checkmark.shield.fill")
                            .foregroundStyle(.green)
                        Text("Speichere diese einmaligen Wiederherstellungscodes jetzt sicher. Sie werden nicht noch einmal angezeigt.")
                        Text(recoveryCodes.joined(separator: "\n"))
                            .font(.system(.body, design: .monospaced))
                            .textSelection(.enabled)
                        Button("Fertig") { dismiss() }.buttonStyle(.borderedProminent)
                    } else if let setup {
                        Text("Öffne deine Authenticator-App und füge dieses Konto hinzu.")
                        if let qrCode = TwoFactorQRCode.image(for: setup.provisioningURI) {
                            Image(decorative: qrCode, scale: 1)
                                .interpolation(.none)
                                .resizable()
                                .scaledToFit()
                                .frame(maxWidth: 220, maxHeight: 220)
                                .padding(12)
                                .background(.white, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                                .accessibilityLabel("QR-Code für die Authenticator-App")
                        }
                        Link("In Authenticator öffnen", destination: URL(string: setup.provisioningURI)!)
                        LabeledContent("Schlüssel", value: setup.secret)
                            .textSelection(.enabled)
                        Group {
                            #if os(iOS)
                            TextField("6-stelliger Code", text: $code)
                                .textContentType(.oneTimeCode).keyboardType(.numberPad)
                            #else
                            TextField("6-stelliger Code", text: $code).textContentType(.oneTimeCode)
                            #endif
                        }
                        .onChange(of: code) { _, value in
                            code = String(value.filter { $0.isNumber }.prefix(6))
                        }
                        Button("2FA aktivieren") { enable() }
                            .disabled(isWorking || code.count != 6)
                    } else if let message {
                        Label(message, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
                    } else {
                        ProgressView("Sichere Einrichtung wird vorbereitet …")
                    }
                }
                Section {
                    Text("Nach der Aktivierung brauchst du bei jeder neuen Anmeldung zusätzlich den sechsstelligen Code aus deiner Authenticator-App.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Zwei-Faktor-Schutz")
            .toolbar { Button("Abbrechen") { dismiss() } }
            .task {
                do { setup = try await DriveAPI.setupTwoFactor() }
                catch { message = error.localizedDescription }
            }
        }
    }

    private func enable() {
        isWorking = true
        Task {
            do {
                recoveryCodes = try await DriveAPI.enableTwoFactor(code: code)
            } catch {
                message = error.localizedDescription
            }
            isWorking = false
        }
    }

}

private enum TwoFactorQRCode {
    private static let context = CIContext(options: [.useSoftwareRenderer: false])

    static func image(for value: String) -> CGImage? {
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "M"
        guard let output = filter.outputImage?.transformed(by: .init(scaleX: 8, y: 8)) else {
            return nil
        }
        return context.createCGImage(output, from: output.extent)
    }
}

private struct FirstLoginSecurityView: View {
    @ObservedObject private var account = AccountSessionStore.shared
    @State private var showSetup = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "checkmark.shield.fill")
                    .font(.system(size: 58))
                    .foregroundStyle(Color.kiesBrass)
                VStack(spacing: 8) {
                    Text("Dein Konto ist bereit")
                        .font(.title2.bold())
                    Text("Deine E-Mail-Adresse ist bestätigt. Schütze dein Konto zusätzlich mit einem Code aus deiner Authenticator-App.")
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                }
                Button("Zwei-Faktor-Schutz einrichten") { showSetup = true }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.kiesForest)
                    .controlSize(.large)
                Button("Später in den Einstellungen") {
                    account.dismissTwoFactorSetupOffer()
                }
                .buttonStyle(.plain)
                .foregroundStyle(Color.kiesForest)
                Spacer()
            }
            .padding(30)
            .background(Color.kiesCanvas.ignoresSafeArea())
            .interactiveDismissDisabled()
            .sheet(isPresented: $showSetup, onDismiss: {
                account.dismissTwoFactorSetupOffer()
            }) {
                TwoFactorSetupView()
            }
        }
    }
}

private struct AccountWelcomeView: View {
    private enum Mode: String, CaseIterable, Identifiable {
        case login = "Anmelden"
        case register = "Registrieren"
        var id: String { rawValue }
    }

    @ObservedObject private var account = AccountSessionStore.shared
    @State private var mode: Mode = .register
    @State private var email = ""
    @State private var password = ""
    @State private var passwordConfirmation = ""
    @State private var totpCode = ""
    @State private var needsTwoFactor = false
    @State private var isWorking = false
    @State private var message: String?
    @State private var isError = false
    @State private var awaitingVerification = false
    @State private var registrationTicket: String?

    var body: some View {
        ZStack {
            LinearGradient(colors: [Color.kiesForest, Color.kiesForest.opacity(0.82)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
                .ignoresSafeArea()
            ScrollView {
                VStack(spacing: 24) {
                    Spacer(minLength: 54)
                    Image(systemName: "location.north.circle.fill")
                        .font(.system(size: 66)).foregroundStyle(Color.kiesBrass)
                    VStack(spacing: 7) {
                        Text("KIES DRIVE").font(.title.bold()).tracking(3)
                        Text("Deine Route. Dein Konto. Auf jedem Gerät.")
                            .font(.subheadline).foregroundStyle(.white.opacity(0.72))
                    }.foregroundStyle(.white)

                    VStack(spacing: 16) {
                        if awaitingVerification {
                            verificationPanel
                        } else {
                            Picker("Konto", selection: $mode) {
                                ForEach(Mode.allCases) { Text($0.rawValue).tag($0) }
                            }
                            .pickerStyle(.segmented)
                            .onChange(of: mode) { _, _ in
                                needsTwoFactor = false
                                totpCode = ""
                                passwordConfirmation = ""
                                message = nil
                            }

                            #if os(iOS)
                            TextField("E-Mail-Adresse", text: $email)
                                .textContentType(.emailAddress).textInputAutocapitalization(.never)
                                .keyboardType(.emailAddress)
                            #else
                            TextField("E-Mail-Adresse", text: $email)
                                .textContentType(.emailAddress)
                            #endif
                            SecureField("Passwort (mindestens 12 Zeichen)", text: $password)
                                .textContentType(mode == .login ? .password : .newPassword)
                            if mode == .register {
                                SecureField("Passwort wiederholen", text: $passwordConfirmation)
                                    .textContentType(.newPassword)
                            }
                            if mode == .login && needsTwoFactor {
                                #if os(iOS)
                                TextField("Authenticator- oder Wiederherstellungscode", text: $totpCode)
                                    .textContentType(.oneTimeCode).textInputAutocapitalization(.characters)
                                    .keyboardType(.asciiCapable)
                                #else
                                TextField("Authenticator- oder Wiederherstellungscode", text: $totpCode)
                                    .textContentType(.oneTimeCode)
                                #endif
                            }

                            statusMessage

                            Button(action: submit) {
                                Group {
                                    if isWorking { ProgressView().tint(.white) }
                                    else { Text(mode.rawValue).fontWeight(.semibold) }
                                }.frame(maxWidth: .infinity).frame(height: 24)
                            }
                            .buttonStyle(.borderedProminent).tint(Color.kiesForest)
                            .disabled(!canSubmit)

                            if mode == .login {
                                ViewThatFits(in: .horizontal) {
                                    HStack(spacing: 20) {
                                        Button("Passwort vergessen?") { requestPasswordReset() }
                                        Button("Bestätigungs-Mail erneut senden") { resendVerification() }
                                    }
                                    VStack(spacing: 12) {
                                        Button("Passwort vergessen?") { requestPasswordReset() }
                                        Button("Bestätigungs-Mail erneut senden") { resendVerification() }
                                    }
                                }
                                .buttonStyle(.plain).font(.footnote.weight(.semibold))
                                .foregroundStyle(Color.kiesForest)
                                .disabled(isWorking || email.isEmpty)
                            }

                            if mode == .register {
                                Text("Wir senden dir anschließend einen Bestätigungslink per E-Mail. Öffne ihn auf diesem Gerät – Kies Drive übernimmt den bestätigten Account automatisch.")
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    .textFieldStyle(.roundedBorder)
                    .padding(22)
                    .background(Color.kiesIvory, in: RoundedRectangle(cornerRadius: 28, style: .continuous))
                    .environment(\.colorScheme, .light)
                    Spacer(minLength: 30)
                }
                .padding(.horizontal, 22)
            }
        }
        .interactiveDismissDisabled()
        .onAppear {
            guard registrationTicket == nil,
                  let pendingTicket = account.pendingRegistrationTicket else { return }
            registrationTicket = pendingTicket
            email = account.pendingRegistrationEmail ?? email
            awaitingVerification = true
        }
        .onOpenURL { url in
            guard url.scheme == "kiesdrive", url.host == "auth-complete",
                  registrationTicket != nil else { return }
            completeVerification()
        }
    }

    private var canSubmit: Bool {
        guard !isWorking, !email.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              !password.isEmpty else { return false }
        return mode == .login || (password.count >= 12 && password == passwordConfirmation)
    }

    @ViewBuilder private var statusMessage: some View {
        if let message {
            Label(message, systemImage: isError ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                .font(.footnote).foregroundStyle(isError ? .red : Color.kiesForest)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var verificationPanel: some View {
        VStack(spacing: 16) {
            Image(systemName: "envelope.badge.shield.half.filled")
                .font(.system(size: 42)).foregroundStyle(Color.kiesBrass)
            Text("Bestätige deine E-Mail").font(.title3.bold())
            Text("Wir haben einen sicheren Bestätigungslink an **\(email)** gesendet. Öffne ihn auf diesem Gerät; Kies Drive meldet dich danach automatisch an.")
                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
            statusMessage
            Button("Bestätigung prüfen und anmelden") { completeVerification() }
            .buttonStyle(.borderedProminent).tint(Color.kiesForest)
            .disabled(isWorking)
            Button("E-Mail erneut senden") { resendVerification() }
                .buttonStyle(.plain).font(.footnote.weight(.semibold))
                .disabled(isWorking)
            Button("Andere E-Mail-Adresse verwenden") {
                awaitingVerification = false
                registrationTicket = nil
                account.clearPendingRegistration()
                mode = .register
                password = ""
                message = nil
            }
            .buttonStyle(.plain).font(.footnote)
        }
    }

    private func submit() {
        isWorking = true
        message = nil
        Task {
            do {
                if mode == .register {
                    guard password.count >= 12 else {
                        throw DriveAPIError.server("Das Passwort muss mindestens 12 Zeichen lang sein.")
                    }
                    guard password == passwordConfirmation else {
                        throw DriveAPIError.server("Die beiden Passwörter stimmen nicht überein.")
                    }
                    registrationTicket = try await DriveAPI.register(email: email, password: password)
                    password = ""
                    passwordConfirmation = ""
                    isError = false
                    if registrationTicket != nil {
                        message = nil
                        awaitingVerification = true
                    } else {
                        mode = .login
                        message = "Falls diese Adresse bereits registriert ist, kannst du dich jetzt anmelden."
                    }
                } else {
                    _ = try await DriveAPI.login(email: email, password: password, totpCode: totpCode)
                }
            } catch DriveAPIError.twoFactorRequired {
                needsTwoFactor = true
                message = "Dein Konto ist geschützt. Gib den Code aus deiner Authenticator-App ein."
                isError = false
            } catch {
                message = error.localizedDescription
                isError = true
            }
            isWorking = false
        }
    }

    private func completeVerification() {
        guard !isWorking, let registrationTicket else { return }
        isWorking = true
        message = nil
        Task {
            do {
                _ = try await DriveAPI.completeRegistration(ticket: registrationTicket)
            } catch {
                message = error.localizedDescription
                isError = true
            }
            isWorking = false
        }
    }

    private func requestPasswordReset() {
        isWorking = true
        message = nil
        Task {
            do {
                try await DriveAPI.requestPasswordReset(email: email)
                message = "Falls ein Konto existiert, ist die E-Mail zum Zurücksetzen unterwegs."
                isError = false
            } catch {
                message = error.localizedDescription
                isError = true
            }
            isWorking = false
        }
    }

    private func resendVerification() {
        isWorking = true
        message = nil
        Task {
            do {
                try await DriveAPI.resendVerification(email: email)
                message = "Falls die Adresse noch bestätigt werden muss, ist eine neue E-Mail unterwegs."
                isError = false
            } catch {
                message = error.localizedDescription
                isError = true
            }
            isWorking = false
        }
    }
}

private extension Color {
    static let kiesForest = Color(red: 0.08, green: 0.20, blue: 0.16)
    static let kiesIvory = Color(red: 0.97, green: 0.95, blue: 0.89)
    static let kiesBrass = Color(red: 0.69, green: 0.53, blue: 0.25)
    static let kiesRouteBlue = Color(red: 0.10, green: 0.43, blue: 0.86)
    static let kiesCanvas = Color(red: 0.93, green: 0.91, blue: 0.85)
}

private struct DriveCardModifier: ViewModifier {
    func body(content: Content) -> some View {
        content
            .padding(16)
            .background(Color.kiesIvory, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 20, style: .continuous)
                .stroke(Color.kiesForest.opacity(0.08), lineWidth: 1))
            .shadow(color: .black.opacity(0.06), radius: 12, y: 5)
    }
}

private extension View {
    func driveCard() -> some View { modifier(DriveCardModifier()) }
}

private extension DriveSettingsView.ConnectionStatus {
    var isTesting: Bool {
        if case .testing = self { return true }
        return false
    }
}

struct JarvisDriveView: View {
    let route: MKRoute?
    let destination: MKMapItem?
    @Environment(\.dismiss) private var dismiss
    @State private var message = ""
    @State private var reply = ""
    @State private var loading = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                ScrollView { Text(reply.isEmpty ? "Frag Jarvis nach der Route, einem Zwischenstopp oder deiner Ankunft." : reply).frame(maxWidth: .infinity, alignment: .leading).padding() }
                HStack {
                    TextField("Jarvis fragen …", text: $message).textFieldStyle(.roundedBorder).onSubmit { ask() }
                    Button("Senden", systemImage: "arrow.up.circle.fill") { ask() }.disabled(message.isEmpty || loading)
                }.padding()
            }
            .navigationTitle("Jarvis unterwegs")
            .toolbar { Button("Schließen") { dismiss() } }
        }
        #if os(macOS)
        .frame(minWidth: 440, minHeight: 480)
        #endif
    }

    private func ask() {
        let routeContext = route.map { " Ziel: \(destination?.name ?? "unbekannt"), Entfernung \(Int($0.distance / 1000)) km, Fahrzeit \(Int($0.expectedTravelTime / 60)) Minuten." } ?? ""
        let prompt = "Du unterstützt mich gerade bei einer Autofahrt.\(routeContext) Meine Frage: \(message)"
        loading = true
        Task { do { reply = try await DriveAPI.askJarvis(prompt) } catch { reply = error.localizedDescription }; loading = false }
    }
}
