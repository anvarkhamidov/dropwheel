import AppKit
import XCTest
@testable import DropwheelCore

final class DropPolicyTests: XCTestCase {
    func testPrefersCopyWhenAllowed() {
        XCTAssertEqual(DropPolicy.operation(for: [.copy, .link, .generic, .move, .delete]), .copy)
    }

    /// ⌘ во время drag в Finder: маска без copy. Раньше колесо возвращало .copy и drop молча отклонялся.
    func testCommandMaskStillAcceptsDrop() {
        XCTAssertEqual(DropPolicy.operation(for: [.generic, .move]), .generic)
    }

    func testControlMaskAcceptsLink() {
        XCTAssertEqual(DropPolicy.operation(for: [.link]), .link)
    }

    func testOptionMaskAcceptsCopy() {
        XCTAssertEqual(DropPolicy.operation(for: [.copy]), .copy)
    }

    func testNeverAcceptsDelete() {
        XCTAssertEqual(DropPolicy.operation(for: [.delete]), [])
        XCTAssertEqual(DropPolicy.operation(for: []), [])
    }
}
