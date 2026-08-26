import XCTest
@testable import Frigate

final class SnapshotAgeBadgeTests: XCTestCase {
    func testJustFetchedReadsNow() {
        XCTAssertEqual(SnapshotAgeBadge.label(age: 0), "Now")
        XCTAssertEqual(SnapshotAgeBadge.label(age: 1.9), "Now")
    }

    func testSecondsAreCountedIndividuallyUnderAMinute() {
        XCTAssertEqual(SnapshotAgeBadge.label(age: 2), "2s ago")
        XCTAssertEqual(SnapshotAgeBadge.label(age: 5), "5s ago")
        XCTAssertEqual(SnapshotAgeBadge.label(age: 59), "59s ago")
    }

    func testMinutesAndBeyondUseRelativeUnits() {
        XCTAssertEqual(SnapshotAgeBadge.label(age: 60), "1m ago")
        XCTAssertEqual(SnapshotAgeBadge.label(age: 120), "2m ago")
        XCTAssertEqual(SnapshotAgeBadge.label(age: 3_600), "1h ago")
        XCTAssertEqual(SnapshotAgeBadge.label(age: 7_200), "2h ago")
        XCTAssertEqual(SnapshotAgeBadge.label(age: 86_400), "1d ago")
    }
}
