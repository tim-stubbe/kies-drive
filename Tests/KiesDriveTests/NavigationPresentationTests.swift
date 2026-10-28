import XCTest
import CoreLocation
import MapKit
@testable import Kies_Drive

final class NavigationPresentationTests: XCTestCase {
    func testDistancePresentationUsesLocalizedMetricFormattingForTripScale() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(
            NavigationDistancePresentationPolicy.text(1_170_000, locale: german),
            "1.170 km"
        )
        XCTAssertEqual(
            NavigationDistancePresentationPolicy.text(19_600, locale: german),
            "19,6 km"
        )
        XCTAssertEqual(
            NavigationDistancePresentationPolicy.text(999.6, locale: german),
            "1,0 km"
        )
        XCTAssertEqual(
            NavigationDistancePresentationPolicy.text(.nan, locale: german),
            "—"
        )
    }

    func testIdleTimerIsDisabledOnlyForForegroundNavigation() {
        XCTAssertTrue(NavigationIdleTimerPolicy.shouldDisable(
            navigationActive: true, sceneActive: true
        ))
        XCTAssertFalse(NavigationIdleTimerPolicy.shouldDisable(
            navigationActive: false, sceneActive: true
        ))
        XCTAssertFalse(NavigationIdleTimerPolicy.shouldDisable(
            navigationActive: true, sceneActive: false
        ))
        XCTAssertFalse(NavigationIdleTimerPolicy.shouldDisable(
            navigationActive: false, sceneActive: false
        ))
    }

    func testRoundaboutPresentationKeepsOrdinalExitVisible() {
        let german = NavigationManeuverPresentation(
            "Im Kreisverkehr die zweite Ausfahrt Richtung Mainz nehmen"
        )
        XCTAssertEqual(german.direction, .roundabout)
        XCTAssertEqual(german.exitLabel, "2. Ausfahrt")
        XCTAssertEqual(german.destinationLabel, "Mainz")

        XCTAssertEqual(
            NavigationManeuverPresentation(
                "Im Kreisverkehr die 3. Ausfahrt nehmen"
            ).exitLabel,
            "3. Ausfahrt"
        )
        XCTAssertEqual(
            NavigationManeuverPresentation(
                "At the roundabout, take the 4th exit"
            ).exitLabel,
            "4. Ausfahrt"
        )
    }

    func testGermanAbfahrtSynonymKeepsExitNumberAndDirection() {
        let presentation = NavigationManeuverPresentation(
            "Nehmen Sie Abfahrt 7 links Richtung Hochheim"
        )

        XCTAssertEqual(presentation.exitLabel, "Ausfahrt 7")
        XCTAssertEqual(presentation.direction, .left)
        XCTAssertEqual(presentation.destinationLabel, "Hochheim")
        XCTAssertEqual(
            CarPlayManeuverSemanticPolicy.semantic(for: presentation),
            .highwayOffRampLeft
        )
    }

    func testOrdinalsOutsideRoundaboutsDoNotInventExitLabels() {
        XCTAssertNil(NavigationManeuverPresentation(
            "Die zweite Straße rechts nehmen"
        ).exitLabel)
        XCTAssertNil(NavigationManeuverPresentation(
            "Am Kreisverkehr geradeaus fahren"
        ).exitLabel)
    }

    func testSearchCompletionGatePublishesExactlyOnce() {
        let gate = NavigationSearchCompletionGate<[String]>()
        var published: [[String]] = []

        XCTAssertTrue(gate.complete(["first"]) { published.append($0) })
        XCTAssertFalse(gate.complete(["late"]) { published.append($0) })
        XCTAssertTrue(gate.didComplete)
        XCTAssertEqual(published, [["first"]])
        XCTAssertEqual(NavigationSearchTimeoutPolicy.timeoutNanoseconds, 8_000_000_000)
    }

    func testCarPlayAlertPrefersConcreteFailureReason() {
        XCTAssertEqual(
            CarPlayAlertPresentationPolicy.titleVariants(for: "  Standort fehlt.  "),
            ["Standort fehlt.", "Aktion nicht möglich"]
        )
        XCTAssertEqual(
            CarPlayAlertPresentationPolicy.titleVariants(for: "  "),
            ["Aktion nicht möglich"]
        )
    }

    func testCarPlayNeverTurnsUnknownManeuverDistanceIntoZero() {
        XCTAssertNil(CarPlayManeuverEstimatePolicy.distance(nil))
        XCTAssertNil(CarPlayManeuverEstimatePolicy.distance(.nan))
        XCTAssertNil(CarPlayManeuverEstimatePolicy.distance(-1))
        XCTAssertEqual(CarPlayManeuverEstimatePolicy.distance(0), 0)
        XCTAssertEqual(CarPlayManeuverEstimatePolicy.distance(450), 450)
    }

    func testCarPlayBreakReminderKeepsConcreteTextAndShortFallback() {
        XCTAssertEqual(
            CarPlayBreakReminderPresentationPolicy.titleVariants(
                for: "  Bitte in etwa 10 Minuten Pause einlegen.  "
            ),
            ["Bitte in etwa 10 Minuten Pause einlegen.", "Pause einplanen"]
        )
        XCTAssertEqual(CarPlayBreakReminderPresentationPolicy.titleVariants(for: "  "), [])
    }

    func testCarPlayStopReminderUsesOneSemanticAlert() {
        let combined = "Bei Autohof Spessart Pause machen und dort tanken."
        XCTAssertEqual(CarPlayStopReminderPresentationPolicy.kind(for: combined), .combined)
        XCTAssertEqual(
            CarPlayStopReminderPresentationPolicy.titleVariants(for: combined),
            [combined, "Fahrtstopp einplanen"]
        )
        XCTAssertEqual(
            CarPlayStopReminderPresentationPolicy.kind(for: "Bitte Pause einlegen."),
            .rest
        )
        XCTAssertEqual(
            CarPlayStopReminderPresentationPolicy.kind(for: "Jetzt tanken."),
            .fuel
        )
        XCTAssertTrue(CarPlayStopReminderPresentationPolicy.titleVariants(for: "  ").isEmpty)
    }

    func testDestinationSearchPublishesOnlyForCurrentUnchangedQuery() {
        let current = UUID()
        XCTAssertTrue(DestinationSearchCompletionPolicy.mayPublish(
            request: current, currentRequest: current,
            query: "Hochheim", currentText: "  Hochheim  "
        ))
        XCTAssertFalse(DestinationSearchCompletionPolicy.mayPublish(
            request: UUID(), currentRequest: current,
            query: "Hochheim", currentText: "Hochheim"
        ))
        XCTAssertFalse(DestinationSearchCompletionPolicy.mayPublish(
            request: current, currentRequest: current,
            query: "Hochheim", currentText: "Mainz"
        ))
    }

    func testDestinationSearchDistinguishesEmptyResultsFromFailures() {
        XCTAssertEqual(
            DestinationSearchBatchCompletionPolicy.resolution(
                resultCount: 2, failureCount: 0, searchCount: 2
            ),
            .results
        )
        XCTAssertEqual(
            DestinationSearchBatchCompletionPolicy.resolution(
                resultCount: 0, failureCount: 0, searchCount: 2
            ),
            .noResults
        )
        XCTAssertEqual(
            DestinationSearchBatchCompletionPolicy.resolution(
                resultCount: 0, failureCount: 1, searchCount: 2
            ),
            .noResults
        )
        XCTAssertEqual(
            DestinationSearchBatchCompletionPolicy.resolution(
                resultCount: 0, failureCount: 2, searchCount: 2
            ),
            .failed
        )
    }

    func testRouteWideAmenitySearchCannotStopAfterEarlyNearbyResults() {
        XCTAssertTrue(NavigationSearchBatchPolicy.shouldFinishEarly(
            uniqueResultCount: NavigationSearchBatchPolicy.usefulResultCount,
            completedSearches: NavigationSearchBatchPolicy.minimumCompletedSearches,
            totalSearches: 12
        ))
        XCTAssertFalse(NavigationSearchBatchPolicy.shouldFinishEarly(
            allowsEarlyFinish: false,
            uniqueResultCount: NavigationSearchBatchPolicy.usefulResultCount,
            completedSearches: NavigationSearchBatchPolicy.minimumCompletedSearches,
            totalSearches: 12
        ), "Long-trip stop searches must cover later route regions even when the first areas return many results")
    }

    func testBreakAmenitySearchExplainsTimeoutCoverage() {
        XCTAssertNil(BreakAmenitySearchPolicy.incompleteCoverageMessage(
            completedSearches: 12, totalSearches: 12
        ))
        XCTAssertEqual(
            BreakAmenitySearchPolicy.incompleteCoverageMessage(
                completedSearches: 5, totalSearches: 12
            ),
            "Pausenorte nur teilweise geprüft (5 von 12 Suchbereichen). Weitere passende Orte können fehlen."
        )
    }

    func testRouteSearchExplainsWhyNoStopCanBeOffered() {
        XCTAssertEqual(
            RouteSearchEmptyResultPolicy.message(
                mapMatches: 0, corridorMatches: 0, acceptableDetours: 0
            ),
            "Keine passenden Orte entlang der verbleibenden Route gefunden."
        )
        XCTAssertEqual(
            RouteSearchEmptyResultPolicy.message(
                mapMatches: 4, corridorMatches: 0, acceptableDetours: 0
            ),
            "Treffer gefunden, aber keiner liegt sinnvoll voraus an deiner Route."
        )
        XCTAssertEqual(
            RouteSearchEmptyResultPolicy.message(
                mapMatches: 4, corridorMatches: 2, acceptableDetours: 0
            ),
            "Treffer gefunden, aber der zusätzliche Fahrweg wäre zu groß."
        )
        XCTAssertNil(RouteSearchEmptyResultPolicy.message(
            mapMatches: 4, corridorMatches: 2, acceptableDetours: 1
        ))
    }

    func testRouteSearchReportsIncompleteMapCoverageWithoutHidingUsefulResults() {
        XCTAssertNil(RouteSearchEmptyResultPolicy.incompleteCoverageMessage(completed: 20, total: 20))
        XCTAssertEqual(
            RouteSearchEmptyResultPolicy.incompleteCoverageMessage(completed: 8, total: 20),
            "Suche teilweise abgeschlossen (8 von 20 Bereichen). Es können weitere Treffer fehlen."
        )
        XCTAssertEqual(
            RouteSearchEmptyResultPolicy.combinedMessage(
                emptyResultMessage: nil, completed: 8, total: 20
            ),
            "Suche teilweise abgeschlossen (8 von 20 Bereichen). Es können weitere Treffer fehlen."
        )
        XCTAssertEqual(
            RouteSearchEmptyResultPolicy.combinedMessage(
                emptyResultMessage: "Keine passenden Orte entlang der verbleibenden Route gefunden.",
                completed: 8, total: 20
            ),
            "Keine passenden Orte entlang der verbleibenden Route gefunden. Suche teilweise abgeschlossen (8 von 20 Bereichen). Es können weitere Treffer fehlen."
        )
    }

    func testEditedDestinationQueryCannotKeepOldCoordinateSelected() {
        XCTAssertTrue(DestinationQuerySelectionPolicy.stillRepresentsSelection(
            query: "  München Hauptbahnhof ",
            selectedName: "MUNCHEN HAUPTBAHNHOF",
            selectedTitle: "München Hauptbahnhof, Bayern"
        ))
        XCTAssertFalse(DestinationQuerySelectionPolicy.stillRepresentsSelection(
            query: "Hamburg Hauptbahnhof",
            selectedName: "München Hauptbahnhof",
            selectedTitle: "München Hauptbahnhof, Bayern"
        ))
        XCTAssertFalse(DestinationQuerySelectionPolicy.stillRepresentsSelection(
            query: "", selectedName: "München Hauptbahnhof", selectedTitle: nil
        ))
    }

    func testRapidDestinationChangesKeepOriginalRollbackBaseline() {
        let original = DestinationActivationBaselinePolicy.choose(
            existing: Optional<String>.none, current: "Original route"
        )
        let secondTap = DestinationActivationBaselinePolicy.choose(
            existing: Optional(original), current: "First in-flight destination"
        )

        XCTAssertEqual(original, "Original route")
        XCTAssertEqual(secondTap, "Original route")
    }

    func testRapidRouteStopChangesKeepOriginalRollbackBaseline() {
        let original = RouteMutationBaselinePolicy.choose(
            existing: Optional<[String]>.none, current: ["required-pass"]
        )
        let secondTap = RouteMutationBaselinePolicy.choose(
            existing: Optional(original), current: ["required-pass", "first-in-flight-stop"]
        )

        XCTAssertEqual(secondTap, ["required-pass"])
    }

    func testRapidRouteOptionChangesKeepOriginalRollbackBaseline() {
        let original = RouteMutationBaselinePolicy.choose(
            existing: Optional<[Bool]>.none, current: [false, false]
        )
        let secondToggle = RouteMutationBaselinePolicy.choose(
            existing: Optional(original), current: [true, false]
        )

        XCTAssertEqual(secondToggle, [false, false])
    }

    func testGlobalRouteOptionRollbackUsesLastCalculatedLockInsteadOfNewToggleValue() {
        let baseline = RouteOptionSettingsBaselinePolicy.baseline(
            waypointID: nil,
            activeDefaults: .init(avoidTolls: false, avoidHighways: true),
            currentAvoidTolls: true,
            currentAvoidHighways: false
        )

        XCTAssertEqual(baseline, .init(avoidTolls: false, avoidHighways: true))
    }

    func testPreviewRouteOptionRollbackUsesInstalledRouteOptionsWithoutTripLock() {
        let installedPreview = LockedRouteOptions(
            avoidTolls: false, avoidHighways: false
        )
        let baseline = RouteOptionSettingsBaselinePolicy.baseline(
            waypointID: nil,
            activeDefaults: installedPreview,
            currentAvoidTolls: true,
            currentAvoidHighways: false
        )

        XCTAssertEqual(baseline, installedPreview)
    }

    func testScopedRouteOptionChangeDoesNotReplaceGlobalSettingsBaseline() {
        let baseline = RouteOptionSettingsBaselinePolicy.baseline(
            waypointID: "slovenia",
            activeDefaults: .init(avoidTolls: false, avoidHighways: true),
            currentAvoidTolls: true,
            currentAvoidHighways: false
        )

        XCTAssertEqual(baseline, .init(avoidTolls: true, avoidHighways: false))
    }

    func testCarPlayTripCallbackDoesNotRestartActiveGuidance() {
        XCTAssertTrue(CarPlayTripStartPolicy.shouldStartNavigation(isNavigating: false))
        XCTAssertFalse(CarPlayTripStartPolicy.shouldStartNavigation(isNavigating: true))
    }

    func testCarPlaySpeedLimitBadgeUsesOnlyVerifiedRouteEvidence() {
        XCTAssertEqual(CarPlaySpeedLimitBadgePolicy.state(
            limit: .init(maxspeed: 80, unlimited: false),
            speedWarning: false, navigationActive: true
        ), .numeric(value: 80, warning: false))
        XCTAssertEqual(CarPlaySpeedLimitBadgePolicy.state(
            limit: .init(maxspeed: 80, unlimited: false),
            speedWarning: true, navigationActive: true
        ), .numeric(value: 80, warning: true))
        XCTAssertEqual(CarPlaySpeedLimitBadgePolicy.state(
            limit: .init(maxspeed: nil, unlimited: true),
            speedWarning: false, navigationActive: true
        ), .unrestricted)
        XCTAssertEqual(CarPlaySpeedLimitBadgePolicy.state(
            limit: .init(maxspeed: nil, unlimited: false),
            speedWarning: false, navigationActive: true
        ), .hidden)
        XCTAssertEqual(CarPlaySpeedLimitBadgePolicy.state(
            limit: .init(maxspeed: 50, unlimited: false),
            speedWarning: true, navigationActive: false
        ), .hidden)
    }

    func testCarPlayReconnectRejectsOldRouteRestoreCompletion() {
        let oldConnection = UUID()
        let currentConnection = UUID()
        XCTAssertTrue(CarPlayConnectionWorkPolicy.mayPublish(
            request: currentConnection, current: currentConnection, connected: true
        ))
        XCTAssertFalse(CarPlayConnectionWorkPolicy.mayPublish(
            request: oldConnection, current: currentConnection, connected: true
        ))
        XCTAssertFalse(CarPlayConnectionWorkPolicy.mayPublish(
            request: currentConnection, current: currentConnection, connected: false
        ))
    }

    func testRouteOriginUsesFirstGeometryVertexInsteadOfOverlayRepresentativeCoordinate() {
        let first = CLLocationCoordinate2D(latitude: 50.01, longitude: 8.01)
        let midpoint = CLLocationCoordinate2D(latitude: 49.0, longitude: 9.0)
        XCTAssertEqual(
            RouteGeometryEndpointPolicy.origin(coordinates: [first], fallback: midpoint).latitude,
            first.latitude,
            accuracy: 0.000_001
        )
        XCTAssertEqual(
            RouteGeometryEndpointPolicy.origin(coordinates: [], fallback: midpoint).longitude,
            midpoint.longitude,
            accuracy: 0.000_001
        )
    }

    func testRefreshingActiveTripPreservesProgressWaypointsAndSegmentRules() {
        let createdAt = Date(timeIntervalSince1970: 1_000)
        let existing = ActiveRouteLock(
            id: UUID(), title: "Kroatien", destinationName: "Split",
            destination: .init(latitude: 43.5, longitude: 16.4),
            waypoints: [
                .init(
                    id: "slovenia", name: "Slowenien",
                    coordinate: .init(latitude: 46.5, longitude: 15.6),
                    required: true,
                    optionsAfter: .init(avoidTolls: true, avoidHighways: true)
                )
            ],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 8_000,
            corridorPoints: [
                .init(latitude: 46.6, longitude: 15.6),
                .init(latitude: 45.6, longitude: 15.7),
            ],
            visitedWaypointIDs: ["slovenia"], lastRouteProgress: 0.63,
            status: .active, createdAt: createdAt, updatedAt: createdAt
        )
        let refreshedAt = Date(timeIntervalSince1970: 2_000)

        let refreshed = ActiveRouteLockRefreshPolicy.refreshed(
            existing: existing, title: "ignored", destinationName: "Split",
            destination: existing.destination, fallbackWaypoints: [],
            fallbackOptions: .init(avoidTolls: true, avoidHighways: false),
            fallbackCorridorWidthMetres: 5_000, fallbackCorridorPoints: [],
            now: refreshedAt
        )

        XCTAssertEqual(refreshed.id, existing.id)
        XCTAssertEqual(refreshed.waypoints, existing.waypoints)
        XCTAssertEqual(refreshed.defaultOptions, existing.defaultOptions)
        XCTAssertEqual(refreshed.corridorPoints, existing.corridorPoints)
        XCTAssertEqual(refreshed.visitedWaypointIDs, ["slovenia"])
        XCTAssertEqual(refreshed.lastRouteProgress, 0.63)
        XCTAssertEqual(refreshed.createdAt, createdAt)
        XCTAssertEqual(refreshed.updatedAt, refreshedAt)
    }

    func testSpeechRetriesCurrentManeuverImmediatelyAfterInterruptionEnds() {
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldRetryImmediately(
            systemAllowsResume: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldRetryImmediately(
            systemAllowsResume: false
        ))
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldRetryManeuverAfterInterruption(
            navigationActive: true, voiceGuidance: true,
            guidanceReliable: true, hasUsableLocation: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldRetryManeuverAfterInterruption(
            navigationActive: false, voiceGuidance: true,
            guidanceReliable: true, hasUsableLocation: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldRetryManeuverAfterInterruption(
            navigationActive: true, voiceGuidance: false,
            guidanceReliable: true, hasUsableLocation: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldRetryManeuverAfterInterruption(
            navigationActive: true, voiceGuidance: true,
            guidanceReliable: false, hasUsableLocation: true
        ))
    }

    func testFailedRerouteSpeechNeverClaimsOldGuidanceIsActive() {
        let timeout = NavigationRerouteFailureSpeechPolicy.text(timedOut: true)
        let failure = NavigationRerouteFailureSpeechPolicy.text(timedOut: false)

        XCTAssertTrue(timeout.contains("Fahrhinweise sind vorübergehend pausiert"))
        XCTAssertTrue(failure.contains("Fahrhinweise sind vorübergehend pausiert"))
        XCTAssertFalse(timeout.contains("Route bleibt aktiv"))
        XCTAssertFalse(failure.contains("Route bleibt aktiv"))
    }

    func testDestinationSearchRanksExactAndAddressMatchesBeforeLooseResults() {
        XCTAssertLessThan(
            DestinationSearchRankingPolicy.relevanceScore(
                query: "Hochheim am Main", name: "Hochheim am Main", title: "Hessen"
            ),
            DestinationSearchRankingPolicy.relevanceScore(
                query: "Hochheim am Main", name: "Hochheim", title: "Erfurt"
            )
        )
        XCTAssertLessThan(
            DestinationSearchRankingPolicy.relevanceScore(
                query: "Raiffeisenstraße 10", name: nil,
                title: "Raiffeisenstraße 10, 55270 Schwabsburg"
            ),
            DestinationSearchRankingPolicy.relevanceScore(
                query: "Raiffeisenstraße 10", name: "Raiffeisenmarkt", title: "Mainz"
            )
        )
    }

    func testDestinationSearchKeepsLocalityQualifierForSameNamedPlaces() {
        let correctLocality = DestinationSearchRankingPolicy.relevanceScore(
            query: "Hochheim am Main", name: "Hochheim",
            title: "Hochheim am Main, Hessen"
        )
        let wrongLocality = DestinationSearchRankingPolicy.relevanceScore(
            query: "Hochheim am Main", name: "Hochheim",
            title: "Hochheim, Thüringen"
        )

        XCTAssertLessThan(correctLocality, wrongLocality)
    }

    func testDestinationSearchDeduplicatesOnlySameNearbyPlace() {
        let first = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        let nearby = CLLocationCoordinate2D(latitude: 50.0001, longitude: 8)
        XCTAssertTrue(DestinationSearchRankingPolicy.isDuplicate(
            name: "McDonald’s", coordinate: first,
            existingName: "McDonald's", existingCoordinate: nearby
        ))
        XCTAssertFalse(DestinationSearchRankingPolicy.isDuplicate(
            name: "McDonald’s", coordinate: first,
            existingName: "Burger King", existingCoordinate: nearby
        ))
    }


    func testRemainingTimePreservesPerLegTravelCharacteristics() throws {
        let estimate = try XCTUnwrap(RouteRemainingTimePolicy.estimate(
            currentLegRemainingDistance: 25_000,
            currentLegDistance: 100_000,
            currentLegTravelTime: 2 * 3600,
            followingLegTravelTimes: [3600]
        ))

        XCTAssertEqual(estimate, 1.5 * 3600, accuracy: 1)
    }

    func testRemainingTimeClampsProgressAndRejectsInvalidLegs() throws {
        let estimate = try XCTUnwrap(RouteRemainingTimePolicy.estimate(
            currentLegRemainingDistance: 120_000,
            currentLegDistance: 100_000,
            currentLegTravelTime: 3600,
            followingLegTravelTimes: [1800, .nan, -20]
        ))

        XCTAssertEqual(estimate, 5400, accuracy: 1)
        XCTAssertNil(RouteRemainingTimePolicy.estimate(
            currentLegRemainingDistance: 1,
            currentLegDistance: 0,
            currentLegTravelTime: 10,
            followingLegTravelTimes: [20]
        ))
    }

    func testOfflineRemainingTimeKeepsFollowingLegEstimate() throws {
        let estimate = try XCTUnwrap(OfflineRouteRemainingTimePolicy.estimate(
            totalRemainingDistance: 125_000,
            currentLegIndex: 0,
            legs: [
                (distance: 100_000, travelTime: 2 * 3600),
                (distance: 100_000, travelTime: 3600),
            ]
        ))

        XCTAssertEqual(estimate, 1.5 * 3600, accuracy: 1)
    }

    func testOfflineRemainingTimeRejectsUnknownLeg() {
        XCTAssertNil(OfflineRouteRemainingTimePolicy.estimate(
            totalRemainingDistance: 1_000,
            currentLegIndex: 2,
            legs: [(distance: 1_000, travelTime: 60)]
        ))
    }

    func testManagedServerURLUsesProductionHTTPSConfiguration() {
        XCTAssertEqual(DriveSettings.configuredBaseURL(info: [
            DriveSettings.serverURLInfoKey: " https://drive.example.test/ "
        ]), "https://drive.example.test")
        XCTAssertEqual(
            ServerEndpointPolicy.url(
                baseURL: "https://drive.example.test/kies-drive",
                path: "/auth/login"
            )?.absoluteString,
            "https://drive.example.test/kies-drive/auth/login"
        )
    }

    func testServiceReadinessDecodesIndividualProductionChecks() throws {
        let payload = Data(#"{"ok":false,"checks":{"public_https":true,"email_delivery":true,"toll_research":false}}"#.utf8)
        let readiness = try JSONDecoder().decode(DriveServiceReadiness.self, from: payload)
        XCTAssertFalse(readiness.ok)
        XCTAssertTrue(readiness.checks.publicHTTPS)
        XCTAssertTrue(readiness.checks.emailDelivery)
        XCTAssertFalse(readiness.checks.tollResearch)
    }

    func testManagedServerURLRejectsUnsafeOrUnexpandedConfiguration() {
        XCTAssertEqual(DriveSettings.configuredBaseURL(info: [
            DriveSettings.serverURLInfoKey: "http://drive.example.test"
        ]), DriveSettings.standaloneBaseURL)
        XCTAssertEqual(DriveSettings.configuredBaseURL(info: [
            DriveSettings.serverURLInfoKey: "$(KIES_DRIVE_SERVER_URL)"
        ]), DriveSettings.standaloneBaseURL)
    }

    func testAlwaysLocationUpgradeIsRequestedOnlyForActiveGuidance() {
        XCTAssertTrue(NavigationLocationAuthorizationPolicy.shouldRequestAlways(
            navigationActive: true, hasWhenInUseAuthorization: true
        ))
        XCTAssertFalse(NavigationLocationAuthorizationPolicy.shouldRequestAlways(
            navigationActive: false, hasWhenInUseAuthorization: true
        ))
        XCTAssertFalse(NavigationLocationAuthorizationPolicy.shouldRequestAlways(
            navigationActive: true, hasWhenInUseAuthorization: false
        ))
        XCTAssertTrue(NavigationLocationAuthorizationPolicy.shouldRequestAlways(
            navigationActive: false, persistentTripActive: true,
            hasWhenInUseAuthorization: true
        ))
        XCTAssertFalse(NavigationLocationAuthorizationPolicy.shouldRequestAlways(
            navigationActive: false, persistentTripActive: true,
            hasWhenInUseAuthorization: false
        ))
        XCTAssertTrue(NavigationLocationAuthorizationPolicy.requiresSystemSettings(.denied))
        XCTAssertTrue(NavigationLocationAuthorizationPolicy.requiresSystemSettings(.restricted))
        XCTAssertFalse(NavigationLocationAuthorizationPolicy.requiresSystemSettings(.notDetermined))
    }

    func testLocationFailuresHaveActionableMessagesAndRateLimitedDiagnostics() {
        XCTAssertTrue(NavigationLocationFailurePolicy.message(errorCode: 1)
            .contains("Einstellungen"))
        XCTAssertTrue(NavigationLocationFailurePolicy.message(errorCode: 0)
            .contains("GPS-Signal"))
        XCTAssertTrue(NavigationLocationFailurePolicy.message(errorCode: 999)
            .contains("Standort vorübergehend"))

        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(NavigationLocationFailurePolicy.shouldRecord(
            lastRecordedAt: nil, now: now
        ))
        XCTAssertFalse(NavigationLocationFailurePolicy.shouldRecord(
            lastRecordedAt: now, now: now.addingTimeInterval(59)
        ))
        XCTAssertTrue(NavigationLocationFailurePolicy.shouldRecord(
            lastRecordedAt: now, now: now.addingTimeInterval(60)
        ))
    }

    func testBatchedLocationsAreProcessedChronologicallyWithoutExactDuplicates() {
        let base = Date(timeIntervalSince1970: 1_000)
        func location(_ seconds: TimeInterval, latitude: Double,
                      horizontalAccuracy: CLLocationAccuracy = 5) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: latitude, longitude: 8), altitude: 0,
                horizontalAccuracy: horizontalAccuracy, verticalAccuracy: 5,
                course: 0, speed: 15, timestamp: base.addingTimeInterval(seconds)
            )
        }
        let oldest = location(1, latitude: 50.0)
        let coarseJunction = location(2, latitude: 50.001, horizontalAccuracy: 75)
        // Core Location may revise both accuracy and coordinate while keeping
        // the same timestamp. Only the refined sample may drive guidance.
        let preciseJunction = location(2, latitude: 50.0012, horizontalAccuracy: 4)
        let latest = location(3, latitude: 50.002)

        let ordered = NavigationLocationBatchPolicy.orderedDistinct([
            latest, coarseJunction, preciseJunction, oldest,
        ])

        XCTAssertEqual(ordered.map(\.timestamp), [oldest.timestamp, preciseJunction.timestamp, latest.timestamp])
        XCTAssertEqual(ordered.map(\.coordinate.latitude), [50.0, 50.0012, 50.002])
        XCTAssertEqual(ordered[1].horizontalAccuracy, 4)
    }

    func testCarPlayCameraDoesNotQueueUpdatesFasterThanMapCanRender() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(CarPlayCameraUpdatePolicy.shouldUpdate(last: nil, current: start))
        XCTAssertFalse(CarPlayCameraUpdatePolicy.shouldUpdate(
            last: start, current: start.addingTimeInterval(0.19)
        ))
        XCTAssertTrue(CarPlayCameraUpdatePolicy.shouldUpdate(
            last: start, current: start.addingTimeInterval(0.2)
        ))
        XCTAssertTrue(CarPlayCameraUpdatePolicy.shouldUpdate(
            last: start, current: start.addingTimeInterval(-1)
        ), "A corrected device clock must not freeze the CarPlay camera")
    }

    func testCarPlayReconnectAlwaysRestoresVehicleFollowing() {
        XCTAssertEqual(
            CarPlayCameraLifecyclePolicy.modeAfterConnection(previous: .free), .follow
        )
        XCTAssertEqual(
            CarPlayCameraLifecyclePolicy.modeAfterConnection(previous: .overview), .follow
        )
        XCTAssertEqual(
            CarPlayCameraLifecyclePolicy.modeAfterConnection(previous: .follow), .follow
        )
    }

    func testCarPlayNewNavigationResetsFreeCameraWithoutFightingLiveReroute() {
        XCTAssertEqual(CarPlayCameraLifecyclePolicy.mode(
            previous: .free, navigationWasActive: false, navigationIsActive: true
        ), .follow)
        XCTAssertEqual(CarPlayCameraLifecyclePolicy.mode(
            previous: .overview, navigationWasActive: false, navigationIsActive: true
        ), .follow)
        XCTAssertEqual(CarPlayCameraLifecyclePolicy.mode(
            previous: .free, navigationWasActive: true, navigationIsActive: true
        ), .free, "A live reroute must preserve the driver's manual camera")
        XCTAssertEqual(CarPlayCameraLifecyclePolicy.mode(
            previous: .overview, navigationWasActive: true, navigationIsActive: false
        ), .overview)
    }

    func testCarPlayExplainsRouteRecoveryWithoutRevivingOldManeuver() {
        XCTAssertEqual(CarPlayRouteRecoveryPresentationPolicy.state(
            recalculating: false, guidanceReliable: true
        ), .normal)
        XCTAssertEqual(CarPlayRouteRecoveryPresentationPolicy.state(
            recalculating: false, guidanceReliable: false, matchingPosition: true
        ), .matchingPosition)
        XCTAssertEqual(CarPlayRouteRecoveryPresentationPolicy.state(
            recalculating: true, guidanceReliable: false
        ), .searching)
        XCTAssertEqual(CarPlayRouteRecoveryPresentationPolicy.state(
            recalculating: false, guidanceReliable: false
        ), .unavailable)
        XCTAssertTrue(CarPlayRouteRecoveryPresentationPolicy.titleVariants(for: .normal).isEmpty)
        XCTAssertTrue(CarPlayRouteRecoveryPresentationPolicy.titleVariants(
            for: .matchingPosition
        ).first?.contains("Position") == true)
        XCTAssertTrue(CarPlayRouteRecoveryPresentationPolicy.titleVariants(
            for: .searching
        ).first?.contains("gesucht") == true)
        XCTAssertTrue(CarPlayRouteRecoveryPresentationPolicy.titleVariants(
            for: .unavailable
        ).first?.contains("sicher") == true)
    }

    func testCarPlayOverviewUsesAThinnerRouteWithoutWeakeningFollowMode() {
        XCTAssertEqual(CarPlayRouteLinePolicy.width(isOverview: false), 7)
        XCTAssertEqual(CarPlayRouteLinePolicy.width(isOverview: true), 4.5)
        XCTAssertLessThan(
            CarPlayRouteLinePolicy.width(isOverview: true),
            CarPlayRouteLinePolicy.width(isOverview: false)
        )
    }

    func testPhoneRouteOverviewUsesThinnerLineAndCasing() {
        XCTAssertEqual(NavigationRouteLinePolicy.width(isOverview: false), 4.5)
        XCTAssertEqual(NavigationRouteLinePolicy.width(isOverview: true), 3)
        XCTAssertEqual(NavigationRouteLinePolicy.outlineWidth(isOverview: false), 6.5)
        XCTAssertEqual(NavigationRouteLinePolicy.outlineWidth(isOverview: true), 4.8, accuracy: 0.001)
        XCTAssertLessThan(
            NavigationRouteLinePolicy.outlineWidth(isOverview: true),
            NavigationRouteLinePolicy.outlineWidth(isOverview: false)
        )
    }

    func testCarPlayOverviewIncludesPlausibleVehicleButRejectsDisplacedFix() throws {
        let start = MKMapPoint(CLLocationCoordinate2D(latitude: 50.0, longitude: 8.0))
        let end = MKMapPoint(CLLocationCoordinate2D(latitude: 50.1, longitude: 8.1))
        let route = MKMapRect(
            x: min(start.x, end.x), y: min(start.y, end.y),
            width: abs(end.x - start.x), height: abs(end.y - start.y)
        )
        let nearby = CLLocationCoordinate2D(latitude: 50.12, longitude: 8.12)
        let nearbyRect = try XCTUnwrap(CarPlayRouteOverviewPolicy.mapRect(
            routeRects: [route], vehicleCoordinate: nearby
        ))
        XCTAssertTrue(nearbyRect.contains(MKMapPoint(nearby)))

        let displaced = CLLocationCoordinate2D(latitude: 48.1, longitude: 11.6)
        let safeRect = try XCTUnwrap(CarPlayRouteOverviewPolicy.mapRect(
            routeRects: [route], vehicleCoordinate: displaced
        ))
        XCTAssertFalse(safeRect.contains(MKMapPoint(displaced)))
        XCTAssertNil(CarPlayRouteOverviewPolicy.mapRect(
            routeRects: [], vehicleCoordinate: nearby
        ))
    }

    func testRouteOverviewIncludesVehicleDestinationAndRequiredStops() throws {
        let routeStart = MKMapPoint(CLLocationCoordinate2D(latitude: 50, longitude: 8))
        let routeEnd = MKMapPoint(CLLocationCoordinate2D(latitude: 50.1, longitude: 8.1))
        let base = MKMapRect(
            x: min(routeStart.x, routeEnd.x), y: min(routeStart.y, routeEnd.y),
            width: abs(routeEnd.x - routeStart.x), height: abs(routeEnd.y - routeStart.y)
        )
        let vehicle = CLLocationCoordinate2D(latitude: 49.9, longitude: 7.9)
        let destination = CLLocationCoordinate2D(latitude: 50.2, longitude: 8.2)

        let expanded = try XCTUnwrap(RouteOverviewMapRectPolicy.including(
            base, coordinates: [vehicle, destination]
        ))

        XCTAssertTrue(expanded.contains(MKMapPoint(vehicle)))
        XCTAssertTrue(expanded.contains(MKMapPoint(destination)))
        XCTAssertNil(RouteOverviewMapRectPolicy.including(
            nil, coordinates: [.init(latitude: .nan, longitude: 8)]
        ))
    }

    func testLocationBatchKeepsUsefulFixesBeforeBadTrailingSample() {
        let now = Date(timeIntervalSince1970: 2_000)
        func location(_ secondsAgo: TimeInterval, latitude: Double,
                      accuracy: CLLocationAccuracy = 5) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: latitude, longitude: 8), altitude: 0,
                horizontalAccuracy: accuracy, verticalAccuracy: 5,
                course: 0, speed: 15,
                timestamp: now.addingTimeInterval(-secondsAgo)
            )
        }
        let previous = location(12, latitude: 50)
        let junction = location(4, latitude: 50.001)
        let badTail = location(1, latitude: 50.5, accuracy: 250)

        let batch = NavigationLocationBatchPolicy.freshGuidanceBatch(
            [badTail, junction], after: previous, now: now
        )

        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.last?.coordinate.latitude, junction.coordinate.latitude)
    }

    func testLocationBatchUsesBufferedJunctionWhenFollowedByLiveEndpoint() {
        let now = Date(timeIntervalSince1970: 2_000)
        func location(_ secondsAgo: TimeInterval, longitude: Double) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: 50, longitude: longitude), altitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 5, course: 90, speed: 20,
                timestamp: now.addingTimeInterval(-secondsAgo)
            )
        }
        let previous = location(100, longitude: 8)
        let bufferedJunction = location(45, longitude: 8.02)
        let liveEndpoint = location(2, longitude: 8.04)

        let batch = NavigationLocationBatchPolicy.freshGuidanceBatch(
            [liveEndpoint, bufferedJunction], after: previous, now: now
        )

        XCTAssertEqual(batch.map(\.timestamp), [bufferedJunction.timestamp, liveEndpoint.timestamp])
    }

    func testLocationBatchSkipsImpossibleIntermediateWithoutPoisoningLiveFix() {
        let now = Date(timeIntervalSince1970: 2_000)
        func location(_ secondsAgo: TimeInterval, latitude: Double) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: latitude, longitude: 8), altitude: 0,
                horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 20,
                timestamp: now.addingTimeInterval(-secondsAgo)
            )
        }
        let previous = location(12, latitude: 50)
        let impossible = location(8, latitude: 51)
        let liveEndpoint = location(2, latitude: 50.001)

        let batch = NavigationLocationBatchPolicy.freshGuidanceBatch(
            [impossible, liveEndpoint], after: previous, now: now
        )

        XCTAssertEqual(batch.count, 1)
        XCTAssertEqual(batch.first?.coordinate.latitude, liveEndpoint.coordinate.latitude)
    }

    func testLocationBatchRejectsAllSamplesWithoutFreshPlausibleEndpoint() {
        let now = Date(timeIntervalSince1970: 2_000)
        let stale = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5,
            course: 0, speed: 15, timestamp: now.addingTimeInterval(-60)
        )
        let inaccurate = CLLocation(
            coordinate: .init(latitude: 50.001, longitude: 8), altitude: 0,
            horizontalAccuracy: 250, verticalAccuracy: 5,
            course: 0, speed: 15, timestamp: now.addingTimeInterval(-1)
        )

        XCTAssertTrue(NavigationLocationBatchPolicy.freshGuidanceBatch(
            [stale, inaccurate], after: nil, now: now
        ).isEmpty)
    }

    func testOnlyNewestBufferedLocationMayStartAutomaticReroute() {
        XCTAssertFalse(NavigationBatchReroutePolicy.mayStartAutomaticReroute(
            sampleIndex: 0, sampleCount: 4
        ))
        XCTAssertFalse(NavigationBatchReroutePolicy.mayStartAutomaticReroute(
            sampleIndex: 2, sampleCount: 4
        ))
        XCTAssertTrue(NavigationBatchReroutePolicy.mayStartAutomaticReroute(
            sampleIndex: 3, sampleCount: 4
        ))
        XCTAssertFalse(NavigationBatchReroutePolicy.mayStartAutomaticReroute(
            sampleIndex: 0, sampleCount: 0
        ))
    }

    func testMotionPolicyRejectsNoisyOrImpossibleSpeeds() {
        XCTAssertEqual(NavigationMotionPolicy.reliableSpeed(
            speedMetresPerSecond: 27, speedAccuracy: 1.5, horizontalAccuracy: 12), 27)
        XCTAssertNil(NavigationMotionPolicy.reliableSpeed(
            speedMetresPerSecond: -1, speedAccuracy: 1, horizontalAccuracy: 12))
        XCTAssertNil(NavigationMotionPolicy.reliableSpeed(
            speedMetresPerSecond: 30, speedAccuracy: 12, horizontalAccuracy: 12))
        XCTAssertNil(NavigationMotionPolicy.reliableSpeed(
            speedMetresPerSecond: 95, speedAccuracy: 1, horizontalAccuracy: 12))
    }

    func testSpeedDisplayUsesOnlyFreshReliableLocation() {
        let now = Date(timeIntervalSince1970: 10_000)
        let fresh = CLLocation(
            coordinate: CLLocationCoordinate2D(latitude: 50, longitude: 8),
            altitude: 0, horizontalAccuracy: 8, verticalAccuracy: 5,
            course: 90, courseAccuracy: 4,
            speed: 23.4, speedAccuracy: 0.8,
            timestamp: now.addingTimeInterval(-2)
        )
        XCTAssertEqual(
            NavigationSpeedDisplayPolicy.speedKilometresPerHour(for: fresh, now: now), 84
        )

        let stale = CLLocation(
            coordinate: fresh.coordinate, altitude: 0,
            horizontalAccuracy: 8, verticalAccuracy: 5,
            course: 90, courseAccuracy: 4,
            speed: 23.4, speedAccuracy: 0.8,
            timestamp: now.addingTimeInterval(-6)
        )
        XCTAssertNil(NavigationSpeedDisplayPolicy.speedKilometresPerHour(for: stale, now: now))

        let inaccurate = CLLocation(
            coordinate: fresh.coordinate, altitude: 0,
            horizontalAccuracy: 90, verticalAccuracy: 5,
            course: 90, courseAccuracy: 4,
            speed: 23.4, speedAccuracy: 0.8,
            timestamp: now
        )
        XCTAssertNil(NavigationSpeedDisplayPolicy.speedKilometresPerHour(for: inaccurate, now: now))
    }

    func testMotionPolicyKeepsCameraStableAtLowSpeed() {
        XCTAssertEqual(NavigationMotionPolicy.reliableCourse(
            courseDegrees: 182, courseAccuracy: 8, speedMetresPerSecond: 18), 182)
        XCTAssertNil(NavigationMotionPolicy.reliableCourse(
            courseDegrees: 182, courseAccuracy: 8, speedMetresPerSecond: 1))
        XCTAssertNil(NavigationMotionPolicy.reliableCourse(
            courseDegrees: 182, courseAccuracy: 80, speedMetresPerSecond: 18))
        XCTAssertNil(NavigationMotionPolicy.reliableCourse(
            courseDegrees: -1, courseAccuracy: 8, speedMetresPerSecond: 18))
    }

    func testRerouteStatusSpeechDoesNotRepeatOnEveryRetry() {
        let start = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(NavigationRerouteStatusSpeechPolicy.shouldAnnounce(
            lastAnnouncement: nil, now: start
        ))
        XCTAssertFalse(NavigationRerouteStatusSpeechPolicy.shouldAnnounce(
            lastAnnouncement: start, now: start.addingTimeInterval(119)
        ))
        XCTAssertTrue(NavigationRerouteStatusSpeechPolicy.shouldAnnounce(
            lastAnnouncement: start, now: start.addingTimeInterval(120)
        ))
        XCTAssertTrue(NavigationRerouteStatusSpeechPolicy.shouldAnnounce(
            lastAnnouncement: start, now: start.addingTimeInterval(-1)
        ), "A clock correction must not mute reroute status indefinitely")
    }

    func testAudioActivationFailureDeduplicatesByManeuverStage() {
        let firstRoute = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!
        let secondRoute = UUID(uuidString: "00000000-0000-0000-0000-000000000002")!
        XCTAssertEqual(
            NavigationSpeechFailureDeduplicationPolicy.key(
                routeGeneration: firstRoute,
                maneuverKey: "route-1:step-4", stage: .prepare
            ),
            NavigationSpeechFailureDeduplicationPolicy.key(
                routeGeneration: firstRoute,
                maneuverKey: "route-1:step-4", stage: .prepare
            )
        )
        XCTAssertNotEqual(
            NavigationSpeechFailureDeduplicationPolicy.key(
                routeGeneration: firstRoute,
                maneuverKey: "route-1:step-4", stage: .prepare
            ),
            NavigationSpeechFailureDeduplicationPolicy.key(
                routeGeneration: firstRoute,
                maneuverKey: "route-1:step-4", stage: .final
            )
        )
        XCTAssertNotEqual(
            NavigationSpeechFailureDeduplicationPolicy.key(
                routeGeneration: firstRoute,
                maneuverKey: "route-1:step-4", stage: .final
            ),
            NavigationSpeechFailureDeduplicationPolicy.key(
                routeGeneration: firstRoute,
                maneuverKey: "route-1:step-5", stage: .final
            )
        )
        XCTAssertNotEqual(
            NavigationSpeechFailureDeduplicationPolicy.key(
                routeGeneration: firstRoute,
                maneuverKey: "route-1:step-4", stage: .final
            ),
            NavigationSpeechFailureDeduplicationPolicy.key(
                routeGeneration: secondRoute,
                maneuverKey: "route-1:step-4", stage: .final
            ),
            "A replacement route owns a fresh diagnostic namespace"
        )
    }

    func testCarPlayManeuverEstimateRejectsStaleMotorwaySpeed() {
        let now = Date(timeIntervalSince1970: 20_000)
        func location(age: TimeInterval, accuracy: CLLocationAccuracy = 8) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: 50, longitude: 8),
                altitude: 0, horizontalAccuracy: accuracy, verticalAccuracy: 5,
                course: 90, courseAccuracy: 5,
                speed: 36, speedAccuracy: 1,
                timestamp: now.addingTimeInterval(-age)
            )
        }

        XCTAssertEqual(
            CarPlayManeuverEstimatePolicy.speed(location(age: 2), now: now), 36
        )
        XCTAssertNil(CarPlayManeuverEstimatePolicy.speed(location(age: 6), now: now))
        XCTAssertNil(CarPlayManeuverEstimatePolicy.speed(
            location(age: 1, accuracy: 90), now: now
        ))
        XCTAssertNil(CarPlayManeuverEstimatePolicy.speed(nil, now: now))
    }

    func testFollowCameraShowsMoreRoadAheadAtMotorwaySpeed() {
        XCTAssertEqual(NavigationFollowCameraPolicy.distance(speedMetresPerSecond: nil), 700)
        XCTAssertEqual(NavigationFollowCameraPolicy.distance(speedMetresPerSecond: 30), 1_190)
        XCTAssertEqual(NavigationFollowCameraPolicy.lookAheadDistance(speedMetresPerSecond: 1), 0)
        XCTAssertEqual(NavigationFollowCameraPolicy.lookAheadDistance(speedMetresPerSecond: 30), 270)

        let origin = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        let north = NavigationFollowCameraPolicy.center(
            from: origin, headingDegrees: 0, speedMetresPerSecond: 30
        )
        XCTAssertGreaterThan(north.latitude, origin.latitude)
        XCTAssertEqual(north.longitude, origin.longitude, accuracy: 0.000_001)
    }

    func testFollowCameraClampsImplausibleSpeedAndDistance() {
        XCTAssertEqual(NavigationFollowCameraPolicy.distance(speedMetresPerSecond: -1), 700)
        XCTAssertEqual(NavigationFollowCameraPolicy.distance(speedMetresPerSecond: 100), 1_400)
        XCTAssertEqual(NavigationFollowCameraPolicy.lookAheadDistance(speedMetresPerSecond: 100), 450)
    }

    func testCourseMatchingHandlesWraparoundAndOppositeCarriageway() throws {
        XCTAssertEqual(try XCTUnwrap(NavigationCourseMatchingPolicy.angularDifference(
            courseDegrees: 355, routeCourseDegrees: 5
        )), 10, accuracy: 0.001)
        XCTAssertTrue(NavigationCourseMatchingPolicy.isPlausible(65))
        XCTAssertFalse(NavigationCourseMatchingPolicy.isPlausible(179))
        XCTAssertTrue(NavigationCourseMatchingPolicy.isPlausible(nil),
                      "Stopped or course-less fixes retain safe distance matching")
    }

    func testStepSelectionDoesNotAdvanceOntoOpposingParallelRoad() {
        let selected = NavigationStepSelectionPolicy.selectedIndex(
            current: 0,
            metrics: [
                .init(distanceFromRoute: 5, remainingOnStep: 4,
                      courseDifferenceDegrees: 5),
                .init(distanceFromRoute: 3, remainingOnStep: 500,
                      courseDifferenceDegrees: 175),
            ],
            transitionRadius: 12
        )
        XCTAssertEqual(selected, 0)
    }

    func testStepSelectionAdvancesAfterVehicleTurnsOntoRamp() {
        let selected = NavigationStepSelectionPolicy.selectedIndex(
            current: 0,
            metrics: [
                .init(distanceFromRoute: 5, remainingOnStep: 4,
                      courseDifferenceDegrees: 88),
                .init(distanceFromRoute: 3, remainingOnStep: 500,
                      courseDifferenceDegrees: 8),
            ],
            transitionRadius: 12
        )
        XCTAssertEqual(selected, 1)
    }

    func testOfflineCourseUsesLocalNearestSegment() throws {
        let northbound = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50.01, longitude: 8),
        ]
        let course = try XCTUnwrap(NavigationCourseMatchingPolicy.routeCourse(
            near: .init(latitude: 50.005, longitude: 8.0001),
            coordinates: northbound
        ))
        XCTAssertEqual(course, 0, accuracy: 0.5)
    }

    func testCourseMatchingSkipsDuplicateGeometryAtJunction() throws {
        let junction = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        let northbound = CLLocationCoordinate2D(latitude: 50.01, longitude: 8)
        let course = try XCTUnwrap(NavigationCourseMatchingPolicy.routeCourse(
            near: junction,
            coordinates: [junction, junction, northbound]
        ))
        XCTAssertEqual(course, 0, accuracy: 0.5)
        XCTAssertFalse(NavigationCourseMatchingPolicy.isPlausible(
            NavigationCourseMatchingPolicy.angularDifference(
                courseDegrees: 180, routeCourseDegrees: course
            )
        ), "A duplicate MapKit point must not hide an opposing carriageway")
    }

    func testCourseMatchingSkipsSubFiveMetreGeometryJitter() throws {
        let origin = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        let tinyEastwardJitter = CLLocationCoordinate2D(
            latitude: 50, longitude: 8.000005
        )
        let northbound = CLLocationCoordinate2D(
            latitude: 50.001, longitude: 8.000005
        )

        let course = try XCTUnwrap(NavigationCourseMatchingPolicy.routeCourse(
            near: origin, coordinates: [origin, tinyEastwardJitter, northbound]
        ))

        XCTAssertEqual(course, 0, accuracy: 1)
        XCTAssertNil(NavigationCourseMatchingPolicy.routeCourse(
            near: origin,
            coordinates: [origin, tinyEastwardJitter, .init(latitude: 50, longitude: 8.00001)]
        ), "Only sub-five-metre jitter must not invent a route heading")
    }

    func testCourseMatchingRejectsHeadingFromDistantRouteGeometry() {
        XCTAssertTrue(NavigationCourseMatchingPolicy.directionalMetricIsLocallySupported(
            nearestDistance: 24, directionalDistance: 35
        ))
        XCTAssertFalse(NavigationCourseMatchingPolicy.directionalMetricIsLocallySupported(
            nearestDistance: 24, directionalDistance: 37
        ), "A crossing route segment 13 m away cannot supply this road's heading")
        XCTAssertFalse(NavigationCourseMatchingPolicy.directionalMetricIsLocallySupported(
            nearestDistance: 24, directionalDistance: 20
        ))
    }

    func testCourseMatchingRejectsEntirelyDegenerateGeometry() {
        let point = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        XCTAssertNil(NavigationCourseMatchingPolicy.routeCourse(
            near: point, coordinates: [point, point, point]
        ))
    }

    func testGuidanceSpeedSurvivesBriefInvalidGPSReading() {
        let measuredAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(NavigationGuidanceSpeedPolicy.effective(
            current: nil, previous: 33.3, previousAt: measuredAt,
            now: measuredAt.addingTimeInterval(8)
        ), 33.3, accuracy: 0.01)
    }

    func testSpeechRetryRequiresFreshAccurateLocationAfterInterruption() {
        let now = Date(timeIntervalSince1970: 1_000)
        let fresh = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 12, verticalAccuracy: 5,
            course: 90, speed: 25, timestamp: now.addingTimeInterval(-3)
        )
        let stale = CLLocation(
            coordinate: fresh.coordinate, altitude: 0,
            horizontalAccuracy: 12, verticalAccuracy: 5,
            course: 90, speed: 25, timestamp: now.addingTimeInterval(-8)
        )
        let coarse = CLLocation(
            coordinate: fresh.coordinate, altitude: 0,
            horizontalAccuracy: 80, verticalAccuracy: 5,
            course: 90, speed: 25, timestamp: now.addingTimeInterval(-1)
        )

        XCTAssertTrue(NavigationSpeechRetryLocationPolicy.mayRetry(using: fresh, now: now))
        XCTAssertFalse(NavigationSpeechRetryLocationPolicy.mayRetry(using: stale, now: now))
        XCTAssertFalse(NavigationSpeechRetryLocationPolicy.mayRetry(using: coarse, now: now))
    }

    func testRouteReplacementPreservesOnlyFreshAccurateNavigationFix() {
        let now = Date(timeIntervalSince1970: 2_000)
        let fresh = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 12, verticalAccuracy: 5,
            course: 90, speed: 25, timestamp: now.addingTimeInterval(-2)
        )
        let stale = CLLocation(
            coordinate: fresh.coordinate, altitude: 0,
            horizontalAccuracy: 12, verticalAccuracy: 5,
            course: 90, speed: 25, timestamp: now.addingTimeInterval(-8)
        )
        let coarse = CLLocation(
            coordinate: fresh.coordinate, altitude: 0,
            horizontalAccuracy: 90, verticalAccuracy: 5,
            course: 90, speed: 25, timestamp: now.addingTimeInterval(-1)
        )

        XCTAssertEqual(
            NavigationRouteReplacementLocationPolicy.location(
                navigationActive: true, lastAccepted: fresh, now: now
            )?.timestamp,
            fresh.timestamp
        )
        XCTAssertNil(NavigationRouteReplacementLocationPolicy.location(
            navigationActive: false, lastAccepted: fresh, now: now
        ))
        XCTAssertNil(NavigationRouteReplacementLocationPolicy.location(
            navigationActive: true, lastAccepted: stale, now: now
        ))
        XCTAssertNil(NavigationRouteReplacementLocationPolicy.location(
            navigationActive: true, lastAccepted: coarse, now: now
        ))
    }

    func testGuidanceSpeedExpiresToSafeCityFallback() {
        let measuredAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(NavigationGuidanceSpeedPolicy.effective(
            current: nil, previous: 33.3, previousAt: measuredAt,
            now: measuredAt.addingTimeInterval(30)
        ), NavigationGuidanceSpeedPolicy.fallbackMetresPerSecond, accuracy: 0.01)
        XCTAssertEqual(NavigationGuidanceSpeedPolicy.effective(
            current: 22, previous: 33.3, previousAt: measuredAt,
            now: measuredAt.addingTimeInterval(30)
        ), 22, accuracy: 0.01)
    }

    func testGuidanceSpeedDoesNotCollapseOnAbruptMotorwaySlowdown() {
        let measuredAt = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(NavigationGuidanceSpeedPolicy.effective(
            current: 12, previous: 50, previousAt: measuredAt,
            now: measuredAt.addingTimeInterval(1)
        ), 47, accuracy: 0.01)
    }

    func testGuidanceSpeedConvergesDuringSustainedDeceleration() {
        let measuredAt = Date(timeIntervalSince1970: 1_000)
        let first = NavigationGuidanceSpeedPolicy.effective(
            current: 12, previous: 50, previousAt: measuredAt,
            now: measuredAt.addingTimeInterval(2)
        )
        let second = NavigationGuidanceSpeedPolicy.effective(
            current: 12, previous: first,
            previousAt: measuredAt.addingTimeInterval(2),
            now: measuredAt.addingTimeInterval(4)
        )
        XCTAssertEqual(first, 44, accuracy: 0.01)
        XCTAssertEqual(second, 38, accuracy: 0.01)
    }

    func testManeuverEstimateUsesMovementAndSensibleFallback() {
        XCTAssertEqual(NavigationEstimatePolicy.timeToManeuver(distanceMetres: 1_000, speedMetresPerSecond: 20), 50, accuracy: 0.01)
        XCTAssertEqual(NavigationEstimatePolicy.timeToManeuver(distanceMetres: 1_390, speedMetresPerSecond: 0), 100, accuracy: 0.1)
        XCTAssertEqual(NavigationEstimatePolicy.timeToManeuver(distanceMetres: 0, speedMetresPerSecond: 30), 0)
    }
    func testDeviationPolicyIgnoresStopsNoiseAndConvergingSlipRoads() {
        XCTAssertTrue(NavigationDeviationPolicy.isOutsideCorridor(
            distanceFromRoute: 180, horizontalAccuracy: 10, speedMetresPerSecond: 0
        ), "Offline guidance must freeze a distant instruction even while the car is stopped")
        XCTAssertFalse(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 250, previousDistance: 230, horizontalAccuracy: 12, speedMetresPerSecond: 0.5))
        XCTAssertFalse(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 250, previousDistance: 320, horizontalAccuracy: 12, speedMetresPerSecond: 20))
        XCTAssertFalse(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 250, previousDistance: 230, horizontalAccuracy: 90, speedMetresPerSecond: 20))
    }

    func testDeviationPolicyRequiresSustainedMovingDeparture() {
        XCTAssertTrue(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 210, previousDistance: 190, horizontalAccuracy: 15, speedMetresPerSecond: 20))
        XCTAssertEqual(NavigationDeviationPolicy.confirmationDuration(speedMetresPerSecond: 8), 6)
        XCTAssertEqual(NavigationDeviationPolicy.confirmationDuration(speedMetresPerSecond: 20), 8)
        XCTAssertEqual(NavigationDeviationPolicy.confirmationDuration(speedMetresPerSecond: 30), 8)
        XCTAssertFalse(NavigationDeviationPolicy.isConfirmed(
            elapsed: 30, consecutiveFixes: 2, speedMetresPerSecond: 30
        ))
        XCTAssertFalse(NavigationDeviationPolicy.isConfirmed(
            elapsed: 7, consecutiveFixes: 3, speedMetresPerSecond: 30
        ))
        XCTAssertTrue(NavigationDeviationPolicy.isConfirmed(
            elapsed: 8, consecutiveFixes: 3, speedMetresPerSecond: 30
        ))
    }

    func testDeviationSequenceDoesNotBridgeLocationDeliveryGaps() {
        let first = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(NavigationDeviationSequencePolicy.shouldRestart(
            previousFixAt: nil, currentFixAt: first
        ))
        XCTAssertFalse(NavigationDeviationSequencePolicy.shouldRestart(
            previousFixAt: first, currentFixAt: first.addingTimeInterval(12)
        ))
        XCTAssertTrue(NavigationDeviationSequencePolicy.shouldRestart(
            previousFixAt: first, currentFixAt: first.addingTimeInterval(12.01)
        ), "A fix after a tunnel or background gap must start fresh confirmation")
        XCTAssertTrue(NavigationDeviationSequencePolicy.shouldRestart(
            previousFixAt: first, currentFixAt: first.addingTimeInterval(-1)
        ), "A clock rollback must not continue an old departure sequence")
    }

    func testWrongWayOnSameRoadRequiresStrongReliableCourseEvidence() {
        XCTAssertTrue(NavigationWrongWayPolicy.isOpposing(
            courseDifferenceDegrees: 172, distanceFromRoute: 8,
            horizontalAccuracy: 9, speedMetresPerSecond: 18
        ))
        XCTAssertTrue(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 8, previousDistance: 7,
            horizontalAccuracy: 9, speedMetresPerSecond: 18,
            wrongWay: true
        ), "Driving backwards along the same polyline must eventually reroute")
        XCTAssertFalse(NavigationWrongWayPolicy.isOpposing(
            courseDifferenceDegrees: 120, distanceFromRoute: 8,
            horizontalAccuracy: 9, speedMetresPerSecond: 18
        ), "A bend must not look like opposing traffic")
        XCTAssertFalse(NavigationWrongWayPolicy.isOpposing(
            courseDifferenceDegrees: 175, distanceFromRoute: 8,
            horizontalAccuracy: 50, speedMetresPerSecond: 18
        ), "An uncertain GPS course must not force a reroute")
        XCTAssertFalse(NavigationWrongWayPolicy.isOpposing(
            courseDifferenceDegrees: 175, distanceFromRoute: 8,
            horizontalAccuracy: 9, speedMetresPerSecond: 2
        ), "Parking and turning around must not force a reroute")
    }

    func testRouteRejoinRequiresSeveralInsideFixesBeforeOldGuidanceReturns() {
        XCTAssertEqual(NavigationRouteRejoinPolicy.requiredConsecutiveInsideFixes, 3)
        XCTAssertFalse(NavigationRouteRejoinPolicy.isConfirmed(consecutiveInsideFixes: 1))
        XCTAssertFalse(NavigationRouteRejoinPolicy.isConfirmed(consecutiveInsideFixes: 2))
        XCTAssertTrue(NavigationRouteRejoinPolicy.isConfirmed(consecutiveInsideFixes: 3))
        XCTAssertTrue(NavigationRouteRejoinPolicy.isConfirmed(consecutiveInsideFixes: 4))
    }

    func testRouteRejoinRejectsMovingParallelRoadWithDifferentDirection() {
        XCTAssertTrue(NavigationRouteRejoinPolicy.acceptsInsideFix(
            isOutsideCorridor: false,
            courseDifferenceDegrees: 12,
            speedMetresPerSecond: 20
        ))
        XCTAssertFalse(NavigationRouteRejoinPolicy.acceptsInsideFix(
            isOutsideCorridor: false,
            courseDifferenceDegrees: 100,
            speedMetresPerSecond: 20
        ))
        XCTAssertTrue(NavigationRouteRejoinPolicy.acceptsInsideFix(
            isOutsideCorridor: false,
            courseDifferenceDegrees: 100,
            speedMetresPerSecond: 0
        ), "A stationary compass must not block distance-only recovery")
        XCTAssertTrue(NavigationRouteRejoinPolicy.acceptsInsideFix(
            isOutsideCorridor: false,
            courseDifferenceDegrees: nil,
            speedMetresPerSecond: 20
        ), "Missing course data must remain recoverable")
        XCTAssertFalse(NavigationRouteRejoinPolicy.acceptsInsideFix(
            isOutsideCorridor: true,
            courseDifferenceDegrees: 0,
            speedMetresPerSecond: 20
        ))
    }

    func testStableRouteRejoinCancelsOnlyAnObsoleteActiveReroute() {
        XCTAssertFalse(NavigationRouteRejoinPolicy.shouldCancelAutomaticReroute(
            isRecalculating: true, guidanceReliable: false, consecutiveInsideFixes: 2
        ))
        XCTAssertTrue(NavigationRouteRejoinPolicy.shouldCancelAutomaticReroute(
            isRecalculating: true, guidanceReliable: false, consecutiveInsideFixes: 3
        ))
        XCTAssertFalse(NavigationRouteRejoinPolicy.shouldCancelAutomaticReroute(
            isRecalculating: false, guidanceReliable: false, consecutiveInsideFixes: 3
        ))
        XCTAssertFalse(NavigationRouteRejoinPolicy.shouldCancelAutomaticReroute(
            isRecalculating: true, guidanceReliable: true, consecutiveInsideFixes: 3
        ))
    }

    func testStableRouteRejoinClearsFailedRerouteBackoff() {
        XCTAssertFalse(NavigationRouteRejoinPolicy.shouldClearRerouteRetryState(
            guidanceReliable: false, consecutiveInsideFixes: 2
        ))
        XCTAssertTrue(NavigationRouteRejoinPolicy.shouldClearRerouteRetryState(
            guidanceReliable: false, consecutiveInsideFixes: 3
        ))
        XCTAssertFalse(NavigationRouteRejoinPolicy.shouldClearRerouteRetryState(
            guidanceReliable: true, consecutiveInsideFixes: 3
        ))
    }

    func testDeviationThresholdReroutesSoonerInTownWithoutWeakeningMotorwayNoiseMargin() {
        XCTAssertEqual(NavigationDeviationPolicy.threshold(
            horizontalAccuracy: 8, speedMetresPerSecond: 8
        ), 55)
        XCTAssertEqual(NavigationDeviationPolicy.threshold(
            horizontalAccuracy: 8, speedMetresPerSecond: 20
        ), 80)
        XCTAssertEqual(NavigationDeviationPolicy.threshold(
            horizontalAccuracy: 8, speedMetresPerSecond: 35
        ), 140)
        XCTAssertEqual(NavigationDeviationPolicy.threshold(
            horizontalAccuracy: 50, speedMetresPerSecond: 8
        ), 150, "Poor GPS accuracy must still widen the corridor")
    }

    func testDeviationCorridorIgnoresDistantFutureCrossing() {
        XCTAssertEqual(
            NavigationDeviationCorridorPolicy.indices(current: 4, stepCount: 80),
            2..<21
        )
        XCTAssertTrue(
            NavigationDeviationCorridorPolicy.indices(current: 4, stepCount: 80).contains(3),
            "A briefly advanced manoeuvre cursor must still include the road immediately behind it"
        )
        XCTAssertFalse(
            NavigationDeviationCorridorPolicy.indices(current: 4, stepCount: 80).contains(0),
            "Old route sections must not mask a genuine deviation"
        )
        XCTAssertFalse(
            NavigationDeviationCorridorPolicy.indices(current: 4, stepCount: 80).contains(60),
            "A much later route crossing must not hide a current wrong turn"
        )
    }

    func testDeviationCorridorClampsAtFinalStepAndInvalidCursor() {
        XCTAssertEqual(NavigationDeviationCorridorPolicy.indices(current: 78, stepCount: 80), 76..<80)
        XCTAssertEqual(NavigationDeviationCorridorPolicy.indices(current: 200, stepCount: 80), 77..<80)
        XCTAssertEqual(NavigationDeviationCorridorPolicy.indices(current: -5, stepCount: 3), 0..<3)
        XCTAssertEqual(NavigationDeviationCorridorPolicy.indices(current: 0, stepCount: 0), 0..<0)
    }

    func testDeviationIgnoresMissingAndInvalidRouteGeometry() {
        XCTAssertNil(NavigationDeviationGeometryPolicy.nearestUsableDistance([]))
        XCTAssertNil(NavigationDeviationGeometryPolicy.nearestUsableDistance([
            (pointCount: 0, distance: 900),
            (pointCount: 1, distance: 800),
            (pointCount: 2, distance: .infinity),
        ]))
        XCTAssertEqual(
            NavigationDeviationGeometryPolicy.nearestUsableDistance([
                (pointCount: 2, distance: 130),
                (pointCount: 8, distance: 45),
            ]),
            45
        )
    }

    func testFailedReroutesBackOffInsteadOfLooping() {
        let attemptedAt = Date(timeIntervalSince1970: 10_000)
        XCTAssertEqual(NavigationRerouteRetryPolicy.cooldown(consecutiveFailures: 0), 30)
        XCTAssertEqual(NavigationRerouteRetryPolicy.cooldown(consecutiveFailures: 1), 60)
        XCTAssertEqual(NavigationRerouteRetryPolicy.cooldown(consecutiveFailures: 4), 180)
        XCTAssertFalse(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt, consecutiveFailures: 2,
            now: attemptedAt.addingTimeInterval(179)
        ))
        XCTAssertTrue(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt, consecutiveFailures: 2,
            now: attemptedAt.addingTimeInterval(180)
        ))
        XCTAssertTrue(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt.addingTimeInterval(1), consecutiveFailures: 4,
            now: attemptedAt
        ), "Clock rollback must not suppress rerouting until a future timestamp")
        XCTAssertFalse(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 300, previousDistance: 280,
            horizontalAccuracy: 8, speedMetresPerSecond: 25,
            rerouteAllowed: false
        ), "A cooldown must clear rather than preserve an old deviation streak")
        XCTAssertTrue(NavigationDeviationPolicy.shouldAccumulate(
            distanceFromRoute: 300, previousDistance: 280,
            horizontalAccuracy: 8, speedMetresPerSecond: 25,
            rerouteAllowed: true
        ))
    }

    func testFailedRerouteRetriesFromMeaningfullyNewDrivingPosition() {
        let attemptedAt = Date(timeIntervalSince1970: 20_000)
        XCTAssertFalse(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt, consecutiveFailures: 3,
            distanceSinceAttempt: 2_000,
            now: attemptedAt.addingTimeInterval(19)
        ), "Movement must not remove the minimum anti-loop delay")
        XCTAssertFalse(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt, consecutiveFailures: 3,
            distanceSinceAttempt: 300,
            now: attemptedAt.addingTimeInterval(30)
        ), "Small GPS movement must retain normal backoff")
        XCTAssertTrue(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt, consecutiveFailures: 3,
            distanceSinceAttempt: 900,
            now: attemptedAt.addingTimeInterval(30)
        ), "A substantially newer origin should regain guidance before three minutes")
        XCTAssertFalse(NavigationRerouteRetryPolicy.mayRetry(
            lastAttempt: attemptedAt, consecutiveFailures: 0,
            distanceSinceAttempt: 2_000,
            now: attemptedAt.addingTimeInterval(29)
        ), "Movement override applies only after an actual failed request")
    }

    func testConfirmedDeviationSuppressesUnsafeOldRouteAnnouncements() {
        XCTAssertTrue(NavigationManeuverSafetyPolicy.mayAnnounceLiveManeuver(
            navigationActive: true, rerouting: false, confirmedOffRoute: false
        ))
        XCTAssertFalse(NavigationManeuverSafetyPolicy.mayAnnounceLiveManeuver(
            navigationActive: true, rerouting: true, confirmedOffRoute: true
        ))
        XCTAssertFalse(NavigationManeuverSafetyPolicy.mayAnnounceLiveManeuver(
            navigationActive: true, rerouting: false, confirmedOffRoute: true
        ), "A failed reroute must not revive spoken instructions from the abandoned road")
        XCTAssertFalse(NavigationManeuverSafetyPolicy.mayAnnounceLiveManeuver(
            navigationActive: false, rerouting: false, confirmedOffRoute: false
        ))
    }

    func testFailedRerouteCanRetryWhileStoppedOnlyForConfirmedDeparture() {
        XCTAssertTrue(NavigationRerouteRetryPolicy.shouldRetryConfirmedDeparture(
            guidanceReliable: false,
            isOutsideCorridor: true,
            retryAllowed: true,
            consecutiveFailures: 1
        ))
        XCTAssertFalse(NavigationRerouteRetryPolicy.shouldRetryConfirmedDeparture(
            guidanceReliable: true,
            isOutsideCorridor: true,
            retryAllowed: true,
            consecutiveFailures: 1
        ), "An ordinary GPS outlier must still pass full departure confirmation")
        XCTAssertFalse(NavigationRerouteRetryPolicy.shouldRetryConfirmedDeparture(
            guidanceReliable: false,
            isOutsideCorridor: false,
            retryAllowed: true,
            consecutiveFailures: 1
        ), "Returning to the installed route must suppress the retry")
        XCTAssertFalse(NavigationRerouteRetryPolicy.shouldRetryConfirmedDeparture(
            guidanceReliable: false,
            isOutsideCorridor: true,
            retryAllowed: false,
            consecutiveFailures: 1
        ), "The existing backoff remains authoritative")
        XCTAssertFalse(NavigationRerouteRetryPolicy.shouldRetryConfirmedDeparture(
            guidanceReliable: false,
            isOutsideCorridor: true,
            retryAllowed: true,
            consecutiveFailures: 0
        ), "The first departure still requires moving multi-fix evidence")
    }

    func testConfirmedDeviationHidesStaleTurnCard() {
        let matching = NavigationInstructionDisplayPolicy.display(
            instruction: "Alte Abfahrt", distance: 50,
            upcomingInstructions: ["Alte Abfahrt"],
            guidanceReliable: false, recalculating: false, matchingPosition: true
        )
        XCTAssertEqual(matching.instruction, "Position wird bestimmt")
        XCTAssertNil(matching.distance)
        XCTAssertTrue(matching.upcomingInstructions.isEmpty)

        let searching = NavigationInstructionDisplayPolicy.display(
            instruction: "Rechts abbiegen", distance: 80,
            upcomingInstructions: ["Rechts abbiegen", "Links abbiegen"],
            guidanceReliable: false, recalculating: true
        )
        XCTAssertEqual(searching.instruction, "Neue Route wird gesucht")
        XCTAssertNil(searching.distance)
        XCTAssertTrue(searching.upcomingInstructions.isEmpty)
        XCTAssertTrue(searching.guidanceUnavailable)

        let failed = NavigationInstructionDisplayPolicy.display(
            instruction: "Rechts abbiegen", distance: 80,
            upcomingInstructions: ["Rechts abbiegen"],
            guidanceReliable: false, recalculating: false
        )
        XCTAssertEqual(failed.instruction, "Route verlassen – sicher weiterfahren")
        XCTAssertNil(failed.distance)
    }

    func testReliableGuidanceKeepsLiveTurnCard() {
        let display = NavigationInstructionDisplayPolicy.display(
            instruction: "Links halten", distance: 450,
            upcomingInstructions: ["Links halten", "Ausfahrt nehmen"],
            guidanceReliable: true, recalculating: false
        )
        XCTAssertEqual(display.instruction, "Links halten")
        XCTAssertEqual(display.distance, 450)
        XCTAssertEqual(display.upcomingInstructions, ["Links halten", "Ausfahrt nehmen"])
        XCTAssertFalse(display.guidanceUnavailable)
    }

    func testInstructionCardCompactsOnlyOnReliableLongCruiseLegs() {
        XCTAssertTrue(NavigationInstructionCardLayoutPolicy.usesCompactCruiseLayout(
            distance: 2_001, guidanceReliable: true,
            recalculating: false, matchingPosition: false
        ))
        XCTAssertFalse(NavigationInstructionCardLayoutPolicy.usesCompactCruiseLayout(
            distance: 2_000, guidanceReliable: true,
            recalculating: false, matchingPosition: false
        ), "The full card must return before an approaching maneuver")
        XCTAssertFalse(NavigationInstructionCardLayoutPolicy.usesCompactCruiseLayout(
            distance: 5_000, guidanceReliable: false,
            recalculating: false, matchingPosition: false
        ))
        XCTAssertFalse(NavigationInstructionCardLayoutPolicy.usesCompactCruiseLayout(
            distance: 5_000, guidanceReliable: true,
            recalculating: true, matchingPosition: false
        ))
        XCTAssertFalse(NavigationInstructionCardLayoutPolicy.usesCompactCruiseLayout(
            distance: 5_000, guidanceReliable: true,
            recalculating: false, matchingPosition: true
        ))
    }

    func testAudioOutputChangeRetriesOnlyIdleReliableGuidance() {
        XCTAssertTrue(NavigationAudioRouteChangeRetryPolicy.shouldRetry(
            outputMayHaveChanged: true, hasActiveSpeechWork: false,
            navigationActive: true, voiceGuidance: true,
            guidanceReliable: true, hasUsableLocation: true
        ))
        XCTAssertFalse(NavigationAudioRouteChangeRetryPolicy.shouldRetry(
            outputMayHaveChanged: true, hasActiveSpeechWork: true,
            navigationActive: true, voiceGuidance: true,
            guidanceReliable: true, hasUsableLocation: true
        ), "An in-flight sentence must not be duplicated across an output change")
        XCTAssertFalse(NavigationAudioRouteChangeRetryPolicy.shouldRetry(
            outputMayHaveChanged: false, hasActiveSpeechWork: false,
            navigationActive: true, voiceGuidance: true,
            guidanceReliable: true, hasUsableLocation: true
        ))
        XCTAssertFalse(NavigationAudioRouteChangeRetryPolicy.shouldRetry(
            outputMayHaveChanged: true, hasActiveSpeechWork: false,
            navigationActive: true, voiceGuidance: true,
            guidanceReliable: false, hasUsableLocation: true
        ), "A device connection must never revive stale turn guidance")
        XCTAssertFalse(NavigationAudioRouteChangeRetryPolicy.shouldRetry(
            outputMayHaveChanged: true, hasActiveSpeechWork: false,
            navigationActive: true, voiceGuidance: false,
            guidanceReliable: true, hasUsableLocation: true
        ))
    }

    func testRerouteWatchdogEndsOnlyAfterBoundedWait() {
        let startedAt = Date(timeIntervalSince1970: 10_000)
        XCTAssertFalse(NavigationRerouteWatchdogPolicy.hasTimedOut(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(NavigationRerouteWatchdogPolicy.timeout - 0.1)
        ))
        XCTAssertTrue(NavigationRerouteWatchdogPolicy.hasTimedOut(
            startedAt: startedAt,
            now: startedAt.addingTimeInterval(NavigationRerouteWatchdogPolicy.timeout)
        ))
        XCTAssertEqual(NavigationRerouteWatchdogPolicy.timeoutNanoseconds, 20_000_000_000)
    }

    func testSuccessfulRerouteUsesNewestAcceptedLocationForFirstManeuver() {
        let trigger = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 8, verticalAccuracy: 5, course: 90, speed: 20,
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let latest = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8.01), altitude: 0,
            horizontalAccuracy: 6, verticalAccuracy: 5, course: 90, speed: 20,
            timestamp: Date(timeIntervalSince1970: 1_012)
        )
        let selected = NavigationReroutePresentationPolicy.location(
            trigger: trigger, latest: latest
        )

        XCTAssertEqual(selected.timestamp, latest.timestamp)
        XCTAssertEqual(selected.coordinate.longitude, latest.coordinate.longitude, accuracy: 0.000_001)
    }

    func testSuccessfulRerouteRejectsClockSkewedOlderLocation() {
        let trigger = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 8, verticalAccuracy: 5,
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let older = CLLocation(
            coordinate: .init(latitude: 50, longitude: 7.99), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5,
            timestamp: Date(timeIntervalSince1970: 990)
        )

        XCTAssertEqual(
            NavigationReroutePresentationPolicy.location(trigger: trigger, latest: older).timestamp,
            trigger.timestamp
        )
        XCTAssertEqual(
            NavigationReroutePresentationPolicy.location(trigger: trigger, latest: nil).timestamp,
            trigger.timestamp
        )
    }

    func testDelayedGuidanceCalculationCannotCommitAfterStopOrWatchdog() {
        let session = UUID()
        let work = UUID()
        XCTAssertTrue(NavigationAsyncWorkPolicy.mayCommitCalculation(
            navigationActive: true, session: session, currentSession: session,
            work: work, currentWork: work
        ))
        XCTAssertFalse(NavigationAsyncWorkPolicy.mayCommitCalculation(
            navigationActive: false, session: session, currentSession: session,
            work: work, currentWork: work
        ), "Stopping navigation must invalidate an in-flight calculation")
        XCTAssertFalse(NavigationAsyncWorkPolicy.mayCommitCalculation(
            navigationActive: true, session: session, currentSession: session,
            work: work, currentWork: UUID()
        ), "The reroute watchdog must prevent its late MapKit result from publishing")
        XCTAssertFalse(NavigationAsyncWorkPolicy.mayCommitCalculation(
            navigationActive: true, session: session, currentSession: UUID(),
            work: nil, currentWork: UUID()
        ), "A calculation from an older drive must not replace the current route")
    }

    func testForegroundCalculationDoesNotDependOnNavigationSession() {
        XCTAssertTrue(NavigationAsyncWorkPolicy.mayCommitCalculation(
            navigationActive: false, session: nil, currentSession: UUID(),
            work: nil, currentWork: UUID()
        ))
    }

    func testManualRouteChangeSupersedesAutomaticRerouteWithoutCancellingItself() {
        let session = UUID()
        XCTAssertTrue(NavigationRerouteSupersessionPolicy.shouldInvalidateAutomaticReroute(
            isRecalculating: true, navigationSession: session, navigationWork: nil
        ))
        XCTAssertFalse(NavigationRerouteSupersessionPolicy.shouldInvalidateAutomaticReroute(
            isRecalculating: true, navigationSession: session, navigationWork: UUID()
        ), "The automatic reroute calculation must retain its own work ownership")
        XCTAssertFalse(NavigationRerouteSupersessionPolicy.shouldInvalidateAutomaticReroute(
            isRecalculating: true, navigationSession: nil, navigationWork: nil
        ), "A route preview outside navigation has no reroute lifecycle to supersede")
        XCTAssertFalse(NavigationRerouteSupersessionPolicy.shouldInvalidateAutomaticReroute(
            isRecalculating: false, navigationSession: session, navigationWork: nil
        ))
    }

    func testMultiLegRoutesUseBoundedParallelBatchesAndMatchingWatchdog() {
        XCTAssertEqual(NavigationMultiLegRoutingPolicy.maximumConcurrentLegs, 5)
        XCTAssertEqual(NavigationMultiLegRoutingPolicy.batches(legCount: 0), [])
        XCTAssertEqual(NavigationMultiLegRoutingPolicy.batches(legCount: 4), [0..<4])
        XCTAssertEqual(NavigationMultiLegRoutingPolicy.batches(legCount: 6), [0..<5, 5..<6])
        XCTAssertEqual(NavigationRerouteWatchdogPolicy.timeout(legCount: 1), 20)
        XCTAssertEqual(NavigationRerouteWatchdogPolicy.timeout(legCount: 5), 20)
        XCTAssertEqual(NavigationRerouteWatchdogPolicy.timeout(legCount: 6), 40)
        XCTAssertEqual(
            NavigationRerouteWatchdogPolicy.timeoutNanoseconds(legCount: 6),
            40_000_000_000
        )
    }

    func testRemoteSyncPolicyIsFastOnlyDuringNavigationAndRejectsBadFixes() {
        XCTAssertEqual(DriveRemoteSyncPolicy.interval(navigationActive: true), 5)
        XCTAssertEqual(DriveRemoteSyncPolicy.interval(navigationActive: false), 15)
        XCTAssertTrue(DriveRemoteSyncPolicy.accepts(CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 20, verticalAccuracy: 20, timestamp: Date()
        )))
        XCTAssertFalse(DriveRemoteSyncPolicy.accepts(CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 250, verticalAccuracy: 20, timestamp: Date()
        )))
    }

    func testRemoteCoordinatesRejectInvalidDestinationAndRequiredStops() {
        XCTAssertTrue(DriveRemoteCoordinatePolicy.isValid(
            latitude: 50.01, longitude: 8.35
        ))
        XCTAssertFalse(DriveRemoteCoordinatePolicy.isValid(
            latitude: 91, longitude: 8.35
        ))
        XCTAssertFalse(DriveRemoteCoordinatePolicy.isValid(
            latitude: 50.01, longitude: -181
        ))
        XCTAssertFalse(DriveRemoteCoordinatePolicy.isValid(
            latitude: .infinity, longitude: 8.35
        ))
    }

    func testRemoteRouteArgumentsNeverCoerceWrongTypesIntoDefaults() {
        XCTAssertTrue(DriveRemoteArgumentPolicy.validOptionalBool([:], key: "avoid_tolls"))
        XCTAssertTrue(DriveRemoteArgumentPolicy.validOptionalBool(
            ["avoid_tolls": .bool(true)], key: "avoid_tolls"
        ))
        XCTAssertFalse(DriveRemoteArgumentPolicy.validOptionalBool(
            ["avoid_tolls": .string("false")], key: "avoid_tolls"
        ))
        XCTAssertFalse(DriveRemoteArgumentPolicy.validOptionalArray(
            ["required_waypoints": .object([:])], key: "required_waypoints"
        ))
        XCTAssertFalse(DriveRemoteArgumentPolicy.validOptionalString(
            ["waypoint_id": .number(42)], key: "waypoint_id"
        ))
    }

    func testRemoteActiveRouteRemainsVisibleDuringOfflineGuidance() {
        XCTAssertTrue(DriveRemoteRouteVisibilityPolicy.hasRoute(
            liveLegCount: 0, offlineGuidanceActive: true
        ))
        XCTAssertTrue(DriveRemoteRouteVisibilityPolicy.hasRoute(
            liveLegCount: 1, offlineGuidanceActive: false
        ))
        XCTAssertFalse(DriveRemoteRouteVisibilityPolicy.hasRoute(
            liveLegCount: 0, offlineGuidanceActive: false
        ))
    }

    func testExpiredRemoteMutationIsRejectedAgainOnDevice() {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let now = Date(timeIntervalSince1970: 10_000)
        XCTAssertTrue(DriveRemoteCommandExpiryPolicy.isExpired(
            formatter.string(from: now.addingTimeInterval(-1)), now: now
        ))
        XCTAssertTrue(DriveRemoteCommandExpiryPolicy.isExpired(
            formatter.string(from: now), now: now
        ))
        XCTAssertFalse(DriveRemoteCommandExpiryPolicy.isExpired(
            formatter.string(from: now.addingTimeInterval(1)), now: now
        ))
        XCTAssertFalse(DriveRemoteCommandExpiryPolicy.isExpired(nil, now: now))
    }

    func testExitNumberAndDirectionAreExtracted() {
        let presentation = NavigationManeuverPresentation("Ausfahrt 69 rechts Richtung Neufahrn nehmen")
        XCTAssertEqual(presentation.exitLabel, "Ausfahrt 69")
        XCTAssertEqual(presentation.direction, .right)
        XCTAssertEqual(presentation.destinationLabel, "Neufahrn")
    }

    func testCarPlayManeuverSemanticUsesNativeExitAndRoundaboutTypes() {
        let motorway = NavigationManeuverPresentation(
            "Ausfahrt 69 rechts auf die A 9 Richtung München nehmen"
        )
        XCTAssertEqual(motorway.highwayExitLabel, "Ausfahrt 69")
        XCTAssertEqual(
            CarPlayManeuverSemanticPolicy.semantic(for: motorway),
            .highwayOffRampRight
        )

        let leftExit = NavigationManeuverPresentation(
            "Ausfahrt 12 links Richtung Wiesbaden nehmen"
        )
        XCTAssertEqual(
            CarPlayManeuverSemanticPolicy.semantic(for: leftExit),
            .highwayOffRampLeft
        )

        let roundabout = NavigationManeuverPresentation(
            "Im Kreisverkehr die zweite Ausfahrt Richtung Mainz nehmen"
        )
        XCTAssertNil(roundabout.highwayExitLabel)
        XCTAssertEqual(roundabout.roundaboutExitNumber, 2)
        XCTAssertEqual(
            CarPlayManeuverSemanticPolicy.semantic(for: roundabout),
            .roundabout(exit: 2)
        )
    }

    func testMotorwayJunctionVariantsProduceCompactExitLabels() {
        XCTAssertEqual(
            NavigationManeuverPresentation(
                "Anschlussstelle 12 rechts Richtung Wiesbaden, danach links halten"
            ).exitLabel,
            "Ausfahrt 12"
        )
        let spaced = NavigationManeuverPresentation(
            "Ausfahrt 69 A rechts Richtung Neufahrn, danach der A9 folgen"
        )
        XCTAssertEqual(spaced.exitLabel, "Ausfahrt 69A")
        XCTAssertEqual(spaced.destinationLabel, "Neufahrn")
    }

    func testManeuverUsesFirstActionWhenInstructionMentionsFollowingTurn() {
        XCTAssertEqual(
            NavigationManeuverPresentation("Links halten, danach rechts abbiegen").direction,
            .slightLeft
        )
        XCTAssertEqual(
            NavigationManeuverPresentation("Scharf rechts, danach links").direction,
            .sharpRight
        )
    }

    func testDestinationSignOmitsRepeatedRoadAction() {
        let presentation = NavigationManeuverPresentation(
            "Ausfahrt 12 rechts Richtung Wiesbaden auf die A66"
        )
        XCTAssertEqual(presentation.exitLabel, "Ausfahrt 12")
        XCTAssertEqual(presentation.roadLabel, "A66")
        XCTAssertEqual(presentation.destinationLabel, "Wiesbaden")
    }

    func testFollowingRoadDefaultsToStraight() {
        let presentation = NavigationManeuverPresentation("Der A9 folgen")
        XCTAssertEqual(presentation.direction, .straight)
        XCTAssertEqual(presentation.roadLabel, "A9")
    }

    func testRoadShieldAllowsWhitespace() {
        XCTAssertEqual(NavigationManeuverPresentation("Auf die A 10 fahren").roadLabel, "A10")
    }

    func testMapChoicesExcludePureSatelliteMode() {
        XCTAssertEqual(DriveMapAppearance.allCases, [.standard, .hybrid])
    }

    func testRemoteStateUsesServerCompatibleSnakeCaseKeys() throws {
        let state = DriveRemoteState(
            location: .init(latitude: 50, longitude: 8, accuracyMetres: 4),
            headingDegrees: 180, speedKmh: 90,
            activeRoute: .init(destination: "Hochheim", distanceMetres: 1_000, travelTimeSeconds: 60),
            nextManeuver: .init(instruction: "Rechts abbiegen", distanceMetres: 120), routeLock: nil,
            navigationActive: true, onRoute: true, rerouting: false,
            offlineGuidanceActive: false, recordedAt: Date(timeIntervalSince1970: 1))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])

        XCTAssertEqual(object["heading_degrees"] as? Double, 180)
        XCTAssertEqual(object["speed_kmh"] as? Double, 90)
        XCTAssertNotNil(object["active_route"])
        XCTAssertNotNil(object["next_maneuver"])
        let maneuver = try XCTUnwrap(object["next_maneuver"] as? [String: Any])
        XCTAssertEqual(maneuver["distance_metres"] as? Double, 120)
        XCTAssertEqual(object["navigation_active"] as? Bool, true)
        XCTAssertEqual(object["on_route"] as? Bool, true)
        XCTAssertEqual(object["rerouting"] as? Bool, false)
        XCTAssertEqual(object["offline_guidance_active"] as? Bool, false)
        XCTAssertNil(object["headingDegrees"])
    }

    func testRemoteStateCanIncludeLocationFreeDriveUsageTotals() throws {
        var state = DriveRemoteState(
            location: nil, headingDegrees: nil, speedKmh: nil,
            activeRoute: nil, nextManeuver: nil, routeLock: nil,
            navigationActive: false, onRoute: nil, rerouting: false,
            offlineGuidanceActive: false, recordedAt: Date(timeIntervalSince1970: 10)
        )
        state.usageStatistics = .init(
            totalDistanceMetres: 42_500,
            totalMovingTimeSeconds: 7_200,
            completedNavigations: 8,
            lastTripDistanceMetres: 1_500,
            lastTripMovingTimeSeconds: 300,
            lastTripEndedAt: Date(timeIntervalSince1970: 9)
        )

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.keyEncodingStrategy = .convertToSnakeCase
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(state)) as? [String: Any])
        let usage = try XCTUnwrap(object["usage_statistics"] as? [String: Any])
        XCTAssertEqual(usage["total_distance_metres"] as? Double, 42_500)
        XCTAssertEqual(usage["total_moving_time_seconds"] as? Double, 7_200)
        XCTAssertEqual(usage["completed_navigations"] as? Int, 8)
        XCTAssertEqual(usage["last_trip_distance_metres"] as? Double, 1_500)
        XCTAssertNotNil(usage["last_trip_ended_at"] as? String)
        XCTAssertNil(usage["location"])
    }

    func testRemoteTripLockOmitsDenseLocalCorridorButKeepsMandatoryRules() throws {
        let waypoint = LockedWaypoint(
            id: "slovenia", name: "Slowenien ohne Autobahn",
            coordinate: .init(latitude: 46.5, longitude: 15.6),
            required: true,
            optionsAfter: .init(avoidTolls: true, avoidHighways: true),
            kind: .routeConstraint
        )
        let lock = ActiveRouteLock(
            id: UUID(), title: "Kroatien", destinationName: "Hochheim",
            destination: .init(latitude: 50.0, longitude: 8.3),
            waypoints: [waypoint],
            defaultOptions: .init(avoidTolls: false, avoidHighways: false),
            corridorWidthMetres: 5_000,
            corridorPoints: (0..<20_000).map {
                .init(latitude: 43 + Double($0) / 10_000, longitude: 16)
            },
            visitedWaypointIDs: [], lastRouteProgress: 0.4,
            status: .active,
            createdAt: Date(timeIntervalSince1970: 1),
            updatedAt: Date(timeIntervalSince1970: 2)
        )
        let state = DriveRemoteState(
            location: nil, headingDegrees: nil, speedKmh: nil,
            activeRoute: nil, nextManeuver: nil,
            routeLock: .init(lock), navigationActive: true,
            onRoute: true, rerouting: false, offlineGuidanceActive: false,
            recordedAt: Date(timeIntervalSince1970: 3)
        )

        let data = try JSONEncoder().encode(state)
        let object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        let remoteLock = try XCTUnwrap(object["route_lock"] as? [String: Any])
        let waypoints = try XCTUnwrap(remoteLock["waypoints"] as? [[String: Any]])

        XCTAssertNil(remoteLock["corridorPoints"])
        XCTAssertNil(remoteLock["corridor_points"])
        XCTAssertEqual(waypoints.first?["id"] as? String, "slovenia")
        XCTAssertNotNil(waypoints.first?["optionsAfter"])
        XCTAssertLessThan(data.count, 16_000)
    }

    func testRouteSearchDiagnosticsRemainLocationPrivate() {
        let events = [
            DriveDiagnosticEvent(
                kind: .routeSearchCompleted,
                detail: "POI 18 · Korridor 6 · Umweg geprüft 6 · zulässig 3"
            ),
            DriveDiagnosticEvent(kind: .routeStopAdded, detail: "Raststätte Spessart"),
        ]

        let report = DriveDiagnosticReport.text(events: events, appVersion: "Test")

        XCTAssertTrue(report.contains("routeSearchCompleted"))
        XCTAssertTrue(report.contains("routeStopAdded"))
        XCTAssertFalse(report.contains("Raststätte Spessart"))
        XCTAssertFalse(report.contains("latitude"))
        XCTAssertFalse(report.contains("longitude"))
    }

    func testRemoteCommandJournalPersistsOutcomeUntilServerAcknowledgesIt() throws {
        let suite = "KiesDriveTests.RemoteJournal.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let journal = DriveRemoteCommandJournal(defaults: defaults, maximumCount: 2)
        journal.save([
            1: .init(ok: true, message: "fertig"),
            2: .init(ok: false, message: "keine Route"),
            3: .init(ok: true, message: "später bestätigt"),
        ])

        let restored = journal.load()
        XCTAssertNil(restored[1], "The bounded journal keeps only the newest outcomes")
        XCTAssertEqual(restored[2], .init(ok: false, message: "keine Route"))
        XCTAssertEqual(restored[3], .init(ok: true, message: "später bestätigt"))

        var acknowledged = restored
        acknowledged.removeValue(forKey: 2)
        journal.save(acknowledged)
        XCTAssertNil(journal.load()[2])
    }

    func testSpeechInstructionsRemoveSymbolsAndSoundLikeSentences() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("rechts ↗ Richtung A 66 / Wiesbaden", distance: 112),
            "In 100 Metern, Rechts Richtung A 66, Wiesbaden."
        )
    }

    func testVoiceSelectionPrioritisesAudioQualityBeforeSiriBranding() {
        let compactSiri = NavigationVoiceSelectionPolicy.score(
            qualityRawValue: 1, identifier: "com.apple.voice.compact.de-DE.siri"
        )
        let premium = NavigationVoiceSelectionPolicy.score(
            qualityRawValue: 3, identifier: "com.apple.voice.premium.de-DE.anna"
        )
        XCTAssertGreaterThan(premium, compactSiri)

        let enhancedSiri = NavigationVoiceSelectionPolicy.score(
            qualityRawValue: 2, identifier: "com.apple.voice.enhanced.de-DE.siri"
        )
        let enhancedGeneric = NavigationVoiceSelectionPolicy.score(
            qualityRawValue: 2, identifier: "com.apple.voice.enhanced.de-DE.anna"
        )
        XCTAssertGreaterThan(enhancedSiri, enhancedGeneric)
    }

    func testPreferredVoiceMustStillBeInstalled() {
        XCTAssertEqual(
            NavigationVoiceSelectionPolicy.selectedIdentifier(
                preferred: "de.voice.anna", available: ["de.voice.anna", "de.voice.siri"]
            ),
            "de.voice.anna"
        )
        XCTAssertNil(
            NavigationVoiceSelectionPolicy.selectedIdentifier(
                preferred: "de.voice.removed", available: ["de.voice.anna"]
            )
        )
        XCTAssertNil(
            NavigationVoiceSelectionPolicy.selectedIdentifier(
                preferred: "", available: ["de.voice.anna"]
            )
        )
    }

    func testCarPlayAlongRouteSearchPreservesDestination() {
        XCTAssertTrue(CarPlaySearchPurpose.destination.replacesDestination)
        XCTAssertFalse(CarPlaySearchPurpose.routeStop.replacesDestination)
    }

    func testCarPlaySearchSelectionRequiresCurrentQueryAndPurpose() {
        let generation = UUID()
        XCTAssertTrue(CarPlaySearchSelectionPolicy.accepts(
            resultGeneration: generation, currentGeneration: generation,
            resultPurpose: .destination, currentPurpose: .destination
        ))
        XCTAssertFalse(CarPlaySearchSelectionPolicy.accepts(
            resultGeneration: UUID(), currentGeneration: generation,
            resultPurpose: .destination, currentPurpose: .destination
        ))
        XCTAssertFalse(CarPlaySearchSelectionPolicy.accepts(
            resultGeneration: generation, currentGeneration: generation,
            resultPurpose: .routeStop, currentPurpose: .destination
        ))
    }

    func testSpeechNormalisesCompactRoadNamesAndUnsafeCharacters() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("\u{FFFC} ↗ A66 • B40 – Richtung Köln (E40)"),
            "A 66, B 40, Richtung Köln, E 40."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Der BAB3 Richtung Passau folgen"),
            "Der Autobahn 3 Richtung Passau folgen."
        )
    }

    func testGermanVoiceReceivesTranslatedMapKitManeuverVocabulary() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "At the roundabout, take the 2nd exit toward A66"
            ),
            "Im Kreisverkehr, die zweite Ausfahrt nehmen Richtung A 66."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Turn right onto B40"),
            "Rechts abbiegen auf B 40."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Keep left toward Köln"),
            "Links halten Richtung Köln."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Make a U-turn"),
            "Bitte wenden."
        )
    }

    func testSpeechSeparatesEuropeanHolidayRouteRoadLabels() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Der D8 Richtung Split folgen, danach auf H3 / G1"
            ),
            "Der D 8 Richtung Split folgen, danach auf H 3, G 1."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Auf SS13 Richtung Tarvisio fahren"),
            "Auf SS 13 Richtung Tarvisio fahren."
        )
    }

    func testSpeechExpandsSpeedUnitBeforeRemovingSlash() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Tempolimit 80 km/h"),
            "Tempolimit 80 Kilometer pro Stunde."
        )
    }

    func testSpeechExpandsGermanJunctionAndRoadAbbreviationsNaturally() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Am AK Wiesbaden rechts auf St 2060, Rtg. Bhf. abfahren"
            ),
            "Am Autobahnkreuz Wiesbaden rechts auf Staatsstraße 2060, Richtung Bahnhof abfahren."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Am AD links zur AS 12 [St. Goar]"
            ),
            "Am Autobahndreieck links zur Anschlussstelle 12, Sankt Goar."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Richtung Ak Saray"),
            "Richtung Ak Saray."
        )
    }

    func testSpeechSeparatesLetteredExitAndRoadSuffixes() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Ausfahrt 69-A rechts auf A66a Richtung Wiesbaden nehmen"
            ),
            "Ausfahrt 69 A rechts auf A 66 a Richtung Wiesbaden nehmen."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Anschlussstelle 12 B links nehmen"),
            "Anschlussstelle 12 B links nehmen."
        )
    }

    func testSpeechPronouncesRoundaboutExitAsNaturalGermanOrdinal() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Im Kreisverkehr die 2. Ausfahrt Richtung A66 nehmen"
            ),
            "Im Kreisverkehr die zweite Ausfahrt Richtung A 66 nehmen."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Ausfahrt 2 Richtung Zentrum nehmen"),
            "Ausfahrt 2 Richtung Zentrum nehmen.",
            "A motorway exit number must not be rewritten as a roundabout ordinal"
        )
    }

    func testSpeechInstructionUsesImmediateCueNearManeuver() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("links abbiegen", distance: 20),
            "Jetzt, Links abbiegen."
        )
    }

    func testSpeechTranslatesCommonCrossBorderManeuvers() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Take the ramp right onto A2 toward Graz"),
            "Die Auffahrt rechts nehmen auf A 2 Richtung Graz."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Merge onto A10"),
            "Einfädeln auf A 10."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Slight left onto SS13"),
            "Leicht links abbiegen auf SS 13."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Your destination is on the right"),
            "Das Ziel befindet sich rechts."
        )
    }

    func testSpeechTranslatesEnglishMotorwayLaneAndExitInstructions() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Use the right lane to take exit 69A toward A66"
            ),
            "Die rechte Spur benutzen und Ausfahrt 69 A nehmen Richtung A 66."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Use the 2 left lanes to take exit 12 toward Graz"
            ),
            "Die 2 linken Spuren benutzen und Ausfahrt 12 nehmen Richtung Graz."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Exit 7B toward Split"),
            "Ausfahrt 7 B nehmen Richtung Split."
        )
    }

    func testSpeechTranslatesEnglishMotorwayContinuationInstructions() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Stay on A10 toward Salzburg"),
            "Weiterfahren auf A 10 Richtung Salzburg."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Follow signs for E71 toward Zagreb"),
            "Der Beschilderung folgen Richtung E 71 Richtung Zagreb."
        )
    }

    func testSpeechUsesNaturalKilometreDistance() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("Ausfahrt rechts nehmen", distance: 1_760),
            "In 2 Kilometern, Ausfahrt rechts nehmen."
        )
    }

    func testSpeechChainsOnlyCloseFollowingManeuver() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Rechts abbiegen", distance: 20,
                then: "links halten Richtung A 66", followingDistance: 180
            ),
            "Jetzt, Rechts abbiegen. Danach, Links halten Richtung A 66."
        )
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText(
                "Rechts abbiegen", distance: 20,
                then: "links halten", followingDistance: 900
            ),
            "Jetzt, Rechts abbiegen."
        )
    }

    func testDenseFollowingManeuverIsIncludedFromFinalCueOnward() {
        XCTAssertFalse(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .prepare, followingDistance: 180
        ))
        XCTAssertTrue(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .final, followingDistance: 180
        ))
        XCTAssertTrue(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .now, followingDistance: 450
        ))
        XCTAssertFalse(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .now, followingDistance: 451
        ))
        XCTAssertFalse(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .now, followingDistance: .infinity
        ))
    }

    func testDenseManeuverWindowAdaptsToDrivingSpeed() {
        XCTAssertEqual(
            NavigationChainedManeuverPolicy.maximumFollowingDistance(
                speedMetresPerSecond: 30 / 3.6
            ),
            150,
            accuracy: 0.001
        )
        XCTAssertEqual(
            NavigationChainedManeuverPolicy.maximumFollowingDistance(
                speedMetresPerSecond: 200 / 3.6
            ),
            200 / 3.6 * 14,
            accuracy: 0.001
        )
        XCTAssertFalse(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .final, followingDistance: 300, speedMetresPerSecond: 30 / 3.6
        ))
        XCTAssertTrue(NavigationChainedManeuverPolicy.shouldIncludeFollowingManeuver(
            at: .final, followingDistance: 700, speedMetresPerSecond: 200 / 3.6
        ))
        XCTAssertEqual(
            NavigationManeuverSpeechPolicy.text(
                instruction: "Ausfahrt nehmen", distance: 300, stage: .final,
                followingInstruction: "rechts halten", followingDistance: 700,
                speedMetresPerSecond: 200 / 3.6
            ),
            "In 300 Metern, Ausfahrt nehmen. Danach, Rechts halten."
        )
    }

    func testRecoveredTransitionChainsHighSpeedMotorwayManeuver() {
        let motorwaySpeed = 200.0 / 3.6
        XCTAssertTrue(
            NavigationTransitionRecoverySpeechPolicy.shouldChainFollowingManeuver(
                distance: 700, speedMetresPerSecond: motorwaySpeed
            )
        )
        XCTAssertEqual(
            NavigationTransitionRecoverySpeechPolicy.text(
                previousInstruction: "Ausfahrt rechts nehmen",
                nextInstruction: "Links halten Richtung A 66",
                nextDistance: 700,
                speedMetresPerSecond: motorwaySpeed
            ),
            "Jetzt, Ausfahrt rechts nehmen. Danach, Links halten Richtung A 66."
        )
    }

    func testRecoveredTransitionDoesNotChainDistantUrbanManeuver() {
        let urbanSpeed = 30.0 / 3.6
        XCTAssertFalse(
            NavigationTransitionRecoverySpeechPolicy.shouldChainFollowingManeuver(
                distance: 700, speedMetresPerSecond: urbanSpeed
            )
        )
        XCTAssertEqual(
            NavigationTransitionRecoverySpeechPolicy.text(
                previousInstruction: "Rechts abbiegen",
                nextInstruction: "Links abbiegen",
                nextDistance: 700,
                speedMetresPerSecond: urbanSpeed
            ),
            "Jetzt, Rechts abbiegen."
        )
    }

    func testMissedCueIsNeverRecoveredAfterTheOldJunctionIsClearlyBehind() {
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "old", nextKey: "new", stages: [],
            previousDistance: 40, speedMetresPerSecond: 25
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "old", nextKey: "new", stages: [],
            previousDistance: 180, speedMetresPerSecond: 25
        ))
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "old", nextKey: "new", stages: [],
            previousDistance: 45, speedMetresPerSecond: 55
        ), "A cue can still be recovered inside the bounded junction window")
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "old", nextKey: "new", stages: [],
            previousDistance: 46, speedMetresPerSecond: 55
        ), "High speed must not turn a late instruction into a 100 m recovery window")
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "old", nextKey: "new", stages: [],
            previousDistance: .infinity, speedMetresPerSecond: 25
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "old", nextKey: "new", stages: [],
            previousDistance: 20, speedMetresPerSecond: 25,
            recoveredAfterLocationGap: true
        ), "A post-tunnel fix must not speak a turn that is already behind the car")
    }

    func testFinalRoadRecoversLastTurnOnlyAtContinuousNearbyJunction() {
        XCTAssertEqual(
            NavigationFinalRoadTransitionPolicy.action(
                previousKey: "last-turn", delivered: [], inFlight: [],
                previousDistance: 24, speedMetresPerSecond: 14,
                recoveredAfterLocationGap: false
            ),
            .recoverNow
        )
        XCTAssertEqual(
            NavigationFinalRoadTransitionPolicy.action(
                previousKey: "last-turn", delivered: [], inFlight: [],
                previousDistance: 24, speedMetresPerSecond: 14,
                recoveredAfterLocationGap: true
            ),
            .closeAsMissed,
            "After a location gap the old turn may already be behind the driver"
        )
        XCTAssertEqual(
            NavigationFinalRoadTransitionPolicy.action(
                previousKey: "last-turn", delivered: [], inFlight: [.final],
                previousDistance: 8, speedMetresPerSecond: 14,
                recoveredAfterLocationGap: false
            ),
            .closeAsDelivered,
            "An audible decisive cue must not be duplicated at the final road"
        )
        XCTAssertEqual(
            NavigationFinalRoadTransitionPolicy.action(
                previousKey: nil, delivered: [], inFlight: [],
                previousDistance: nil, speedMetresPerSecond: 14,
                recoveredAfterLocationGap: false
            ),
            .none
        )
        XCTAssertEqual(
            NavigationFinalRoadTransitionPolicy.action(
                previousKey: "last-turn", delivered: [.early], inFlight: [],
                previousDistance: 24, speedMetresPerSecond: 14,
                recoveredAfterLocationGap: false, voiceGuidance: false
            ),
            .closeMuted,
            "Muted navigation should close the maneuver without reporting a missed cue"
        )
    }

    func testOnlineAndOfflineManeuverSpeechShareDenseTurnWording() {
        XCTAssertEqual(
            NavigationManeuverSpeechPolicy.text(
                instruction: "Rechts abbiegen", distance: 90, stage: .final,
                followingInstruction: "Links halten", followingDistance: 180
            ),
            "In 100 Metern, Rechts abbiegen. Danach, Links halten."
        )
        XCTAssertEqual(
            NavigationManeuverSpeechPolicy.text(
                instruction: "Rechts abbiegen", distance: 90, stage: .prepare,
                followingInstruction: "Links halten", followingDistance: 180
            ),
            "In 100 Metern, Rechts abbiegen."
        )
        XCTAssertEqual(
            NavigationManeuverSpeechPolicy.text(
                instruction: "Rechts abbiegen", distance: 70, stage: .now,
                followingInstruction: "Links halten", followingDistance: 180
            ),
            "Jetzt, Rechts abbiegen. Danach, Links halten."
        )
    }

    func testOfflineGuidanceMeasuresDistanceBetweenCloseManeuvers() throws {
        let points = [
            CLLocationCoordinate2D(latitude: 50.0000, longitude: 8.0000),
            CLLocationCoordinate2D(latitude: 50.0010, longitude: 8.0000),
            CLLocationCoordinate2D(latitude: 50.0020, longitude: 8.0000),
            CLLocationCoordinate2D(latitude: 50.0030, longitude: 8.0000),
        ]
        let steps = [
            OfflineGuidanceStep(instruction: "", distance: 111, coordinates: [points[0], points[1]]),
            OfflineGuidanceStep(instruction: "Rechts abbiegen", distance: 111, coordinates: [points[1], points[2]]),
            OfflineGuidanceStep(instruction: "Links halten", distance: 111, coordinates: [points[2], points[3]]),
        ]
        let progress = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: points[0], currentIndex: 0, steps: steps, transitionRadius: 12
        ))
        XCTAssertEqual(progress.followingManeuverDistance ?? -1, 111, accuracy: 0.1)
        XCTAssertEqual(progress.followingManeuverStepIndex, 2)
        XCTAssertEqual(progress.followingManeuverInstruction, "Links halten")
    }

    func testOfflineGuidanceRecoversAcrossLongGapBeyondEightySteps() throws {
        let coordinates = (0...100).map { index in
            CLLocationCoordinate2D(latitude: 50 + Double(index) * 0.001, longitude: 8)
        }
        let steps = (0..<100).map { index in
            OfflineGuidanceStep(
                instruction: index > 0 && index.isMultiple(of: 10) ? "Geradeaus" : "",
                distance: 111,
                coordinates: [coordinates[index], coordinates[index + 1]]
            )
        }

        let recovered = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: coordinates[95], currentIndex: 0, steps: steps,
            transitionRadius: 12, allowsFullRecovery: true, courseDegrees: 0
        ))
        let bounded = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: coordinates[95], currentIndex: 0, steps: steps,
            transitionRadius: 12, allowsFullRecovery: false, courseDegrees: 0
        ))

        XCTAssertGreaterThanOrEqual(recovered.currentStepIndex, 94,
                                    "A fresh fix after a long gap must find the current cached road")
        XCTAssertLessThan(bounded.currentStepIndex, 94,
                          "Normal updates must retain the bounded forward search")
    }

    func testOfflineGuidanceSkipsEmptyRestoredTransitionGeometry() throws {
        let points = [
            CLLocationCoordinate2D(latitude: 50.0000, longitude: 8.0000),
            CLLocationCoordinate2D(latitude: 50.0010, longitude: 8.0000),
            CLLocationCoordinate2D(latitude: 50.0020, longitude: 8.0000),
        ]
        let steps = [
            OfflineGuidanceStep(instruction: "", distance: 0, coordinates: []),
            OfflineGuidanceStep(instruction: "", distance: 111, coordinates: [points[0], points[1]]),
            OfflineGuidanceStep(
                instruction: "Rechts abbiegen", distance: 111,
                coordinates: [points[1], points[2]]
            ),
        ]

        let progress = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: points[0], currentIndex: 0, steps: steps, transitionRadius: 12
        ))

        XCTAssertEqual(progress.currentStepIndex, 1)
        XCTAssertEqual(progress.instruction, "Rechts abbiegen")
        XCTAssertTrue(progress.distanceToManeuver.isFinite)
    }

    func testOfflineGuidanceExposesOpposingCourseOnCachedRoad() throws {
        let south = CLLocationCoordinate2D(latitude: 50.0000, longitude: 8.0000)
        let north = CLLocationCoordinate2D(latitude: 50.0020, longitude: 8.0000)
        let later = CLLocationCoordinate2D(latitude: 50.0030, longitude: 8.0000)
        let steps = [
            OfflineGuidanceStep(instruction: "", distance: 222, coordinates: [south, north]),
            OfflineGuidanceStep(
                instruction: "Rechts abbiegen", distance: 111,
                coordinates: [north, later]
            ),
        ]

        let progress = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: south, currentIndex: 0, steps: steps,
            transitionRadius: 12, courseDegrees: 180
        ))

        XCTAssertEqual(progress.courseDifferenceDegrees ?? -1, 180, accuracy: 1)
        XCTAssertTrue(NavigationWrongWayPolicy.isOpposing(
            courseDifferenceDegrees: progress.courseDifferenceDegrees,
            distanceFromRoute: progress.distanceFromRoute,
            horizontalAccuracy: 8, speedMetresPerSecond: 18
        ))
    }

    func testAnnouncementStagesAdaptToRoadSpeed() {
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 850, speedKmh: 120), .early)
        XCTAssertNil(NavigationAnnouncementStage.stage(distance: 850, speedKmh: 50))
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 200, speedKmh: 50), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 30, speedKmh: 50), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 1_700, speedKmh: 200), .early)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 650, speedKmh: 200), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 120, speedKmh: 200), .now)
    }

    func testImmediateCueUsesRealisticSpeedDependentWindow() {
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 40, speedKmh: 50), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 55, speedKmh: 50), .final)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 95, speedKmh: 120), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 130, speedKmh: 120), .final)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 165, speedKmh: 200), .now)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 220, speedKmh: 200), .final)
    }

    func testSpeechPriorityProtectsImmediateManeuverFromStatusMessage() {
        XCTAssertEqual(NavigationSpeechPriority.forAnnouncementStage(.early), .maneuver)
        XCTAssertEqual(NavigationSpeechPriority.forAnnouncementStage(.prepare), .maneuver)
        XCTAssertEqual(NavigationSpeechPriority.forAnnouncementStage(.final), .critical)
        XCTAssertEqual(NavigationSpeechPriority.forAnnouncementStage(.now), .critical)
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.hasActiveWork(
            isSpeaking: false, hasQueuedUtterance: true
        ), "An utterance queued before playback must already own the speech slot")
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.hasActiveWork(
            isSpeaking: true, hasQueuedUtterance: false
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.hasActiveWork(
            isSpeaking: false, hasQueuedUtterance: false
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .critical, incoming: .status
        ))
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .status, incoming: .maneuver
        ))
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .maneuver, incoming: .critical
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .critical, incoming: .critical
        ), "A following final or immediate turn must not cut a decisive cue in half")
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldInterrupt(
            active: .maneuver, incoming: .maneuver
        ), "A later preparation stage must be able to supersede an unfinished earlier stage")
    }

    func testNewDistanceStageDoesNotCutOffSameManeuverSentence() {
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldDeferForSameManeuver(
            activeKeys: ["leg-0-step-4"], incomingKeys: ["leg-0-step-4"],
            incomingPriority: .maneuver
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldDeferForSameManeuver(
            activeKeys: ["leg-0-step-4"], incomingKeys: ["leg-0-step-5"],
            incomingPriority: .maneuver
        ), "A genuinely different upcoming maneuver may replace old preparation")
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldDeferForSameManeuver(
            activeKeys: ["leg-0-step-4"], incomingKeys: ["leg-0-step-4"],
            incomingPriority: .critical
        ), "The immediate cue must still overtake an old distance cue")
    }

    func testImmediateNextTurnPreemptsOnlyStaleFinalCue() {
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldPreemptCriticalFinalCue(
            activeKeys: ["leg-0-step-4"], activeStages: [.final],
            incomingKeys: ["leg-0-step-5"], incomingStages: [.now]
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldPreemptCriticalFinalCue(
            activeKeys: ["leg-0-step-4"], activeStages: [.now],
            incomingKeys: ["leg-0-step-5"], incomingStages: [.now]
        ), "A current immediate cue must still finish")
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldPreemptCriticalFinalCue(
            activeKeys: ["leg-0-step-4", "leg-0-step-5"], activeStages: [.final],
            incomingKeys: ["leg-0-step-5"], incomingStages: [.now]
        ), "A chained utterance already contains the next turn")
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldPreemptCriticalFinalCue(
            activeKeys: ["leg-0-step-4"], activeStages: [.final],
            incomingKeys: ["leg-0-step-5"], incomingStages: [.final]
        ), "Only the immediate next instruction may interrupt critical speech")
    }

    func testOnlyUnexpectedManeuverCancellationRetriesImmediately() {
        XCTAssertTrue(NavigationSpeechCancellationPolicy.shouldRetryUnexpectedCancellation(
            hadManeuverClaim: true, navigationActive: true, voiceGuidance: true,
            guidanceReliable: true, hasUsableLocation: true
        ))
        XCTAssertTrue(NavigationSpeechCancellationPolicy.shouldRetryUnexpectedCancellation(
            hadManeuverClaim: false, hadReminderClaim: true,
            navigationActive: true, voiceGuidance: true,
            guidanceReliable: true, hasUsableLocation: true
        ), "An interrupted pause/fuel reminder must be reconsidered without waiting for another GPS fix")
        XCTAssertFalse(NavigationSpeechCancellationPolicy.shouldRetryUnexpectedCancellation(
            hadManeuverClaim: false, navigationActive: true, voiceGuidance: true,
            guidanceReliable: true, hasUsableLocation: true
        ), "An app-initiated stop clears ownership and must remain silent")
        XCTAssertFalse(NavigationSpeechCancellationPolicy.shouldRetryUnexpectedCancellation(
            hadManeuverClaim: true, navigationActive: true, voiceGuidance: true,
            guidanceReliable: false, hasUsableLocation: true
        ), "A cancelled instruction from a departed route must never be repeated")
        XCTAssertFalse(NavigationSpeechCancellationPolicy.shouldRetryUnexpectedCancellation(
            hadManeuverClaim: true, navigationActive: true, voiceGuidance: false,
            guidanceReliable: true, hasUsableLocation: true
        ))
    }

    func testUnmutingRetriesGuidanceOnlyDuringActiveNavigation() {
        XCTAssertTrue(NavigationVoiceGuidanceTogglePolicy.shouldRetryCurrentManeuver(
            enabled: true, navigationActive: true
        ))
        XCTAssertFalse(NavigationVoiceGuidanceTogglePolicy.shouldRetryCurrentManeuver(
            enabled: false, navigationActive: true
        ))
        XCTAssertFalse(NavigationVoiceGuidanceTogglePolicy.shouldRetryCurrentManeuver(
            enabled: true, navigationActive: false
        ))
    }

    func testFinishedSpeechCommitsQueuedClaimWhenStartCallbackWasLost() {
        XCTAssertEqual(
            NavigationAnnouncementDeliveryPolicy.completedClaims(
                active: "started", queued: "queued"
            ),
            "started"
        )
        XCTAssertEqual(
            NavigationAnnouncementDeliveryPolicy.completedClaims(
                active: Optional<String>.none, queued: "queued"
            ),
            "queued"
        )
        XCTAssertNil(
            NavigationAnnouncementDeliveryPolicy.completedClaims(
                active: Optional<String>.none, queued: Optional<String>.none
            )
        )
    }

    func testCommittedReplacementRouteCancelsEveryOldSpokenManeuver() {
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldCancelForRouteReplacement(
            navigationActive: true, hasSpeechWork: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldCancelForRouteReplacement(
            navigationActive: false, hasSpeechWork: true
        ), "Route preview changes must not cancel unrelated speech")
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldCancelForRouteReplacement(
            navigationActive: true, hasSpeechWork: false
        ))
    }

    func testConfirmedDeviationCancelsUnsafeOldRouteSpeech() {
        XCTAssertTrue(NavigationSpeechInterruptionPolicy.shouldCancelForConfirmedDeviation(
            confirmedOffRoute: true, navigationActive: true, hasSpeechWork: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldCancelForConfirmedDeviation(
            confirmedOffRoute: false, navigationActive: true, hasSpeechWork: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldCancelForConfirmedDeviation(
            confirmedOffRoute: true, navigationActive: false, hasSpeechWork: true
        ))
        XCTAssertFalse(NavigationSpeechInterruptionPolicy.shouldCancelForConfirmedDeviation(
            confirmedOffRoute: true, navigationActive: true, hasSpeechWork: false
        ))
    }

    func testManeuverAnnouncementRemainsRetryableUntilSpeechActuallyStarts() {
        XCTAssertTrue(NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            .prepare, delivered: [], pending: []
        ))
        XCTAssertFalse(NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            .prepare, delivered: [], pending: [.prepare]
        ), "A queued utterance must not be enqueued repeatedly")
        XCTAssertTrue(NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            .prepare, delivered: [], pending: []
        ), "A cancelled-before-start utterance must be retryable")
        XCTAssertFalse(NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            .prepare,
            delivered: NavigationAnnouncementDeliveryPolicy.stages(upTo: .prepare),
            pending: []
        ))
    }

    func testStalledSpeechClaimExpiresAndCanBeRetried() {
        let issuedAt = Date(timeIntervalSince1970: 100)
        XCTAssertFalse(NavigationSpeechClaimTimeoutPolicy.isExpired(
            issuedAt: issuedAt, now: issuedAt.addingTimeInterval(3.9), active: false
        ))
        XCTAssertTrue(NavigationSpeechClaimTimeoutPolicy.isExpired(
            issuedAt: issuedAt, now: issuedAt.addingTimeInterval(4), active: false
        ))
        XCTAssertFalse(NavigationSpeechClaimTimeoutPolicy.isExpired(
            issuedAt: issuedAt, now: issuedAt.addingTimeInterval(19.9), active: true
        ))
        XCTAssertTrue(NavigationSpeechClaimTimeoutPolicy.isExpired(
            issuedAt: issuedAt, now: issuedAt.addingTimeInterval(20), active: true
        ))
        XCTAssertTrue(NavigationSpeechClaimTimeoutPolicy.isExpired(
            issuedAt: issuedAt, now: issuedAt.addingTimeInterval(-1), active: false
        ), "Clock rollback must release a speech claim that could otherwise block forever")
    }

    func testManeuverDeliveryCommitsOnlyAfterCompletePlayback() {
        XCTAssertFalse(NavigationAnnouncementDeliveryPolicy.shouldCommitDelivery(
            didFinish: false
        ), "Starting or later cancelling audio must not consume a maneuver cue")
        XCTAssertTrue(NavigationAnnouncementDeliveryPolicy.shouldCommitDelivery(
            didFinish: true
        ))
    }

    func testLateOlderSpeechCompletionCannotRegressDeliveredManeuverStage() {
        let decisive = NavigationAnnouncementDeliveryPolicy.stages(upTo: .now)
        let afterLatePrepare = NavigationAnnouncementDeliveryPolicy.committedStages(
            delivered: decisive, completing: .prepare
        )

        XCTAssertEqual(afterLatePrepare, decisive)
        XCTAssertFalse(NavigationAnnouncementDeliveryPolicy.shouldAttempt(
            .now, delivered: afterLatePrepare, pending: []
        ), "A late older callback must not make the completed final cue eligible again")
    }

    func testNewRouteSeedsItsOwnFirstManeuverImmediately() throws {
        let seed = try XCTUnwrap(NavigationInitialManeuverPolicy.seed(steps: [
            (instruction: "", distance: 420),
            (instruction: "Rechts auf die A 66 fahren", distance: 1_200),
            (instruction: "Links halten Richtung Wiesbaden", distance: 800),
        ]))
        XCTAssertEqual(seed.instruction, "Rechts auf die A 66 fahren")
        XCTAssertEqual(seed.distance, 420)
        XCTAssertEqual(seed.upcomingInstructions, [
            "Rechts auf die A 66 fahren", "Links halten Richtung Wiesbaden"
        ])
        XCTAssertEqual(seed.followingManeuverDistance, 1_200)
    }

    func testNewRouteWithoutManeuverDoesNotReuseOldInstruction() {
        XCTAssertNil(NavigationInitialManeuverPolicy.seed(steps: [
            (instruction: "", distance: 200),
            (instruction: "   ", distance: 300),
        ]))
    }

    func testNavigationStartRegistersFirstManeuverForTransitionRecovery() throws {
        let seed = try XCTUnwrap(NavigationInitialManeuverDiagnosticPolicy.seed(steps: [
            (legIndex: 0, stepIndex: 0, instruction: "", distance: 420),
            (legIndex: 0, stepIndex: 1,
             instruction: "Rechts auf die A 66 fahren", distance: 1_200),
            (legIndex: 0, stepIndex: 2,
             instruction: "Links halten Richtung Wiesbaden", distance: 800),
        ]))

        XCTAssertEqual(seed.key, "0:1:Rechts auf die A 66 fahren")
        XCTAssertEqual(seed.instruction, "Rechts auf die A 66 fahren")
        XCTAssertEqual(seed.distance, 420, accuracy: 0.001)
        XCTAssertNil(NavigationInitialManeuverDiagnosticPolicy.seed(steps: [
            (legIndex: 0, stepIndex: 0, instruction: "", distance: 500),
        ]))
    }

    func testOfflineResumeRegistersFirstRemainingManeuverForTransitionRecovery() throws {
        let seed = try XCTUnwrap(NavigationInitialManeuverDiagnosticPolicy.offlineSeed(
            steps: [
                (instruction: "", distance: 350),
                (instruction: "Ausfahrt Richtung Graz nehmen", distance: 1_100),
            ],
            startingStepIndex: 18
        ))

        XCTAssertEqual(seed.key, "offline:19:Ausfahrt Richtung Graz nehmen")
        XCTAssertEqual(seed.instruction, "Ausfahrt Richtung Graz nehmen")
        XCTAssertEqual(seed.distance, 350, accuracy: 0.001)
        XCTAssertNil(NavigationInitialManeuverDiagnosticPolicy.offlineSeed(
            steps: [(instruction: "", distance: 100)], startingStepIndex: 18
        ))
    }

    func testRestoredOfflineRouteSeedsDistanceAndUpcomingFromRemainingStepsOnly() throws {
        let cachedSteps = [
            (instruction: "Alte Abfahrt", distance: 700.0),
            (instruction: "", distance: 420.0),
            (instruction: "Rechts auf die A66", distance: 900.0),
            (instruction: "Links halten Richtung Wiesbaden", distance: 600.0),
        ]

        let seed = try XCTUnwrap(NavigationInitialManeuverPolicy.seed(
            steps: Array(cachedSteps.dropFirst())
        ))

        XCTAssertEqual(seed.instruction, "Rechts auf die A66")
        XCTAssertEqual(seed.stepIndex, 1)
        XCTAssertEqual(seed.distance, 420, accuracy: 0.001)
        XCTAssertEqual(seed.upcomingInstructions, [
            "Rechts auf die A66", "Links halten Richtung Wiesbaden"
        ])
        XCTAssertFalse(seed.upcomingInstructions.contains("Alte Abfahrt"))
    }

    func testCarPlayGuidanceUsesOnlyRealRouteInstructions() {
        XCTAssertEqual(CarPlayGuidancePresentationPolicy.instructions(
            upcoming: [" Rechts abbiegen ", "", "Links halten", "Ausfahrt nehmen"],
            next: "Ignorierter alter Hinweis"
        ), ["Rechts abbiegen", "Links halten", "Ausfahrt nehmen"])
        XCTAssertEqual(CarPlayGuidancePresentationPolicy.instructions(
            upcoming: [], next: " Geradeaus fahren "
        ), ["Geradeaus fahren"])
        XCTAssertEqual(CarPlayGuidancePresentationPolicy.instructions(
            upcoming: ["  "], next: nil
        ), ["Route folgen"])
        XCTAssertEqual(CarPlayGuidancePresentationPolicy.instructions(
            upcoming: ["Alte Abfahrt nehmen"], next: "Alte Abfahrt nehmen",
            guidanceReliable: false
        ), [], "CarPlay must remove stale maneuver cards after a confirmed deviation")
    }

    func testGuidanceRemovesOnlyConsecutiveDuplicateInstructions() {
        let instructions = NavigationInstructionSequencePolicy.removingConsecutiveDuplicates([
            " Rechts abbiegen ",
            "rechts ABBIEGEN",
            "Links halten",
            "Rechts abbiegen",
        ])

        XCTAssertEqual(instructions, [
            "Rechts abbiegen", "Links halten", "Rechts abbiegen",
        ])
        XCTAssertEqual(CarPlayGuidancePresentationPolicy.instructions(
            upcoming: ["Ausfahrt 4 nehmen", " AUSFAHRT 4 NEHMEN ", "Links halten"],
            next: nil
        ), ["Ausfahrt 4 nehmen", "Links halten"])
    }

    func testGuidanceTreatsMapKitRoadSpacingAndPunctuationAsSameManeuver() {
        XCTAssertEqual(
            NavigationInstructionSequencePolicy.removingConsecutiveDuplicates([
                "Ausfahrt 4 auf die A66 nehmen",
                " AUSFAHRT 4 auf die A 66 nehmen. ",
                "Links halten Richtung Köln",
            ]),
            ["Ausfahrt 4 auf die A66 nehmen", "Links halten Richtung Köln"]
        )
        XCTAssertEqual(
            NavigationInstructionSequencePolicy.firstDistinctInstructionIndex(
                in: [
                    "Rechts auf die B40 abbiegen",
                    "Rechts auf die B 40 abbiegen.",
                    "Geradeaus fahren",
                ],
                after: 0
            ),
            2
        )
        XCTAssertEqual(
            NavigationInstructionSequencePolicy.identity("Richtung MÜNCHEN-Süd"),
            NavigationInstructionSequencePolicy.identity("Richtung Munchen Sud")
        )
    }

    func testDuplicateBoundaryInstructionDoesNotBorrowWrongFollowingDistance() throws {
        let seed = try XCTUnwrap(NavigationInitialManeuverPolicy.seed(steps: [
            (instruction: "Ausfahrt 4 nehmen", distance: 80),
            (instruction: " AUSFAHRT 4 NEHMEN ", distance: 120),
            (instruction: "", distance: 300),
            (instruction: "Links halten", distance: 500),
        ]))

        XCTAssertEqual(seed.upcomingInstructions, ["Ausfahrt 4 nehmen", "Links halten"])
        XCTAssertEqual(try XCTUnwrap(seed.followingManeuverDistance), 500, accuracy: 0.001)
        XCTAssertEqual(NavigationInstructionSequencePolicy.firstDistinctInstructionIndex(
            in: ["Rechts abbiegen", "rechts ABBIEGEN", "", "Links halten"], after: 0
        ), 3)
    }

    func testCarPlayAdvancesIdenticallyWordedManeuversByRouteIdentity() {
        XCTAssertNotEqual(
            CarPlayManeuverIdentityPolicy.live(legIndex: 0, stepIndex: 4),
            CarPlayManeuverIdentityPolicy.live(legIndex: 0, stepIndex: 5)
        )
        XCTAssertNotEqual(
            CarPlayManeuverIdentityPolicy.offline(stepIndex: 4),
            CarPlayManeuverIdentityPolicy.offline(stepIndex: 5)
        )
    }

    func testCarPlayListAllocationNeverExceedsLimitAndKeepsPriorityOrder() {
        XCTAssertEqual(
            CarPlayListPriorityPolicy.allocation(
                groupCounts: [2, 4, 3, 5, 7, 3], maximum: 12
            ),
            [2, 4, 3, 3, 0, 0]
        )
        XCTAssertEqual(
            CarPlayListPriorityPolicy.allocation(
                groupCounts: [1, 0, 0, 0, 2, 3], maximum: 12
            ),
            [1, 0, 0, 0, 2, 3]
        )
    }

    func testCarPlayRouteOptionsClearlyShowTheirToggleState() {
        XCTAssertEqual(
            CarPlayRouteOptionPresentationPolicy.detail(enabled: true),
            "Aktiv · antippen zum Ausschalten"
        )
        XCTAssertEqual(
            CarPlayRouteOptionPresentationPolicy.detail(enabled: false),
            "Aus · antippen zum Einschalten"
        )
        XCTAssertEqual(CarPlayRouteOptionPresentationPolicy.symbol(enabled: true),
                       "checkmark.circle.fill")
        XCTAssertEqual(CarPlayRouteOptionPresentationPolicy.symbol(enabled: false), "circle")
    }

    func testCarPlayUsesTheSameMapAppearanceAsThePhone() {
        XCTAssertEqual(
            CarPlayMapAppearancePolicy.mapType(for: .standard),
            MKMapType.standard
        )
        XCTAssertEqual(
            CarPlayMapAppearancePolicy.mapType(for: .hybrid),
            MKMapType.hybrid
        )
    }

    func testCachedFuelPriceIsNeverPresentedAsCurrent() {
        XCTAssertEqual(
            FuelStationPricePresentationPolicy.compact(price: 1.899, cached: false),
            "1.899 €"
        )
        XCTAssertEqual(
            FuelStationPricePresentationPolicy.compact(price: 1.899, cached: true),
            "Gespeichert · 1.899 €"
        )
        XCTAssertEqual(
            FuelStationPricePresentationPolicy.sourceLabel(fuel: .diesel, cached: true),
            "Gespeichert · Preisstand unbekannt · Diesel"
        )
        XCTAssertEqual(
            FuelStationPricePresentationPolicy.sourceLabel(fuel: .diesel, cached: false),
            "Serverpreis · Preisstand unbekannt · Diesel"
        )
    }

    func testRouteFuelStationArrivalUsesOnlyRemainingJourney() throws {
        XCTAssertEqual(
            try XCTUnwrap(RouteFuelStationArrivalPolicy.secondsUntilArrival(
                candidateProgress: 0.6,
                currentProgress: 0.4,
                remainingTravelTime: 3_600
            )),
            1_200,
            accuracy: 0.001
        )
        XCTAssertEqual(
            RouteFuelStationArrivalPolicy.secondsUntilArrival(
                candidateProgress: 1,
                currentProgress: 1,
                remainingTravelTime: 500
            ),
            0
        )
        XCTAssertNil(RouteFuelStationArrivalPolicy.secondsUntilArrival(
            candidateProgress: 0.3,
            currentProgress: 0.4,
            remainingTravelTime: 3_600
        ))
        XCTAssertNil(RouteFuelStationArrivalPolicy.secondsUntilArrival(
            candidateProgress: .nan,
            currentProgress: 0.4,
            remainingTravelTime: 3_600
        ))
    }

    func testCarPlayPriorityKeepsRouteOptionsAheadOfComfortSearch() {
        let allocation = CarPlayListPriorityPolicy.allocation(
            groupCounts: [2, 4, 2, 3, 3, 7, 3], maximum: 12
        )
        XCTAssertEqual(allocation, [2, 4, 2, 3, 1, 0, 0])
    }

    func testCarPlayGuidanceKeepsExitAndRoadVisibleOnSmallDisplays() {
        let variants = CarPlayGuidancePresentationPolicy.variants(
            for: "Ausfahrt 69 rechts auf die A 9 Richtung München nehmen"
        )
        XCTAssertEqual(variants.first, "Ausfahrt 69 rechts auf die A 9 Richtung München nehmen")
        XCTAssertTrue(variants.contains("Ausfahrt 69, Richtung München"))
        XCTAssertTrue(variants.contains("A9, Richtung München"))
        XCTAssertTrue(variants.contains("Ausfahrt 69"))
        XCTAssertTrue(variants.contains("A9"))
    }

    func testCarPlayGuidanceVariantsAreNonemptyAndUnique() {
        let variants = CarPlayGuidancePresentationPolicy.variants(for: "A 66 folgen")
        XCTAssertFalse(variants.contains(where: { $0.isEmpty }))
        XCTAssertEqual(variants.count, Set(variants).count)
    }

    func testCarPlayPlannedStopsCombineBreakAndFuelAtSamePlace() {
        let candidate = BreakCandidate(id: "stop-a", name: "Autohof A",
                                       coordinate: .init(latitude: 49, longitude: 8),
                                       progress: 0.3, detourMetres: 900, isOpen: true,
                                       supportsFuel: true)
        let result = RouteScenarioResult(
            id: "route", routeTitle: "Route", scenario: .init(id: "normal", name: "Normal",
            targetSpeedKmh: 130), distanceMetres: 500_000, drivingTime: 18_000,
            totalTime: 19_000, fuel: .init(litres: 30, cost: 55,
            averageConsumptionLPer100km: 6), toll: .noToll(source: "Test", sourceURL: nil),
            breaks: [.init(id: "break", candidate: candidate, afterDriving: 7_200,
                           duration: 900, routeProgress: 0.3, explanation: "Pause")],
            fuelStops: [.init(id: "fuel", candidate: candidate, afterDistanceMetres: 150_000,
                              routeProgress: 0.3, explanation: "Tanken")], unlimitedFraction: 0.2)
        let plan = LongTripPlan(createdAt: Date(), results: [result], note: "")

        let actions = CarPlayPlannedStopPolicy.actions(
            plan: plan, existingWaypointIDs: [], existingWaypointNames: [],
            currentRouteProgress: 0
        )

        XCTAssertEqual(actions.count, 1)
        XCTAssertEqual(actions.first?.purpose, CarPlayPlannedStopAction.Purpose.breakAndFuel)
        XCTAssertEqual(actions.first?.candidate.id, "stop-a")
        XCTAssertTrue(PlannedStopSelectionPolicy.acceptsCarPlayAction(
            actions[0], currentPlan: plan
        ))
    }

    func testPlannedFuelStopActionRejectsUnknownAndStaleStops() {
        let candidate = BreakCandidate(
            id: "station-a", name: "Autohof A",
            coordinate: .init(latitude: 49, longitude: 8), progress: 0.4,
            detourMetres: 700, isOpen: true, supportsFuel: true
        )
        let stop = PlannedFuelStop(
            id: "fuel-a", candidate: candidate,
            afterDistanceMetres: 200_000, routeProgress: 0.4,
            explanation: "Tankstopp"
        )
        let result = RouteScenarioResult(
            id: "route", routeTitle: "Route", scenario: .target(130),
            distanceMetres: 500_000, drivingTime: 18_000, totalTime: 19_000,
            fuel: .init(litres: 30, cost: 55, averageConsumptionLPer100km: 6),
            toll: .unknown(reason: "Test"), breaks: [], fuelStops: [stop],
            unlimitedFraction: 0.2
        )
        let plan = LongTripPlan(createdAt: Date(), results: [result], note: "")

        XCTAssertTrue(PlannedStopSelectionPolicy.acceptsFuelStop(stop, currentPlan: plan))
        XCTAssertFalse(PlannedStopSelectionPolicy.acceptsFuelStop(stop, currentPlan: nil))

        let movedStop = PlannedFuelStop(
            id: stop.id, candidate: candidate,
            afterDistanceMetres: stop.afterDistanceMetres,
            routeProgress: 0.5, explanation: "Neu berechnet"
        )
        let movedResult = RouteScenarioResult(
            id: result.id, routeTitle: result.routeTitle, scenario: result.scenario,
            distanceMetres: result.distanceMetres, drivingTime: result.drivingTime,
            totalTime: result.totalTime, fuel: result.fuel, toll: result.toll,
            breaks: [], fuelStops: [movedStop], unlimitedFraction: result.unlimitedFraction
        )
        XCTAssertFalse(PlannedStopSelectionPolicy.acceptsFuelStop(
            stop, currentPlan: .init(createdAt: Date(), results: [movedResult], note: "")
        ))
    }

    func testCarPlayPlannedStopsExcludeExistingAndKeepEarliestTwo() {
        func candidate(_ id: String, _ progress: Double) -> BreakCandidate {
            .init(id: id, name: "Stop \(id)", coordinate: .init(latitude: 49, longitude: 8),
                  progress: progress, detourMetres: 500, isOpen: true)
        }
        let first = candidate("first", 0.15)
        let second = candidate("second", 0.3)
        let third = candidate("third", 0.5)
        let result = RouteScenarioResult(
            id: "route", routeTitle: "Route", scenario: .init(id: "normal", name: "Normal",
            targetSpeedKmh: 130), distanceMetres: 500_000, drivingTime: 18_000,
            totalTime: 19_000, fuel: .init(litres: 30, cost: 55,
            averageConsumptionLPer100km: 6), toll: .noToll(source: "Test", sourceURL: nil),
            breaks: [first, second, third].map {
                .init(id: $0.id, candidate: $0, afterDriving: $0.progress * 18_000,
                      duration: 900, routeProgress: $0.progress, explanation: "Pause")
            }, fuelStops: [], unlimitedFraction: 0.2)
        let plan = LongTripPlan(createdAt: Date(), results: [result], note: "")

        let actions = CarPlayPlannedStopPolicy.actions(
            plan: plan, existingWaypointIDs: ["first"], existingWaypointNames: [],
            currentRouteProgress: 0, maximum: 2
        )

        XCTAssertEqual(actions.map { $0.candidate.id }, ["second", "third"])
    }

    func testCarPlayPlannedStopsExcludeBreaksAndFuelBehindVehicle() {
        func candidate(_ id: String, _ progress: Double) -> BreakCandidate {
            .init(id: id, name: "Stop \(id)", coordinate: .init(latitude: 49, longitude: 8),
                  progress: progress, detourMetres: 500, isOpen: true)
        }
        let behind = candidate("behind", 0.3)
        let ahead = candidate("ahead", 0.7)
        let result = RouteScenarioResult(
            id: "route", routeTitle: "Route", scenario: .init(id: "normal", name: "Normal",
            targetSpeedKmh: 130), distanceMetres: 500_000, drivingTime: 18_000,
            totalTime: 19_000, fuel: .init(litres: 30, cost: 55,
            averageConsumptionLPer100km: 6), toll: .noToll(source: "Test", sourceURL: nil),
            breaks: [.init(id: "behind-break", candidate: behind, afterDriving: 7_200,
                           duration: 900, routeProgress: 0.3, explanation: "Pause")],
            fuelStops: [
                .init(id: "behind-fuel", candidate: behind, afterDistanceMetres: 150_000,
                      routeProgress: 0.3, explanation: "Tanken"),
                .init(id: "ahead-fuel", candidate: ahead, afterDistanceMetres: 350_000,
                      routeProgress: 0.7, explanation: "Tanken"),
            ], unlimitedFraction: 0.2
        )

        let actions = CarPlayPlannedStopPolicy.actions(
            plan: .init(createdAt: Date(), results: [result], note: ""),
            existingWaypointIDs: [], existingWaypointNames: [], currentRouteProgress: 0.5
        )

        XCTAssertEqual(actions.map(\.candidate.id), ["ahead"])
        XCTAssertEqual(actions.first?.purpose, .fuelOnly)
        XCTAssertTrue(PlannedStopSelectionPolicy.acceptsCarPlayAction(
            actions[0], currentPlan: .init(createdAt: Date(), results: [result], note: "")
        ), "A fuel-only CarPlay action must be valid without manufacturing a break")
    }

    func testCarPlayRejectsStalePlannedStopAfterPlanMoves() {
        let candidate = BreakCandidate(
            id: "stop", name: "Autohof", coordinate: .init(),
            progress: 0.4, detourMetres: 100, isOpen: true
        )
        let action = CarPlayPlannedStopAction(
            candidate: candidate, purpose: .breakOnly,
            insertionRouteProgress: 0.4, afterDriving: 3_000, afterDistanceMetres: nil
        )
        let movedBreak = PlannedBreak(
            id: "break", candidate: candidate, afterDriving: 3_500,
            duration: 1_200, routeProgress: 0.5, explanation: "Neu geplant",
            installedRouteProgress: 0.5
        )
        let result = RouteScenarioResult(
            id: "route", routeTitle: "Route", scenario: .target(130),
            distanceMetres: 100_000, drivingTime: 4_000, totalTime: 5_200,
            fuel: .init(litres: 7, cost: 12, averageConsumptionLPer100km: 7),
            toll: .unknown(reason: "Test"), breaks: [movedBreak], fuelStops: [],
            unlimitedFraction: 0
        )

        XCTAssertFalse(PlannedStopSelectionPolicy.acceptsCarPlayAction(
            action, currentPlan: .init(createdAt: Date(), results: [result], note: "")
        ))
    }

    func testCarPlayKeepsRebasedRemainingStopUsingInstalledRouteProgress() throws {
        let candidate = BreakCandidate(
            id: "remaining", name: "Raststätte voraus",
            coordinate: .init(latitude: 49, longitude: 8),
            progress: 0.4, installedRouteProgress: 0.82,
            detourMetres: 500, isOpen: true
        )
        let result = RouteScenarioResult(
            id: "route", routeTitle: "Reststrecke", scenario: .target(130),
            distanceMetres: 120_000, drivingTime: 5_000, totalTime: 5_900,
            fuel: .init(litres: 8, cost: 14, averageConsumptionLPer100km: 6.7),
            toll: .unknown(reason: "Test"),
            breaks: [.init(id: "break", candidate: candidate, afterDriving: 2_000,
                           duration: 900, routeProgress: 0.4, explanation: "Pause")],
            fuelStops: [], unlimitedFraction: 0
        )

        let action = try XCTUnwrap(CarPlayPlannedStopPolicy.actions(
            plan: .init(createdAt: Date(), results: [result], note: ""),
            existingWaypointIDs: [], existingWaypointNames: [],
            currentRouteProgress: 0.7
        ).first)
        XCTAssertEqual(action.insertionRouteProgress, 0.82, accuracy: 0.001)
    }

    func testCarPlayMakesImmediateRestAndFuelNeedsExplicit() {
        let candidate = BreakCandidate(
            id: "stop", name: "Autohof", coordinate: .init(), progress: 0,
            detourMetres: 0, isOpen: true, supportsFuel: true
        )
        let rest = CarPlayPlannedStopAction(
            candidate: candidate, purpose: .breakAndFuel,
            insertionRouteProgress: 0, afterDriving: 0, afterDistanceMetres: 0
        )
        let fuel = CarPlayPlannedStopAction(
            candidate: candidate, purpose: .fuelOnly,
            insertionRouteProgress: 0, afterDriving: nil, afterDistanceMetres: 0
        )
        XCTAssertEqual(CarPlayPlannedStopDetailPolicy.text(for: rest), "Pause jetzt einlegen")
        XCTAssertEqual(
            CarPlayPlannedStopDetailPolicy.text(for: fuel),
            "Bei nächster Gelegenheit tanken"
        )
    }

    func testPhoneAndCarPlayShareStrictForwardStopVisibility() {
        XCTAssertFalse(PlannedRouteStopVisibilityPolicy.isAhead(0.49, current: 0.5))
        XCTAssertFalse(PlannedRouteStopVisibilityPolicy.isAhead(0.5, current: 0.5))
        XCTAssertTrue(PlannedRouteStopVisibilityPolicy.isAhead(0.6, current: 0.5))
        XCTAssertFalse(PlannedRouteStopVisibilityPolicy.isAhead(.nan, current: 0.5))
        XCTAssertFalse(PlannedRouteStopVisibilityPolicy.isAhead(0.6, current: .infinity))
    }

    func testRouteSearchResultBecomesInvalidWhenRouteGeometryChanges() {
        let searchedRoute = UUID()
        XCTAssertTrue(RouteSearchSelectionPolicy.accepts(
            resultRouteGeneration: searchedRoute,
            currentRouteGeneration: searchedRoute
        ))
        XCTAssertFalse(RouteSearchSelectionPolicy.accepts(
            resultRouteGeneration: searchedRoute,
            currentRouteGeneration: UUID()
        ))
        XCTAssertTrue(RouteSearchSelectionPolicy.accepts(
            resultRouteGeneration: nil,
            currentRouteGeneration: UUID()
        ), "Direct non-search stop additions remain supported")
    }

    func testStaleFuelStationSelectionIsRejectedAfterRouteRefresh() {
        let old = FuelStation(
            id: "fuel-1", name: "Alt", brand: "Alt", street: "", place: "",
            lat: 50, lon: 8, price: 1.8, open: true, distanceKm: 1
        )
        let current = FuelStation(
            id: "fuel-2", name: "Neu", brand: "Neu", street: "", place: "",
            lat: 50.1, lon: 8.1, price: 1.7, open: true, distanceKm: 1
        )
        XCTAssertFalse(PlannedStopSelectionPolicy.acceptsFuelStation(
            id: old.id, coordinate: old.coordinate,
            currentlySelected: false, available: [current]
        ))
        XCTAssertTrue(PlannedStopSelectionPolicy.acceptsFuelStation(
            id: old.id, coordinate: old.coordinate,
            currentlySelected: false, available: [old]
        ))
        XCTAssertTrue(PlannedStopSelectionPolicy.acceptsFuelStation(
            id: old.id, coordinate: old.coordinate,
            currentlySelected: true, available: []
        ), "A locked stop must remain removable after provider results refresh")
        XCTAssertFalse(PlannedStopSelectionPolicy.acceptsFuelStation(
            id: old.id, coordinate: old.coordinate,
            currentlySelected: false, available: [old],
            candidateProgress: 0.40, currentProgress: 0.55,
            totalRouteDistance: 400_000, navigationActive: true
        ), "A visible provider result becomes unsafe after the car passes it")
        XCTAssertTrue(PlannedStopSelectionPolicy.acceptsFuelStation(
            id: old.id, coordinate: old.coordinate,
            currentlySelected: false, available: [old],
            candidateProgress: 0.60, currentProgress: 0.55,
            totalRouteDistance: 400_000, navigationActive: true
        ))
        XCTAssertTrue(PlannedStopSelectionPolicy.acceptsFuelStation(
            id: old.id, coordinate: old.coordinate,
            currentlySelected: true, available: [],
            candidateProgress: 0.10, currentProgress: 0.90,
            totalRouteDistance: 400_000, navigationActive: true
        ), "An already locked stop stays removable even after it is passed")
    }

    func testRouteStopMutationGateCoalescesRepeatedTapUntilCalculationFinishes() {
        var gate = RouteStopMutationGate()
        XCTAssertFalse(gate.isBusy)
        XCTAssertEqual(gate.begin("fuel-1"), .started)
        XCTAssertTrue(gate.isBusy)
        XCTAssertTrue(gate.isActive("fuel-1"))
        XCTAssertEqual(
            gate.begin("fuel-1"), .coalesced,
            "A repeated tap must not invert an in-flight toggle"
        )
        XCTAssertEqual(
            gate.begin("fuel-2"), .busy,
            "Different stop edits share one route and must not calculate concurrently"
        )

        gate.finish("fuel-1")
        XCTAssertFalse(gate.isBusy)
        XCTAssertFalse(gate.isActive("fuel-1"))
        XCTAssertEqual(
            gate.begin("fuel-2"), .started,
            "A different stop becomes actionable after the first calculation completes"
        )
    }

    func testRouteStopMutationOutcomeCacheNeverReusesPendingOrOldSuccess() {
        var outcomes = RouteStopMutationOutcomeCache(maximumCount: 2)
        outcomes.record(true, for: "first")
        XCTAssertEqual(outcomes.outcome(for: "first"), true)

        outcomes.begin("first")
        XCTAssertNil(outcomes.outcome(for: "first"),
                     "A new in-flight mutation must not inherit an earlier success")
        outcomes.record(false, for: "first")
        XCTAssertEqual(outcomes.outcome(for: "first"), false)

        outcomes.record(true, for: "second")
        outcomes.record(true, for: "third")
        XCTAssertNil(outcomes.outcome(for: "first"), "Old outcomes stay bounded")
        XCTAssertEqual(outcomes.outcome(for: "second"), true)
        XCTAssertEqual(outcomes.outcome(for: "third"), true)
    }

    func testRouteStopMutationGateUsesStablePOIIdentity() {
        let first = RouteStopMutationGate.itemIdentifier(
            name: " McDonald's ", latitude: 50.0123454, longitude: 8.5432104
        )
        let same = RouteStopMutationGate.itemIdentifier(
            name: "mcDONALD'S", latitude: 50.01234549, longitude: 8.54321049
        )
        let other = RouteStopMutationGate.itemIdentifier(
            name: "McDonald's", latitude: 50.012347, longitude: 8.5432104
        )
        XCTAssertEqual(first, same)
        XCTAssertNotEqual(first, other)
    }

    func testNamedRouteSearchPrefersRelevantBrandOverTinyUnrelatedDetour() {
        let exact = RouteSearchPolicy.rankingScore(
            detourMetres: 1_000, candidateProgress: 0.4, currentProgress: 0.2,
            remainingRouteDistance: 100_000,
            queryRelevance: DestinationSearchRankingPolicy.relevanceScore(
                query: "McDonalds", name: "McDonald's", title: nil
            )
        )
        let unrelated = RouteSearchPolicy.rankingScore(
            detourMetres: 0, candidateProgress: 0.4, currentProgress: 0.2,
            remainingRouteDistance: 100_000,
            queryRelevance: DestinationSearchRankingPolicy.relevanceScore(
                query: "McDonalds", name: "Burger Haus", title: nil
            )
        )

        XCTAssertLessThan(exact, unrelated)
    }

    func testFinalCueHasEnoughHighSpeedReactionTime() {
        // The final cue must start early enough to survive Bluetooth/audio
        // latency and still leave time to change lanes safely.
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 410, speedKmh: 200), .final)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 430, speedKmh: 200), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 240, speedKmh: 120), .final)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 270, speedKmh: 120), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 100, speedKmh: 50), .final)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 110, speedKmh: 50), .prepare)
    }

    func testManeuverStageUsesBoundedGPSAccuracySafetyMargin() {
        XCTAssertEqual(
            NavigationAnnouncementStage.stage(
                distance: 470, speedKmh: 200, horizontalAccuracy: 60
            ),
            .final,
            "A plausible GPS error must not postpone the decisive motorway cue"
        )
        XCTAssertEqual(
            NavigationAnnouncementStage.stage(
                distance: 540, speedKmh: 200, horizontalAccuracy: 500
            ),
            .prepare,
            "A coarse fix must not move the announcement horizon without limit"
        )
        XCTAssertEqual(
            NavigationAnnouncementStage.stage(
                distance: 110, speedKmh: 50, horizontalAccuracy: -1
            ),
            .prepare,
            "Invalid Core Location accuracy must contribute no safety margin"
        )
    }

    func testActiveNavigationKeepsFullBackgroundLocationConfiguration() {
        let browsing = NavigationLocationRuntimePolicy.configuration(navigationActive: false)
        XCTAssertEqual(browsing.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(browsing.distanceFilter, 25)
        XCTAssertFalse(browsing.allowsBackgroundUpdates)
        XCTAssertTrue(browsing.pausesAutomatically)

        let navigating = NavigationLocationRuntimePolicy.configuration(navigationActive: true)
        XCTAssertEqual(navigating.desiredAccuracy, kCLLocationAccuracyBestForNavigation)
        XCTAssertEqual(navigating.distanceFilter, 8)
        XCTAssertTrue(navigating.allowsBackgroundUpdates)
        XCTAssertFalse(navigating.pausesAutomatically)

        let pausedTrip = NavigationLocationRuntimePolicy.configuration(
            navigationActive: false, persistentTripActive: true
        )
        XCTAssertEqual(pausedTrip.desiredAccuracy, kCLLocationAccuracyNearestTenMeters)
        XCTAssertEqual(pausedTrip.distanceFilter, kCLDistanceFilterNone)
        XCTAssertTrue(pausedTrip.allowsBackgroundUpdates)
        XCTAssertFalse(pausedTrip.pausesAutomatically)
    }

    func testRemoteLocationRefreshChecksAreRateLimitedButRecoverFromClockChanges() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(DriveRemoteLocationRefreshPolicy.mayCheck(lastCheck: nil, now: now))
        XCTAssertFalse(DriveRemoteLocationRefreshPolicy.mayCheck(
            lastCheck: now.addingTimeInterval(-14), now: now
        ))
        XCTAssertTrue(DriveRemoteLocationRefreshPolicy.mayCheck(
            lastCheck: now.addingTimeInterval(-15), now: now
        ))
        XCTAssertTrue(DriveRemoteLocationRefreshPolicy.mayCheck(
            lastCheck: now.addingTimeInterval(5), now: now
        ))
    }

    func testLocationGapDiagnosticsRequireARealDeliveryInterruption() {
        let start = Date(timeIntervalSince1970: 1_000)
        let previous = CLLocation(
            coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
            horizontalAccuracy: 8, verticalAccuracy: 4, timestamp: start
        )
        let shortGap = CLLocation(
            coordinate: .init(latitude: 50.001, longitude: 8), altitude: 0,
            horizontalAccuracy: 8, verticalAccuracy: 4,
            timestamp: start.addingTimeInterval(29)
        )
        let recovered = CLLocation(
            coordinate: .init(latitude: 50.002, longitude: 8), altitude: 0,
            horizontalAccuracy: 8, verticalAccuracy: 4,
            timestamp: start.addingTimeInterval(45)
        )

        XCTAssertNil(NavigationLocationGapPolicy.recoveredGap(
            previous: nil, current: recovered
        ))
        XCTAssertNil(NavigationLocationGapPolicy.recoveredGap(
            previous: previous, current: shortGap
        ))
        XCTAssertEqual(NavigationLocationGapPolicy.recoveredGap(
            previous: previous, current: recovered
        ), 45)
    }

    func testRepeatedRecoveredLocationGapsMakeDriveQualityActionable() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, date: start, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .locationGapRecovered, date: start.addingTimeInterval(60), detail: "45 s"),
            DriveDiagnosticEvent(kind: .locationGapRecovered, date: start.addingTimeInterval(120), detail: "50 s"),
            DriveDiagnosticEvent(kind: .locationGapRecovered, date: start.addingTimeInterval(180), detail: "40 s"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.recoveredLocationGaps, 3)
        XCTAssertEqual(summary.quality, .attention)
        XCTAssertTrue(summary.recommendation.contains("Standortübertragung"))
    }

    func testManeuverDiagnosticsDetectMissingFinalCue() {
        XCTAssertTrue(ManeuverDiagnosticPolicy.missedFinalCue(stages: [.early, .prepare]))
        XCTAssertFalse(ManeuverDiagnosticPolicy.missedFinalCue(stages: [.early, .final]))
        XCTAssertFalse(ManeuverDiagnosticPolicy.missedFinalCue(stages: [.early, .prepare, .now]))
        XCTAssertFalse(ManeuverDiagnosticPolicy.deliveredDecisiveCue(stages: [.early, .prepare]))
        XCTAssertTrue(ManeuverDiagnosticPolicy.deliveredDecisiveCue(stages: [.final]))
        XCTAssertTrue(ManeuverDiagnosticPolicy.deliveredDecisiveCue(stages: [.now]))
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .routeTransition
        ))
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .arrival
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .userStopped
        ), "An explicit stop must not be diagnosed as a missed turn")
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .recoveryQueued
        ), "A queued recovery is judged by actual audio completion, not as immediately missed")
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecordMissedFinalCue(
            stages: [.early, .prepare], reason: .voiceGuidanceDisabled
        ), "A deliberately muted route must not be counted as a missed spoken turn")
    }

    func testManeuverTransitionRecoversFinalCueOnlyOnceWhenGPSCrossesJunction() {
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early, .prepare]
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early, .prepare, .now]
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early, .prepare, .final]
        ), "A completed final distance cue must not be repeated behind the junction")
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early, .prepare], inFlightStages: [.now]
        ), "An immediate cue still playing at the junction must not be interrupted and repeated")
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early], inFlightStages: [.final]
        ), "An actionable final cue already in flight is decisive")
        XCTAssertTrue(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:2:Links halten",
            stages: [.early], inFlightStages: [.prepare]
        ), "A non-decisive preparation cue must not mask a missing final cue")
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: "0:1:Rechts abbiegen", nextKey: "0:1:Rechts abbiegen",
            stages: [.early, .prepare]
        ))
        XCTAssertFalse(ManeuverDiagnosticPolicy.shouldRecoverFinalCue(
            previousKey: nil, nextKey: "0:1:Rechts abbiegen", stages: []
        ))
    }

    func testRecentDestinationsDeduplicateAndKeepLatestFirst() {
        let suite = "DriveHistoryTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let first = RecentDestination(name: "Zuhause", subtitle: "A", latitude: 50, longitude: 8,
                                      lastUsedAt: Date(timeIntervalSince1970: 1))
        let newer = RecentDestination(name: "Zuhause neu", subtitle: "B", latitude: 50, longitude: 8,
                                      lastUsedAt: Date(timeIntervalSince1970: 2))
        _ = RecentDestinationStore.record(first, defaults: defaults)
        let values = RecentDestinationStore.record(newer, defaults: defaults)
        XCTAssertEqual(values.count, 1)
        XCTAssertEqual(values.first?.name, "Zuhause neu")
    }

    func testSavedDestinationsRejectInvalidCoordinatesAndBlankNames() {
        let suite = "DriveSavedDestinationValidationTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let valid = RecentDestination(
            name: "Zuhause", subtitle: "Hochheim", latitude: 50, longitude: 8
        )
        _ = RecentDestinationStore.record(valid, defaults: defaults)

        XCTAssertEqual(RecentDestinationStore.record(.init(
            name: "Außerhalb", subtitle: "", latitude: 91, longitude: 8
        ), defaults: defaults), [valid])
        XCTAssertEqual(RecentDestinationStore.record(.init(
            name: "   ", subtitle: "", latitude: 50, longitude: 8
        ), defaults: defaults), [valid])

        DriveFavoriteStore.save([
            .init(name: "Büro", subtitle: "Mainz", latitude: 50, longitude: 8),
            .init(name: "Ungültig", subtitle: "", latitude: 50, longitude: 181),
            .init(name: " ", subtitle: "", latitude: 50, longitude: 8),
        ], defaults: defaults)
        XCTAssertEqual(DriveFavoriteStore.load(defaults: defaults).map(\.name), ["Büro"])
    }

    func testFavoritesRoundTripForPhoneAndCarPlay() {
        let suite = "DriveFavoriteTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        let favorites = [
            DriveFavorite(name: "Büro", subtitle: "Mainz", latitude: 50.01, longitude: 8.27),
            DriveFavorite(name: "Hotel", subtitle: "Graz", latitude: 47.07, longitude: 15.44)
        ]
        DriveFavoriteStore.save(favorites, defaults: defaults)
        XCTAssertEqual(DriveFavoriteStore.load(defaults: defaults), favorites)
    }

    func testDiagnosticsAreBounded() {
        let suite = "DriveDiagnosticTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        for index in 0..<120 {
            DriveDiagnosticStore.append(.routeCalculated, detail: "\(index)", defaults: defaults)
        }
        let events = DriveDiagnosticStore.load(defaults: defaults)
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(events.first?.detail, "20")
        XCTAssertEqual(events.last?.detail, "119")
    }

    func testDiagnosticStoreBoundsAndFlattensVerboseDetail() throws {
        let suite = "DriveDiagnosticDetailBounds-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let verbose = "Audiofehler\n\t" + String(repeating: "x", count: 2_000)

        DriveDiagnosticStore.append(.speechDeliveryFailed, detail: verbose, defaults: defaults)

        let event = try XCTUnwrap(DriveDiagnosticStore.load(defaults: defaults).last)
        XCTAssertLessThanOrEqual(event.detail.count, DriveDiagnosticDetail.maximumStoredLength)
        XCTAssertFalse(event.detail.contains("\n"))
        XCTAssertFalse(event.detail.contains("\t"))
        XCTAssertTrue(event.detail.hasPrefix("Audiofehler "))
    }

    func testDiagnosticStoreNotifiesViewsAfterAppendAndClear() throws {
        let suite = "DriveDiagnosticNotificationTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        var notifications = 0
        let observer = NotificationCenter.default.addObserver(
            forName: DriveDiagnosticStore.didChange, object: nil, queue: nil
        ) { _ in notifications += 1 }
        defer { NotificationCenter.default.removeObserver(observer) }

        DriveDiagnosticStore.append(.navigationStarted, detail: "Test", defaults: defaults)
        DriveDiagnosticStore.clear(defaults: defaults)

        XCTAssertEqual(notifications, 2)
        XCTAssertTrue(DriveDiagnosticStore.load(defaults: defaults).isEmpty)
    }

    func testBoundedDiagnosticsRetainCurrentLongTripStart() throws {
        let suite = "DriveDiagnosticLongTripTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        DriveDiagnosticStore.append(.navigationStarted, detail: "Urlaubsfahrt", defaults: defaults)
        for index in 0..<120 {
            DriveDiagnosticStore.append(
                .maneuverAnnounced, detail: "Manöver \(index)", defaults: defaults
            )
        }
        DriveDiagnosticStore.append(.arrivalReached, detail: "Ziel", defaults: defaults)

        let events = DriveDiagnosticStore.load(defaults: defaults)
        XCTAssertEqual(events.count, 100)
        XCTAssertEqual(events.first?.kind, .navigationStarted)
        XCTAssertNotNil(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(events.last?.kind, .arrivalReached)
    }

    func testBoundedDiagnosticsRetainEarlySafetyFailureAndRecoveryOnLongTrip() throws {
        let start = DriveDiagnosticEvent(kind: .navigationStarted, detail: "Urlaubsfahrt")
        let failure = DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Kurz kein Netz")
        let recovery = DriveDiagnosticEvent(kind: .rerouteSucceeded, detail: "Route wieder da")
        let missed = DriveDiagnosticEvent(kind: .maneuverFinalCueMissed, detail: "Ausfahrt")
        var events = [start, failure, recovery, missed]
        events += (0..<140).map {
            DriveDiagnosticEvent(kind: .maneuverAnnounced, detail: "Manöver \($0)")
        }
        events.append(.init(kind: .arrivalReached, detail: "Ziel"))

        let bounded = DriveDiagnosticStore.bounded(events)
        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: bounded))

        XCTAssertEqual(bounded.count, 100)
        XCTAssertEqual(bounded.first?.kind, .navigationStarted)
        XCTAssertTrue(bounded.contains { $0.id == failure.id })
        XCTAssertTrue(bounded.contains { $0.id == recovery.id })
        XCTAssertTrue(bounded.contains { $0.id == missed.id })
        XCTAssertEqual(summary.rerouteFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
        XCTAssertEqual(summary.missedFinalCues, 1)
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(bounded.last?.kind, .arrivalReached)
    }

    func testUnresolvedLocationServiceFailureIsVisibleAndRecoveryClearsIt() throws {
        let start = Date(timeIntervalSince1970: 1_000)
        let failed = DriveDiagnosticEvent(
            kind: .locationServiceFailure, date: start.addingTimeInterval(1),
            detail: "Core Location Fehlercode 1"
        )
        let unresolved = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: [
            .init(kind: .navigationStarted, date: start, detail: "Urlaubsfahrt"),
            failed,
        ]))
        XCTAssertEqual(unresolved.locationServiceFailures, 1)
        XCTAssertEqual(unresolved.quality, .critical)
        XCTAssertTrue(unresolved.recommendation.contains("Standortdienst"))

        let recovered = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: [
            .init(kind: .navigationStarted, date: start, detail: "Urlaubsfahrt"),
            failed,
            .init(kind: .locationServiceRecovered, date: start.addingTimeInterval(2),
                  detail: "Gültige Standortmessung wieder empfangen"),
        ]))
        XCTAssertEqual(recovered.locationServiceFailures, 0)
        XCTAssertEqual(recovered.resolvedRouteIssues, 1)
        XCTAssertEqual(recovered.quality, .good)
    }

    func testDiagnosticReportIsReadableAndContainsNoInventedLocationTrail() {
        let event = DriveDiagnosticEvent(
            kind: .maneuverFinalCueMissed,
            date: Date(timeIntervalSince1970: 0),
            detail: "Rechts abbiegen\nauf die A66"
        )
        let report = DriveDiagnosticReport.text(events: [event], appVersion: "1.0 (42)")
        XCTAssertTrue(report.contains("App-Version: 1.0 (42)"))
        XCTAssertTrue(report.contains("maneuverFinalCueMissed"))
        XCTAssertFalse(report.contains("A66"))
        XCTAssertTrue(report.contains("Fahranweisung ausgeblendet"))
        XCTAssertTrue(report.contains("Keine vollständige Standortspur"))
    }

    func testDiagnosticReportSelectionExcludesOlderDrivesAndLateCallbacks() throws {
        let oldSession = UUID()
        let currentSession = UUID()
        let events = [
            DriveDiagnosticEvent(sessionID: oldSession, kind: .navigationStarted, detail: "Alte Fahrt"),
            DriveDiagnosticEvent(sessionID: oldSession, kind: .rerouteFailed, detail: "Alter Fehler"),
            DriveDiagnosticEvent(sessionID: oldSession, kind: .navigationStopped, detail: "Beendet"),
            DriveDiagnosticEvent(sessionID: currentSession, kind: .navigationStarted, detail: "Kroatien"),
            DriveDiagnosticEvent(sessionID: currentSession, kind: .maneuverAnnounced, detail: "Rechts"),
            DriveDiagnosticEvent(sessionID: currentSession, kind: .navigationStarted, detail: "Kroatien fortsetzen"),
            DriveDiagnosticEvent(sessionID: currentSession, kind: .arrivalReached, detail: "Ziel"),
            DriveDiagnosticEvent(sessionID: currentSession, kind: .rerouteFailed, detail: "Verspätet"),
        ]

        let selected = DriveDiagnosticReport.latestSessionEvents(in: events)

        XCTAssertEqual(selected.map(\.detail), [
            "Kroatien", "Rechts", "Kroatien fortsetzen", "Ziel"
        ])
        XCTAssertEqual(Set(selected.compactMap(\.sessionID)), Set([currentSession]))
    }

    func testDiagnosticReportSelectionRequiresANavigationSession() {
        let events = [DriveDiagnosticEvent(kind: .routeCalculated, detail: "Vorschau")]
        XCTAssertTrue(DriveDiagnosticReport.latestSessionEvents(in: events).isEmpty)
    }

    func testDiagnosticContextContainsQualityButNeverCoordinates() {
        let location = CLLocation(
            coordinate: .init(latitude: 50.123456, longitude: 8.654321),
            altitude: 0, horizontalAccuracy: 13.6, verticalAccuracy: 5,
            course: 90, speed: 27.8, timestamp: Date()
        )
        let detail = DriveDiagnosticDetail.navigationSample("Rechts abbiegen", location: location)
        XCTAssertEqual(detail, "Rechts abbiegen · GPS ±14 m · 100 km/h")
        XCTAssertFalse(detail.contains("50.123456"))
        XCTAssertFalse(detail.contains("8.654321"))
    }

    func testDiagnosticSummaryUsesOnlyLatestNavigationSession() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Alte Fahrt"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Alter Fehler"),
            DriveDiagnosticEvent(kind: .navigationStopped, detail: "Alte Fahrt"),
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Neue Fahrt"),
            DriveDiagnosticEvent(kind: .maneuverAnnounced, detail: "Rechts"),
            DriveDiagnosticEvent(kind: .locationRejected, detail: "GPS ±90 m"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertEqual(summary.rerouteRequests, 0)
        XCTAssertEqual(summary.rerouteFailures, 0)
        XCTAssertEqual(summary.rejectedLocations, 1)
        XCTAssertEqual(summary.arrivals, 0)
        XCTAssertEqual(summary.maneuverAnnouncements, 1)
        XCTAssertEqual(summary.resolvedRouteIssues, 0)
    }

    func testDiagnosticStoreKeepsSessionIdentityAcrossRouteRestore() throws {
        let suite = "DriveDiagnosticSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        DriveDiagnosticStore.append(.navigationStarted, detail: "Kroatien", defaults: defaults)
        DriveDiagnosticStore.append(.rerouteFailed, detail: "Kein Netz", defaults: defaults)
        // A restored trip starts guidance again after an app restart.
        DriveDiagnosticStore.append(.navigationStarted, detail: "Offline · Kroatien", defaults: defaults)
        DriveDiagnosticStore.append(.rerouteSucceeded, detail: "Route wieder da", defaults: defaults)

        let events = DriveDiagnosticStore.load(defaults: defaults)
        XCTAssertEqual(events[0].sessionID, events[2].sessionID)
        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.eventCount, 4)
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
    }

    func testDiagnosticStoreKeepsTripSessionAcrossNavigationPause() throws {
        let suite = "DriveDiagnosticStopSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        let tripID = UUID()
        DriveDiagnosticStore.activateSession(tripID, defaults: defaults)
        DriveDiagnosticStore.append(.navigationStarted, detail: "Kroatien", defaults: defaults)
        DriveDiagnosticStore.append(.rerouteFailed, detail: "Vor der Pause", defaults: defaults)
        DriveDiagnosticStore.append(.navigationStopped, detail: "Rast", defaults: defaults)
        DriveDiagnosticStore.append(.navigationStarted, detail: "Kroatien fortsetzen", defaults: defaults)
        DriveDiagnosticStore.append(.rerouteSucceeded, detail: "Nach der Pause", defaults: defaults)

        let events = DriveDiagnosticStore.load(defaults: defaults)
        XCTAssertEqual(Set(events.compactMap(\.sessionID)), Set([tripID]))
        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.eventCount, 5)
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
    }

    func testDiagnosticSummarySurfacesRestoreFailureAfterNavigationPause() throws {
        let tripID = UUID()
        let events = [
            DriveDiagnosticEvent(sessionID: tripID, kind: .navigationStarted,
                                 detail: "Urlaubsfahrt"),
            DriveDiagnosticEvent(sessionID: tripID, kind: .navigationStopped,
                                 detail: "Pause"),
            DriveDiagnosticEvent(sessionID: tripID, kind: .routeRestoreFailed,
                                 detail: "Keine passende Route verfügbar"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertEqual(summary.routeRestoreFailures, 1)
        XCTAssertTrue(summary.recommendation.contains("fortgesetzt"))

        let recovered = events + [
            DriveDiagnosticEvent(sessionID: tripID, kind: .navigationStarted,
                                 detail: "Offline fortgesetzt"),
            DriveDiagnosticEvent(sessionID: tripID, kind: .routeRestoreSucceeded,
                                 detail: "Offline-Cache verwendet"),
        ]
        let recoveredSummary = try XCTUnwrap(
            DriveDiagnosticSummary.latestSession(in: recovered)
        )
        XCTAssertEqual(recoveredSummary.routeRestoreFailures, 0)
        XCTAssertEqual(recoveredSummary.quality, .good)
        XCTAssertEqual(recoveredSummary.resolvedRouteIssues, 1)
    }

    func testLateRestoreCallbackCannotReopenCompletedArrivalDiagnostics() throws {
        let tripID = UUID()
        let started = DriveDiagnosticEvent(
            sessionID: tripID, kind: .navigationStarted, detail: "Urlaubsfahrt"
        )
        let arrival = DriveDiagnosticEvent(
            sessionID: tripID, kind: .arrivalReached, detail: "Ziel erreicht"
        )
        let lateRestoreFailure = DriveDiagnosticEvent(
            sessionID: tripID, kind: .routeRestoreFailed,
            detail: "Verspätete Berechnung nach Fahrtende"
        )
        let events = [started, arrival, lateRestoreFailure]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.eventCount, 2)
        XCTAssertEqual(summary.routeRestoreFailures, 0)
        XCTAssertEqual(
            DriveDiagnosticReport.latestSessionEvents(in: events).map(\.id),
            [started.id, arrival.id]
        )
    }

    func testDiagnosticExportIncludesOnlySameTripRestoreAfterPause() {
        let tripID = UUID()
        let unrelatedID = UUID()
        let started = DriveDiagnosticEvent(
            sessionID: tripID, kind: .navigationStarted, detail: "Urlaubsfahrt"
        )
        let stopped = DriveDiagnosticEvent(
            sessionID: tripID, kind: .navigationStopped, detail: "Pause"
        )
        let unrelated = DriveDiagnosticEvent(
            sessionID: unrelatedID, kind: .rerouteFailed, detail: "Fremde Arbeit"
        )
        let restore = DriveDiagnosticEvent(
            sessionID: tripID, kind: .routeRestoreFailed,
            detail: "Keine passende Route verfügbar"
        )

        let selected = DriveDiagnosticReport.latestSessionEvents(
            in: [started, stopped, unrelated, restore]
        )

        XCTAssertEqual(selected.map(\.id), [started.id, stopped.id, restore.id])
    }

    func testDiagnosticStoreCreatesNewSessionAfterTripFinished() throws {
        let suite = "DriveDiagnosticFinishedSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        DriveDiagnosticStore.activateSession(UUID(), defaults: defaults)
        DriveDiagnosticStore.append(.navigationStarted, detail: "Alte Fahrt", defaults: defaults)
        DriveDiagnosticStore.append(.navigationStopped, detail: "Beendet", defaults: defaults)
        DriveDiagnosticStore.finishActiveSession(defaults: defaults)
        DriveDiagnosticStore.append(.navigationStarted, detail: "Neue Fahrt", defaults: defaults)

        let events = DriveDiagnosticStore.load(defaults: defaults)
        XCTAssertNotEqual(events[0].sessionID, events[2].sessionID)
        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.eventCount, 1)
    }

    func testDiagnosticSummaryOnlyWarnsForClusteredGPSFailures() throws {
        let start = Date(timeIntervalSince1970: 10_000)
        let spread = [
            DriveDiagnosticEvent(kind: .navigationStarted, date: start, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(60), detail: "GPS"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(3_600), detail: "GPS"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(7_200), detail: "GPS"),
        ]
        let clustered = [
            DriveDiagnosticEvent(kind: .navigationStarted, date: start, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(10), detail: "GPS"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(25), detail: "GPS"),
            DriveDiagnosticEvent(kind: .locationRejected, date: start.addingTimeInterval(50), detail: "GPS"),
        ]

        XCTAssertEqual(try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: spread)).quality, .good)
        let warning = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: clustered))
        XCTAssertEqual(warning.quality, .attention)
        XCTAssertEqual(warning.rejectedLocations, 3)
        XCTAssertTrue(warning.recommendation.contains("GPS"))
    }

    func testDiagnosticSummaryFlagsMissedFinalCue() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .maneuverFinalCueMissed, detail: "Ausfahrt"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.missedFinalCues, 1)
    }

    func testDiagnosticSummaryFlagsUnrecoveredSpeechDeliveryFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .speechDeliveryFailed, detail: "Ausfahrt"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.speechDeliveryFailures, 1)
        XCTAssertTrue(summary.recommendation.contains("Audiosystem"))
    }

    func testDiagnosticSummaryExplainsAudioActivationFailureSeparately() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "Manöver-ID abc · Audioausgabe nicht verfügbar · now · Ausfahrt nehmen"
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertTrue(summary.recommendation.contains("nicht aktivieren"))
        XCTAssertTrue(summary.recommendation.contains("Audioausgabe"))
    }

    func testDiagnosticSummaryExplainsInterruptedSpeechSeparately() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "Fahransage unerwartet vom Audiosystem abgebrochen · GPS ±8 m"
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertTrue(summary.recommendation.contains("unterbrochen"))
        XCTAssertTrue(summary.recommendation.contains("Telefon- oder Siri-Unterbrechungen"))
    }

    func testDiagnosticSummaryClearsSpeechFailureAfterSuccessfulRetry() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .speechDeliveryFailed, detail: "Ausfahrt"),
            DriveDiagnosticEvent(kind: .maneuverAnnounced, detail: "Ausfahrt"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.speechDeliveryFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
    }

    func testDiagnosticSummaryClearsRecoveredBreakReminderSpeechFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "Pausenerinnerung · plan · GPS ±8 m · 100 km/h"
            ),
            DriveDiagnosticEvent(
                kind: .breakReminderShown,
                detail: "Pausenerinnerung · plan · Pause einplanen"
            ),
            DriveDiagnosticEvent(
                kind: .breakReminderAnnounced,
                detail: "Pausenerinnerung · plan"
            ),
            DriveDiagnosticEvent(
                kind: .fuelReminderShown,
                detail: "Tankhinweis · soon · In 10 Kilometern tanken"
            ),
            DriveDiagnosticEvent(
                kind: .fuelReminderAnnounced,
                detail: "Tankhinweis · gesprochen · In 10 Kilometern tanken"
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.speechDeliveryFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
        XCTAssertEqual(summary.breakRemindersShown, 1)
        XCTAssertEqual(summary.breakRemindersAnnounced, 1)
        XCTAssertEqual(summary.fuelRemindersShown, 1)
        XCTAssertEqual(summary.fuelRemindersAnnounced, 1)
    }

    func testDifferentLaterManeuverDoesNotHideSpeechFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "now · Ausfahrt rechts nehmen · GPS ±8 m · 100 km/h"
            ),
            DriveDiagnosticEvent(
                kind: .maneuverAnnounced,
                detail: "prepare · 300 m · Links abbiegen"
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.speechDeliveryFailures, 1)
    }

    func testDiagnosticSummaryClearsRecoveredFuelReminderSpeechFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "Tankhinweis · In etwa 10 Kilometern tanken. · GPS ±8 m · 100 km/h"
            ),
            DriveDiagnosticEvent(
                kind: .fuelReminderAnnounced,
                detail: "Tankhinweis · gesprochen · In etwa 10 Kilometern tanken."
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.speechDeliveryFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
        XCTAssertEqual(summary.fuelRemindersAnnounced, 1)
    }

    func testMatchingRetriedManeuverClearsOnlyItsSpeechFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "now · Ausfahrt rechts nehmen · GPS ±8 m · 100 km/h"
            ),
            DriveDiagnosticEvent(
                kind: .maneuverAnnounced,
                detail: "now · 20 m · Ausfahrt rechts nehmen"
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.speechDeliveryFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
    }

    func testRepeatedInstructionOnDifferentManeuverDoesNotHideAudioFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: DriveDiagnosticDetail.maneuver(
                    "now · Rechts abbiegen", key: "0:4:Rechts abbiegen"
                )
            ),
            DriveDiagnosticEvent(
                kind: .maneuverAnnounced,
                detail: DriveDiagnosticDetail.maneuver(
                    "now · 20 m · Rechts abbiegen", key: "0:9:Rechts abbiegen"
                )
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.speechDeliveryFailures, 1)
    }

    func testMatchingManeuverIdentityResolvesAudioFailure() throws {
        let key = "0:4:Rechts abbiegen"
        let failure = DriveDiagnosticDetail.maneuver("now · Rechts abbiegen", key: key)
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .speechDeliveryFailed, detail: failure),
            DriveDiagnosticEvent(
                kind: .maneuverAnnounced,
                detail: DriveDiagnosticDetail.maneuver(
                    "now · 20 m · Rechts abbiegen", key: key
                )
            ),
        ]

        XCTAssertNotNil(DriveDiagnosticDetail.maneuverIdentity(in: failure))
        XCTAssertFalse(failure.contains(key), "Diagnostic identity must not expose the raw route key")
        XCTAssertFalse(failure.contains(Data(key.utf8).base64EncodedString()),
                       "Diagnostic identity must not be reversibly encoded")
        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.speechDeliveryFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
    }

    func testSharedDiagnosticReportRedactsDestinationsStopsAndManeuverRoads() {
        let rawKey = "0:4:Rechts abbiegen auf Mainzer Straße"
        let legacyIdentity = Data(rawKey.utf8).base64EncodedString()
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Privatadresse Hochheim"),
            DriveDiagnosticEvent(kind: .routeStopAdded, detail: "Privater Treffpunkt"),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "Manöver-ID \(legacyIdentity) · now · Rechts abbiegen auf Mainzer Straße · GPS ±8 m · 48 km/h"
            ),
        ]

        let report = DriveDiagnosticReport.text(events: events, appVersion: "Test")

        XCTAssertFalse(report.contains("Privatadresse Hochheim"))
        XCTAssertFalse(report.contains("Privater Treffpunkt"))
        XCTAssertFalse(report.contains("Mainzer Straße"))
        XCTAssertFalse(report.contains(legacyIdentity))
        XCTAssertTrue(report.contains("Fahranweisung ausgeblendet"))
        XCTAssertTrue(report.contains("GPS ±8 m"))
        XCTAssertTrue(report.contains("48 km/h"))
    }

    func testSharedDiagnosticReportRedactsPausedDestinationAndReminderPlaces() {
        let events = [
            DriveDiagnosticEvent(
                kind: .navigationStopped, detail: "Private Wohnadresse Hochheim"
            ),
            DriveDiagnosticEvent(
                kind: .breakReminderShown,
                detail: "Pausenerinnerung · soon · Pause bei Autohof Spessart einplanen"
            ),
            DriveDiagnosticEvent(
                kind: .fuelReminderAnnounced,
                detail: "Tankhinweis · gesprochen · Bei JET Bodenheim tanken"
            ),
            DriveDiagnosticEvent(
                kind: .speechDeliveryFailed,
                detail: "Tankhinweis · Bei Shell Nierstein tanken · GPS ±9 m · 80 km/h"
            ),
        ]

        let report = DriveDiagnosticReport.text(events: events, appVersion: "Test")

        XCTAssertFalse(report.contains("Private Wohnadresse Hochheim"))
        XCTAssertFalse(report.contains("Autohof Spessart"))
        XCTAssertFalse(report.contains("JET Bodenheim"))
        XCTAssertFalse(report.contains("Shell Nierstein"))
        XCTAssertTrue(report.contains("Navigation pausiert · Ziel ausgeblendet"))
        XCTAssertTrue(report.contains("Pausenerinnerung · Ort ausgeblendet · soon"))
        XCTAssertTrue(report.contains("Tankhinweis · Ort ausgeblendet · gesprochen"))
        XCTAssertTrue(report.contains("GPS ±9 m"))
        XCTAssertTrue(report.contains("80 km/h"))
    }

    func testDiagnosticSummaryClearsTransientRouteFailureAfterSuccessfulRecovery() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Kein Netz"),
            DriveDiagnosticEvent(kind: .offlineRouteDeparture, detail: "Korridor verlassen"),
            DriveDiagnosticEvent(kind: .rerouteSucceeded, detail: "Online wiederhergestellt"),
            DriveDiagnosticEvent(kind: .maneuverAnnounced, detail: "Rechts"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.rerouteFailures, 0)
        XCTAssertEqual(summary.offlineRouteDepartures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 2)
        XCTAssertTrue(summary.recommendation.contains("automatisch behoben"))
    }

    func testDiagnosticSummaryCountsCompletedRestBreaks() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .breakReminderShown, detail: "Pause bald"),
            DriveDiagnosticEvent(
                kind: .restBreakCompleted,
                detail: "Mindestens 20 Minuten Stillstand erkannt"
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.restBreaksCompleted, 1)
        XCTAssertEqual(summary.breakRemindersShown, 1)
        XCTAssertEqual(summary.quality, .good)
    }

    func testDiagnosticSummaryReportsUnresolvedRouteStopFailure() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .routeStopFailed,
                detail: "Zwischenstopp nicht berechenbar · Autohof Spessart"
            ),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .attention)
        XCTAssertEqual(summary.routeStopFailures, 1)
        XCTAssertTrue(summary.recommendation.contains("Zwischenstopp"))
    }

    func testDiagnosticSummaryClearsRouteStopFailureAfterSuccessfulRetry() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(
                kind: .routeStopFailed,
                detail: "Zwischenstopp nicht berechenbar · Autohof Spessart"
            ),
            DriveDiagnosticEvent(kind: .routeStopAdded, detail: "autohof spessart"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.routeStopFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
    }

    func testDiagnosticSummaryClearsOfflineDepartureAfterRejoiningCache() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .offlineRouteDeparture, detail: "Korridor verlassen"),
            DriveDiagnosticEvent(kind: .offlineRouteRejoined, detail: "Korridor erreicht"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.offlineRouteDepartures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
    }

    func testDiagnosticSummaryClearsFailedRerouteAfterStableOnlineRejoin() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .rerouteRequested, detail: "Falsche Abfahrt"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Kein Netz"),
            DriveDiagnosticEvent(kind: .routeRejoined, detail: "Ursprüngliche Route erreicht"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.rerouteFailures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
        XCTAssertTrue(summary.recommendation.contains("automatisch behoben"))
    }

    func testDiagnosticSummaryKeepsFailureAfterLatestOnlineRejoinOpen() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .routeRejoined, detail: "Ursprüngliche Route erreicht"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Später erneut kein Netz"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.rerouteFailures, 1)
        XCTAssertEqual(summary.resolvedRouteIssues, 0)
    }

    func testOfflineRejoinDoesNotHideFailedOnlineReroute() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Kein Netz"),
            DriveDiagnosticEvent(kind: .offlineRouteDeparture, detail: "Korridor verlassen"),
            DriveDiagnosticEvent(kind: .offlineRouteRejoined, detail: "Korridor erreicht"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.rerouteFailures, 1)
        XCTAssertEqual(summary.offlineRouteDepartures, 0)
        XCTAssertEqual(summary.resolvedRouteIssues, 1)
    }

    func testDiagnosticSummaryKeepsFailureAfterLatestRecoveryOpen() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .rerouteSucceeded, detail: "Erholt"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Erneut kein Netz"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .critical)
        XCTAssertEqual(summary.rerouteFailures, 1)
        XCTAssertEqual(summary.resolvedRouteIssues, 0)
    }

    func testDiagnosticSummaryEndsAtStopAndIgnoresLateAsyncEvents() throws {
        let events = [
            DriveDiagnosticEvent(kind: .navigationStarted, detail: "Fahrt"),
            DriveDiagnosticEvent(kind: .maneuverAnnounced, detail: "Rechts"),
            DriveDiagnosticEvent(kind: .navigationStopped, detail: "Fahrt beendet"),
            DriveDiagnosticEvent(kind: .rerouteFailed, detail: "Verspätete Antwort"),
            DriveDiagnosticEvent(kind: .maneuverFinalCueMissed, detail: "Verspätete Diagnose"),
        ]

        let summary = try XCTUnwrap(DriveDiagnosticSummary.latestSession(in: events))
        XCTAssertEqual(summary.quality, .good)
        XCTAssertEqual(summary.eventCount, 3)
        XCTAssertEqual(summary.rerouteFailures, 0)
        XCTAssertEqual(summary.missedFinalCues, 0)
    }

    func testNavigationLocationPolicyRejectsImpossibleJumpAndStaleFix() {
        let now = Date()
        let first = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                               horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-2))
        let jump = CLLocation(coordinate: .init(latitude: 51, longitude: 9), altitude: 0,
                              horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-1))
        let stale = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                               horizontalAccuracy: 5, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-60))
        XCTAssertFalse(NavigationLocationPolicy.accepts(jump, after: first, now: now))
        XCTAssertFalse(NavigationLocationPolicy.accepts(stale, after: nil, now: now))
        XCTAssertTrue(NavigationLocationPolicy.rejectionReason(
            for: jump, after: first, now: now
        )?.contains("Unplausibler GPS-Sprung") == true)
        XCTAssertEqual(NavigationLocationPolicy.rejectionReason(
            for: stale, after: nil, now: now
        ), "GPS-Messung ist veraltet")
    }

    func testNavigationLocationPolicySafelyAcceptsBoundedBufferedFixes() {
        let now = Date()
        let buffered = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                                  horizontalAccuracy: 5, verticalAccuracy: 5,
                                  timestamp: now.addingTimeInterval(-60))
        let tooOld = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                                horizontalAccuracy: 5, verticalAccuracy: 5,
                                timestamp: now.addingTimeInterval(-121))

        XCTAssertFalse(NavigationLocationPolicy.accepts(buffered, after: nil, now: now))
        XCTAssertTrue(NavigationLocationPolicy.accepts(
            buffered, after: nil, now: now,
            maximumAge: NavigationLocationBatchPolicy.maximumBufferedSampleAge
        ))
        XCTAssertFalse(NavigationLocationPolicy.accepts(
            tooOld, after: nil, now: now,
            maximumAge: NavigationLocationBatchPolicy.maximumBufferedSampleAge
        ))
    }

    func testNavigationLocationPolicyAcceptsNormalMovement() {
        let now = Date()
        let first = CLLocation(coordinate: .init(latitude: 50, longitude: 8), altitude: 0,
                               horizontalAccuracy: 8, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-2))
        let next = CLLocation(coordinate: .init(latitude: 50.0005, longitude: 8), altitude: 0,
                              horizontalAccuracy: 8, verticalAccuracy: 5, timestamp: now.addingTimeInterval(-1))
        XCTAssertTrue(NavigationLocationPolicy.accepts(next, after: first, now: now))
    }

    func testLocationDiagnosticThrottleRetainsARealFailureBurst() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(NavigationLocationDiagnosticPolicy.shouldLog(
            lastLoggedAt: nil, now: start
        ))
        XCTAssertFalse(NavigationLocationDiagnosticPolicy.shouldLog(
            lastLoggedAt: start, now: start.addingTimeInterval(19)
        ))
        XCTAssertTrue(NavigationLocationDiagnosticPolicy.shouldLog(
            lastLoggedAt: start, now: start.addingTimeInterval(20)
        ))
        XCTAssertTrue(NavigationLocationDiagnosticPolicy.shouldLog(
            lastLoggedAt: start, now: start.addingTimeInterval(-1)
        ), "A clock correction must not suppress diagnostics indefinitely")
    }

    func testArrivalRequiresAccurateSlowFixNearDestination() {
        let destination = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        let nearAndSlow = CLLocation(coordinate: destination, altitude: 0,
                                     horizontalAccuracy: 8, verticalAccuracy: 5,
                                     course: 0, speed: 2, timestamp: Date())
        let fast = CLLocation(coordinate: destination, altitude: 0,
                              horizontalAccuracy: 8, verticalAccuracy: 5,
                              course: 0, speed: 20, timestamp: Date())
        XCTAssertTrue(NavigationArrivalPolicy.isArrivalFix(nearAndSlow, destination: destination))
        XCTAssertFalse(NavigationArrivalPolicy.isArrivalFix(fast, destination: destination))
        XCTAssertTrue(NavigationArrivalPolicy.mayCompleteTrip(hasOpenRequiredWaypoints: false))
        XCTAssertFalse(NavigationArrivalPolicy.mayCompleteTrip(
            hasOpenRequiredWaypoints: true
        ), "Arrival must not silently skip a mandatory pass or user-selected stop")
        XCTAssertFalse(NavigationArrivalPolicy.mayCompleteTrip(
            hasOpenRequiredWaypoints: false,
            guidanceReliable: false,
            remainingRouteDistance: 20
        ), "A nearby parallel road must not complete an unreliable route")
        XCTAssertFalse(NavigationArrivalPolicy.mayCompleteTrip(
            hasOpenRequiredWaypoints: false,
            recalculating: true,
            remainingRouteDistance: 20
        ), "Arrival must wait for the replacement route")
        XCTAssertFalse(NavigationArrivalPolicy.mayCompleteTrip(
            hasOpenRequiredWaypoints: false,
            remainingRouteDistance: NavigationArrivalPolicy.maximumRemainingRouteDistance + 1
        ), "Geographic proximity alone is insufficient while the route still continues")
        XCTAssertTrue(NavigationArrivalPolicy.mayCompleteTrip(
            hasOpenRequiredWaypoints: false,
            remainingRouteDistance: NavigationArrivalPolicy.maximumRemainingRouteDistance
        ))
        let firstFix = Date(timeIntervalSince1970: 1_000)
        XCTAssertFalse(NavigationArrivalPolicy.hasSettled(
            since: firstFix, at: firstFix.addingTimeInterval(3.9)
        ), "A short buffered GPS burst must not complete the trip")
        XCTAssertTrue(NavigationArrivalPolicy.hasSettled(
            since: firstFix, at: firstFix.addingTimeInterval(4)
        ))
    }

    func testAccountLoginResponseDecodesServerSession() throws {
        let data = Data(#"{"session":"secure-session","expires_at":"2026-11-01T00:00:00Z","email":"driver@example.com","two_factor_enabled":true}"#.utf8)
        let response = try JSONDecoder().decode(AccountLoginResponse.self, from: data)
        XCTAssertEqual(response.session, "secure-session")
        XCTAssertEqual(response.email, "driver@example.com")
        XCTAssertTrue(response.twoFactorEnabled)
    }

    func testServerEndpointRequiresHTTPSOutsidePrivateNetworks() {
        XCTAssertNotNil(ServerEndpointPolicy.url(baseURL: "https://drive.example.com", path: "/auth/login"))
        XCTAssertNotNil(ServerEndpointPolicy.url(baseURL: "http://100.72.226.91:18080", path: "/auth/login"))
        XCTAssertNotNil(ServerEndpointPolicy.url(baseURL: "http://192.168.1.20:8080", path: "/auth/login"))
        XCTAssertNil(ServerEndpointPolicy.url(baseURL: "http://drive.example.com", path: "/auth/login"))
        XCTAssertNil(ServerEndpointPolicy.url(baseURL: "ftp://drive.example.com", path: "/auth/login"))
        XCTAssertEqual(ServerEndpointPolicy.url(
            baseURL: "https://drive.example.com", path: "/stations?fuel=e10&radius=8"
        )?.query, "fuel=e10&radius=8")
    }

    func testServerEndpointPreservesBasePathAndNormalisesSlash() throws {
        let url = try XCTUnwrap(ServerEndpointPolicy.url(
            baseURL: "https://drive.example.com/service/", path: "auth/login"
        ))
        XCTAssertEqual(url.absoluteString, "https://drive.example.com/service/auth/login")
    }

    func testLockedDestinationUsesTripTitleInsteadOfContradictoryPlacemark() {
        XCTAssertEqual(DestinationSubtitlePolicy.subtitle(
            name: "Hochheim am Main",
            lockedRouteTitle: "Heimfahrt über Wurzenpass",
            locality: nil,
            administrativeArea: nil,
            country: "Schweiz",
            fallbackTitle: "Schweiz"
        ), "Heimfahrt über Wurzenpass")
    }

    func testDestinationSubtitleBuildsUsefulUniquePlaceHierarchy() {
        XCTAssertEqual(DestinationSubtitlePolicy.subtitle(
            name: "Café",
            lockedRouteTitle: nil,
            locality: "Mainz",
            administrativeArea: "Rheinland-Pfalz",
            country: "Deutschland",
            fallbackTitle: "Café, Mainz"
        ), "Mainz · Rheinland-Pfalz · Deutschland")
    }

    func testDestinationSubtitleRejectsUnverifiedCountryOnlyPlacemark() {
        XCTAssertEqual(DestinationSubtitlePolicy.subtitle(
            name: "Café Maldaner",
            lockedRouteTitle: nil,
            locality: "Schweiz",
            administrativeArea: nil,
            country: "Schweiz",
            fallbackTitle: "Schweiz"
        ), "Ausgewähltes Ziel")
    }

    func testStepSelectionDoesNotJumpToNearbyFutureRamp() {
        let metrics = [
            NavigationStepMetric(distanceFromRoute: 4, remainingOnStep: 600),
            NavigationStepMetric(distanceFromRoute: 2, remainingOnStep: 900),
            NavigationStepMetric(distanceFromRoute: 3, remainingOnStep: 1_200),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(current: 0, metrics: metrics,
                                                                    transitionRadius: 10), 0)
    }

    func testStepSelectionDoesNotTreatParallelRampAsMissedExit() {
        let beforeExit = [
            NavigationStepMetric(distanceFromRoute: 72, remainingOnStep: 650),
            NavigationStepMetric(distanceFromRoute: 5, remainingOnStep: 900,
                                 courseDifferenceDegrees: 2),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: beforeExit, transitionRadius: 12
        ), 0, "A closer parallel ramp must not hide the upcoming exit")

        let afterExit = [
            NavigationStepMetric(distanceFromRoute: 72, remainingOnStep: 60),
            NavigationStepMetric(distanceFromRoute: 5, remainingOnStep: 900,
                                 courseDifferenceDegrees: 2),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: afterExit, transitionRadius: 12
        ), 1, "The missed-step fallback must still advance near the junction")
    }

    func testLiveMetricEvaluationIsBoundedOnVeryLongRoute() {
        XCTAssertEqual(
            NavigationStepSelectionPolicy.metricEvaluationIndices(
                current: 400, stepCount: 1_000
            ),
            400..<481
        )
        XCTAssertEqual(
            NavigationStepSelectionPolicy.metricEvaluationIndices(
                current: 980, stepCount: 1_000
            ),
            980..<1_000
        )
        XCTAssertEqual(
            NavigationStepSelectionPolicy.metricEvaluationIndices(
                current: 0, stepCount: 0
            ),
            0..<0
        )
    }

    func testLiveFullRecoveryRequiresBothLongGapAndMeaningfulDisplacement() {
        let start = Date(timeIntervalSince1970: 1_000)
        let previous = CLLocation(
            coordinate: .init(latitude: 50.0, longitude: 8.0),
            altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
            timestamp: start
        )
        func location(latitude: Double, after seconds: TimeInterval) -> CLLocation {
            CLLocation(
                coordinate: .init(latitude: latitude, longitude: 8.0),
                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                timestamp: start.addingTimeInterval(seconds)
            )
        }

        XCTAssertFalse(NavigationLiveRecoveryPolicy.allowsFullRouteMatch(
            previous: previous, current: location(latitude: 50.03, after: 30)
        ), "A normal live update must keep the bounded fast path")
        XCTAssertFalse(NavigationLiveRecoveryPolicy.allowsFullRouteMatch(
            previous: previous, current: location(latitude: 50.001, after: 180)
        ), "A stationary pause must not scan the complete route")
        XCTAssertTrue(NavigationLiveRecoveryPolicy.allowsFullRouteMatch(
            previous: previous, current: location(latitude: 50.03, after: 180)
        ), "A long moving GPS gap must be able to recover beyond the bounded step window")
        XCTAssertFalse(NavigationLiveRecoveryPolicy.allowsFullRouteMatch(
            previous: nil, current: location(latitude: 50.03, after: 180)
        ))
    }

    func testNavigationPersistenceUsesShortCrashSafeCheckpoints() {
        let start = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: nil, now: start
        ))
        XCTAssertFalse(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(29.9)
        ))
        XCTAssertTrue(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(30)
        ))
        XCTAssertTrue(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(-1)
        ), "Clock rollback must start a fresh checkpoint window")
        XCTAssertFalse(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(59.9), interval: 60
        ))
        XCTAssertTrue(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(60), interval: 60
        ))
        XCTAssertTrue(NavigationPersistenceCheckpointPolicy.shouldPersist(
            last: start, now: start.addingTimeInterval(-1), interval: 60
        ), "Route and offline progress must checkpoint after clock rollback")
    }

    func testStepSelectionAdvancesSequentiallyAtJunction() {
        let metrics = [
            NavigationStepMetric(distanceFromRoute: 5, remainingOnStep: 4),
            NavigationStepMetric(distanceFromRoute: 6, remainingOnStep: 500),
            NavigationStepMetric(distanceFromRoute: 3, remainingOnStep: 900),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(current: 0, metrics: metrics,
                                                                    transitionRadius: 10), 1)
    }

    func testStepSelectionDoesNotConsumeTwoCloseManeuversFromOneLiveFix() {
        let compactJunction = [
            NavigationStepMetric(
                distanceFromRoute: 5, remainingOnStep: 4, stepDistance: 180
            ),
            NavigationStepMetric(
                distanceFromRoute: 4, remainingOnStep: 6, stepDistance: 10,
                hasManeuverInstruction: true
            ),
            NavigationStepMetric(
                distanceFromRoute: 5, remainingOnStep: 450, stepDistance: 450,
                hasManeuverInstruction: true
            ),
        ]

        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: compactJunction, transitionRadius: 10
        ), 1, "The second close turn must remain the next visible and audible maneuver")
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: compactJunction, transitionRadius: 10,
            allowsFullRecovery: true
        ), 2, "Explicit recovery may catch up when the car is already beyond both turns")
    }

    func testStepSelectionSkipsOnlyPlausibleEmptyMapKitTransition() {
        let usableSuccessor = [
            NavigationStepMetric(
                distanceFromRoute: .greatestFiniteMagnitude,
                remainingOnStep: .greatestFiniteMagnitude,
                stepDistance: 0, hasUsableGeometry: false
            ),
            NavigationStepMetric(distanceFromRoute: 8, remainingOnStep: 600),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: usableSuccessor, transitionRadius: 10
        ), 1)

        let distantSuccessor = [
            usableSuccessor[0],
            NavigationStepMetric(distanceFromRoute: 180, remainingOnStep: 600),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: distantSuccessor, transitionRadius: 10
        ), 0, "Missing geometry alone must never skip onto a distant road")

        let opposingSuccessor = [
            usableSuccessor[0],
            NavigationStepMetric(
                distanceFromRoute: 8, remainingOnStep: 600,
                courseDifferenceDegrees: 150
            ),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: opposingSuccessor, transitionRadius: 10
        ), 0, "Missing geometry must not snap guidance onto opposing traffic")
    }

    func testStepSelectionSkipsConsecutiveEmptyMapKitTransitions() {
        let metrics = [
            NavigationStepMetric(
                distanceFromRoute: .greatestFiniteMagnitude,
                remainingOnStep: .greatestFiniteMagnitude,
                stepDistance: 0, hasUsableGeometry: false
            ),
            NavigationStepMetric(
                distanceFromRoute: .greatestFiniteMagnitude,
                remainingOnStep: .greatestFiniteMagnitude,
                stepDistance: 0, hasUsableGeometry: false
            ),
            NavigationStepMetric(
                distanceFromRoute: .greatestFiniteMagnitude,
                remainingOnStep: .greatestFiniteMagnitude,
                stepDistance: 0, hasUsableGeometry: false
            ),
            NavigationStepMetric(distanceFromRoute: 9, remainingOnStep: 480),
        ]

        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 10
        ), 3)
    }

    func testStepSelectionNeverSkipsGeometryFreeManeuverInstruction() {
        let metrics = [
            NavigationStepMetric(
                distanceFromRoute: .greatestFiniteMagnitude,
                remainingOnStep: .greatestFiniteMagnitude,
                stepDistance: 0, hasUsableGeometry: false
            ),
            NavigationStepMetric(
                distanceFromRoute: .greatestFiniteMagnitude,
                remainingOnStep: .greatestFiniteMagnitude,
                stepDistance: 0, hasUsableGeometry: false,
                hasManeuverInstruction: true
            ),
            NavigationStepMetric(distanceFromRoute: 6, remainingOnStep: 500),
        ]

        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 10
        ), 0, "A real maneuver must not disappear merely because MapKit omitted its geometry")
    }

    func testStepSelectionCompletesGeometryFreeManeuverAtJunction() {
        let approaching = [
            NavigationStepMetric(
                distanceFromRoute: 5, remainingOnStep: 40, stepDistance: 300
            ),
            NavigationStepMetric(
                distanceFromRoute: .greatestFiniteMagnitude,
                remainingOnStep: .greatestFiniteMagnitude,
                stepDistance: 0, hasUsableGeometry: false,
                hasManeuverInstruction: true
            ),
            NavigationStepMetric(
                distanceFromRoute: 7, remainingOnStep: 500, stepDistance: 500,
                courseDifferenceDegrees: 4
            ),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: approaching, transitionRadius: 10
        ), 0, "The instruction-only turn must remain active before the junction")

        var afterTurn = approaching
        afterTurn[0] = NavigationStepMetric(
            distanceFromRoute: 12, remainingOnStep: 6, stepDistance: 300
        )
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: afterTurn, transitionRadius: 10
        ), 2, "Once on the outgoing road, guidance must not freeze on missing geometry")

        afterTurn[2] = NavigationStepMetric(
            distanceFromRoute: 7, remainingOnStep: 500, stepDistance: 500,
            courseDifferenceDegrees: 150
        )
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: afterTurn, transitionRadius: 10
        ), 0, "An opposing nearby road must not complete the maneuver")
    }

    func testStepSelectionDoesNotDropFinalCueBeforeJunctionWithCoarseGPS() {
        let beforeJunction = [
            NavigationStepMetric(distanceFromRoute: 7, remainingOnStep: 22),
            NavigationStepMetric(distanceFromRoute: 9, remainingOnStep: 500),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: beforeJunction, transitionRadius: 30
        ), 0, "The current maneuver must remain active until the junction")

        let atJunction = [
            NavigationStepMetric(distanceFromRoute: 5, remainingOnStep: 7),
            NavigationStepMetric(distanceFromRoute: 6, remainingOnStep: 500),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: atJunction, transitionRadius: 30
        ), 1)
    }

    func testStepSelectionRecoversForwardAfterLargeLocationGap() {
        let metrics = [
            NavigationStepMetric(distanceFromRoute: 700, remainingOnStep: 0),
            NavigationStepMetric(distanceFromRoute: 550, remainingOnStep: 0),
            NavigationStepMetric(distanceFromRoute: 7, remainingOnStep: 300),
            NavigationStepMetric(distanceFromRoute: 20, remainingOnStep: 800),
        ]
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(current: 0, metrics: metrics,
                                                                    transitionRadius: 12), 2)
    }

    func testStepRecoveryDoesNotSnapToDistantRouteCrossing() {
        var metrics = Array(repeating: NavigationStepMetric(distanceFromRoute: 600, remainingOnStep: 0),
                            count: 30)
        metrics[3] = .init(distanceFromRoute: 35, remainingOnStep: 400)
        metrics[25] = .init(distanceFromRoute: 2, remainingOnStep: 20_000)
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(current: 0, metrics: metrics,
                                                                    transitionRadius: 12), 3)
    }

    func testStepRecoveryCanCatchUpAcrossManyShortUrbanSteps() {
        var metrics = Array(repeating: NavigationStepMetric(
            distanceFromRoute: 700, remainingOnStep: 0, stepDistance: 120
        ), count: 50)
        metrics[31] = .init(distanceFromRoute: 12, remainingOnStep: 80, stepDistance: 120)

        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12
        ), 31)
    }

    func testMeasuredRecoveryStillPrefersEarlierPlausibleCrossing() {
        var metrics = Array(repeating: NavigationStepMetric(
            distanceFromRoute: 700, remainingOnStep: 0, stepDistance: 150
        ), count: 60)
        metrics[22] = .init(distanceFromRoute: 35, remainingOnStep: 90, stepDistance: 150)
        metrics[40] = .init(distanceFromRoute: 2, remainingOnStep: 600, stepDistance: 150)

        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12
        ), 22)
    }

    func testInitialOfflineRecoveryCanResumeFarBeyondShortRecoveryWindow() {
        var metrics = Array(repeating: NavigationStepMetric(
            distanceFromRoute: 3_000, remainingOnStep: 0
        ), count: 80)
        metrics[54] = .init(distanceFromRoute: 18, remainingOnStep: 700)
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12, allowsFullRecovery: true
        ), 54)
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12
        ), 0, "Ordinary updates must not jump across most of the route")
    }

    func testInitialOfflineRecoveryPrefersEarlierPlausibleSegmentAtCrossing() {
        var metrics = Array(repeating: NavigationStepMetric(
            distanceFromRoute: 2_000, remainingOnStep: 0
        ), count: 80)
        metrics[42] = .init(distanceFromRoute: 30, remainingOnStep: 600)
        metrics[70] = .init(distanceFromRoute: 2, remainingOnStep: 8_000)
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12, allowsFullRecovery: true
        ), 42)
    }

    func testInitialOfflineRecoveryEscapesNearbyWrongDirectionOverlap() {
        let metrics = [
            NavigationStepMetric(
                distanceFromRoute: 2, remainingOnStep: 900,
                courseDifferenceDegrees: 175
            ),
            NavigationStepMetric(
                distanceFromRoute: 8, remainingOnStep: 700,
                courseDifferenceDegrees: 4
            ),
        ]

        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12,
            allowsFullRecovery: true
        ), 1, "A restored out-and-back route must follow the matching carriageway direction")
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12
        ), 0, "Continuous guidance must not jump forward from one contradictory course fix")
    }

    func testFullRecoveryCanResumeBeyondGeometryFreeManeuver() {
        let metrics = [
            NavigationStepMetric(
                distanceFromRoute: 1_500, remainingOnStep: 500, stepDistance: 2_000
            ),
            NavigationStepMetric(
                distanceFromRoute: .greatestFiniteMagnitude,
                remainingOnStep: .greatestFiniteMagnitude,
                stepDistance: 0, hasUsableGeometry: false,
                hasManeuverInstruction: true
            ),
            NavigationStepMetric(
                distanceFromRoute: 9, remainingOnStep: 700, stepDistance: 900,
                courseDifferenceDegrees: 3
            ),
        ]

        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12,
            allowsFullRecovery: true
        ), 2, "A restored trip must match the road reached during the location gap")
        XCTAssertEqual(NavigationStepSelectionPolicy.selectedIndex(
            current: 0, metrics: metrics, transitionRadius: 12
        ), 0, "Continuous guidance must still protect the unseen maneuver")
    }

    func testOfflineResumeEstimateStartsAtPersistedStepInsteadOfWholeTrip() {
        let estimate = OfflineGuidanceResumeEstimatePolicy.estimate(
            stepDistances: [10_000, 20_000, 30_000, 40_000],
            currentIndex: 2,
            routeDistance: 100_000,
            routeTravelTime: 5_000
        )

        XCTAssertEqual(estimate.distance, 70_000, accuracy: 0.001)
        XCTAssertEqual(estimate.travelTime, 3_500, accuracy: 0.001)
    }

    func testOfflineResumeEstimateAtEndDoesNotRestoreFullRouteTotals() {
        let estimate = OfflineGuidanceResumeEstimatePolicy.estimate(
            stepDistances: [1_000, 2_000], currentIndex: 2,
            routeDistance: 3_000, routeTravelTime: 180
        )

        XCTAssertEqual(estimate.distance, 0)
        XCTAssertEqual(estimate.travelTime, 0)
    }

    func testOfflineGuidanceFindsNextManeuverAlongCachedGeometry() throws {
        let steps = [
            OfflineGuidanceStep(instruction: "", distance: 1_000, coordinates: [
                .init(latitude: 50, longitude: 8), .init(latitude: 50, longitude: 8.014)
            ]),
            OfflineGuidanceStep(instruction: "Rechts auf die B 40 abbiegen", distance: 700, coordinates: [
                .init(latitude: 50, longitude: 8.014), .init(latitude: 49.994, longitude: 8.014)
            ]),
            OfflineGuidanceStep(instruction: "Links Richtung Ziel", distance: 300, coordinates: [
                .init(latitude: 49.994, longitude: 8.014), .init(latitude: 49.994, longitude: 8.01)
            ]),
        ]
        let progress = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: .init(latitude: 50, longitude: 8.007), currentIndex: 0,
            steps: steps, transitionRadius: 15
        ))

        XCTAssertEqual(progress.currentStepIndex, 0)
        XCTAssertEqual(progress.maneuverStepIndex, 1)
        XCTAssertEqual(progress.instruction, "Rechts auf die B 40 abbiegen")
        XCTAssertGreaterThan(progress.distanceToManeuver, 400)
        XCTAssertLessThan(progress.distanceToManeuver, 600)
        XCTAssertEqual(progress.upcomingInstructions.count, 2)
        XCTAssertLessThan(progress.distanceFromRoute, 20)
    }

    func testOfflineResumeStartsNearPersistedTripProgress() {
        let steps = (0..<10).map { index in
            OfflineGuidanceStep(
                instruction: "Schritt \(index)", distance: 1_000,
                coordinates: [
                    .init(latitude: 50, longitude: 8 + Double(index) * 0.01),
                    .init(latitude: 50, longitude: 8 + Double(index + 1) * 0.01),
                ]
            )
        }

        XCTAssertEqual(OfflineGuidanceResumePolicy.stepIndex(
            steps: steps, persistedProgress: 0.72
        ), 7)
        XCTAssertEqual(OfflineGuidanceResumePolicy.stepIndex(
            steps: steps, persistedProgress: nil
        ), 0)
    }

    func testOfflineResumeKeepsSmallBackwardSafetyAllowance() {
        let steps = (0..<5).map { index in
            OfflineGuidanceStep(
                instruction: "Schritt \(index)", distance: 1_000,
                coordinates: [.init(latitude: 50, longitude: 8),
                              .init(latitude: 50, longitude: 8.01)]
            )
        }

        XCTAssertEqual(OfflineGuidanceResumePolicy.stepIndex(
            steps: steps, persistedProgress: 0.405
        ), 1, "A checkpoint just beyond a junction must retain the preceding guidance step")
        XCTAssertEqual(OfflineGuidanceResumePolicy.stepIndex(
            steps: steps, persistedProgress: 2
        ), 4)
    }

    func testOfflineProgressUsesCachedDistanceWhenLiveLegsAreUnavailable() throws {
        XCTAssertEqual(try XCTUnwrap(OfflineRouteProgressPolicy.progress(
            liveRouteDistance: 0, cachedRouteDistance: 100_000,
            remainingDistance: 40_000
        )), 0.6, accuracy: 0.000_1)
        XCTAssertEqual(try XCTUnwrap(OfflineRouteProgressPolicy.progress(
            liveRouteDistance: 120_000, cachedRouteDistance: 100_000,
            remainingDistance: 30_000
        )), 0.75, accuracy: 0.000_1)
        XCTAssertNil(OfflineRouteProgressPolicy.progress(
            liveRouteDistance: 0, cachedRouteDistance: 0,
            remainingDistance: 0
        ))
    }

    func testOfflineGuidanceReportsDistanceFromCachedCorridor() throws {
        let steps = [
            OfflineGuidanceStep(instruction: "Geradeaus", distance: 1_000, coordinates: [
                .init(latitude: 50, longitude: 8), .init(latitude: 50, longitude: 8.014)
            ])
        ]

        let progress = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: .init(latitude: 50.01, longitude: 8.007), currentIndex: 0,
            steps: steps, transitionRadius: 12
        ))

        XCTAssertGreaterThan(progress.distanceFromRoute, 1_000)
    }

    func testOfflineGuidanceDoesNotJumpToNearbyFutureParallelStep() throws {
        let steps = [
            OfflineGuidanceStep(instruction: "", distance: 1_000, coordinates: [
                .init(latitude: 50, longitude: 8), .init(latitude: 50, longitude: 8.014)
            ]),
            OfflineGuidanceStep(instruction: "Rechts abbiegen", distance: 1_000, coordinates: [
                .init(latitude: 50.00005, longitude: 8), .init(latitude: 50.00005, longitude: 8.014)
            ]),
        ]
        let progress = try XCTUnwrap(OfflineGuidanceEngine.progress(
            at: .init(latitude: 50, longitude: 8.003), currentIndex: 0,
            steps: steps, transitionRadius: 12
        ))
        XCTAssertEqual(progress.currentStepIndex, 0)
        XCTAssertEqual(progress.maneuverStepIndex, 1)
    }

    func testOfflineRecoveryIsThrottled() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(OfflineRouteRecoveryPolicy.shouldAttempt(lastAttempt: nil, now: now))
        XCTAssertFalse(OfflineRouteRecoveryPolicy.shouldAttempt(
            lastAttempt: now.addingTimeInterval(-89), now: now
        ))
        XCTAssertTrue(OfflineRouteRecoveryPolicy.shouldAttempt(
            lastAttempt: now.addingTimeInterval(-90), now: now
        ))
        XCTAssertTrue(OfflineRouteRecoveryPolicy.shouldAttempt(
            lastAttempt: now.addingTimeInterval(1), now: now
        ), "Clock rollback must allow online recovery to restart")
        XCTAssertFalse(OfflineRouteRecoveryPolicy.shouldAttempt(
            lastAttempt: now.addingTimeInterval(-19), urgent: true, now: now
        ))
        XCTAssertTrue(OfflineRouteRecoveryPolicy.shouldAttempt(
            lastAttempt: now.addingTimeInterval(-20), urgent: true, now: now
        ), "A confirmed offline departure needs a prompt online reroute retry")
        XCTAssertFalse(OfflineRouteRecoveryPolicy.shouldAttempt(
            lastAttempt: now.addingTimeInterval(-20), urgent: false, now: now
        ), "On-route offline guidance keeps the calm normal retry cadence")
    }

    func testOfflineInitialRecoveryWaitsForPositionInsideRouteCorridor() {
        XCTAssertEqual(OfflineInitialPositionMatchPolicy.requiredConsecutiveMatches, 3)
        XCTAssertTrue(OfflineInitialPositionMatchPolicy.continuesCandidate(
            previousStepIndex: 10, currentStepIndex: 10
        ))
        XCTAssertTrue(OfflineInitialPositionMatchPolicy.continuesCandidate(
            previousStepIndex: 10, currentStepIndex: 12
        ), "Short MapKit steps may advance while the car remains on the matched route")
        XCTAssertTrue(OfflineInitialPositionMatchPolicy.continuesCandidate(
            previousStepIndex: 10, currentStepIndex: 9
        ), "One-step cursor jitter should not restart the confirmation count")
        XCTAssertFalse(OfflineInitialPositionMatchPolicy.continuesCandidate(
            previousStepIndex: 10, currentStepIndex: 13
        ), "A large jump must be confirmed from scratch")
        XCTAssertFalse(OfflineInitialPositionMatchPolicy.continuesCandidate(
            previousStepIndex: 10, currentStepIndex: 8
        ), "A backwards snap beyond one adjacent step must be confirmed from scratch")
        XCTAssertFalse(OfflineInitialPositionMatchPolicy.continuesCandidate(
            previousStepIndex: nil, currentStepIndex: 10
        ))
        XCTAssertFalse(OfflineInitialPositionMatchPolicy.isConfirmed(consecutiveMatches: 1))
        XCTAssertFalse(OfflineInitialPositionMatchPolicy.isConfirmed(consecutiveMatches: 2))
        XCTAssertTrue(OfflineInitialPositionMatchPolicy.isConfirmed(consecutiveMatches: 3))
        XCTAssertFalse(OfflineInitialPositionMatchPolicy.isReliable(
            distanceFromRoute: 2_000, horizontalAccuracy: 20,
            speedMetresPerSecond: 25
        ))
        XCTAssertTrue(OfflineInitialPositionMatchPolicy.isReliable(
            distanceFromRoute: 35, horizontalAccuracy: 10,
            speedMetresPerSecond: 12
        ))
        XCTAssertFalse(OfflineInitialPositionMatchPolicy.isReliable(
            distanceFromRoute: 20, horizontalAccuracy: 8,
            speedMetresPerSecond: 18, wrongWay: true
        ), "A nearby road match in the opposite direction must not revive cached guidance")
    }

    func testOfflineRecoveryPublishesOnlyACommittedActiveOnlineRoute() {
        XCTAssertTrue(OfflineRouteRecoveryPolicy.acceptsOnlineResult(
            calculationSucceeded: true, navigationActive: true,
            stillUsingOfflineGuidance: false
        ))
        XCTAssertFalse(OfflineRouteRecoveryPolicy.acceptsOnlineResult(
            calculationSucceeded: false, navigationActive: true,
            stillUsingOfflineGuidance: true
        ))
        XCTAssertFalse(OfflineRouteRecoveryPolicy.acceptsOnlineResult(
            calculationSucceeded: true, navigationActive: false,
            stillUsingOfflineGuidance: false
        ))
        XCTAssertFalse(OfflineRouteRecoveryPolicy.acceptsOnlineResult(
            calculationSucceeded: true, navigationActive: true,
            stillUsingOfflineGuidance: true
        ))
    }

    func testLockedTripRestoreRetriesAfterTransientFailureWithoutRequestStorm() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertTrue(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: false, attemptInProgress: false, lastAttempt: nil, now: now
        ))
        XCTAssertFalse(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: false, attemptInProgress: false,
            lastAttempt: now.addingTimeInterval(-89), now: now
        ))
        XCTAssertTrue(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: false, attemptInProgress: false,
            lastAttempt: now.addingTimeInterval(-90), now: now
        ))
        XCTAssertTrue(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: false, attemptInProgress: false,
            lastAttempt: now.addingTimeInterval(1), now: now
        ), "Clock rollback must not strand a persisted trip")
        XCTAssertFalse(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: true, attemptInProgress: false, lastAttempt: nil, now: now
        ))
        XCTAssertFalse(RouteLockRestorePolicy.shouldAttempt(
            navigationActive: false, attemptInProgress: true, lastAttempt: nil, now: now
        ))
    }

    func testTripRestorePrefersFreshOnlineThenOfflineBeforeStaleLiveRoute() {
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: true, hasMatchingLiveRoute: true,
            hasMatchingOfflineRoute: true
        ), .online)
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: false, hasMatchingLiveRoute: true,
            hasMatchingOfflineRoute: true
        ), .offline)
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: false, hasMatchingLiveRoute: true,
            hasMatchingOfflineRoute: false
        ), .staleLive)
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: false, hasMatchingLiveRoute: false,
            hasMatchingOfflineRoute: false
        ), .unavailable)
        XCTAssertEqual(RouteRestoreModePolicy.mode(
            onlineCalculationSucceeded: false, hasMatchingLiveRoute: false,
            hasMatchingOfflineRoute: true
        ), .offline)
    }

    func testForegroundCalculationUsesOnlyExactlyMatchingFallbackGeometry() {
        XCTAssertEqual(ForegroundRouteFallbackPolicy.mode(
            onlineCalculationSucceeded: true, hasMatchingLiveRoute: false,
            hasMatchingOfflineRoute: false
        ), .online)
        XCTAssertEqual(ForegroundRouteFallbackPolicy.mode(
            onlineCalculationSucceeded: false, hasMatchingLiveRoute: true,
            hasMatchingOfflineRoute: true
        ), .matchingLive, "A matching live route should remain a non-disruptive preview")
        XCTAssertEqual(ForegroundRouteFallbackPolicy.mode(
            onlineCalculationSucceeded: false, hasMatchingLiveRoute: false,
            hasMatchingOfflineRoute: true
        ), .offline, "Mismatched live constraints must not block exact cached guidance")
        XCTAssertEqual(ForegroundRouteFallbackPolicy.mode(
            onlineCalculationSucceeded: false, hasMatchingLiveRoute: false,
            hasMatchingOfflineRoute: false
        ), .unavailable)
    }

    func testStaleLiveRouteRequiresExactActiveConstraints() {
        XCTAssertTrue(LiveRouteRestoreEligibilityPolicy.mayReuse(
            destinationMatches: true,
            installedConstraintIdentity: "destination#avoid-highways#pass-a",
            activeConstraintIdentity: "destination#avoid-highways#pass-a"
        ))
        XCTAssertFalse(LiveRouteRestoreEligibilityPolicy.mayReuse(
            destinationMatches: true,
            installedConstraintIdentity: "destination#motorway#pass-a",
            activeConstraintIdentity: "destination#avoid-highways#pass-a"
        ))
        XCTAssertFalse(LiveRouteRestoreEligibilityPolicy.mayReuse(
            destinationMatches: true,
            installedConstraintIdentity: nil,
            activeConstraintIdentity: "destination#avoid-highways#pass-a"
        ))
        XCTAssertFalse(LiveRouteRestoreEligibilityPolicy.mayReuse(
            destinationMatches: false,
            installedConstraintIdentity: "same",
            activeConstraintIdentity: "same"
        ))
    }

    func testNavigationDestinationIdentityUsesRoadLevelTolerance() {
        let destination = CLLocationCoordinate2D(latitude: 50.0147, longitude: 8.3522)
        XCTAssertTrue(NavigationDestinationIdentityPolicy.matches(
            .init(latitude: 50.01475, longitude: 8.3522), destination
        ))
        XCTAssertFalse(NavigationDestinationIdentityPolicy.matches(
            .init(latitude: 50.02, longitude: 8.3522), destination
        ))
        XCTAssertFalse(NavigationDestinationIdentityPolicy.matches(nil, destination))
    }

    func testOnlyLatestDestinationActivationMayRestoreItsSnapshot() {
        let older = UUID()
        let latest = UUID()
        XCTAssertFalse(DestinationActivationRollbackPolicy.shouldRollback(
            request: older, current: latest
        ))
        XCTAssertTrue(DestinationActivationRollbackPolicy.shouldRollback(
            request: latest, current: latest
        ))
        XCTAssertFalse(DestinationActivationRollbackPolicy.isCurrent(
            request: older, current: latest
        ))
        XCTAssertTrue(DestinationActivationRollbackPolicy.isCurrent(
            request: latest, current: latest
        ))
    }

    func testRouteEnrichmentRequiresMatchingRouteAndRequest() {
        let route = UUID()
        let request = UUID()
        XCTAssertTrue(RouteEnrichmentPublicationPolicy.isCurrent(
            route: route, currentRoute: route,
            request: request, currentRequest: request
        ))
        XCTAssertFalse(RouteEnrichmentPublicationPolicy.isCurrent(
            route: route, currentRoute: UUID(),
            request: request, currentRequest: request
        ))
        XCTAssertFalse(RouteEnrichmentPublicationPolicy.isCurrent(
            route: route, currentRoute: route,
            request: request, currentRequest: UUID()
        ))
    }

    func testFailedRouteMutationCannotRollbackNewerState() {
        XCTAssertTrue(RouteMutationRollbackPolicy.shouldRollback(
            current: ["fuel-a", "rest-b"], mutated: ["fuel-a", "rest-b"]
        ))
        XCTAssertFalse(RouteMutationRollbackPolicy.shouldRollback(
            current: ["fuel-a", "rest-b", "food-c"], mutated: ["fuel-a", "rest-b"]
        ))
    }

    func testRouteOptionScopeKeepsWaypointRulesOutOfGlobalPreferences() {
        XCTAssertNil(RouteOptionScopePolicy.waypointID("  "))
        XCTAssertTrue(RouteOptionScopePolicy.mutatesGlobalSettings(waypointID: nil))
        XCTAssertTrue(RouteOptionScopePolicy.mutatesGlobalSettings(waypointID: ""))
        XCTAssertEqual(RouteOptionScopePolicy.waypointID("  slovenia  "), "slovenia")
        XCTAssertFalse(RouteOptionScopePolicy.mutatesGlobalSettings(
            waypointID: "slovenia"
        ))
    }

    func testAsyncGuidanceWorkCannotSurviveStopOrNewSession() {
        let session = UUID()
        let work = UUID()
        XCTAssertTrue(NavigationAsyncWorkPolicy.isCurrent(
            navigationActive: true,
            session: session, currentSession: session,
            work: work, currentWork: work
        ))
        XCTAssertFalse(NavigationAsyncWorkPolicy.isCurrent(
            navigationActive: false,
            session: session, currentSession: session,
            work: work, currentWork: work
        ))
        XCTAssertFalse(NavigationAsyncWorkPolicy.isCurrent(
            navigationActive: true,
            session: session, currentSession: UUID(),
            work: work, currentWork: work
        ))
        XCTAssertFalse(NavigationAsyncWorkPolicy.isCurrent(
            navigationActive: true,
            session: session, currentSession: session,
            work: work, currentWork: UUID()
        ))
    }

    func testOfflineCacheRequiresSameDestinationWhenCoordinatesAreAvailable() {
        let cached = CLLocationCoordinate2D(latitude: 50.0000, longitude: 8.0000)
        XCTAssertTrue(OfflineRouteCachePolicy.matches(
            cacheName: "Hauptstraße 1", cacheCoordinate: cached,
            destinationName: "Anderer Anzeigename",
            destinationCoordinate: .init(latitude: 50.0010, longitude: 8.0000)
        ))
        XCTAssertFalse(OfflineRouteCachePolicy.matches(
            cacheName: "Hauptstraße 1", cacheCoordinate: cached,
            destinationName: "Hauptstraße 1",
            destinationCoordinate: .init(latitude: 51.0000, longitude: 8.0000)
        ), "An identical place label must never override a clearly different coordinate")
    }

    func testLegacyOfflineCacheFallsBackToTrimmedName() {
        XCTAssertTrue(OfflineRouteCachePolicy.matches(
            cacheName: "  Hochheim am Main ", cacheCoordinate: nil,
            destinationName: "hochheim am main", destinationCoordinate: .init(latitude: 50, longitude: 8)
        ))
        XCTAssertFalse(OfflineRouteCachePolicy.matches(
            cacheName: "Hochheim am Main", cacheCoordinate: nil,
            destinationName: "Hochheim bei Erfurt", destinationCoordinate: .init(latitude: 51, longitude: 11)
        ))
    }

    func testOfflineGuidanceRequiresExactActiveTripEvenWhenDestinationMatches() {
        XCTAssertTrue(OfflineRouteGuidanceEligibilityPolicy.mayStart(
            available: true, belongsToExactActiveTrip: true
        ))
        XCTAssertFalse(OfflineRouteGuidanceEligibilityPolicy.mayStart(
            available: true, belongsToExactActiveTrip: false
        ), "A same-destination cache from another trip must remain preview-only")
        XCTAssertFalse(OfflineRouteGuidanceEligibilityPolicy.mayStart(
            available: false, belongsToExactActiveTrip: true
        ))
    }

    func testOfflineGuidanceRejectsExpiredAndInvalidFutureCaches() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        XCTAssertTrue(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(-6 * 24 * 60 * 60), now: now
        ))
        XCTAssertFalse(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(-8 * 24 * 60 * 60), now: now
        ))
        XCTAssertTrue(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
            belongsToActiveTrip: true, now: now
        ))
        XCTAssertFalse(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(-31 * 24 * 60 * 60),
            belongsToActiveTrip: true, now: now
        ))
        XCTAssertTrue(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(4 * 60), now: now
        ))
        XCTAssertFalse(OfflineRouteFreshnessPolicy.isUsable(
            savedAt: now.addingTimeInterval(10 * 60), now: now
        ))
    }

    func testExtendedOfflineRetentionRequiresExactActiveTripIdentity() {
        let firstTrip = UUID()
        let secondTrip = UUID()
        XCTAssertTrue(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: firstTrip, activeTripID: firstTrip, active: true
        ))
        XCTAssertFalse(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: firstTrip, activeTripID: secondTrip, active: true
        ))
        XCTAssertFalse(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: nil, activeTripID: firstTrip, active: true
        ))
        XCTAssertFalse(OfflineRouteTripIdentityPolicy.belongs(
            cacheTripID: firstTrip, activeTripID: firstTrip, active: false
        ))
    }

    func testOfflineRouteIsNeverDisplayedWithoutMatchingActiveDestination() {
        let now = Date(timeIntervalSince1970: 2_000_000)
        let cached = CLLocationCoordinate2D(latitude: 50.0, longitude: 8.0)
        XCTAssertFalse(OfflineRouteAvailabilityPolicy.isUsable(
            savedAt: now, cacheName: "Altes Ziel", cacheCoordinate: cached,
            destinationName: nil, destinationCoordinate: nil, now: now
        ))
        XCTAssertFalse(OfflineRouteAvailabilityPolicy.isUsable(
            savedAt: now, cacheName: "Altes Ziel", cacheCoordinate: cached,
            destinationName: "Neues Ziel",
            destinationCoordinate: .init(latitude: 51, longitude: 9),
            belongsToActiveTrip: true, now: now
        ))
        XCTAssertTrue(OfflineRouteAvailabilityPolicy.isUsable(
            savedAt: now, cacheName: "Ziel", cacheCoordinate: cached,
            destinationName: "Ziel",
            destinationCoordinate: .init(latitude: 50.001, longitude: 8), now: now
        ))
        XCTAssertTrue(OfflineRouteAvailabilityPolicy.isUsable(
            savedAt: now.addingTimeInterval(-8 * 24 * 60 * 60),
            cacheName: "Ziel", cacheCoordinate: cached,
            destinationName: "Ziel",
            destinationCoordinate: .init(latitude: 50.001, longitude: 8),
            belongsToActiveTrip: true, now: now
        ))
    }

    func testRouteSearchNeverSuggestsMateriallyPassedStops() {
        XCTAssertFalse(RouteSearchPolicy.isAhead(candidateIndex: 20, currentIndex: 60,
                                                 routePointCount: 100))
        XCTAssertTrue(RouteSearchPolicy.isAhead(candidateIndex: 58, currentIndex: 60,
                                                routePointCount: 100))
        XCTAssertTrue(RouteSearchPolicy.isAhead(candidateIndex: 75, currentIndex: 60,
                                                routePointCount: 100))
    }

    func testRouteSearchFallsBackToPersistedProgressDuringGPSGap() {
        XCTAssertEqual(RouteSearchPolicy.currentProgress(
            projected: 0.72, persisted: 0.45, navigationActive: true
        ), 0.72)
        XCTAssertEqual(RouteSearchPolicy.currentProgress(
            projected: nil, persisted: 0.45, navigationActive: true
        ), 0.45)
        XCTAssertEqual(RouteSearchPolicy.currentProgress(
            projected: nil, persisted: 0.45, navigationActive: false
        ), 0)
        XCTAssertEqual(RouteSearchPolicy.currentProgress(
            projected: 1.4, persisted: nil, navigationActive: true
        ), 1)
    }

    func testRouteSearchUsesProgressOfInstalledRerouteBeforeOriginalTripProgress() {
        let installed = RouteSearchPolicy.installedRouteProgress(
            totalDistance: 200_000,
            remainingDistance: 200_000,
            navigationActive: true
        )

        XCTAssertEqual(installed, 0)
        XCTAssertEqual(RouteSearchPolicy.currentProgress(
            projected: installed,
            persisted: 0.8,
            navigationActive: true
        ), 0, "A fresh route from the current position must be searched from its beginning")
    }

    func testInstalledRouteProgressTracksCurrentGeometryAndRejectsInvalidState() {
        XCTAssertEqual(RouteSearchPolicy.installedRouteProgress(
            totalDistance: 200_000, remainingDistance: 50_000, navigationActive: true
        ) ?? -1, 0.75, accuracy: 0.001)
        XCTAssertEqual(RouteSearchPolicy.installedRouteProgress(
            totalDistance: 200_000, remainingDistance: 0, navigationActive: true
        ), 1)
        XCTAssertNil(RouteSearchPolicy.installedRouteProgress(
            totalDistance: 200_000, remainingDistance: 50_000, navigationActive: false
        ))
        XCTAssertNil(RouteSearchPolicy.installedRouteProgress(
            totalDistance: 0, remainingDistance: 0, navigationActive: true
        ))
    }

    func testSpeedLimitSelectionUsesCurrentVisitAtRouteCrossing() {
        let crossing = CLLocationCoordinate2D(latitude: 50, longitude: 8)
        let points = [
            .init(latitude: 50, longitude: 7.99),
            crossing,
            .init(latitude: 50.01, longitude: 8),
            crossing,
            .init(latitude: 50, longitude: 8.01),
        ]

        let early = SpeedLimitSelectionPolicy.index(
            near: crossing, points: points, availableLimitCount: points.count,
            expectedProgress: 0.2
        )
        let late = SpeedLimitSelectionPolicy.index(
            near: crossing, points: points, availableLimitCount: points.count,
            expectedProgress: 0.8
        )

        XCTAssertEqual(early, 1)
        XCTAssertEqual(late, 3)
    }

    func testSpeedLimitSelectionNeverIndexesBeyondProviderResponse() {
        let points = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.01),
        ]
        XCTAssertNil(SpeedLimitSelectionPolicy.index(
            near: points[1], points: points, availableLimitCount: 1,
            expectedProgress: 1
        ))
    }

    func testSpeedLimitDisappearsWhileInstalledRouteIsUntrustworthy() {
        XCTAssertTrue(SpeedLimitGuidanceAvailabilityPolicy.mayPresent(
            navigationActive: false, guidanceReliable: false, recalculating: true
        ), "A harmless route preview may still inspect its loaded limit data")
        XCTAssertTrue(SpeedLimitGuidanceAvailabilityPolicy.mayPresent(
            navigationActive: true, guidanceReliable: true, recalculating: false
        ))
        XCTAssertFalse(SpeedLimitGuidanceAvailabilityPolicy.mayPresent(
            navigationActive: true, guidanceReliable: false, recalculating: false
        ))
        XCTAssertFalse(SpeedLimitGuidanceAvailabilityPolicy.mayPresent(
            navigationActive: true, guidanceReliable: true, recalculating: true
        ))
    }

    func testSpeedLimitPresentationPrefersNumericEvidenceOverConflict() {
        XCTAssertEqual(SpeedLimitPresentationPolicy.presentation(for: .init(
            maxspeed: 120, unlimited: true
        )), .numeric(120))
        XCTAssertEqual(SpeedLimitPresentationPolicy.presentation(for: .init(
            maxspeed: nil, unlimited: true
        )), .unrestricted)
        XCTAssertEqual(SpeedLimitPresentationPolicy.presentation(for: .init(
            maxspeed: nil, unlimited: false
        )), .unavailable)
        XCTAssertEqual(SpeedLimitPresentationPolicy.presentation(for: .init(
            maxspeed: -1, unlimited: true
        )), .unrestricted)
    }

    func testRouteSearchAheadCheckUsesDistanceProgress() {
        XCTAssertTrue(RouteSearchPolicy.isAhead(
            candidateProgress: 0.498, currentProgress: 0.50,
            totalRouteDistance: 100_000
        ))
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.40, currentProgress: 0.50,
            totalRouteDistance: 100_000
        ))
        XCTAssertTrue(RouteSearchPolicy.isAhead(
            candidateProgress: 0.75, currentProgress: 0.50,
            totalRouteDistance: 100_000
        ))
    }

    func testRouteSearchBackwardToleranceDoesNotScaleToManyKilometres() {
        XCTAssertTrue(RouteSearchPolicy.isAhead(
            candidateProgress: 0.4997, currentProgress: 0.50,
            totalRouteDistance: 800_000
        ), "Small GPS/projection drift remains acceptable")
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.4975, currentProgress: 0.50,
            totalRouteDistance: 800_000
        ), "A stop two kilometres behind must never create an Autobahn return trip")
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.48, currentProgress: 0.50,
            totalRouteDistance: 800_000
        ), "A continental route must not turn two percent into 16 km behind")
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.5, currentProgress: 0.5,
            totalRouteDistance: 0
        ))
    }

    func testRouteSearchSelectionRejectsResultPassedWhileListWasOpen() {
        XCTAssertTrue(RouteSearchPolicy.isAhead(
            candidateProgress: 0.55, currentProgress: 0.54,
            totalRouteDistance: 400_000
        ))
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.55, currentProgress: 0.62,
            totalRouteDistance: 400_000
        ), "A stop selected after driving well past it must not route the car backwards")
    }

    func testRouteStopInsertionUsesStricterFreshProgressThanSearchList() {
        XCTAssertTrue(RouteSearchPolicy.isAhead(
            candidateProgress: 0.498, currentProgress: 0.50,
            totalRouteDistance: 100_000
        ), "The result may remain visible through small projection jitter")
        XCTAssertFalse(RouteStopInsertionPolicy.isStillAhead(
            candidateProgress: 0.498, currentProgress: 0.50,
            totalRouteDistance: 100_000
        ), "A stop 200 metres behind must not be committed")
        XCTAssertTrue(RouteStopInsertionPolicy.isStillAhead(
            candidateProgress: 0.4998, currentProgress: 0.50,
            totalRouteDistance: 100_000
        ), "Road-level GPS drift remains acceptable at commit time")
    }

    func testRouteSearchActionabilityTracksMovementAndRouteReplacement() {
        let generation = UUID()
        XCTAssertTrue(RouteSearchSelectionPolicy.isActionable(
            resultRouteGeneration: generation, currentRouteGeneration: generation,
            candidateProgress: 0.55, currentProgress: 0.50,
            totalRouteDistance: 400_000, navigationActive: true
        ))
        XCTAssertFalse(RouteSearchSelectionPolicy.isActionable(
            resultRouteGeneration: generation, currentRouteGeneration: generation,
            candidateProgress: 0.55, currentProgress: 0.62,
            totalRouteDistance: 400_000, navigationActive: true
        ), "An open list must hide a stop once the car has passed it")
        XCTAssertFalse(RouteSearchSelectionPolicy.isActionable(
            resultRouteGeneration: generation, currentRouteGeneration: UUID(),
            candidateProgress: 0.80, currentProgress: 0.20,
            totalRouteDistance: 400_000, navigationActive: true
        ), "A reroute invalidates progress measured on the old geometry")
        XCTAssertTrue(RouteSearchSelectionPolicy.isActionable(
            resultRouteGeneration: generation, currentRouteGeneration: generation,
            candidateProgress: 0.10, currentProgress: 0.90,
            totalRouteDistance: 400_000, navigationActive: false
        ), "A stationary route preview has no moving cursor")
    }

    func testRouteSearchSelectionDoesNotMoveBackAtRepeatedJunction() {
        let reconciled = RouteSearchPolicy.installedProgress(
            projected: 0.42,
            distanceEstimate: 0.58
        )
        let current = RouteSearchPolicy.currentProgress(
            projected: reconciled,
            persisted: 0.80,
            navigationActive: true
        )

        XCTAssertEqual(current, 0.58)
        XCTAssertFalse(RouteSearchPolicy.isAhead(
            candidateProgress: 0.50,
            currentProgress: current,
            totalRouteDistance: 400_000
        ), "A stop beside an earlier visit to the same junction is already behind the car")
    }

    func testRouteSearchQueriesOnlyTheRemainingRoute() {
        let route = (0...10).map {
            CLLocationCoordinate2D(latitude: 50, longitude: 8 + Double($0) / 100)
        }
        let remaining = RouteSearchPolicy.remainingRouteCoordinates(route, currentProgress: 0.6)
        XCTAssertLessThan(remaining.count, route.count)
        XCTAssertGreaterThanOrEqual(remaining.first?.longitude ?? 0, 8.05)
        XCTAssertEqual(remaining.last?.longitude, route.last?.longitude)
    }

    func testLongRouteSearchDoesNotQueryManyKilometresBehindVehicle() throws {
        let route = (0...100).map {
            CLLocationCoordinate2D(latitude: 45 + Double($0) / 10, longitude: 8)
        }
        let remaining = RouteSearchPolicy.remainingRouteCoordinates(
            route, currentProgress: 0.5
        )
        let first = try XCTUnwrap(remaining.first)
        let firstProgress = try XCTUnwrap(
            RouteGeometryProgress.nearestProgress(of: first, on: route)
        ).progress
        XCTAssertGreaterThanOrEqual(firstProgress, 0.49)
    }

    func testRouteSearchRadiusScalesWithoutFloodingLocalSearch() {
        let short = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50.1, longitude: 8),
        ]
        let long = [
            CLLocationCoordinate2D(latitude: 45, longitude: 8),
            CLLocationCoordinate2D(latitude: 55, longitude: 8),
        ]
        XCTAssertEqual(RouteSearchPolicy.searchRegionSpanMetres(
            routeCoordinates: short, searchPointCount: 5
        ), 15_000, accuracy: 1)
        XCTAssertGreaterThan(RouteSearchPolicy.searchRegionSpanMetres(
            routeCoordinates: long, searchPointCount: 5
        ), 100_000)
        XCTAssertLessThanOrEqual(RouteSearchPolicy.searchRegionSpanMetres(
            routeCoordinates: long, searchPointCount: 5
        ), 150_000)
    }

    func testRouteSearchRegionsOverlapAcrossRegionalRoutes() {
        let route = (0...18).map {
            CLLocationCoordinate2D(latitude: 50 + Double($0) * 0.05, longitude: 8)
        }
        let routeDistance = zip(route, route.dropFirst()).reduce(0.0) {
            $0 + CLLocation(latitude: $1.0.latitude, longitude: $1.0.longitude)
                .distance(from: CLLocation(latitude: $1.1.latitude, longitude: $1.1.longitude))
        }
        let regionSpan = RouteSearchPolicy.searchRegionSpanMetres(
            routeCoordinates: route, searchPointCount: 5
        )

        XCTAssertEqual(regionSpan, routeDistance / 4 * 1.2, accuracy: 5)
        XCTAssertGreaterThan(regionSpan, routeDistance / 4,
                             "Adjacent MapKit search regions must overlap")
    }

    func testAlongRouteSearchAddsBoundedCoverageForLongTrips() {
        func equatorialRoute(longitude: Double) -> [CLLocationCoordinate2D] {
            [
                .init(latitude: 0, longitude: 0),
                .init(latitude: 0, longitude: longitude),
            ]
        }

        XCTAssertEqual(RouteSearchPolicy.searchPointCount(
            routeCoordinates: equatorialRoute(longitude: 1)
        ), 2)
        XCTAssertEqual(RouteSearchPolicy.searchPointCount(
            routeCoordinates: equatorialRoute(longitude: 1.8)
        ), 3)
        XCTAssertEqual(RouteSearchPolicy.searchPointCount(
            routeCoordinates: equatorialRoute(longitude: 9)
        ), 10)
        XCTAssertEqual(RouteSearchPolicy.searchPointCount(
            routeCoordinates: equatorialRoute(longitude: 25)
        ), RouteSearchPolicy.maximumAlongRouteSearchPoints)
        XCTAssertEqual(RouteSearchPolicy.maximumAlongRouteSearchPoints, 20)
    }

    func testRouteSearchBatchLimitsRemainSmallAndBounded() {
        XCTAssertEqual(NavigationSearchBatchPolicy.timeoutNanoseconds, 8_000_000_000)
        XCTAssertEqual(NavigationSearchBatchPolicy.maximumConcurrentMapSearches, 3)
        XCTAssertTrue(NavigationSearchBatchPolicy.shouldContinue(
            isCurrentRequest: true, taskCancelled: false
        ))
        XCTAssertFalse(NavigationSearchBatchPolicy.shouldContinue(
            isCurrentRequest: false, taskCancelled: false
        ))
        XCTAssertFalse(NavigationSearchBatchPolicy.shouldContinue(
            isCurrentRequest: true, taskCancelled: true
        ))
        XCTAssertEqual(NavigationSearchBatchPolicy.maximumConcurrentRouteSearches, 5)
        XCTAssertEqual(NavigationSearchBatchPolicy.maximumConcurrentAmenitySearches, 8)
        XCTAssertEqual(NavigationSearchBatchPolicy.maximumConcurrentDetourCalculations, 3)
        XCTAssertEqual(NavigationSearchBatchPolicy.detourBatches(candidateCount: 0), [])
        XCTAssertEqual(NavigationSearchBatchPolicy.detourBatches(candidateCount: 2), [0..<2])
        XCTAssertEqual(
            NavigationSearchBatchPolicy.detourBatches(candidateCount: 6),
            [0..<3, 3..<6]
        )
        XCTAssertFalse(NavigationSearchBatchPolicy.shouldFinishEarly(
            uniqueResultCount: 20, completedSearches: 1, totalSearches: 5
        ), "One region is not enough geographic coverage")
        XCTAssertFalse(NavigationSearchBatchPolicy.shouldFinishEarly(
            uniqueResultCount: 7, completedSearches: 2, totalSearches: 5
        ))
        XCTAssertTrue(NavigationSearchBatchPolicy.shouldFinishEarly(
            uniqueResultCount: 8, completedSearches: 2, totalSearches: 5
        ))
        XCTAssertFalse(NavigationSearchBatchPolicy.shouldFinishEarly(
            uniqueResultCount: 20, completedSearches: 5, totalSearches: 5
        ), "A completed batch does not need an early-cancellation path")
    }

    func testRouteSearchBatchCountsOverlappingResultsOnlyOnce() {
        let rawResults = ["McDonalds A", "McDonalds A", "Tankstelle B", "Tankstelle B"]
        let uniqueCount = NavigationSearchBatchPolicy.uniqueResultCount(rawResults, areDuplicates: ==)

        XCTAssertEqual(uniqueCount, 2)
        XCTAssertFalse(NavigationSearchBatchPolicy.shouldFinishEarly(
            uniqueResultCount: uniqueCount, completedSearches: 2, totalSearches: 5
        ), "Duplicate POIs from overlapping regions must not cancel searches farther ahead")
    }

    func testDirectionsDeadlinePrecedesRerouteWatchdog() {
        XCTAssertLessThan(
            NavigationDirectionsTimeoutPolicy.routeCalculation,
            NavigationRerouteWatchdogPolicy.timeout
        )
        XCTAssertLessThan(
            NavigationDirectionsTimeoutPolicy.detourCalculation,
            NavigationDirectionsTimeoutPolicy.routeCalculation
        )
        XCTAssertEqual(
            NavigationDirectionsTimeoutPolicy.nanoseconds(for: 8),
            8_000_000_000
        )
    }

    func testRouteComparisonPublishesOnlyForCurrentEligibleRoute() {
        let route = UUID()
        XCTAssertTrue(RouteComparisonPublicationPolicy.mayPublish(
            requestRoute: route, currentRoute: route, stillEligible: true
        ))
        XCTAssertFalse(RouteComparisonPublicationPolicy.mayPublish(
            requestRoute: route, currentRoute: UUID(), stillEligible: true
        ))
        XCTAssertFalse(RouteComparisonPublicationPolicy.mayPublish(
            requestRoute: route, currentRoute: route, stillEligible: false
        ))
    }

    func testRouteSearchRejectsExcessiveOrInvalidDrivingDetours() {
        XCTAssertTrue(RouteSearchPolicy.acceptsDetour(4_500))
        XCTAssertTrue(RouteSearchPolicy.acceptsDetour(20_000))
        XCTAssertFalse(RouteSearchPolicy.acceptsDetour(20_001))
        XCTAssertFalse(RouteSearchPolicy.acceptsDetour(.infinity))
        XCTAssertFalse(RouteSearchPolicy.acceptsDetour(-1))
    }

    func testRouteSearchScalesAcceptableDetourToTripLength() {
        XCTAssertEqual(RouteSearchPolicy.maximumDetour(remainingRouteDistance: 20_000), 3_000)
        XCTAssertEqual(RouteSearchPolicy.maximumDetour(remainingRouteDistance: 200_000), 10_000)
        XCTAssertEqual(RouteSearchPolicy.maximumDetour(remainingRouteDistance: 800_000), 20_000)
        XCTAssertTrue(RouteSearchPolicy.acceptsDetour(
            2_900, remainingRouteDistance: 20_000
        ))
        XCTAssertFalse(RouteSearchPolicy.acceptsDetour(
            3_100, remainingRouteDistance: 20_000
        ))
    }

    func testRouteSearchProgressNeverMovesBackAtRouteCrossing() {
        XCTAssertEqual(RouteSearchPolicy.installedProgress(
            projected: 0.42, distanceEstimate: 0.50
        ), 0.50)
        XCTAssertEqual(RouteSearchPolicy.installedProgress(
            projected: 0.58, distanceEstimate: 0.50
        ), 0.58)
        XCTAssertEqual(RouteSearchPolicy.installedProgress(
            projected: nil, distanceEstimate: 0.50
        ), 0.50)
        XCTAssertNil(RouteSearchPolicy.installedProgress(
            projected: .infinity, distanceEstimate: nil
        ))
    }

    func testRouteSearchRanksSmallUsefulDetourAheadOfEarlierLargeDetour() {
        let earlyLargeDetour = RouteSearchPolicy.rankingScore(
            detourMetres: 8_000, candidateProgress: 0.25,
            currentProgress: 0.20, remainingRouteDistance: 200_000
        )
        let laterSmallDetour = RouteSearchPolicy.rankingScore(
            detourMetres: 500, candidateProgress: 0.30,
            currentProgress: 0.20, remainingRouteDistance: 200_000
        )
        XCTAssertLessThan(laterSmallDetour, earlyLargeDetour)
        XCTAssertEqual(RouteSearchPolicy.rankingScore(
            detourMetres: .infinity, candidateProgress: 0.3,
            currentProgress: 0.2, remainingRouteDistance: 100_000
        ), .greatestFiniteMagnitude)
    }

    func testRouteSearchOnlyEstimatesSmallUnverifiedDetours() throws {
        XCTAssertEqual(
            try XCTUnwrap(RouteSearchPolicy.estimatedDetour(airDistance: 900)),
            1_800,
            accuracy: 0.1
        )
        XCTAssertEqual(RouteSearchPolicy.estimatedDetour(airDistance: 3_000), 6_000)
        XCTAssertNil(RouteSearchPolicy.estimatedDetour(airDistance: 3_001))
        XCTAssertNil(RouteSearchPolicy.estimatedDetour(airDistance: .infinity))
        XCTAssertNil(RouteSearchPolicy.estimatedDetour(airDistance: -1))
    }

    func testRouteSearchDetourAnchorsFollowDrivingDirection() throws {
        let route = [
            CLLocationCoordinate2D(latitude: 50, longitude: 8),
            CLLocationCoordinate2D(latitude: 50, longitude: 8.1)
        ]
        let anchors = try XCTUnwrap(RouteSearchPolicy.detourAnchors(
            routeCoordinates: route, progress: 0.5
        ))
        XCTAssertLessThan(anchors.entry.longitude, anchors.exit.longitude)
        XCTAssertEqual(anchors.baselineMetres, 2_000, accuracy: 5)
    }

    func testRouteSearchShortlistSpreadsDrivingChecksAcrossRouteSections() {
        let candidates = [
            (name: "Early far", progress: 0.10, distance: 900.0),
            (name: "Early best", progress: 0.105, distance: 120.0),
            (name: "Early duplicate", progress: 0.11, distance: 300.0),
            (name: "Middle", progress: 0.35, distance: 250.0),
            (name: "Later", progress: 0.70, distance: 180.0),
        ]

        let shortlist = RouteSearchPolicy.diverseShortlist(
            candidates, maximum: 3,
            progress: { $0.progress }, airDistance: { $0.distance }
        )

        XCTAssertEqual(shortlist.map(\.name), ["Early best", "Middle", "Later"])
    }

    func testRouteSearchShortlistKeepsExactMatchBeforeCloserWeakResult() {
        let candidates = [
            (name: "generic", progress: 0.40, distance: 40.0, relevance: 8.0),
            (name: "mcdonalds", progress: 0.405, distance: 140.0, relevance: 0.0),
        ]

        let shortlist = RouteSearchPolicy.diverseShortlist(
            candidates, maximum: 1,
            progress: { $0.progress }, airDistance: { $0.distance },
            queryRelevance: { $0.relevance }
        )

        XCTAssertEqual(shortlist.map(\.name), ["mcdonalds"])
    }

    func testRouteSearchShortlistHonoursRequestLimitAndEmptyLimit() {
        let candidates = (0..<10).map { (progress: Double($0) / 10, distance: Double($0)) }
        XCTAssertEqual(RouteSearchPolicy.diverseShortlist(
            candidates, maximum: 4,
            progress: { $0.progress }, airDistance: { $0.distance }
        ).count, 4)
        XCTAssertTrue(RouteSearchPolicy.diverseShortlist(
            candidates, maximum: 0,
            progress: { $0.progress }, airDistance: { $0.distance }
        ).isEmpty)
    }

    func testRouteSearchSubtractsDistanceDrivenAnywayFromDetour() throws {
        XCTAssertEqual(try XCTUnwrap(RouteSearchPolicy.additionalDistance(
            viaDistance: 2_750, baselineDistance: 2_000
        )), 750, accuracy: 0.1)
        XCTAssertEqual(try XCTUnwrap(RouteSearchPolicy.additionalDistance(
            viaDistance: 1_900, baselineDistance: 2_000
        )), 0, accuracy: 0.1)
        XCTAssertNil(RouteSearchPolicy.additionalDistance(
            viaDistance: .infinity, baselineDistance: 2_000
        ))
    }

    func testRouteSearchCompletionPublishesOnlyForCurrentGeometryAndQuery() {
        let request = UUID()
        let route = UUID()
        XCTAssertEqual(RouteSearchCompletionPolicy.disposition(
            request: request, currentRequest: request,
            routeGeneration: route, currentRouteGeneration: route,
            query: "McDonald’s", currentQuery: "McDonald’s"
        ), .publish)
    }

    func testRouteSearchResultsDisappearAsSoonAsQueryMateriallyChanges() {
        XCTAssertTrue(RouteSearchPublishedQueryPolicy.matches(
            resultQuery: " McDonald’s ", editedQuery: "mcdonald’s"
        ))
        XCTAssertFalse(RouteSearchPublishedQueryPolicy.matches(
            resultQuery: "McDonald’s", editedQuery: "Burger King"
        ))
        XCTAssertFalse(RouteSearchPublishedQueryPolicy.matches(
            resultQuery: nil, editedQuery: "McDonald’s"
        ))
    }

    func testRouteSearchCanMergeSameNamedPoiCoordinateDrift() {
        let first = CLLocationCoordinate2D(latitude: 50.0000, longitude: 8.0000)
        let nearby = CLLocationCoordinate2D(latitude: 50.0005, longitude: 8.0000)
        XCTAssertTrue(DestinationSearchRankingPolicy.isDuplicate(
            name: "McDonald’s", coordinate: first,
            existingName: "McDonalds", existingCoordinate: nearby,
            toleranceMetres: 80
        ))
        XCTAssertFalse(DestinationSearchRankingPolicy.isDuplicate(
            name: "McDonald’s", coordinate: first,
            existingName: "McDonalds", existingCoordinate: nearby,
            toleranceMetres: 40
        ))
    }

    func testFinalDestinationCannotBecomeDuplicateIntermediateStop() {
        let destination = CLLocationCoordinate2D(latitude: 50.0000, longitude: 8.0000)
        XCTAssertFalse(RouteStopEndpointPolicy.isDistinctFromDestination(
            stop: .init(latitude: 50.0005, longitude: 8.0000),
            destination: destination
        ))
        XCTAssertTrue(RouteStopEndpointPolicy.isDistinctFromDestination(
            stop: .init(latitude: 50.0020, longitude: 8.0000),
            destination: destination
        ))
        XCTAssertTrue(RouteStopEndpointPolicy.isDistinctFromDestination(
            stop: destination, destination: nil
        ))
        XCTAssertFalse(RouteStopEndpointPolicy.isDistinctFromDestination(
            stop: .init(latitude: .nan, longitude: 8), destination: nil
        ))
        XCTAssertFalse(RouteStopEndpointPolicy.isDistinctFromDestination(
            stop: .init(latitude: 91, longitude: 8), destination: nil
        ))
        XCTAssertFalse(RouteStopEndpointPolicy.isDistinctFromDestination(
            stop: .init(latitude: 50, longitude: -181), destination: destination
        ))
        XCTAssertTrue(RouteStopEndpointPolicy.isValid(destination))
        XCTAssertFalse(RouteStopEndpointPolicy.isValid(.init(latitude: 50, longitude: .infinity)))
    }

    func testNavigationDestinationRequiresValidOriginAndTargetCoordinates() {
        XCTAssertTrue(NavigationDestinationCoordinatePolicy.isValid(
            .init(latitude: 50.0147, longitude: 8.3522)
        ))
        XCTAssertFalse(NavigationDestinationCoordinatePolicy.isValid(
            .init(latitude: .nan, longitude: 8.3522)
        ))
        XCTAssertFalse(NavigationDestinationCoordinatePolicy.isValid(
            .init(latitude: -91, longitude: 8.3522)
        ))
        XCTAssertFalse(NavigationDestinationCoordinatePolicy.isValid(
            .init(latitude: 50.0147, longitude: 181)
        ))
    }

    func testRouteSearchCompletionFinishesSpinnerWhenOwnedSearchBecomesStale() {
        let request = UUID()
        XCTAssertEqual(RouteSearchCompletionPolicy.disposition(
            request: request, currentRequest: request,
            routeGeneration: UUID(), currentRouteGeneration: UUID(),
            query: "Tankstelle", currentQuery: "Tankstelle"
        ), .discardAndFinish)
        let route = UUID()
        XCTAssertEqual(RouteSearchCompletionPolicy.disposition(
            request: request, currentRequest: request,
            routeGeneration: route, currentRouteGeneration: route,
            query: "Tankstelle", currentQuery: "Raststätte"
        ), .discardAndFinish)
    }

    func testOlderRouteSearchCannotFinishNewerSearchState() {
        let route = UUID()
        XCTAssertEqual(RouteSearchCompletionPolicy.disposition(
            request: UUID(), currentRequest: UUID(),
            routeGeneration: route, currentRouteGeneration: route,
            query: "Essen", currentQuery: "Essen"
        ), .superseded)
    }

    func testDriveUsageCountsPlausibleMovement() throws {
        let start = CLLocation(coordinate: .init(latitude: 49.8, longitude: 8.3),
                               altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                               course: 0, speed: 14, timestamp: Date(timeIntervalSince1970: 1_000))
        let end = CLLocation(coordinate: .init(latitude: 49.801, longitude: 8.3),
                             altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                             course: 0, speed: 14, timestamp: Date(timeIntervalSince1970: 1_010))
        let segment = try XCTUnwrap(DriveUsageSegmentPolicy.segment(previous: start, current: end))
        XCTAssertGreaterThan(segment.distanceMetres, 100)
        XCTAssertEqual(segment.movingTime, 10)
    }

    func testDriveUsageRejectsNavigationToleratedGpsJump() {
        let start = CLLocation(
            coordinate: .init(latitude: 49.8, longitude: 8.3), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 20,
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let jumped = CLLocation(
            coordinate: .init(latitude: 49.803, longitude: 8.3), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 20,
            timestamp: Date(timeIntervalSince1970: 1_001)
        )

        XCTAssertNil(DriveUsageSegmentPolicy.segment(previous: start, current: jumped))
    }

    func testDriveUsageRetainsPlausibleHighwaySpeed() throws {
        let start = CLLocation(
            coordinate: .init(latitude: 49.8, longitude: 8.3), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 60,
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let end = CLLocation(
            coordinate: .init(latitude: 49.8007, longitude: 8.3), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 60,
            timestamp: Date(timeIntervalSince1970: 1_001)
        )

        XCTAssertNotNil(DriveUsageSegmentPolicy.segment(previous: start, current: end))
    }

    func testDriveUsageRejectsStationaryJitterAndLongGaps() {
        let start = CLLocation(coordinate: .init(latitude: 49.8, longitude: 8.3),
                               altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                               course: 0, speed: 0, timestamp: Date(timeIntervalSince1970: 1_000))
        let jitter = CLLocation(coordinate: .init(latitude: 49.800001, longitude: 8.3),
                                altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                                course: 0, speed: 0, timestamp: Date(timeIntervalSince1970: 1_010))
        let late = CLLocation(coordinate: .init(latitude: 49.9, longitude: 8.3),
                              altitude: 0, horizontalAccuracy: 5, verticalAccuracy: 5,
                              course: 0, speed: 20, timestamp: Date(timeIntervalSince1970: 1_500))
        XCTAssertNil(DriveUsageSegmentPolicy.segment(previous: start, current: jitter))
        XCTAssertNil(DriveUsageSegmentPolicy.segment(previous: start, current: late))
    }

    func testDriveUsageDoesNotCountWholeStoppedIntervalWhenMovementJustResumed() throws {
        let start = CLLocation(
            coordinate: .init(latitude: 49.8, longitude: 8.3), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 0,
            timestamp: Date(timeIntervalSince1970: 1_000)
        )
        let resumed = CLLocation(
            coordinate: .init(latitude: 49.80009, longitude: 8.3), altitude: 0,
            horizontalAccuracy: 5, verticalAccuracy: 5, course: 0, speed: 10,
            timestamp: Date(timeIntervalSince1970: 1_060)
        )
        let segment = try XCTUnwrap(DriveUsageSegmentPolicy.segment(
            previous: start, current: resumed
        ))
        XCTAssertGreaterThan(segment.distanceMetres, 9)
        XCTAssertLessThan(segment.movingTime, 2)
        XCTAssertNotEqual(segment.movingTime, 60)
    }

    func testDriveUsageStatisticsAccumulateTrips() {
        var statistics = DriveUsageStatistics()
        statistics.recordTrip(distanceMetres: 12_500, movingTime: 3_600,
                              endedAt: Date(timeIntervalSince1970: 2_000))
        statistics.recordTrip(distanceMetres: 7_500, movingTime: 1_800,
                              endedAt: Date(timeIntervalSince1970: 3_000))
        XCTAssertEqual(statistics.totalDistanceMetres, 20_000)
        XCTAssertEqual(statistics.totalMovingTime, 5_400)
        XCTAssertEqual(statistics.completedNavigations, 2)
        XCTAssertEqual(statistics.lastTripDistanceMetres, 7_500)
    }

    func testUsageTripTransitionFinalizesOnlyAReplacedMatchingTrip() {
        let previous = UUID()
        let next = UUID()

        XCTAssertTrue(DriveUsageTripTransitionPolicy.shouldFinalize(
            sessionTripID: previous, previousTripID: previous, nextTripID: next
        ))
        XCTAssertFalse(DriveUsageTripTransitionPolicy.shouldFinalize(
            sessionTripID: previous, previousTripID: previous, nextTripID: previous
        ))
        XCTAssertFalse(DriveUsageTripTransitionPolicy.shouldFinalize(
            sessionTripID: UUID(), previousTripID: previous, nextTripID: next
        ))
        XCTAssertFalse(DriveUsageTripTransitionPolicy.shouldFinalize(
            sessionTripID: previous, previousTripID: previous, nextTripID: nil
        ))
    }

    func testUsageSessionSurvivesPauseWithoutPersistingLocations() throws {
        let suite = "DriveUsageSessionTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DriveUsageSessionStore(defaults: defaults)
        let expected = DriveUsageSessionState(
            tripID: UUID(), distanceMetres: 428_000, movingTime: 14_400
        )
        store.save(expected)

        XCTAssertEqual(store.load(), expected)
        let encoded = try XCTUnwrap(defaults.data(forKey: store.key))
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("latitude"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("longitude"))
        store.clear()
        XCTAssertEqual(store.load(), DriveUsageSessionState())
    }

    func testUsageCheckpointOverwritesOlderAggregateWithoutCoordinates() throws {
        let suite = "DriveUsageCheckpointTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = DriveUsageSessionStore(defaults: defaults)
        let tripID = UUID()
        store.save(.init(tripID: tripID, distanceMetres: 1_000, movingTime: 120))
        let latest = DriveUsageSessionState(
            tripID: tripID, distanceMetres: 1_850, movingTime: 181
        )
        store.save(latest)

        XCTAssertEqual(store.load(), latest)
        let encoded = try XCTUnwrap(defaults.data(forKey: store.key))
        let text = try XCTUnwrap(String(data: encoded, encoding: .utf8))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("latitude"))
        XCTAssertFalse(text.localizedCaseInsensitiveContains("longitude"))
    }

    func testRouteOverviewRejectsRemoteVehicleFixButKeepsNearbyDeviation() throws {
        let route = MKMapRect(
            origin: MKMapPoint(.init(latitude: 50.0, longitude: 8.0)),
            size: .init(width: 5_000, height: 5_000)
        )
        let nearby = CLLocationCoordinate2D(latitude: 50.05, longitude: 8.05)
        let remote = CLLocationCoordinate2D(latitude: 48.14, longitude: 11.58)

        XCTAssertNotNil(RouteOverviewMapRectPolicy.vehicleCoordinate(nearby, near: route))
        XCTAssertNil(RouteOverviewMapRectPolicy.vehicleCoordinate(remote, near: route))
        XCTAssertNil(RouteOverviewMapRectPolicy.vehicleCoordinate(
            .init(latitude: .nan, longitude: 8), near: route
        ))
        XCTAssertEqual(
            RouteOverviewMapRectPolicy.vehicleCoordinate(remote, near: nil)?.longitude,
            remote.longitude
        )
    }
}
