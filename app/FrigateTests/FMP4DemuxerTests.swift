import CoreMedia
import XCTest
@testable import Frigate

/// The demuxer is exercised against streams built by `FMP4Fixture`, box by box, using real
/// H.264/HEVC parameter sets - VideoToolbox validates them, so they cannot be lorem ipsum. That
/// keeps the tests hermetic while still covering the exact byte layout go2rtc emits.
final class FMP4DemuxerTests: XCTestCase {
    private var demuxer = FMP4Demuxer()

    override func setUp() {
        super.setUp()
        demuxer = FMP4Demuxer()
    }

    // MARK: Init segment

    func testH264InitSegmentProducesTheVideoTrack() throws {
        let events = try demuxer.append(Data(FMP4Fixture.initSegment()))

        guard case .track(let track)? = events.first, events.count == 1 else {
            return XCTFail("expected exactly one track event, got \(events)")
        }
        XCTAssertEqual(track.trackID, 1)
        XCTAssertEqual(track.timescale, 90000)
        let dimensions = CMVideoFormatDescriptionGetDimensions(track.formatDescription)
        XCTAssertEqual(dimensions.width, 1280)
        XCTAssertEqual(dimensions.height, 720)
    }

    func testHEVCInitSegmentProducesTheVideoTrack() throws {
        let entry = FMP4Fixture.box("hvc1", FMP4Fixture.visualSampleEntryFields(), FMP4Fixture.hvcC())
        let events = try demuxer.append(Data(FMP4Fixture.initSegment(sampleEntry: entry)))

        guard case .track(let track)? = events.first else {
            return XCTFail("expected a track event, got \(events)")
        }
        let dimensions = CMVideoFormatDescriptionGetDimensions(track.formatDescription)
        XCTAssertEqual(dimensions.width, 1920)
        XCTAssertEqual(dimensions.height, 1080)
    }

    /// The codec handshake requests video only, but a server that sends something else anyway must
    /// produce a diagnosable error, not a crash or a silent black screen.
    func testAudioOnlyInitSegmentIsUnsupported() {
        let entry = FMP4Fixture.box("mp4a", FMP4Fixture.visualSampleEntryFields())
        XCTAssertThrowsError(try demuxer.append(Data(FMP4Fixture.initSegment(sampleEntry: entry)))) { error in
            guard case FMP4Demuxer.DemuxError.unsupported = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
        }
    }

    // MARK: Fragments

    func testFragmentProducesSamplesWithTimingAndSyncFlags() throws {
        _ = try demuxer.append(Data(FMP4Fixture.initSegment()))
        let key = FMP4Fixture.SampleSpec(bytes: [0x00, 0x00, 0x00, 0x02, 0x65, 0x88], isSync: true)
        let delta = FMP4Fixture.SampleSpec(bytes: [0x00, 0x00, 0x00, 0x02, 0x41, 0x9A])
        let events = try demuxer.append(Data(FMP4Fixture.fragment(baseDecodeTime: 90000, samples: [key, delta])))

        guard case .samples(let samples)? = events.first, events.count == 1 else {
            return XCTFail("expected one samples event, got \(events)")
        }
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(Array(samples[0].data), key.bytes)
        XCTAssertEqual(Array(samples[1].data), delta.bytes)
        XCTAssertTrue(samples[0].isSync)
        XCTAssertFalse(samples[1].isSync)
        XCTAssertEqual(samples[0].decodeTime, 90000)
        XCTAssertEqual(samples[1].decodeTime, 93000)
        XCTAssertEqual(samples[0].presentationTime, 90000, "no composition offset means PTS == DTS")
        XCTAssertEqual(samples[0].duration, 3000)
    }

    func testCompositionOffsetsShiftPresentationTime() throws {
        _ = try demuxer.append(Data(FMP4Fixture.initSegment()))
        let sample = FMP4Fixture.SampleSpec(bytes: [0x00, 0x00, 0x00, 0x01, 0x65], compositionOffset: 1500, isSync: true)
        let events = try demuxer.append(Data(FMP4Fixture.fragment(baseDecodeTime: 0, samples: [sample])))

        guard case .samples(let samples)? = events.first else {
            return XCTFail("expected samples, got \(events)")
        }
        XCTAssertEqual(samples[0].decodeTime, 0)
        XCTAssertEqual(samples[0].presentationTime, 1500)
    }

    func testConsecutiveFragmentsCarryTheirOwnBaseTimes() throws {
        _ = try demuxer.append(Data(FMP4Fixture.initSegment()))
        let sample = FMP4Fixture.SampleSpec(bytes: [0x00, 0x00, 0x00, 0x01, 0x65], isSync: true)
        _ = try demuxer.append(Data(FMP4Fixture.fragment(baseDecodeTime: 0, samples: [sample])))
        let events = try demuxer.append(Data(FMP4Fixture.fragment(baseDecodeTime: 3000, samples: [sample])))

        guard case .samples(let samples)? = events.first else {
            return XCTFail("expected samples, got \(events)")
        }
        XCTAssertEqual(samples[0].decodeTime, 3000)
    }

    /// The whole point of an *incremental* demuxer: WebSocket message boundaries and box
    /// boundaries have no relationship, so any split must produce identical output.
    func testChunkedDeliveryProducesIdenticalEvents() throws {
        let sampleA = FMP4Fixture.SampleSpec(bytes: (0..<40).map { UInt8($0) }, isSync: true)
        let sampleB = FMP4Fixture.SampleSpec(bytes: (40..<90).map { UInt8($0) })
        let stream = FMP4Fixture.initSegment() + FMP4Fixture.fragment(baseDecodeTime: 500, samples: [sampleA, sampleB])

        var tracks = 0
        var samples: [FMP4Demuxer.Sample] = []
        for start in stride(from: 0, to: stream.count, by: 7) {
            let chunk = Array(stream[start..<min(start + 7, stream.count)])
            for event in try demuxer.append(Data(chunk)) {
                switch event {
                case .track: tracks += 1
                case .samples(let batch): samples.append(contentsOf: batch)
                }
            }
        }

        XCTAssertEqual(tracks, 1)
        XCTAssertEqual(samples.count, 2)
        XCTAssertEqual(Array(samples[0].data), sampleA.bytes)
        XCTAssertEqual(Array(samples[1].data), sampleB.bytes)
        XCTAssertEqual(samples[1].decodeTime, 3500)
    }

    func testFragmentBeforeInitSegmentIsMalformed() {
        let sample = FMP4Fixture.SampleSpec(bytes: [0x00], isSync: true)
        XCTAssertThrowsError(try demuxer.append(Data(FMP4Fixture.fragment(baseDecodeTime: 0, samples: [sample])))) { error in
            guard case FMP4Demuxer.DemuxError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    /// go2rtc never uses absolute file offsets - and in a stream that discards consumed bytes they
    /// cannot be honoured, so pretending would corrupt video. Reject loudly instead.
    func testAbsoluteBaseDataOffsetAddressingIsRejected() throws {
        _ = try demuxer.append(Data(FMP4Fixture.initSegment()))
        let tfhd = FMP4Fixture.fullBox("tfhd", version: 0, flags: 0x01, FMP4Fixture.u32(1), FMP4Fixture.u64(0))
        let tfdt = FMP4Fixture.fullBox("tfdt", version: 0, flags: 0, FMP4Fixture.u32(0))
        let moof = FMP4Fixture.box("moof", FMP4Fixture.box("traf", tfhd, tfdt))

        XCTAssertThrowsError(try demuxer.append(Data(moof))) { error in
            guard case FMP4Demuxer.DemuxError.unsupported = error else {
                return XCTFail("expected .unsupported, got \(error)")
            }
        }
    }

    /// A trun that promises more bytes than its mdat delivers must be an error, not an
    /// out-of-bounds read into whatever box arrives next.
    func testSampleReachingOutsideItsMdatIsMalformed() throws {
        _ = try demuxer.append(Data(FMP4Fixture.initSegment()))
        let sample = FMP4Fixture.SampleSpec(bytes: Array(repeating: 0xAB, count: 60), isSync: true)
        var bytes = FMP4Fixture.fragment(baseDecodeTime: 0, samples: [sample])
        let truncatedMdat = FMP4Fixture.box("mdat", Array(repeating: 0xAB, count: 5))
        bytes.replaceSubrange((bytes.count - 68)..., with: truncatedMdat)

        XCTAssertThrowsError(try demuxer.append(Data(bytes))) { error in
            guard case FMP4Demuxer.DemuxError.malformed = error else {
                return XCTFail("expected .malformed, got \(error)")
            }
        }
    }

    // MARK: Codec configuration records

    func testParseAVCConfigExtractsParameterSetsAndNALLength() throws {
        let payload: [UInt8] = [1, 0x64, 0x00, 0x1F, 0xFF, 0xE1]
            + FMP4Fixture.u16(FMP4Fixture.sps.count) + FMP4Fixture.sps
            + [1] + FMP4Fixture.u16(FMP4Fixture.pps.count) + FMP4Fixture.pps
        let config = try FMP4Demuxer.parseAVCConfig(payload)

        XCTAssertEqual(config.nalUnitHeaderLength, 4)
        XCTAssertEqual(config.parameterSets, [FMP4Fixture.sps, FMP4Fixture.pps])
    }

    func testParseHEVCConfigExtractsParameterSetsInArrayOrder() throws {
        let payload = Array(FMP4Fixture.hvcC()[8...])  // strip the box header the helper adds
        let config = try FMP4Demuxer.parseHEVCConfig(payload)

        XCTAssertEqual(config.nalUnitHeaderLength, 4)
        XCTAssertEqual(config.parameterSets, [FMP4Fixture.hevcVPS, FMP4Fixture.hevcSPS, FMP4Fixture.hevcPPS])
    }

    func testTruncatedAVCConfigIsMalformed() {
        XCTAssertThrowsError(try FMP4Demuxer.parseAVCConfig([1, 0x64, 0x00]))
    }

    // MARK: Sample buffers

    func testSampleBufferCarriesTimingAndSyncAttachment() throws {
        guard case .track(let track)? = try demuxer.append(Data(FMP4Fixture.initSegment())).first else {
            return XCTFail("no track")
        }
        let sample = FMP4Demuxer.Sample(
            data: Data([0x00, 0x00, 0x00, 0x01, 0x41]),
            decodeTime: 90000,
            presentationTime: 93000,
            duration: 3000,
            isSync: false
        )
        let buffer = try VideoSampleBufferFactory.make(sample, track: track)

        XCTAssertEqual(CMSampleBufferGetPresentationTimeStamp(buffer), CMTime(value: 93000, timescale: 90000))
        XCTAssertEqual(CMSampleBufferGetDecodeTimeStamp(buffer), CMTime(value: 90000, timescale: 90000))
        XCTAssertEqual(CMSampleBufferGetDuration(buffer), CMTime(value: 3000, timescale: 90000))
        XCTAssertEqual(CMSampleBufferGetTotalSampleSize(buffer), 5)

        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
        let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments!, 0), to: CFDictionary.self) as NSDictionary
        XCTAssertEqual(first[kCMSampleAttachmentKey_NotSync] as? Bool, true)
    }

    func testSyncSampleBufferHasNoNotSyncAttachment() throws {
        guard case .track(let track)? = try demuxer.append(Data(FMP4Fixture.initSegment())).first else {
            return XCTFail("no track")
        }
        let sample = FMP4Demuxer.Sample(
            data: Data([0x00, 0x00, 0x00, 0x01, 0x65]),
            decodeTime: 0,
            presentationTime: 0,
            duration: 3000,
            isSync: true
        )
        let buffer = try VideoSampleBufferFactory.make(sample, track: track)

        let attachments = CMSampleBufferGetSampleAttachmentsArray(buffer, createIfNecessary: false)
        if let attachments, CFArrayGetCount(attachments) > 0 {
            let first = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFDictionary.self) as NSDictionary
            XCTAssertNil(first[kCMSampleAttachmentKey_NotSync])
        }
    }
}
