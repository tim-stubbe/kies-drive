import XCTest
@testable import Kies_Drive

final class NavigationPresentationTests: XCTestCase {
    func testExitNumberAndDirectionAreExtracted() {
        let presentation = NavigationManeuverPresentation("Ausfahrt 69 rechts Richtung Neufahrn nehmen")
        XCTAssertEqual(presentation.exitLabel, "Ausfahrt 69")
        XCTAssertEqual(presentation.direction, .right)
        XCTAssertEqual(presentation.destinationLabel, "Neufahrn nehmen")
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
            nextManeuver: .init(instruction: "Rechts abbiegen"), routeLock: nil,
            navigationActive: true, recordedAt: Date(timeIntervalSince1970: 1))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])

        XCTAssertEqual(object["heading_degrees"] as? Double, 180)
        XCTAssertEqual(object["speed_kmh"] as? Double, 90)
        XCTAssertNotNil(object["active_route"])
        XCTAssertNotNil(object["next_maneuver"])
        XCTAssertEqual(object["navigation_active"] as? Bool, true)
        XCTAssertNil(object["headingDegrees"])
    }

    func testSpeechInstructionsRemoveSymbolsAndSoundLikeSentences() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("rechts ↗ Richtung A 66 / Wiesbaden", distance: 112),
            "In 100 Metern, Rechts Richtung A 66, Wiesbaden."
        )
    }

    func testSpeechInstructionUsesImmediateCueNearManeuver() {
        XCTAssertEqual(
            NavigationSpeechFormatter.spokenText("links abbiegen", distance: 20),
            "Jetzt, Links abbiegen."
        )
    }

    func testAnnouncementStagesAdaptToRoadSpeed() {
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 850, speedKmh: 120), .early)
        XCTAssertNil(NavigationAnnouncementStage.stage(distance: 850, speedKmh: 50))
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 200, speedKmh: 50), .prepare)
        XCTAssertEqual(NavigationAnnouncementStage.stage(distance: 30, speedKmh: 50), .now)
    }
}
