import CoreMedia
import Foundation

/// Incremental demuxer for the live fMP4 byte stream go2rtc's MSE endpoint produces: an init
/// segment (`ftyp` + `moov`), then an endless run of `moof` + `mdat` fragment pairs.
///
/// Hand-written on purpose. No library consumes a *live* fMP4 byte stream - the survey is in
/// ADR-012 - and the subset a live stream needs is small: this reads exactly the boxes go2rtc
/// writes and rejects, loudly, the ones it never does (absolute `base_data_offset` addressing,
/// a `trun` with no data offset). VideoToolbox does all actual decoding; this type only locates
/// samples and their timing so `CMSampleBuffer`s can be handed to an `AVSampleBufferDisplayLayer`.
///
/// Feed it whatever byte chunks arrive; it buffers across chunk boundaries and emits events as
/// boxes complete. Byte-order is big-endian throughout (ISO 14496-12).
nonisolated struct FMP4Demuxer {
    /// The stream's video track, known once the init segment has been parsed.
    struct VideoTrack {
        let trackID: UInt32
        /// Ticks per second for every timestamp in `Sample`.
        let timescale: CMTimeScale
        let formatDescription: CMVideoFormatDescription
    }

    /// One video sample (an access unit), AVCC/HVCC length-prefixed exactly as it sat in `mdat` -
    /// which is the layout `CMSampleBuffer` wants, so the bytes pass through untouched.
    struct Sample {
        let data: Data
        /// In `VideoTrack.timescale` units.
        let decodeTime: Int64
        let presentationTime: Int64
        let duration: Int64
        let isSync: Bool
    }

    enum Event {
        case track(VideoTrack)
        case samples([Sample])
    }

    enum DemuxError: Error, Equatable {
        /// The stream violates the container format - nothing a retry of the same bytes can fix.
        case malformed(String)
        /// Valid ISO-BMFF, but a shape this demuxer deliberately does not handle.
        case unsupported(String)
    }

    private static let maximumBoxSize = 32 << 20

    private var buffer: [UInt8] = []
    private var cursor = 0
    private var track: VideoTrack?
    private var trexDefaults: [UInt32: SampleDefaults] = [:]
    private var pendingFragment: Fragment?

    /// Parses whatever complete boxes `data` completes, holding the remainder for the next call.
    mutating func append(_ data: Data) throws -> [Event] {
        buffer.append(contentsOf: data)
        var events: [Event] = []

        while let box = try nextTopLevelBox() {
            switch box.type {
            case "moov":
                let track = try parseMoov(box)
                self.track = track
                events.append(.track(track))
            case "moof":
                guard track != nil else { throw DemuxError.malformed("moof before moov") }
                pendingFragment = try parseMoof(box)
            case "mdat":
                if let fragment = pendingFragment {
                    pendingFragment = nil
                    let samples = try extractSamples(fragment, mdat: box)
                    if !samples.isEmpty {
                        events.append(.samples(samples))
                    }
                }
            default:
                break  // ftyp/styp/sidx/free/…: nothing in them we need.
            }
            cursor = box.range.upperBound
        }

        compact()
        return events
    }

    // MARK: Box scanning

    private struct Box {
        let type: String
        /// The whole box, header included, as buffer indices.
        let range: Range<Int>
        /// The content after the header.
        let payload: Range<Int>
    }

    /// The complete box at `cursor`, or `nil` while its bytes are still arriving.
    private func nextTopLevelBox() throws -> Box? {
        guard let box = try readBoxHeader(at: cursor, limit: buffer.count, requireComplete: false) else {
            return nil
        }
        guard box.range.upperBound <= buffer.count else { return nil }
        return box
    }

    /// Reads one box header. `requireComplete` distinguishes walking *inside* an already-complete
    /// parent (where a child overrunning the parent is corruption) from the top level (where an
    /// overrun just means the rest hasn't arrived yet).
    private func readBoxHeader(at start: Int, limit: Int, requireComplete: Bool) throws -> Box? {
        guard limit - start >= 8 else {
            if requireComplete { throw DemuxError.malformed("truncated box header") }
            return nil
        }
        var size = Int(u32(at: start))
        let type = fourCC(at: start + 4)
        var headerLength = 8
        if size == 1 {
            guard limit - start >= 16 else {
                if requireComplete { throw DemuxError.malformed("truncated large box header") }
                return nil
            }
            let large = u64(at: start + 8)
            guard let converted = Int(exactly: large) else { throw DemuxError.malformed("box size overflow") }
            size = converted
            headerLength = 16
        }
        // size 0 means "to end of file", which a live stream doesn't have.
        guard size >= headerLength else { throw DemuxError.unsupported("box '\(type)' with size \(size)") }
        // The top-level loop buffers until a box completes, and the size comes off the wire - a
        // lying header must be an error, not an instruction to buffer gigabytes. Real MSE
        // fragments are well under a megabyte; recordings-scale mdats do not appear on this path.
        guard size <= Self.maximumBoxSize else {
            throw DemuxError.malformed("box '\(type)' claims \(size) bytes")
        }
        let end = start + size
        if requireComplete {
            guard end <= limit else { throw DemuxError.malformed("box '\(type)' overruns its parent") }
        }
        return Box(type: type, range: start..<end, payload: (start + headerLength)..<end)
    }

    /// All child boxes filling `range`, which must already be fully buffered.
    private func childBoxes(in range: Range<Int>) throws -> [Box] {
        var children: [Box] = []
        var offset = range.lowerBound
        while offset < range.upperBound {
            guard let box = try readBoxHeader(at: offset, limit: range.upperBound, requireComplete: true) else {
                throw DemuxError.malformed("truncated child box")
            }
            children.append(box)
            offset = box.range.upperBound
        }
        return children
    }

    private func firstChild(_ type: String, of box: Box) throws -> Box? {
        try childBoxes(in: box.payload).first { $0.type == type }
    }

    /// Drops consumed bytes. A pending fragment pins the buffer at its `moof`, because the sample
    /// offsets in it are relative to that box and the `mdat` they point into is still arriving.
    private mutating func compact() {
        let keep = pendingFragment.map { min($0.moofStart, cursor) } ?? cursor
        guard keep > 0 else { return }
        buffer.removeFirst(keep)
        cursor -= keep
        pendingFragment?.moofStart -= keep
    }

    // MARK: Init segment (moov)

    private mutating func parseMoov(_ moov: Box) throws -> VideoTrack {
        var video: VideoTrack?
        var defaults: [UInt32: SampleDefaults] = [:]

        for child in try childBoxes(in: moov.payload) {
            switch child.type {
            case "trak":
                if video == nil {
                    video = try parseTrak(child)
                }
            case "mvex":
                for trex in try childBoxes(in: child.payload) where trex.type == "trex" {
                    let (trackID, trackDefaults) = try parseTrex(trex)
                    defaults[trackID] = trackDefaults
                }
            default:
                break
            }
        }

        guard let video else {
            throw DemuxError.unsupported("no H.264/H.265 video track in init segment")
        }
        trexDefaults = defaults
        return video
    }

    /// A `VideoTrack` if this trak is playable video, `nil` if it is some other media (the codec
    /// handshake requests video only, but skipping cleanly beats trusting that).
    private func parseTrak(_ trak: Box) throws -> VideoTrack? {
        guard let tkhd = try firstChild("tkhd", of: trak) else {
            throw DemuxError.malformed("trak without tkhd")
        }
        try require(!tkhd.payload.isEmpty, "empty tkhd")
        let tkhdVersion = u8(at: tkhd.payload.lowerBound)
        // After version+flags: creation and modification times (4 or 8 bytes each), then track ID.
        let trackIDOffset = tkhd.payload.lowerBound + 4 + (tkhdVersion == 1 ? 16 : 8)
        try require(trackIDOffset + 4 <= tkhd.payload.upperBound, "truncated tkhd")
        let trackID = u32(at: trackIDOffset)

        guard let mdia = try firstChild("mdia", of: trak),
              let mdhd = try firstChild("mdhd", of: mdia)
        else { throw DemuxError.malformed("trak without mdia/mdhd") }

        try require(!mdhd.payload.isEmpty, "empty mdhd")
        let mdhdVersion = u8(at: mdhd.payload.lowerBound)
        let timescaleOffset = mdhd.payload.lowerBound + 4 + (mdhdVersion == 1 ? 16 : 8)
        try require(timescaleOffset + 4 <= mdhd.payload.upperBound, "truncated mdhd")
        let timescale = u32(at: timescaleOffset)
        guard let cmTimescale = CMTimeScale(exactly: timescale), cmTimescale > 0 else {
            throw DemuxError.malformed("invalid media timescale \(timescale)")
        }

        guard let minf = try firstChild("minf", of: mdia),
              let stbl = try firstChild("stbl", of: minf),
              let stsd = try firstChild("stsd", of: stbl)
        else { throw DemuxError.malformed("trak without stbl/stsd") }

        guard let format = try parseSampleDescription(stsd) else { return nil }
        return VideoTrack(trackID: trackID, timescale: cmTimescale, formatDescription: format)
    }

    /// The `CMVideoFormatDescription` for the first sample entry, or `nil` for a non-video codec.
    private func parseSampleDescription(_ stsd: Box) throws -> CMVideoFormatDescription? {
        // stsd is a full box: version+flags (4), entry count (4), then the entries as boxes.
        let entriesStart = stsd.payload.lowerBound + 8
        try require(entriesStart <= stsd.payload.upperBound, "truncated stsd")
        guard let entry = try readBoxHeader(at: entriesStart, limit: stsd.payload.upperBound, requireComplete: true) else {
            throw DemuxError.malformed("empty stsd")
        }

        let isH264 = entry.type == "avc1" || entry.type == "avc3"
        let isHEVC = entry.type == "hvc1" || entry.type == "hev1"
        guard isH264 || isHEVC else { return nil }

        // A VisualSampleEntry carries 78 bytes of fixed fields (SampleEntry's 8 + width/height/
        // resolution/etc.) before its child boxes - where avcC/hvcC lives.
        let configStart = entry.payload.lowerBound + 78
        try require(configStart <= entry.payload.upperBound, "truncated \(entry.type) sample entry")
        let configBoxes = try childBoxes(in: configStart..<entry.payload.upperBound)

        if isH264 {
            guard let avcC = configBoxes.first(where: { $0.type == "avcC" }) else {
                throw DemuxError.malformed("\(entry.type) without avcC")
            }
            let config = try Self.parseAVCConfig(Array(buffer[avcC.payload]))
            return try Self.makeFormatDescription(
                parameterSets: config.parameterSets,
                nalUnitHeaderLength: config.nalUnitHeaderLength,
                hevc: false
            )
        } else {
            guard let hvcC = configBoxes.first(where: { $0.type == "hvcC" }) else {
                throw DemuxError.malformed("\(entry.type) without hvcC")
            }
            let config = try Self.parseHEVCConfig(Array(buffer[hvcC.payload]))
            return try Self.makeFormatDescription(
                parameterSets: config.parameterSets,
                nalUnitHeaderLength: config.nalUnitHeaderLength,
                hevc: true
            )
        }
    }

    private func parseTrex(_ trex: Box) throws -> (UInt32, SampleDefaults) {
        // Full box: version+flags, track ID, default sample description index / duration / size / flags.
        try require(trex.payload.count >= 24, "truncated trex")
        let base = trex.payload.lowerBound
        let trackID = u32(at: base + 4)
        return (trackID, SampleDefaults(
            duration: u32(at: base + 12),
            size: u32(at: base + 16),
            flags: u32(at: base + 20)
        ))
    }

    // MARK: Fragments (moof + mdat)

    private struct SampleDefaults {
        var duration: UInt32 = 0
        var size: UInt32 = 0
        var flags: UInt32 = 0
    }

    private struct Fragment {
        /// Buffer index of the moof's first byte - what every sample offset is relative to.
        var moofStart: Int
        var samples: [SampleDescriptor]
    }

    private struct SampleDescriptor {
        /// Relative to the start of the moof box.
        let offset: Int
        let size: Int
        let decodeTime: Int64
        let presentationTime: Int64
        let duration: Int64
        let isSync: Bool
    }

    private func parseMoof(_ moof: Box) throws -> Fragment {
        guard let track else { throw DemuxError.malformed("moof before moov") }
        var descriptors: [SampleDescriptor] = []

        for traf in try childBoxes(in: moof.payload) where traf.type == "traf" {
            let children = try childBoxes(in: traf.payload)
            guard let tfhd = children.first(where: { $0.type == "tfhd" }) else {
                throw DemuxError.malformed("traf without tfhd")
            }
            let header = try parseTfhd(tfhd)
            guard header.trackID == track.trackID else { continue }
            if header.hasAbsoluteBaseOffset {
                // Absolute file offsets are meaningless in an endless stream where "the file" is a
                // window we discard as we go. go2rtc (and CMAF generally) uses default-base-is-moof.
                throw DemuxError.unsupported("base-data-offset addressing")
            }

            guard let tfdt = children.first(where: { $0.type == "tfdt" }) else {
                // Without a decode time the samples cannot be placed on the timeline at all.
                throw DemuxError.unsupported("fragment without tfdt")
            }
            var decodeTime = try parseTfdt(tfdt)

            let trexDefault = trexDefaults[header.trackID] ?? SampleDefaults()
            let defaults = SampleDefaults(
                duration: header.defaultSampleDuration ?? trexDefault.duration,
                size: header.defaultSampleSize ?? trexDefault.size,
                flags: header.defaultSampleFlags ?? trexDefault.flags
            )

            for trun in children where trun.type == "trun" {
                try appendRunSamples(
                    trun,
                    moofStart: moof.range.lowerBound,
                    defaults: defaults,
                    decodeTime: &decodeTime,
                    into: &descriptors
                )
            }
        }

        return Fragment(moofStart: moof.range.lowerBound, samples: descriptors)
    }

    private struct TrackFragmentHeader {
        let trackID: UInt32
        let hasAbsoluteBaseOffset: Bool
        let defaultSampleDuration: UInt32?
        let defaultSampleSize: UInt32?
        let defaultSampleFlags: UInt32?
    }

    private func parseTfhd(_ tfhd: Box) throws -> TrackFragmentHeader {
        var reader = Reader(buffer: buffer, range: tfhd.payload)
        let flags = try reader.u32() & 0x00FF_FFFF
        let trackID = try reader.u32()
        let hasAbsoluteBaseOffset = flags & 0x01 != 0
        if hasAbsoluteBaseOffset { try reader.skip(8) }
        if flags & 0x02 != 0 { try reader.skip(4) }  // sample-description-index
        let duration = flags & 0x08 != 0 ? try reader.u32() : nil
        let size = flags & 0x10 != 0 ? try reader.u32() : nil
        let sampleFlags = flags & 0x20 != 0 ? try reader.u32() : nil
        return TrackFragmentHeader(
            trackID: trackID,
            hasAbsoluteBaseOffset: hasAbsoluteBaseOffset,
            defaultSampleDuration: duration,
            defaultSampleSize: size,
            defaultSampleFlags: sampleFlags
        )
    }

    private func parseTfdt(_ tfdt: Box) throws -> Int64 {
        var reader = Reader(buffer: buffer, range: tfdt.payload)
        let version = try reader.u32() >> 24
        let raw = version == 1 ? try reader.u64() : UInt64(try reader.u32())
        guard let time = Int64(exactly: raw) else { throw DemuxError.malformed("tfdt overflow") }
        return time
    }

    private func appendRunSamples(
        _ trun: Box,
        moofStart: Int,
        defaults: SampleDefaults,
        decodeTime: inout Int64,
        into descriptors: inout [SampleDescriptor]
    ) throws {
        var reader = Reader(buffer: buffer, range: trun.payload)
        let versionAndFlags = try reader.u32()
        let version = versionAndFlags >> 24
        let flags = versionAndFlags & 0x00FF_FFFF
        let sampleCount = try reader.u32()
        // The count comes off the wire. With no per-sample fields present the loop below reads
        // nothing per iteration, so nothing else bounds it - and a stream is entitled to lie.
        try require(sampleCount <= 100_000, "implausible trun sample count \(sampleCount)")

        guard flags & 0x01 != 0 else {
            // Legal per spec ("continue after the previous run"), but go2rtc always writes the
            // offset and inferring it is exactly the kind of silent guess that corrupts video.
            throw DemuxError.unsupported("trun without data offset")
        }
        let dataOffset = Int(Int32(bitPattern: try reader.u32()))
        guard dataOffset >= 0 else { throw DemuxError.malformed("negative trun data offset") }

        let firstSampleFlags = flags & 0x04 != 0 ? try reader.u32() : nil
        var offset = dataOffset

        for index in 0..<sampleCount {
            let duration = flags & 0x100 != 0 ? try reader.u32() : defaults.duration
            let size = flags & 0x200 != 0 ? try reader.u32() : defaults.size
            let explicitFlags = flags & 0x400 != 0 ? try reader.u32() : nil
            let compositionOffset: Int64
            if flags & 0x800 != 0 {
                let raw = try reader.u32()
                compositionOffset = version == 0 ? Int64(raw) : Int64(Int32(bitPattern: raw))
            } else {
                compositionOffset = 0
            }

            let sampleFlags = explicitFlags ?? (index == 0 ? firstSampleFlags : nil) ?? defaults.flags
            guard size > 0 else { throw DemuxError.malformed("zero-size sample") }

            descriptors.append(SampleDescriptor(
                offset: offset,
                size: Int(size),
                decodeTime: decodeTime,
                presentationTime: decodeTime + compositionOffset,
                duration: Int64(duration),
                isSync: sampleFlags & 0x0001_0000 == 0  // sample_is_non_sync_sample
            ))
            decodeTime += Int64(duration)
            offset += Int(size)
        }
    }

    private func extractSamples(_ fragment: Fragment, mdat: Box) throws -> [Sample] {
        try fragment.samples.map { descriptor in
            let start = fragment.moofStart + descriptor.offset
            let end = start + descriptor.size
            guard start >= mdat.payload.lowerBound, end <= mdat.payload.upperBound else {
                throw DemuxError.malformed("sample outside mdat")
            }
            return Sample(
                data: Data(buffer[start..<end]),
                decodeTime: descriptor.decodeTime,
                presentationTime: descriptor.presentationTime,
                duration: descriptor.duration,
                isSync: descriptor.isSync
            )
        }
    }

    // MARK: Codec configuration

    struct CodecConfig: Equatable {
        /// SPS/PPS (H.264) or VPS/SPS/PPS (H.265), in stream order.
        let parameterSets: [[UInt8]]
        /// How many bytes each NAL length prefix in the samples occupies (1-4).
        let nalUnitHeaderLength: Int32
    }

    /// `avcC` (ISO 14496-15 AVCDecoderConfigurationRecord) → parameter sets. Internal so the byte
    /// wrangling is testable without CoreMedia accepting the result.
    static func parseAVCConfig(_ bytes: [UInt8]) throws -> CodecConfig {
        var reader = Reader(buffer: bytes, range: bytes.indices)
        try reader.skip(4)  // version, profile, compatibility, level
        let nalLength = Int32(try reader.u8() & 0x03) + 1
        var sets: [[UInt8]] = []
        let spsCount = Int(try reader.u8() & 0x1F)
        for _ in 0..<spsCount {
            let length = Int(try reader.u16())
            sets.append(Array(try reader.take(length)))
        }
        let ppsCount = Int(try reader.u8())
        for _ in 0..<ppsCount {
            let length = Int(try reader.u16())
            sets.append(Array(try reader.take(length)))
        }
        guard sets.count >= 2 else { throw DemuxError.malformed("avcC without SPS/PPS") }
        return CodecConfig(parameterSets: sets, nalUnitHeaderLength: nalLength)
    }

    /// `hvcC` (HEVCDecoderConfigurationRecord) → VPS/SPS/PPS.
    static func parseHEVCConfig(_ bytes: [UInt8]) throws -> CodecConfig {
        var reader = Reader(buffer: bytes, range: bytes.indices)
        try reader.skip(21)  // version + profile/tier/level block
        let nalLength = Int32(try reader.u8() & 0x03) + 1
        var sets: [[UInt8]] = []
        let arrayCount = Int(try reader.u8())
        for _ in 0..<arrayCount {
            let nalType = try reader.u8() & 0x3F
            let naluCount = Int(try reader.u16())
            for _ in 0..<naluCount {
                let length = Int(try reader.u16())
                let nalu = Array(try reader.take(length))
                // 32/33/34 = VPS/SPS/PPS. Anything else (SEI arrays) isn't a parameter set.
                if (32...34).contains(nalType) {
                    sets.append(nalu)
                }
            }
        }
        guard sets.count >= 3 else { throw DemuxError.malformed("hvcC without VPS/SPS/PPS") }
        return CodecConfig(parameterSets: sets, nalUnitHeaderLength: nalLength)
    }

    private static func makeFormatDescription(
        parameterSets: [[UInt8]],
        nalUnitHeaderLength: Int32,
        hevc: Bool
    ) throws -> CMVideoFormatDescription {
        let copies = parameterSets.map { set -> UnsafeMutablePointer<UInt8> in
            let pointer = UnsafeMutablePointer<UInt8>.allocate(capacity: set.count)
            set.withUnsafeBufferPointer { pointer.update(from: $0.baseAddress!, count: set.count) }
            return pointer
        }
        defer { copies.forEach { $0.deallocate() } }
        let pointers = copies.map { UnsafePointer($0) }
        let sizes = parameterSets.map(\.count)

        var description: CMFormatDescription?
        let status: OSStatus
        if hevc {
            status = CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: nalUnitHeaderLength,
                extensions: nil,
                formatDescriptionOut: &description
            )
        } else {
            status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
                allocator: kCFAllocatorDefault,
                parameterSetCount: pointers.count,
                parameterSetPointers: pointers,
                parameterSetSizes: sizes,
                nalUnitHeaderLength: nalUnitHeaderLength,
                formatDescriptionOut: &description
            )
        }
        guard status == noErr, let description else {
            throw DemuxError.unsupported("parameter sets rejected by VideoToolbox (\(status))")
        }
        return description
    }

    // MARK: Byte reading

    private func u8(at index: Int) -> UInt8 { buffer[index] }

    private func u32(at index: Int) -> UInt32 {
        UInt32(buffer[index]) << 24 | UInt32(buffer[index + 1]) << 16
            | UInt32(buffer[index + 2]) << 8 | UInt32(buffer[index + 3])
    }

    private func u64(at index: Int) -> UInt64 {
        UInt64(u32(at: index)) << 32 | UInt64(u32(at: index + 4))
    }

    private func fourCC(at index: Int) -> String {
        String(decoding: buffer[index..<index + 4], as: UTF8.self)
    }

    /// Sequential bounds-checked reads within one box's payload.
    private struct Reader {
        private let buffer: [UInt8]
        private var offset: Int
        private let end: Int

        init(buffer: [UInt8], range: Range<Int>) {
            self.buffer = buffer
            self.offset = range.lowerBound
            self.end = range.upperBound
        }

        mutating func u8() throws -> UInt8 {
            try require(offset + 1 <= end, "read past end of box")
            defer { offset += 1 }
            return buffer[offset]
        }

        mutating func u16() throws -> UInt16 {
            try require(offset + 2 <= end, "read past end of box")
            defer { offset += 2 }
            return UInt16(buffer[offset]) << 8 | UInt16(buffer[offset + 1])
        }

        mutating func u32() throws -> UInt32 {
            try require(offset + 4 <= end, "read past end of box")
            defer { offset += 4 }
            return UInt32(buffer[offset]) << 24 | UInt32(buffer[offset + 1]) << 16
                | UInt32(buffer[offset + 2]) << 8 | UInt32(buffer[offset + 3])
        }

        mutating func u64() throws -> UInt64 {
            let high = try u32()
            let low = try u32()
            return UInt64(high) << 32 | UInt64(low)
        }

        mutating func skip(_ count: Int) throws {
            try require(offset + count <= end, "read past end of box")
            offset += count
        }

        mutating func take(_ count: Int) throws -> ArraySlice<UInt8> {
            try require(count >= 0 && offset + count <= end, "read past end of box")
            defer { offset += count }
            return buffer[offset..<offset + count]
        }
    }
}

private nonisolated func require(_ condition: Bool, _ reason: String) throws {
    guard condition else { throw FMP4Demuxer.DemuxError.malformed(reason) }
}

/// Turns demuxed samples into `CMSampleBuffer`s an `AVSampleBufferDisplayLayer` can enqueue.
/// Separate from the demuxer so the parsing stays pure bytes-in, values-out.
nonisolated enum VideoSampleBufferFactory {
    enum FactoryError: Error {
        case coreMedia(OSStatus)
    }

    static func make(_ sample: FMP4Demuxer.Sample, track: FMP4Demuxer.VideoTrack) throws -> CMSampleBuffer {
        var blockBuffer: CMBlockBuffer?
        var status = CMBlockBufferCreateWithMemoryBlock(
            allocator: kCFAllocatorDefault,
            memoryBlock: nil,
            blockLength: sample.data.count,
            blockAllocator: kCFAllocatorDefault,
            customBlockSource: nil,
            offsetToData: 0,
            dataLength: sample.data.count,
            flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &blockBuffer
        )
        guard status == kCMBlockBufferNoErr, let blockBuffer else { throw FactoryError.coreMedia(status) }

        status = sample.data.withUnsafeBytes { bytes in
            CMBlockBufferReplaceDataBytes(
                with: bytes.baseAddress!,
                blockBuffer: blockBuffer,
                offsetIntoDestination: 0,
                dataLength: sample.data.count
            )
        }
        guard status == kCMBlockBufferNoErr else { throw FactoryError.coreMedia(status) }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: sample.duration, timescale: track.timescale),
            presentationTimeStamp: CMTime(value: sample.presentationTime, timescale: track.timescale),
            decodeTimeStamp: CMTime(value: sample.decodeTime, timescale: track.timescale)
        )
        var size = sample.data.count
        var sampleBuffer: CMSampleBuffer?
        status = CMSampleBufferCreateReady(
            allocator: kCFAllocatorDefault,
            dataBuffer: blockBuffer,
            formatDescription: track.formatDescription,
            sampleCount: 1,
            sampleTimingEntryCount: 1,
            sampleTimingArray: &timing,
            sampleSizeEntryCount: 1,
            sampleSizeArray: &size,
            sampleBufferOut: &sampleBuffer
        )
        guard status == noErr, let sampleBuffer else { throw FactoryError.coreMedia(status) }

        if !sample.isSync,
           let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let attachment = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                attachment,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque()
            )
        }
        return sampleBuffer
    }
}
