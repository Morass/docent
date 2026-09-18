import XCTest
@testable import DocentKit

final class SafeTextTests: XCTestCase {
    func testEscapeSequencesCannotSurviveIntoOutput() {
        XCTAssertEqual(SafeText.terminal("\u{1B}[2J\u{1B}[HOwned"), "[2J[HOwned")
        XCTAssertEqual(SafeText.terminal("title\u{1B}]0;pwned\u{07}"), "title]0;pwned")
    }

    func testTabsAndNewlinesSurvive() {
        XCTAssertEqual(SafeText.terminal("a\tb\nc"), "a\tb\nc")
    }

    func testC1ControlsAreRemoved() {
        XCTAssertEqual(SafeText.terminal("a\u{9B}31mb"), "a31mb")
    }

    func testOrdinaryTextIsUntouched() {
        XCTAssertEqual(SafeText.terminal("NSString.length — “quoted” ✓"), "NSString.length — “quoted” ✓")
    }
}
