import AudioRing
import AudioToolbox
import Testing
@testable import sscrcpy_mirror

/// Pulls `count` frames from the ring as the output unit does.
func pull(_ ring: OpaquePointer, _ count: Int) -> (left: [Float], right: [Float]) {
    var left = [Float](repeating: .nan, count: count)
    var right = [Float](repeating: .nan, count: count)
    left.withUnsafeMutableBufferPointer { l in
        right.withUnsafeMutableBufferPointer { r in
            let buffers = AudioBufferList.allocate(maximumBuffers: 2)
            defer { free(buffers.unsafeMutablePointer) }
            buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: l.baseAddress)
            buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(count * 4), mData: r.baseAddress)
            var flags = AudioUnitRenderActionFlags()
            var time = AudioTimeStamp()
            _ = audio_ring_render(UnsafeMutableRawPointer(ring), &flags, &time, 0, UInt32(count), buffers.unsafeMutablePointer)
        }
    }
    return (left, right)
}

/// Writes frames numbered `numbers` on the left, and their negatives on the right.
@discardableResult
func write(_ ring: OpaquePointer, _ numbers: ClosedRange<Int>) -> UInt32 {
    let left = numbers.map(Float.init)
    return audio_ring_write(ring, left, left.map { -$0 }, UInt32(left.count))
}

@Test func ringWaitsForTargetThenPlaysInOrder() {
    let ring = audio_ring_new(16, 8)
    write(ring, 1 ... 5)
    // Below the target: silence, and no underflow, since playback has not started.
    #expect(pull(ring, 4) == ([0, 0, 0, 0], [0, 0, 0, 0]))
    #expect(!audio_ring_played(ring))
    write(ring, 6 ... 8)
    #expect(pull(ring, 4) == ([1, 2, 3, 4], [-1, -2, -3, -4]))
    #expect(audio_ring_played(ring))
    #expect(audio_ring_take_underflow(ring) == 0)
    // Running out: the rest is silence, counted as underflow.
    #expect(pull(ring, 6).left == [5, 6, 7, 8, 0, 0])
    #expect(audio_ring_take_underflow(ring) == 2)
    #expect(audio_ring_take_underflow(ring) == 0)
    // Once started, playback goes on below the target.
    write(ring, 9 ... 9)
    #expect(pull(ring, 2).left == [9, 0])
}

@Test func ringDropsTheOldestAndWraps() {
    let ring = audio_ring_new(8, 1)
    write(ring, 1 ... 6)
    #expect(audio_ring_drop(ring, 6) == 0)
    #expect(audio_ring_drop(ring, 2) == 4)
    #expect(audio_ring_level(ring) == 2)
    #expect(pull(ring, 2).left == [5, 6])
    // Across the end of the ring.
    #expect(write(ring, 7 ... 12) == 6)
    #expect(pull(ring, 6).left == [7, 8, 9, 10, 11, 12])
    // A full ring takes no more.
    #expect(write(ring, 1 ... 10) == 8)
}

@Test func ringDropsAfterPlaying() {
    let ring = audio_ring_new(8, 1)
    write(ring, 1 ... 6)
    #expect(pull(ring, 2).left == [1, 2])
    #expect(audio_ring_drop(ring, 2) == 2)
    #expect(audio_ring_level(ring) == 2)
    #expect(pull(ring, 2).left == [5, 6])
}

@Test func ringReusesDroppedFrames() {
    let ring = audio_ring_new(8, 1)
    write(ring, 1 ... 8)
    #expect(audio_ring_drop(ring, 2) == 6)
    // Before the output skips them, as after a stall of the output.
    #expect(write(ring, 9 ... 14) == 6)
    #expect(pull(ring, 8).left == [7, 8, 9, 10, 11, 12, 13, 14])
}

private let target = AudioRegulator.target

/// Pushes `count` packets of a 20 ms sine, the first starting at `pts` microseconds.
func push(_ regulator: AudioRegulator, _ count: Int, from pts: Int64) throws {
    let sine = (0 ..< 960).map { sin(Float($0) * 2 * .pi / 48) / 2 }
    for k in 0 ..< count {
        try regulator.push(sine, sine, count: 960, pts: pts + Int64(k) * 20_000)
    }
}

/// Packets enough for the target: playback starts at the next pull.
let startPackets = target / 960 + 1

/// Starts playback, then for 1.2 s pushes a packet every 20 ms, before which the output has
/// played the ring down to `level` frames, and `underflow` frames more. Returns when the last
/// packet ends, in microseconds.
@discardableResult
func play(_ regulator: AudioRegulator, down level: Int, underflow: Int = 0) throws -> Int64 {
    try push(regulator, startPackets, from: 1_000_000)
    for k in 0 ..< 60 {
        _ = pull(regulator.ring, max(0, Int(audio_ring_level(regulator.ring)) - level) + underflow)
        try push(regulator, 1, from: 1_000_000 + Int64(startPackets + k) * 20_000)
    }
    return 1_000_000 + Int64(startPackets + 60) * 20_000
}

@Test func regulatorBufferingLimits() throws {
    let regulator = try AudioRegulator()
    // Before playback, at most 10 ms over the target, which would only delay it.
    try push(regulator, 10, from: 1_000_000)
    #expect(audio_ring_level(regulator.ring) == UInt32(target + 480))
    _ = pull(regulator.ring, 512)
    // Playing, at most 110% of the target plus 60 ms.
    try push(regulator, 20, from: 1_200_000)
    #expect(audio_ring_level(regulator.ring) == UInt32(target * 11 / 10 + 2880))
}

@Test func regulatorCompensatesLowBuffering() throws {
    let regulator = try AudioRegulator()
    // 15 ms under the target after each write: played slower, to make it up over 4 s.
    try play(regulator, down: target - 960 - 720)
    #expect(abs(regulator.rate - (1 - 720 / 192_000)) < 0.0002)
}

@Test func regulatorCompensatesHighBuffering() throws {
    let regulator = try AudioRegulator()
    // 25 ms over the target after each write: played faster.
    try play(regulator, down: target - 960 + 1200)
    #expect(abs(regulator.rate - (1 + 1200 / 192_000)) < 0.0002)
}

@Test func regulatorNeverPlaysFasterBelowTarget() throws {
    let regulator = try AudioRegulator()
    // Underflows raise the average above the target, but the ring itself stays low: playing
    // faster would only underflow more.
    try play(regulator, down: 0, underflow: 480)
    #expect(regulator.average > Float(target + 192))
    #expect(regulator.rate == 1)
}

@Test func regulatorPassesTheSoundThrough() throws {
    let regulator = try AudioRegulator()
    // A 1 kHz sine of amplitude 1/2 on the left, its opposite on the right. Whatever the delay,
    // a frame and the one a quarter period (12 frames) later are a point of the circle of
    // radius 1/2.
    let sine = (0 ..< 960).map { sin(Float($0) * 2 * .pi / 48) / 2 }
    for k in 0 ..< 10 {
        try regulator.push(sine, sine.map { -$0 }, count: 960, pts: 1_000_000 + Int64(k) * 20_000)
    }
    let (left, right) = pull(regulator.ring, 2880)
    let error = (0 ..< 2880 - 12).map { k in
        max(abs(left[k] * left[k] + left[k + 12] * left[k + 12] - 0.25), abs(left[k] + right[k]))
    }.max()!
    #expect(error < 0.001)
}

@Test func regulatorCompensatesAtMostTwoPercent() throws {
    let regulator = try AudioRegulator()
    // 0.8 s at 30 ms, then 0.4 s of silence for want of packets, then the late packets at once.
    try push(regulator, startPackets, from: 1_000_000)
    for k in 0 ..< 40 {
        _ = pull(regulator.ring, Int(audio_ring_level(regulator.ring)) - 1440)
        try push(regulator, 1, from: 1_000_000 + Int64(startPackets + k) * 20_000)
    }
    _ = pull(regulator.ring, Int(audio_ring_level(regulator.ring)) + 19200)
    try push(regulator, 10, from: 1_000_000 + Int64(startPackets + 40) * 20_000)
    #expect(regulator.rate == 1.02)
}

@Test func regulatorCountsDropsAtOnce() throws {
    let regulator = try AudioRegulator()
    try push(regulator, startPackets, from: 1_000_000)
    _ = pull(regulator.ring, 512)
    // The output stops pulling: each packet over the limit is dropped, and taken off the
    // average at once.
    try push(regulator, 40, from: 1_000_000 + Int64(startPackets) * 20_000)
    let limit = target * 11 / 10 + 2880
    #expect(audio_ring_level(regulator.ring) == UInt32(limit))
    #expect(regulator.average < Float(limit))
}

@Test func regulatorForgetsTheSilenceOfAGap() throws {
    let regulator = try AudioRegulator()
    let end = try play(regulator, down: target - 960 - 720)
    #expect(regulator.rate < 1)
    // No packet for a second: the output plays the ring, then silence.
    _ = pull(regulator.ring, 48000)
    // Packets again, the ring at the target after each write for a second: nothing to
    // compensate.
    for k in 0 ..< 60 {
        _ = pull(regulator.ring, max(0, Int(audio_ring_level(regulator.ring)) - (target - 960)))
        try push(regulator, 1, from: end + 1_000_000 + Int64(k) * 20_000)
    }
    #expect(regulator.rate == 1)
}

@Test func regulatorRestartsAfterAGap() throws {
    let regulator = try AudioRegulator()
    let end = try play(regulator, down: target - 960 - 720)
    #expect(regulator.rate < 1)
    // More than 100 ms after the last packet ended: back to the target, at the normal rate.
    _ = pull(regulator.ring, Int(audio_ring_level(regulator.ring)) - 720)
    try push(regulator, 1, from: end + 101_000)
    #expect(regulator.rate == 1)
    #expect(abs(Int(audio_ring_level(regulator.ring)) - target) <= 1)
}

// Three Opus packets as the device sends them (CELT, fullband, 20 ms, stereo), of 1 kHz on the
// left and 2 kHz on the right (ffmpeg's libopus, 32 kbps).
let tonePackets = [
    hex("fc9fda3f6b9e52ee68b8ec3ca903806fd762024fe752cc819d2a0b57d0b7f33d3a0e4cc76057e2435b524c4ce2799759a5fcbca8ff717f1bca1695b889a5e45c44f191680f5c685559789bacd47ff0f6c17f550642c02e2beb8ec0103c0068000010040fdd449d1dc5f5c68c16b1"),
    hex("fc9e8ed779b92b3be2c44f3c80e5e3594b1d982643429612b3b67f4a0c221bd8419ba56aeb1cb1cb1cb1cb91f15723e2ae47c4eae49af8e65cf2afbaf3b62898b2c7fedc1d54241613195b6a3dc675050703eb4fc470bb610abe30eaab7d4dffd08a6dd17892f8b26e38f9ae492c671cd37f5ff3b7cfe144851b5db4965db070d6f10289828bbf4c28156ee5b568a20f59a527f60540475a2568515793f8dd4e8947857ca006c2b8e532ada7b33afd9fc4cfb036ab4bf19550696ed1"),
    hex("fc9cf35e3d8a766171fb225c904a8e69ce0e39e9cac86dac35fa30f1da7996e6292e22e22e2346f3668de6cd1bcd389149f121e62cff5c54d47ba05496b598ac9d697a0e17c67aec053aabe3044afe38f14d41d8697c0f246335bebf0beb2d183945b587330002c1627738f11b3fa7923ba48eef0309b2428dab3686cdb070ddca984f9c9f84f37ec9fe4fd95f0b5cac5dd56a93a566df6df113dfbf9b334d708d707b1e32dace84f7eaed611e901dade72b6f2688cad1"),
]

@Test func decodesOpusIntoOneBufferPerChannel() throws {
    let decoder = try OpusDecoder()
    let counts = try tonePackets.map { packet in try packet.withUnsafeBytes { try decoder.decode($0) } }
    // The decoder drops the first 2.5 ms; then each packet is 20 ms.
    #expect(counts == [840, 960, 960])
    func crossings(_ samples: UnsafeMutablePointer<Float>) -> Int {
        (1 ..< 960).count { (samples[$0 - 1] < 0) != (samples[$0] < 0) }
    }
    // 20 periods on the left, 40 on the right.
    #expect((39 ... 41).contains(crossings(decoder.left)))
    #expect((79 ... 81).contains(crossings(decoder.right)))
    // A packet that is not audio, here the configuration, decodes to nothing: an error.
    let head = hex("4f707573486561640102380180bb0000000000")
    #expect(throws: Failure.self) { try head.withUnsafeBytes { try decoder.decode($0) } }
}

/// Tests never start the Mac's audio output.
func noOutput(_ ring: OpaquePointer) {
    Issue.record("audio output started")
}

@Test func audioStreamStart() throws {
    // A device that cannot capture audio says so, then sends nothing more until it
    // disconnects: that is not an error, and the stream is read to its end.
    let fd = try socket(sending: [0, 0, 0, 0, 1, 2, 3, 4, 5])
    defer { close(fd) }
    try receiveAudio(fd, play: noOutput)
    var byte: UInt8 = 0
    #expect(recv(fd, &byte, 1, MSG_DONTWAIT) == 0)
    #expect(throws: Failure.self) { try receiveAudio(try socket(sending: [0, 0, 0, 1]), play: noOutput) }
    #expect(throws: Failure.self) { try receiveAudio(try socket(sending: [0, 0x61, 0x61, 0x63]), play: noOutput) }
    // Disconnected before the codec.
    try receiveAudio(try socket(sending: [0x6f, 0x70]), play: noOutput)
}

@Test func audioStreamPackets() throws {
    var stream = Array("opus".utf8)
    func packet(config: Bool, pts: Int, _ payload: [UInt8]) {
        stream += [config ? 0x40 : 0, 0, 0, 0] + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: pts >> $0) }
        stream += [0, 0, UInt8(payload.count >> 8), UInt8(truncatingIfNeeded: payload.count)] + payload
    }
    // The configuration is skipped, the packets are played, and a packet cut short is a
    // disconnect.
    packet(config: true, pts: 0, hex("4f707573486561640102380180bb0000000000"))
    for (k, p) in tonePackets.enumerated() { packet(config: false, pts: k * 20_000, p) }
    stream += [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 100, 1, 2, 3]
    var ring: OpaquePointer?
    try receiveAudio(try socket(sending: stream)) { ring = $0 }
    // 840 + 960 + 960 frames, less the one the varispeed keeps.
    #expect(audio_ring_level(try #require(ring)) == 2759)
    // An empty packet is invalid.
    #expect(throws: Failure.self) {
        try receiveAudio(try socket(sending: Array("opus".utf8) + [UInt8](repeating: 0, count: 12)), play: { _ in })
    }
}

@Test func audioOption() throws {
    #expect(try Options(["--serial=abc"]).audio)
    #expect(try !Options(["--serial=abc", "--no-audio"]).audio)
    #expect(throws: Failure.self) { try Options(["--serial=abc", "--no-audio=1"]) }
}
