import Foundation

/// Incremental parser for a `multipart/x-mixed-replace` stream - the MJPEG tier's wire format.
///
/// Frigate writes each frame as `--<boundary>\r\nContent-Type: image/jpeg\r\n\r\n<jpeg>\r\n\r\n`
/// (`frigate/api/media.py`), forever. Feed it whatever chunks arrive; complete JPEG bodies come
/// out. Two details carry the design:
///
/// - **Body scanning uses `\r\n--<boundary>`** (the spec's real delimiter), not the bare marker,
///   so boundary-looking bytes inside compressed JPEG data can't split a frame.
/// - **A frame is emitted as soon as its own bytes prove it complete** - the body ending in the
///   JPEG end-of-image marker plus the part's closing blank line - rather than waiting for the
///   *next* part's boundary to arrive. The server only sends that boundary with the next frame,
///   one frame interval later; waiting for it would lag the whole feed by 1/fps for no reason.
nonisolated struct MultipartFrameParser {
    private enum Phase {
        /// Before a part: looking for the boundary marker.
        case seekingBoundary
        /// After the boundary: looking for the blank line ending the part headers.
        case seekingHeaderEnd
        /// In a body: looking for its end.
        case readingBody
    }

    enum ParseError: Error, Equatable {
        /// The stream never produced a frame boundary within any plausible frame's worth of bytes -
        /// whatever the server is sending, it is not the multipart JPEG feed this parses.
        case bufferOverflow(bytes: Int)
    }

    /// Far beyond any real frame (a 720p q70 JPEG is ~100-300KB). The stream is endless, so a
    /// buffer that outgrows this is never going to produce a boundary - fail rather than eat RAM.
    private static let maximumBufferedBytes = 8 << 20

    private let marker: [UInt8]
    private let bodyDelimiter: [UInt8]
    private var buffer: [UInt8] = []
    private var phase: Phase = .seekingBoundary
    /// Resume point for searches, so re-scanning after every chunk stays O(new bytes) rather than
    /// re-walking a growing buffer.
    private var scanFrom = 0

    private static let headerEnd: [UInt8] = [0x0D, 0x0A, 0x0D, 0x0A]
    /// JPEG EOI marker plus the part's closing CRLF CRLF: what a finished body ends with.
    private static let bodyTerminator: [UInt8] = [0xFF, 0xD9, 0x0D, 0x0A, 0x0D, 0x0A]

    init(boundary: String) {
        marker = Array("--\(boundary)".utf8)
        bodyDelimiter = [0x0D, 0x0A] + marker
    }

    /// Parses `chunk`, returning any frames it completed.
    mutating func append(_ chunk: some Sequence<UInt8>) throws -> [Data] {
        buffer.append(contentsOf: chunk)
        guard buffer.count <= Self.maximumBufferedBytes else {
            throw ParseError.bufferOverflow(bytes: buffer.count)
        }
        var frames: [Data] = []
        while advance(&frames) {}
        return frames
    }

    /// One phase step. Returns whether it made progress and is worth calling again.
    private mutating func advance(_ frames: inout [Data]) -> Bool {
        switch phase {
        case .seekingBoundary:
            guard let index = find(marker) else {
                holdPosition(for: marker)
                return false
            }
            consume(index + marker.count)
            phase = .seekingHeaderEnd
            return true

        case .seekingHeaderEnd:
            guard let index = find(Self.headerEnd) else {
                holdPosition(for: Self.headerEnd)
                return false
            }
            consume(index + Self.headerEnd.count)
            phase = .readingBody
            return true

        case .readingBody:
            if let index = find(bodyDelimiter) {
                emit(bodyEnding: index, into: &frames)
                consume(index + 2)  // leave the marker itself for .seekingBoundary
                phase = .seekingBoundary
                return true
            }
            if buffer.count >= Self.bodyTerminator.count,
               buffer.suffix(Self.bodyTerminator.count).elementsEqual(Self.bodyTerminator) {
                emit(bodyEnding: buffer.count, into: &frames)
                consume(buffer.count)
                phase = .seekingBoundary
                return false  // buffer is empty; nothing to scan until more arrives
            }
            holdPosition(for: bodyDelimiter)
            return false
        }
    }

    /// The body is everything up to `end`, minus the part's trailing CRLFs.
    private func emit(bodyEnding end: Int, into frames: inout [Data]) {
        var bodyEnd = end
        while bodyEnd > 0, buffer[bodyEnd - 1] == 0x0A || buffer[bodyEnd - 1] == 0x0D {
            bodyEnd -= 1
        }
        guard bodyEnd > 0 else { return }
        frames.append(Data(buffer[0..<bodyEnd]))
    }

    private func find(_ needle: [UInt8]) -> Int? {
        let last = buffer.count - needle.count
        guard last >= 0, scanFrom <= last else { return nil }
        for start in scanFrom...last {
            if buffer[start..<start + needle.count].elementsEqual(needle) {
                return start
            }
        }
        return nil
    }

    /// After a failed search, remember how far is *definitely* clear, keeping enough tail that a
    /// needle split across two chunks is still found.
    private mutating func holdPosition(for needle: [UInt8]) {
        scanFrom = max(0, buffer.count - needle.count + 1)
    }

    private mutating func consume(_ count: Int) {
        buffer.removeFirst(count)
        scanFrom = 0
    }
}
