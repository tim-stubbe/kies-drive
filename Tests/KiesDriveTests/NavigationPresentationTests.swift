import XCTest
@testable import Kies_Drive

final class NavigationPresentationTests: XCTestCase {
    func testExitNumberAndDirectionAreExtracted() {
        let presentation = NavigationManeuverPresentation("Ausfahrt 69 rechts Richtung Neufahrn nehmen")
        XCTAssertEqual(presentation.exitLabel, "Ausfahrt 69")
        XCTAssertEqual(presentation.direction, .right)
    }

    func testFollowingRoadDefaultsToStraight() {
        XCTAssertEqual(NavigationManeuverPresentation("Der A9 folgen").direction, .straight)
    }
}
