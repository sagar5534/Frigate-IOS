import XCTest
@testable import Frigate

final class MultipartFrameParserTests: XCTestCase {
    /// A minimal valid-enough JPEG body: SOI ... EOI. Content bytes are arbitrary.
    private func jpeg(_ filler: [UInt8] = [0x01, 0x02, 0x03]) -> [UInt8] {
        [0xFF, 0xD8] + filler + [0xFF, 0xD9]
    }

    /// One part exactly as Frigate's `imagestream` writes it.
    private func part(_ body: [UInt8]) -> [UInt8] {
        Array("--frame\r\nContent-Type: image/jpeg\r\n\r\n".utf8) + body + Array("\r\n\r\n".utf8)
    }

    func testASinglePartIsEmittedFromItsOwnTerminatorWithoutWaitingForTheNextBoundary() throws {
        var parser = MultipartFrameParser(boundary: "frame")
        let body = jpeg()

        let frames = try parser.append(part(body))

        // This is the latency property: the next boundary only arrives with the *next* frame,
        // 1/fps later, so waiting for it would delay every frame by a full frame interval.
        XCTAssertEqual(frames.map(Array.init), [body])
    }

    func testConsecutivePartsInOneChunkAllEmit() throws {
        var parser = MultipartFrameParser(boundary: "frame")
        let first = jpeg([0x11])
        let second = jpeg([0x22, 0x23])

        let frames = try parser.append(part(first) + part(second))

        XCTAssertEqual(frames.map(Array.init), [first, second])
    }

    /// WebSocket-free HTTP chunking means arbitrary splits - a boundary, a header, or a JPEG can
    /// arrive one byte at a time and the output must not change.
    func testByteAtATimeDeliveryProducesIdenticalFrames() throws {
        var parser = MultipartFrameParser(boundary: "frame")
        let first = jpeg([0x31, 0x32])
        let second = jpeg([0x41])

        var frames: [Data] = []
        for byte in part(first) + part(second) {
            frames.append(contentsOf: try parser.append([byte]))
        }

        XCTAssertEqual(frames.map(Array.init), [first, second])
    }

    /// A body that happens to contain the boundary text mid-JPEG must not be split: the real
    /// delimiter is CRLF + marker, and compressed data containing a bare "--frame" is survivable
    /// while a torn frame is not.
    func testBoundaryLikeBytesInsideABodyDoNotSplitTheFrame() throws {
        var parser = MultipartFrameParser(boundary: "frame")
        let body = [0xFF, 0xD8] + Array("--frame".utf8) + [0xFF, 0xD9]

        // No JPEG terminator ambiguity here: end the part and start the next one.
        let frames = try parser.append(part(body) + part(jpeg()))

        XCTAssertEqual(frames.first.map(Array.init), body)
        XCTAssertEqual(frames.count, 2)
    }

    /// A body that is not JPEG (no EOI terminator match) is still emitted once the next part's
    /// boundary proves where it ended.
    func testANonJPEGBodyEmitsWhenTheNextBoundaryArrives() throws {
        var parser = MultipartFrameParser(boundary: "frame")
        let body: [UInt8] = [0x00, 0x01, 0x02]

        XCTAssertTrue(try parser.append(part(body)).isEmpty, "no terminator, so nothing to emit yet")
        let frames = try parser.append(part(jpeg()))
        XCTAssertEqual(frames.first.map(Array.init), body)
    }

    func testLeadingNoiseBeforeTheFirstBoundaryIsIgnored() throws {
        var parser = MultipartFrameParser(boundary: "frame")
        let body = jpeg()

        let frames = try parser.append(Array("HTTP noise".utf8) + part(body))

        XCTAssertEqual(frames.map(Array.init), [body])
    }

    func testAlternateBoundaryNamesAreHonoured() throws {
        var parser = MultipartFrameParser(boundary: "xyz")
        let body = jpeg()
        let raw = Array("--xyz\r\nContent-Type: image/jpeg\r\n\r\n".utf8) + body + Array("\r\n\r\n".utf8)

        XCTAssertEqual(try parser.append(raw).map(Array.init), [body])
    }

    func testPartialTrailingDataIsHeldNotEmitted() throws {
        var parser = MultipartFrameParser(boundary: "frame")
        let body = jpeg([0x55, 0x56, 0x57])
        let raw = part(body)

        XCTAssertTrue(try parser.append(Array(raw.dropLast(3))).isEmpty)
        XCTAssertEqual(try parser.append(Array(raw.suffix(3))).map(Array.init), [body])
    }

    /// The stream is endless, so a stream that never yields a boundary must become an error, not
    /// an ever-growing buffer.
    func testABoundarylessStreamOverflowsInsteadOfBufferingForever() {
        var parser = MultipartFrameParser(boundary: "frame")
        let garbage = [UInt8](repeating: 0x42, count: 1 << 20)
        XCTAssertThrowsError(
            try {
                for _ in 0..<16 {
                    _ = try parser.append(garbage)
                }
            }()
        ) { error in
            guard case MultipartFrameParser.ParseError.bufferOverflow = error else {
                return XCTFail("expected .bufferOverflow, got \(error)")
            }
        }
    }
}
