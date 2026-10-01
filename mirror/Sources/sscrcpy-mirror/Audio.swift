import AudioRing
import AudioToolbox

/// Plays the audio stream until it ends, which means the device disconnected. `play` starts
/// the output of the regulator's ring.
nonisolated func receiveAudio(_ fd: Int32, play: (OpaquePointer) throws -> Void) throws {
    var codec = [UInt8](repeating: 0, count: 4)
    guard codec.withUnsafeMutableBytes({ receive(fd, $0) }) else { return }
    switch codec {
    case [0, 0, 0, 0]:
        // The device cannot capture audio (the server says why, e.g. Android 10) and sends
        // nothing more.
        while codec.withUnsafeMutableBytes({ receive(fd, $0) }) {}
        return
    case [0, 0x72, 0x61, 0x77]: // "raw" (Server.parameters)
        break
    default:
        throw Failure("unexpected audio codec \(codec)")
    }
    let regulator = try AudioRegulator()
    try play(regulator.ring)
    var header = [UInt8](repeating: 0, count: 12)
    // A packet is one read of the device's capture: at most 1024 frames (AudioConfig.java).
    var packet = [UInt8](repeating: 0, count: 1024 * 4)
    let left = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    let right = UnsafeMutablePointer<Float>.allocate(capacity: 1024)
    while header.withUnsafeMutableBytes({ receive(fd, $0) }) {
        guard case let .media(size, config, _, pts) = Header(header), !config, size > 0, size <= packet.count, size % 4 == 0 else {
            throw Failure("invalid audio packet")
        }
        // The server never cuts a packet short: the device disconnected, as between packets.
        guard packet.withUnsafeMutableBytes({ receive(fd, UnsafeMutableRawBufferPointer(rebasing: $0[..<size])) }) else {
            return
        }
        let count = packet.withUnsafeBytes { splitFrames(UnsafeRawBufferPointer(rebasing: $0[..<size]), left, right) }
        try regulator.push(left, right, count: count, pts: pts)
    }
}

/// Splits 16-bit stereo frames, as the device sends them, into one Float32 buffer per channel.
/// Returns the number of frames.
nonisolated func splitFrames(_ data: UnsafeRawBufferPointer, _ left: UnsafeMutablePointer<Float>, _ right: UnsafeMutablePointer<Float>) -> Int {
    let count = data.count / 4
    for i in 0 ..< count {
        left[i] = Float(Int16(littleEndian: data.loadUnaligned(fromByteOffset: 4 * i, as: Int16.self))) / 32768
        right[i] = Float(Int16(littleEndian: data.loadUnaligned(fromByteOffset: 4 * i + 2, as: Int16.self))) / 32768
    }
    return count
}

/// The audio as the regulator and the output take it: 48 kHz stereo Float32, one buffer per
/// channel, which the varispeed requires and the output unit takes as it is.
nonisolated let pcmFormat = AudioStreamBasicDescription(
    mSampleRate: 48000, mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | kAudioFormatFlagIsNonInterleaved,
    mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0
)

/// Fails with the status of an Audio Toolbox call.
nonisolated func check(_ status: OSStatus, _ call: String) throws {
    guard status == noErr else { throw Failure("\(call) failed (\(status))") }
}

/// The receiving half of scrcpy's audio regulator (audio_regulator.c), whose other half plays
/// the ring on the audio thread. It keeps about 80 ms buffered: on overflow it drops the
/// oldest frames, and it compensates the drift between the device's clock and the output's,
/// and the delay underruns add, by resampling slightly with AUVarispeed.
nonisolated final class AudioRegulator {
    /// 80 ms. scrcpy's default is 50 ms, but it plays through 30 to 40 ms more of SDL's audio
    /// queue after its regulator; this output has no such queue, so about the same delay buys
    /// far fewer underruns on Wi-Fi.
    static let target = 3840
    /// Room for the target and 1 s more, as in scrcpy.
    let ring = audio_ring_new(UInt32(target + 48000), UInt32(target))
    private let varispeed: AudioUnit
    /// Input frames per output frame, as the varispeed plays them: scrcpy's compensation.
    private(set) var rate: Float32 = 1
    /// Frames the varispeed has not taken yet, one buffer per channel.
    fileprivate let fifo = (UnsafeMutablePointer<Float>.allocate(capacity: 2048), UnsafeMutablePointer<Float>.allocate(capacity: 2048))
    fileprivate var fifoCount = 0
    private let out = (UnsafeMutablePointer<Float>.allocate(capacity: 2048), UnsafeMutablePointer<Float>.allocate(capacity: 2048))
    private let buffers = AudioBufferList.allocate(maximumBuffers: 2)
    /// Advances with each render: the varispeed repeats its last output for a repeated time.
    private var time = AudioTimeStamp()
    /// The ring's level averaged over the last writes, up to 128 (scrcpy's util/average.c).
    private(set) var average: Float = 0
    private var averaged: Float = 0
    private var compensating = false
    private var sinceResync = 0
    private var nextPTS: Int64 = 0

    init() throws {
        var description = AudioComponentDescription(
            componentType: kAudioUnitType_FormatConverter, componentSubType: kAudioUnitSubType_Varispeed,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
        )
        var unit: AudioUnit?
        try check(AudioComponentInstanceNew(AudioComponentFindNext(nil, &description)!, &unit), "AudioComponentInstanceNew")
        varispeed = unit!
        var format = pcmFormat
        for scope in [kAudioUnitScope_Input, kAudioUnitScope_Output] {
            try check(AudioUnitSetProperty(
                varispeed, kAudioUnitProperty_StreamFormat, scope, 0, &format, UInt32(MemoryLayout.size(ofValue: format))
            ), "AudioUnitSetProperty")
        }
        var input = AURenderCallbackStruct(inputProc: supplyFrames, inputProcRefCon: Unmanaged.passUnretained(self).toOpaque())
        try check(AudioUnitSetProperty(
            varispeed, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &input, UInt32(MemoryLayout.size(ofValue: input))
        ), "AudioUnitSetProperty")
        try check(AudioUnitInitialize(varispeed), "AudioUnitInitialize")
        time.mFlags = .sampleTimeValid
    }

    /// Buffers frames that start at `pts` microseconds.
    func push(_ left: UnsafePointer<Float>, _ right: UnsafePointer<Float>, count: Int, pts: Int64) throws {
        let target = Self.target
        if nextPTS != 0, pts - nextPTS > 100_000 {
            // A gap of more than 100 ms, typically silence the device did not capture: start
            // again from the target.
            let level = Int(audio_ring_level(ring))
            if count + level < target {
                audio_ring_write(ring, nil, nil, UInt32(target - level - count))
            }
            average = Float(target)
            try setRate(1)
            compensating = false
            sinceResync = 0
            _ = audio_ring_take_underflow(ring)
        }
        nextPTS = pts + Int64(count) * 1_000_000 / 48000

        fifo.0.advanced(by: fifoCount).update(from: left, count: count)
        fifo.1.advanced(by: fifoCount).update(from: right, count: count)
        fifoCount += count
        // As many frames as the varispeed can render from the FIFO: for n frames it takes n ×
        // rate input frames, give or take 0.0001 of rounding (measured), and leaves 2 at most.
        let frames = Int((Double(fifoCount) - 0.01) / Double(rate))
        buffers[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: out.0)
        buffers[1] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: out.1)
        var flags = AudioUnitRenderActionFlags()
        try check(AudioUnitRender(varispeed, &flags, &time, 0, UInt32(frames), buffers.unsafeMutablePointer), "AudioUnitRender")
        time.mSampleTime += Double(frames)
        let written = Int(audio_ring_write(ring, out.0, out.1, UInt32(frames)))

        let played = audio_ring_played(ring)
        let underflow = played ? Int(audio_ring_take_underflow(ring)) : 0
        // At most 110% of the target plus 60 ms; until playback starts, 10 ms over the target,
        // as more would only delay it.
        let maxLevel = played ? target * 11 / 10 + 2880 : target + 480
        let level = Int(audio_ring_level(ring))
        let dropped = Int(audio_ring_drop(ring, UInt32(maxLevel)))
        guard played else { return }

        // What the regulator itself adds or removes counts at once; the level is smoothed.
        average = max(0, average + Float(written - count + underflow - dropped))
        averaged = min(averaged + 1, 128)
        average = ((averaged - 1) * average + Float(level)) / averaged
        sinceResync += written
        if sinceResync >= 48000 {
            sinceResync = 0
            var diff = Int(Float(target) - average)
            // Compensate above 4 ms of error, until it is below 1 ms, but never play faster
            // while the ring is below the target: that would underrun.
            if abs(diff) < (compensating ? 48 : 192) || diff < 0 && level < target {
                diff = 0
            }
            // Over 4 s, at most 2%.
            diff = min(max(diff, -3840), 3840)
            try setRate(1 - Float32(diff) / 192_000)
            compensating = diff != 0
        }
    }

    private func setRate(_ rate: Float32) throws {
        self.rate = rate
        let status = AudioUnitSetParameter(varispeed, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, rate, 0)
        try check(status, "AudioUnitSetParameter")
    }
}

/// The varispeed's input: frames from the FIFO, which it never asks too many of (see push).
/// AudioUnitRender calls it on the receiving thread, not the audio thread, so it may be Swift.
nonisolated func supplyFrames(
    _ regulator: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
    _ time: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32, _ data: UnsafeMutablePointer<AudioBufferList>?
) -> OSStatus {
    let regulator = Unmanaged<AudioRegulator>.fromOpaque(regulator).takeUnretainedValue()
    let count = Int(frames)
    guard count <= regulator.fifoCount else { return kAudioUnitErr_TooManyFramesToProcess }
    let buffers = UnsafeMutableAudioBufferListPointer(data!)
    let (left, right) = regulator.fifo
    buffers[0].mData!.assumingMemoryBound(to: Float.self).update(from: left, count: count)
    buffers[1].mData!.assumingMemoryBound(to: Float.self).update(from: right, count: count)
    regulator.fifoCount -= count
    left.update(from: left + count, count: regulator.fifoCount)
    right.update(from: right + count, count: regulator.fifoCount)
    return noErr
}

/// Starts the default output unit playing the ring. It plays on the output device the user
/// chooses, following their changes.
nonisolated func startOutput(from ring: OpaquePointer) throws {
    var description = AudioComponentDescription(
        componentType: kAudioUnitType_Output, componentSubType: kAudioUnitSubType_DefaultOutput,
        componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0
    )
    var unit: AudioUnit?
    try check(AudioComponentInstanceNew(AudioComponentFindNext(nil, &description)!, &unit), "AudioComponentInstanceNew")
    var format = pcmFormat
    try check(AudioUnitSetProperty(
        unit!, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Input, 0, &format, UInt32(MemoryLayout.size(ofValue: format))
    ), "AudioUnitSetProperty")
    var render = AURenderCallbackStruct(inputProc: audio_ring_render, inputProcRefCon: UnsafeMutableRawPointer(ring))
    try check(AudioUnitSetProperty(
        unit!, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input, 0, &render, UInt32(MemoryLayout.size(ofValue: render))
    ), "AudioUnitSetProperty")
    try check(AudioUnitInitialize(unit!), "AudioUnitInitialize")
    try check(AudioOutputUnitStart(unit!), "AudioOutputUnitStart")
}
