import XCTest
@testable import Frigate

final class EventFiltersTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_700_000_000) // 2023-11-14 22:13:20 UTC

    func testDefaultFiltersIsDefault() {
        XCTAssertTrue(EventFilters().isDefault)
    }

    func testNonDefaultFiltersIsNotDefault() {
        var filters = EventFilters()
        filters.severity = .alert
        XCTAssertFalse(filters.isDefault)
    }

    func testLast24HoursBounds() {
        let bounds = EventFilters.TimeRange.last24Hours.bounds(now: now)
        XCTAssertEqual(bounds.before, now.timeIntervalSince1970)
        XCTAssertEqual(bounds.after, now.timeIntervalSince1970 - 24 * 3600)
    }

    func testLast7DaysBounds() {
        let bounds = EventFilters.TimeRange.last7Days.bounds(now: now)
        XCTAssertEqual(bounds.before, now.timeIntervalSince1970)
        XCTAssertEqual(bounds.after, now.timeIntervalSince1970 - 7 * 24 * 3600)
    }

    func testTodayBoundsStartsAtMidnight() {
        let bounds = EventFilters.TimeRange.today.bounds(now: now)
        let startOfDay = Calendar.current.startOfDay(for: now)
        XCTAssertEqual(bounds.after, startOfDay.timeIntervalSince1970)
        XCTAssertEqual(bounds.before, now.timeIntervalSince1970)
    }
}
