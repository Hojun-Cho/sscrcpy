import AVFoundation
import Testing
@testable import sscrcpy_mirror

@Test func sessionHeader() {
    // The last bit of byte 3 ("client resized") does not matter here.
    let header: [UInt8] = [0x80, 0, 0, 1, 0, 0, 0x02, 0xD0, 0, 0, 0x05, 0xC8]
    #expect(Header(header) == .session(width: 720, height: 1480))
}

@Test func mediaHeaders() {
    let config: [UInt8] = [0x40, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 31]
    #expect(Header(config) == .media(size: 31, config: true, keyFrame: false, pts: 0))
    // PTS bits must not leak into the flags, nor flags into the PTS.
    let keyFrame: [UInt8] = [0x20, 0x1F, 0xFF, 0, 0, 0x12, 0x34, 0x56, 0, 1, 0, 0]
    #expect(Header(keyFrame) == .media(size: 65536, config: false, keyFrame: true, pts: 0x1FFF_0000_1234_56))
    let frame: [UInt8] = [0x1F, 0xFF, 0, 0, 0, 0, 0, 0, 0, 0, 0x10, 0]
    #expect(Header(frame) == .media(size: 4096, config: false, keyFrame: false, pts: 0x1FFF_0000_0000_0000))
}

@Test func nalUnitsWithMixedStartCodes() {
    // 4-byte and 3-byte start codes, as x264 writes them; trailing zeros at the end.
    let data: [UInt8] = [
        0, 0, 0, 1, 0x67, 0xAA,
        0, 0, 1, 0x68, 0xBB,
        0, 0, 0, 1, 0x65, 0xCC, 0xDD, 0, 0,
    ]
    let units = data.withUnsafeBytes { nalUnits($0) }
    #expect(units == [4 ..< 6, 9 ..< 11, 15 ..< 18])
}

// SPS and PPS of a 720x1480 H.264 stream (ffmpeg testsrc, libx264 baseline).
let config: [UInt8] = [0, 0, 0, 1] + hex("6742c020d900b40bbf970110000003001000000303c0f1832480")
    + [0, 0, 0, 1] + hex("68cb83cb20")

func hex(_ s: String) -> [UInt8] {
    stride(from: 0, to: s.count, by: 2).map {
        let start = s.index(s.startIndex, offsetBy: $0)
        return UInt8(s[start ..< s.index(start, offsetBy: 2)], radix: 16)!
    }
}

@Test func formatFromConfig() throws {
    let format = try config.withUnsafeBytes { try makeFormat($0) }
    let size = CMVideoFormatDescriptionGetDimensions(format)
    #expect(size.width == 720 && size.height == 1480)
}

@Test func sampleHasLengthPrefixedUnits() throws {
    let format = try config.withUnsafeBytes { try makeFormat($0) }
    let frame: [UInt8] = [0, 0, 0, 1, 0x06, 0xAA, 0, 0, 1, 0x65, 0xBB, 0xCC]
    for keyFrame in [true, false] {
        let sample = try frame.withUnsafeBytes { try makeSample($0, format: format, keyFrame: keyFrame) }

        let block = try #require(CMSampleBufferGetDataBuffer(sample))
        var bytes = [UInt8](repeating: 0, count: CMBlockBufferGetDataLength(block))
        CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: bytes.count, destination: &bytes)
        #expect(bytes == [0, 0, 0, 2, 0x06, 0xAA, 0, 0, 0, 3, 0x65, 0xBB, 0xCC])

        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)! as NSArray
        let attachment = attachments[0] as! NSDictionary
        #expect(attachment[kCMSampleAttachmentKey_DisplayImmediately] as? Bool == true)
        #expect((attachment[kCMSampleAttachmentKey_NotSync] as? Bool ?? false) == !keyFrame)
    }
}

// Three frames each of 16x32 and 32x16 H.264 (ffmpeg testsrc, libx264 baseline): SPS, PPS,
// IDR, P, P.
let portrait = [
    "6742c00ad915b0110000030001000003003c0f122648", "68cb83cb20",
    "6588840a7ecb91c03f1b06020a80a020440004d34dca723ffd137c0b5af8280802a0280819012ad8c443d5075245ec15eff584c2320e7880006c611c8007580982d248e204e129b1f000587c00160002fc20f1117099e9a7ffd5440b7f1d135fc8400030560b0003056210fc41984c58760d0047a1206802bac4d03c8d1f34e43060d42700d20d2ddf36cb660041a1000040300051c7006d8870337e1a319e0026fdc00b41780163a2c7780f412500f2f9abf2",
    "419a3816ee", "419a5406bb80",
].map(hex)
let landscape = [
    "6742c00ad90bb0110000030001000003003c0f122648", "68cb83cb20",
    "658884097f6c3022dc38a000200300109ea9663037c8b5d33d8000c500027f7b200a9db18263fde603a30adfcfcd1a1d01e626a10804014e08005958019ed2df5a140b0e81b97090184a00c60cbec0005eb4b8c10a9a563fc2020cc6f19364394563b2760e5f330c45bf8864198714000404a280013e00679f441bbadc0000129e00f818c40e2be1e0058c04a333bfc3336a1008071206c20870d78e05800f6fe91e0b000c283fe409a2ec74b0de1c1066001c15bda33f38c3330514d1ba96dc68caf812b3ffe8",
    "419a3814ee", "419a54063b80",
].map(hex)

@MainActor @Test func reportsSessionsThatShowFrames() throws {
    // What the server sends for rotations: a session, its configuration and frames, then
    // the same for the new size. The first session repeats its configuration, as the server
    // may. The last session ends before its first frame: the window must not resize for it.
    var stream: [UInt8] = []
    func session(_ width: UInt8, _ height: UInt8) {
        stream += [0x80, 0, 0, 0, 0, 0, 0, width, 0, 0, 0, height]
    }
    func packet(config: Bool, _ units: [[UInt8]]) {
        let payload: [UInt8] = units.flatMap { [0, 0, 0, 1] + $0 }
        let flags: UInt8 = config ? 0x40 : 0
        stream += [flags, 0, 0, 0, 0, 0, 0, 0, 0, 0, UInt8(payload.count >> 8), UInt8(payload.count & 0xFF)]
        stream += payload
    }
    session(16, 32)
    packet(config: true, [portrait[0], portrait[1]])
    packet(config: false, [portrait[2]])
    packet(config: true, [portrait[0], portrait[1]])
    packet(config: false, [portrait[3]])
    packet(config: false, [portrait[4]])
    session(32, 16)
    packet(config: true, [landscape[0], landscape[1]])
    for unit in landscape[2...] { packet(config: false, [unit]) }
    session(16, 32)
    packet(config: true, [portrait[0], portrait[1]])

    let fd = try socket(sending: stream)
    defer { close(fd) }
    let layer = AVSampleBufferDisplayLayer()
    var sessions: [[Int]] = []
    try withExtendedLifetime(layer) {
        try receiveVideo(fd, to: layer.sampleBufferRenderer) { sessions.append([$0, $1]) }
    }
    #expect(sessions == [[16, 32], [32, 16]])
    #expect(layer.sampleBufferRenderer.status != .failed)
}

@Test func options() throws {
    let o = try Options(["--serial=abc", "--window-title=My phone", "--video-bit-rate=8M", "--max-size=1024", "--max-fps=60"])
    #expect(o.serial == "abc" && o.windowTitle == "My phone")
    #expect(o.videoBitRate == 8_000_000 && o.maxSize == 1024 && o.maxFps == 60)
    #expect(try Options(["--serial=abc", "--video-bit-rate=800k"]).videoBitRate == 800_000)
    #expect(throws: Failure.self) { try Options(["--serial=abc", "--video-bit-rate=0"]) }
    #expect(throws: Failure.self) { try Options(["--serial=abc", "--turbo"]) }
    #expect(throws: Failure.self) { try Options(["--window-title=x"]) }
    // A device name may start with a combining mark.
    #expect(try Options(["--serial=abc", "--window-title=\u{301}x"]).windowTitle == "\u{301}x")
}

@Test func streamCutInsideAPacketIsADisconnect() throws {
    // A header announcing 100 bytes, then only 3 of them: receiveVideo returns as for any
    // disconnect instead of failing.
    let fd = try socket(sending: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 100, 0, 0, 1])
    defer { close(fd) }
    try receiveVideo(fd, to: AVSampleBufferVideoRenderer()) { _, _ in }
}

/// A socket that yields `bytes`, then the end of the stream.
func socket(sending bytes: [UInt8]) throws -> Int32 {
    var fds: [Int32] = [0, 0]
    try #require(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
    try #require(bytes.withUnsafeBytes { write(fds[1], $0.baseAddress, $0.count) } == bytes.count)
    close(fds[1])
    return fds[0]
}
