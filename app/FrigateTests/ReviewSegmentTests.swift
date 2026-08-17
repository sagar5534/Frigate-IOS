import XCTest
@testable import Frigate

final class ReviewSegmentTests: XCTestCase {
    func testDecodesCompletedAlertSegment() throws {
        let json = Data("""
        {
          "id": "1700000000.123456-abc123",
          "camera": "front_door",
          "start_time": 1700000000.0,
          "end_time": 1700000030.0,
          "severity": "alert",
          "has_been_reviewed": false,
          "thumb_path": "/media/frigate/clips/review/thumb-front_door-1700000000.123456-abc123.webp",
          "data": {
            "detections": ["1700000000.123456-abc123"],
            "objects": ["person", "person", "car"],
            "sub_labels": [],
            "zones": ["driveway"],
            "audio": []
          }
        }
        """.utf8)

        let segment = try JSONDecoder().decode(ReviewSegment.self, from: json)
        XCTAssertEqual(segment.id, "1700000000.123456-abc123")
        XCTAssertEqual(segment.camera, "front_door")
        XCTAssertEqual(segment.startTime, 1700000000.0)
        XCTAssertEqual(segment.endTime, 1700000030.0)
        XCTAssertEqual(segment.severity, .alert)
        XCTAssertFalse(segment.hasBeenReviewed)
        XCTAssertEqual(segment.data.zones, ["driveway"])
        XCTAssertFalse(segment.isInProgress)
        XCTAssertEqual(segment.duration, 30.0)
        XCTAssertEqual(segment.thumbnailPath, "clips/review/thumb-front_door-1700000000.123456-abc123.webp")
        XCTAssertEqual(segment.objectSummary, "Car, Person")
    }

    func testInProgressSegmentHasNilEndTime() throws {
        let json = Data("""
        {
          "id": "x", "camera": "backyard", "start_time": 100.0, "end_time": null,
          "severity": "detection", "has_been_reviewed": true,
          "thumb_path": "/media/frigate/clips/review/thumb-backyard-x.webp",
          "data": {"detections": [], "objects": [], "sub_labels": [], "zones": [], "audio": []}
        }
        """.utf8)

        let segment = try JSONDecoder().decode(ReviewSegment.self, from: json)
        XCTAssertTrue(segment.isInProgress)
        XCTAssertNil(segment.duration)
    }

    func testUnknownSeverityFallsBackToDetectionInsteadOfThrowing() throws {
        let json = Data("""
        {
          "id": "x", "camera": "backyard", "start_time": 100.0, "end_time": 200.0,
          "severity": "some_future_severity", "has_been_reviewed": false,
          "thumb_path": "/media/frigate/clips/review/thumb-backyard-x.webp",
          "data": {"detections": [], "objects": [], "sub_labels": [], "zones": [], "audio": []}
        }
        """.utf8)

        let segment = try JSONDecoder().decode(ReviewSegment.self, from: json)
        XCTAssertEqual(segment.severity, .detection)
    }

    func testMissingDataSubArraysDecodeAsEmpty() throws {
        let json = Data("""
        {
          "id": "x", "camera": "backyard", "start_time": 100.0, "end_time": 200.0,
          "severity": "detection", "has_been_reviewed": false,
          "thumb_path": "/media/frigate/clips/review/thumb-backyard-x.webp",
          "data": {}
        }
        """.utf8)

        let segment = try JSONDecoder().decode(ReviewSegment.self, from: json)
        XCTAssertEqual(segment.data.objects, [])
        XCTAssertEqual(segment.data.zones, [])
        XCTAssertEqual(segment.objectSummary, "Detection")
    }

    func testThumbnailPathFallsBackWhenPrefixMissing() throws {
        let json = Data("""
        {
          "id": "x", "camera": "backyard", "start_time": 100.0, "end_time": 200.0,
          "severity": "alert", "has_been_reviewed": false,
          "thumb_path": "clips/review/thumb-backyard-x.webp",
          "data": {}
        }
        """.utf8)

        let segment = try JSONDecoder().decode(ReviewSegment.self, from: json)
        XCTAssertEqual(segment.thumbnailPath, "clips/review/thumb-backyard-x.webp")
    }

    func testDecodesListOfSegments() throws {
        let json = Data("""
        [
          {
            "id": "1", "camera": "front_door", "start_time": 100.0, "end_time": 130.0,
            "severity": "alert", "has_been_reviewed": false,
            "thumb_path": "/media/frigate/clips/review/thumb-front_door-1.webp",
            "data": {"detections": [], "objects": ["person"], "sub_labels": [], "zones": [], "audio": []}
          },
          {
            "id": "2", "camera": "backyard", "start_time": 200.0, "end_time": 230.0,
            "severity": "detection", "has_been_reviewed": true,
            "thumb_path": "/media/frigate/clips/review/thumb-backyard-2.webp",
            "data": {"detections": [], "objects": ["cat"], "sub_labels": [], "zones": [], "audio": []}
          }
        ]
        """.utf8)

        let segments = try JSONDecoder().decode([ReviewSegment].self, from: json)
        XCTAssertEqual(segments.map(\.id), ["1", "2"])
    }
}
