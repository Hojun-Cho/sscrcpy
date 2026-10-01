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

@Test func regulatorRendersFullPacketsAtTheSlowestRate() throws {
    // Packets of 1024 frames, the most the device sends. Once playing, the output stalls: the
    // drops take the average down, the regulator slows by the full 2%, and each packet then
    // renders to about 1045 frames, within the varispeed's 1156 per call.
    let regulator = try AudioRegulator()
    let sine = (0 ..< 1024).map { sin(Float($0) * 2 * .pi / 48) / 2 }
    for k in 0 ..< 100 {
        if k == 5 { _ = pull(regulator.ring, Int(audio_ring_level(regulator.ring))) }
        try regulator.push(sine, sine, count: 1024, pts: 1_000_000 + Int64(k) * 21_333)
    }
    #expect(regulator.rate < 0.981)
}

@Test func splitsSixteenBitStereoFrames() {
    // Little-endian, left then right: 0 and -32768, 16384 and 32767, -1 and 1.
    let data: [UInt8] = [0x00, 0x00, 0x00, 0x80, 0x00, 0x40, 0xff, 0x7f, 0xff, 0xff, 0x01, 0x00]
    var left = [Float](repeating: .nan, count: 3)
    var right = left
    let count = data.withUnsafeBytes { bytes in
        left.withUnsafeMutableBufferPointer { l in
            right.withUnsafeMutableBufferPointer { r in splitFrames(bytes, l.baseAddress!, r.baseAddress!) }
        }
    }
    #expect(count == 3)
    #expect(left == [0, 0.5, -1 / 32768])
    #expect(right == [-1, 32767 / 32768, 1 / 32768])
}

/// Tests never start the Mac's audio output.
func noOutput(_ ring: OpaquePointer) {
    Issue.record("audio output started")
}

let rawCodec: [UInt8] = [0, 0x72, 0x61, 0x77]

@Test func audioStreamStart() throws {
    // A device that cannot capture audio says so, then sends nothing more until it
    // disconnects: that is not an error, and the stream is read to its end.
    let fd = try socket(sending: [0, 0, 0, 0, 1, 2, 3, 4, 5])
    defer { close(fd) }
    try receiveAudio(fd, play: noOutput)
    var byte: UInt8 = 0
    #expect(recv(fd, &byte, 1, MSG_DONTWAIT) == 0)
    // Only raw plays: the server's default Opus, like AAC, is never asked for.
    #expect(throws: Failure.self) { try receiveAudio(try socket(sending: Array("opus".utf8)), play: noOutput) }
    #expect(throws: Failure.self) { try receiveAudio(try socket(sending: [0, 0x61, 0x61, 0x63]), play: noOutput) }
    // Disconnected before the codec.
    try receiveAudio(try socket(sending: [0, 0x72]), play: noOutput)
}

@Test func audioStreamKeepsTheChannels() throws {
    // Left at 0.5, right at -0.25. The second packet comes after a gap of more than 100 ms, so
    // the regulator fills the ring with silence up to its target and the ring plays. (The stream
    // must fit the socket pair's buffer, 8 KB.)
    func packet(pts: Int) -> [UInt8] {
        [0, 0, 0, 0] + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: pts >> $0) } + [0, 0, 0x08, 0x00]
            + Array([[UInt8]](repeating: [0x00, 0x40, 0x00, 0xe0], count: 512).joined())
    }
    var ring: OpaquePointer?
    try receiveAudio(try socket(sending: rawCodec + packet(pts: 0) + packet(pts: 200_000))) { ring = $0 }
    let (left, right) = pull(try #require(ring), Int(audio_ring_level(ring!)))
    #expect(left.suffix(400).allSatisfy { abs($0 - 0.5) < 0.005 })
    #expect(right.suffix(400).allSatisfy { abs($0 + 0.25) < 0.005 })
}

@Test func audioStreamPackets() throws {
    func packet(config: Bool = false, pts: Int = 0, size: Int) -> [UInt8] {
        [config ? 0x40 : 0, 0, 0, 0] + [24, 16, 8, 0].map { UInt8(truncatingIfNeeded: pts >> $0) }
            + [0, 0, UInt8(size >> 8), UInt8(truncatingIfNeeded: size)] + [UInt8](repeating: 0, count: size)
    }
    // The packets are played, and a packet cut short is a disconnect. (The whole stream must fit
    // the socket pair's buffer, 8 KB.)
    var stream = rawCodec + packet(pts: 0, size: 4096) + packet(pts: 21_333, size: 1024) + packet(pts: 26_666, size: 4)
    stream += [0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 100, 1, 2, 3]
    var ring: OpaquePointer?
    try receiveAudio(try socket(sending: stream)) { ring = $0 }
    // 1024 + 256 + 1 frames, less the one the varispeed keeps.
    #expect(audio_ring_level(try #require(ring)) == 1280)
    // Invalid: an empty packet, half a frame over, more than one read of the capture, and a
    // configuration packet, which raw audio has none of.
    for (config, size) in [(false, 0), (false, 6), (false, 4100), (true, 4)] {
        #expect(throws: Failure.self) {
            try receiveAudio(try socket(sending: rawCodec + packet(config: config, size: size)), play: { _ in })
        }
    }
}

@Test func audioOption() throws {
    #expect(try Options(["--serial=abc"]).audio)
    #expect(try !Options(["--serial=abc", "--no-audio"]).audio)
    #expect(throws: Failure.self) { try Options(["--serial=abc", "--no-audio=1"]) }
}
