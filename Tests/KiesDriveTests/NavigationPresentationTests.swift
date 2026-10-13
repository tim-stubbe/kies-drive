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
}
