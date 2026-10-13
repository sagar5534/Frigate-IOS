import Foundation

/// Builders for hand-crafted fMP4 streams, shared by the demuxer tests and the MSE player tests.
///
/// The codec bytes are real (x264/x265 output) because VideoToolbox validates parameter sets -
/// an invented SPS would make every test fail for the wrong reason. The layout matches what
/// go2rtc emits: `ftyp`+`moov` init segment, then `moof`+`mdat` pairs using default-base-is-moof
/// addressing with `trun` offsets relative to the moof's first byte.
enum FMP4Fixture {
    /// x264 1280x720 high-profile SPS + PPS (verified accepted by VideoToolbox).
    static let sps: [UInt8] = [
        0x67, 0x64, 0x00, 0x1F, 0xAC, 0xD9, 0x40, 0x50, 0x05, 0xBB, 0x01, 0x6C,
        0x80, 0x00, 0x00, 0x03, 0x00, 0x80, 0x00, 0x00, 0x1E, 0x07, 0x8C, 0x18, 0xCB,
    ]
    static let pps: [UInt8] = [0x68, 0xEB, 0xEC, 0xB2, 0x2C]

    /// x265 1920x1080 VPS/SPS/PPS (verified accepted by VideoToolbox).
    static let hevcVPS: [UInt8] = [
        0x40, 0x01, 0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00,
        0x90, 0x00, 0x00, 0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0x99, 0x98, 0x09,
    ]
    static let hevcSPS: [UInt8] = [
        0x42, 0x01, 0x01, 0x01, 0x60, 0x00, 0x00, 0x03, 0x00, 0x90, 0x00, 0x00,
        0x03, 0x00, 0x00, 0x03, 0x00, 0x78, 0xA0, 0x03, 0xC0, 0x80, 0x10, 0xE5,
        0x96, 0x56, 0x69, 0x24, 0xCA, 0xE0, 0x10, 0x00, 0x00, 0x03, 0x00, 0x10,
        0x00, 0x00, 0x03, 0x01, 0xE0, 0x80,
    ]
    static let hevcPPS: [UInt8] = [0x44, 0x01, 0xC1, 0x72, 0xB4, 0x62, 0x40]

    // MARK: Primitive builders

    static func u16(_ value: Int) -> [UInt8] {
        [UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func u32(_ value: Int) -> [UInt8] {
        [UInt8(value >> 24 & 0xFF), UInt8(value >> 16 & 0xFF), UInt8(value >> 8 & 0xFF), UInt8(value & 0xFF)]
    }

    static func u64(_ value: UInt64) -> [UInt8] {
        u32(Int(value >> 32)) + u32(Int(value & 0xFFFF_FFFF))
    }

    static func box(_ type: String, _ payloads: [UInt8]...) -> [UInt8] {
        let payload = payloads.flatMap { $0 }
        return u32(8 + payload.count) + Array(type.utf8) + payload
    }

    static func fullBox(_ type: String, version: UInt8, flags: Int, _ payloads: [UInt8]...) -> [UInt8] {
        let payload = payloads.flatMap { $0 }
        return box(type, [version] + u32(flags).suffix(3) + payload)
    }

    // MARK: Codec configuration boxes

    static func avcC() -> [UInt8] {
        box("avcC", [1, 0x64, 0x00, 0x1F, 0xFF, 0xE1], u16(sps.count), sps, [1], u16(pps.count), pps)
    }

    static func hvcC() -> [UInt8] {
        var payload: [UInt8] = [1] + [UInt8](repeating: 0, count: 20)  // version + profile/level block
        payload += [0xFF]  // reserved bits + lengthSizeMinusOne = 3
        payload += [3]  // three arrays: VPS, SPS, PPS
        for (nalType, nalu) in [(32, hevcVPS), (33, hevcSPS), (34, hevcPPS)] {
            payload += [UInt8(nalType)] + u16(1) + u16(nalu.count) + nalu
        }
        return box("hvcC", payload)
    }

    /// The 78 fixed bytes of a VisualSampleEntry that precede its config boxes.
    static func visualSampleEntryFields() -> [UInt8] {
        var fields = [UInt8](repeating: 0, count: 6) + u16(1)  // reserved + data_reference_index
        fields += [UInt8](repeating: 0, count: 16)  // pre_defined/reserved
        fields += u16(1280) + u16(720)
        fields += u32(0x0048_0000) + u32(0x0048_0000) + u32(0)  // resolution + reserved
        fields += u16(1)  // frame_count
        fields += [UInt8](repeating: 0, count: 32)  // compressorname
        fields += u16(0x0018) + u16(0xFFFF)  // depth + pre_defined
        return fields
    }

    // MARK: Segments

    static func trak(trackID: Int, timescale: Int, sampleEntry: [UInt8]) -> [UInt8] {
        let tkhd = fullBox("tkhd", version: 0, flags: 7, u32(0), u32(0), u32(trackID), u32(0), u32(0))
        let mdhd = fullBox("mdhd", version: 0, flags: 0, u32(0), u32(0), u32(timescale), u32(0), u32(0))
        let stsd = fullBox("stsd", version: 0, flags: 0, u32(1), sampleEntry)
        let stbl = box("stbl", stsd)
        let minf = box("minf", stbl)
        let mdia = box("mdia", mdhd, minf)
        return box("trak", tkhd, mdia)
    }

    static func initSegment(
        sampleEntry: [UInt8]? = nil,
        trexDefaultDuration: Int = 3000,
        trexDefaultFlags: Int = 0x0001_0000
    ) -> [UInt8] {
        let entry = sampleEntry ?? box("avc1", visualSampleEntryFields(), avcC())
        let trex = fullBox(
            "trex", version: 0, flags: 0,
            u32(1), u32(1), u32(trexDefaultDuration), u32(0), u32(trexDefaultFlags)
        )
        let moov = box("moov", trak(trackID: 1, timescale: 90000, sampleEntry: entry), box("mvex", trex))
        return box("ftyp", Array("iso5".utf8), u32(512)) + moov
    }

    struct SampleSpec {
        let bytes: [UInt8]
        var duration: Int = 3000
        var compositionOffset: Int? = nil
        var isSync = false

        init(bytes: [UInt8], duration: Int = 3000, compositionOffset: Int? = nil, isSync: Bool = false) {
            self.bytes = bytes
            self.duration = duration
            self.compositionOffset = compositionOffset
            self.isSync = isSync
        }
    }

    /// One `moof`+`mdat` pair addressed the way go2rtc writes them.
    static func fragment(baseDecodeTime: UInt64, samples: [SampleSpec]) -> [UInt8] {
        let hasCTS = samples.contains { $0.compositionOffset != nil }

        func build(dataOffset: Int) -> [UInt8] {
            var trunPayload = u32(samples.count) + u32(dataOffset)
            for sample in samples {
                trunPayload += u32(sample.duration)
                trunPayload += u32(sample.bytes.count)
                trunPayload += u32(sample.isSync ? 0 : 0x0001_0000)
                if hasCTS {
                    trunPayload += u32(sample.compositionOffset ?? 0)
                }
            }
            let trunFlags = 0x01 | 0x100 | 0x200 | 0x400 | (hasCTS ? 0x800 : 0)
            let trun = fullBox("trun", version: 0, flags: trunFlags, trunPayload)
            let tfhd = fullBox("tfhd", version: 0, flags: 0x02_0000, u32(1))
            let tfdt = fullBox("tfdt", version: 1, flags: 0, u64(baseDecodeTime))
            let traf = box("traf", tfhd, tfdt, trun)
            let mfhd = fullBox("mfhd", version: 0, flags: 0, u32(1))
            return box("moof", mfhd, traf)
        }

        // Two passes: the trun's data offset points past the moof, whose size depends on the trun.
        let moofSize = build(dataOffset: 0).count
        let moof = build(dataOffset: moofSize + 8)
        let mdat = box("mdat", samples.flatMap(\.bytes))
        return moof + mdat
    }
}
