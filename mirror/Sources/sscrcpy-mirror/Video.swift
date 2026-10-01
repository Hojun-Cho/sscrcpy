import AVFoundation

/// The 12-byte header before each packet of the video and audio streams.
nonisolated enum Header: Equatable {
    /// A video capture session starts (at first, then on each rotation), at this video size.
    /// No payload follows.
    case session(width: Int, height: Int)
    /// `size` bytes follow: the codec configuration (for H.264, SPS and PPS) or a frame or
    /// audio packet, which starts at `pts` microseconds.
    case media(size: Int, config: Bool, keyFrame: Bool, pts: Int64)

    init(_ b: [UInt8]) {
        func u32(_ i: Int) -> Int {
            Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
        }
        if b[0] & 0x80 != 0 {
            self = .session(width: u32(4), height: u32(8))
        } else {
            // The high bits of the 64-bit PTS carry the flags. Video ignores the PTS: every
            // frame is shown as soon as it is decoded.
            let pts = Int64(u32(0) & 0x1fff_ffff) << 32 | Int64(u32(4))
            self = .media(size: u32(8), config: b[0] & 0x40 != 0, keyFrame: b[0] & 0x20 != 0, pts: pts)
        }
    }
}

/// Reads the start of the video stream: the codec and the first session. Returns the
/// video size.
nonisolated func receiveVideoStart(_ fd: Int32) throws -> (width: Int, height: Int) {
    var codec = [UInt8](repeating: 0, count: 4)
    guard codec.withUnsafeMutableBytes({ receive(fd, $0) }) else {
        throw Failure("could not read the video codec")
    }
    guard codec == Array("h264".utf8) else { throw Failure("unexpected video codec \(codec)") }
    var header = [UInt8](repeating: 0, count: 12)
    guard header.withUnsafeMutableBytes({ receive(fd, $0) }) else {
        throw Failure("could not read the video size")
    }
    guard case let .session(width, height) = Header(header), width > 0, height > 0 else {
        throw Failure("the video stream does not start with its size")
    }
    return (width, height)
}

/// Decodes and shows the video stream until it ends, which means the device disconnected.
/// While `visible` says no part of the window shows, frames are decoded but not displayed.
/// `onSession` receives the video size of each new capture session once its first frame
/// is on its way to the screen, as scrcpy resizes its window.
nonisolated func receiveVideo(
    _ fd: Int32,
    to renderer: AVSampleBufferVideoRenderer,
    visible: () -> Bool,
    onSession: (Int, Int) -> Void
) throws {
    var header = [UInt8](repeating: 0, count: 12)
    var packet = [UInt8]()
    var format: CMVideoFormatDescription?
    var session: (width: Int, height: Int)?
    while header.withUnsafeMutableBytes({ receive(fd, $0) }) {
        switch Header(header) {
        case let .session(width, height):
            session = (width, height)
        case let .media(size, config, keyFrame, _):
            guard size > 0 else { throw Failure("empty video packet") }
            if packet.count < size { packet = [UInt8](repeating: 0, count: size) }
            // The server never cuts a packet short: the device disconnected, as between packets.
            guard packet.withUnsafeMutableBytes({ receive(fd, UnsafeMutableRawBufferPointer(rebasing: $0[..<size])) }) else {
                return
            }
            try packet.withUnsafeBytes { buffer in
                let data = UnsafeRawBufferPointer(rebasing: buffer[..<size])
                if config {
                    format = try makeFormat(data)
                    return
                }
                guard let format else { throw Failure("video frame before the codec configuration") }
                renderer.enqueue(try makeSample(data, format: format, keyFrame: keyFrame, display: visible()))
            }
            if renderer.status == .failed {
                throw Failure("video decoding failed: \(renderer.error?.localizedDescription ?? "")")
            }
            if !config, let (width, height) = session {
                onSession(width, height)
                session = nil
            }
        }
    }
}

/// The NAL units of H.264 Annex B data, without their start codes.
nonisolated func nalUnits(_ data: UnsafeRawBufferPointer) -> [Range<Int>] {
    var units: [Range<Int>] = []
    var start: Int?
    func end(at i: Int) {
        guard let s = start else { return }
        // A NAL unit never ends in 0x00: zeros before a start code are padding or the first
        // byte of a 4-byte start code (00 00 00 01).
        var e = i
        while e > s, data[e - 1] == 0 { e -= 1 }
        if e > s { units.append(s ..< e) }
    }
    var i = 0
    while i + 3 <= data.count {
        if data[i] == 0, data[i + 1] == 0, data[i + 2] == 1 {
            end(at: i)
            i += 3
            start = i
        } else {
            i += 1
        }
    }
    end(at: data.count)
    return units
}

/// The format of the frames that follow a configuration packet (SPS and PPS).
nonisolated func makeFormat(_ config: UnsafeRawBufferPointer) throws -> CMVideoFormatDescription {
    let sets = nalUnits(config).filter { [7, 8].contains(config[$0.lowerBound] & 0x1f) }
    let base = config.baseAddress!.assumingMemoryBound(to: UInt8.self)
    var format: CMVideoFormatDescription?
    let status = CMVideoFormatDescriptionCreateFromH264ParameterSets(
        allocator: nil,
        parameterSetCount: sets.count,
        parameterSetPointers: sets.map { base + $0.lowerBound },
        parameterSetSizes: sets.map(\.count),
        nalUnitHeaderLength: 4,
        formatDescriptionOut: &format
    )
    guard status == noErr, let format else { throw Failure("invalid H.264 configuration (\(status))") }
    return format
}

/// A frame for the display layer: the NAL units get 4-byte lengths instead of start
/// codes, and the frame is shown as soon as it is decoded, unless `display` is false.
nonisolated func makeSample(
    _ frame: UnsafeRawBufferPointer,
    format: CMVideoFormatDescription,
    keyFrame: Bool,
    display: Bool
) throws -> CMSampleBuffer {
    let units = nalUnits(frame)
    var size = units.reduce(0) { $0 + 4 + $1.count }
    var block: CMBlockBuffer?
    var status = CMBlockBufferCreateWithMemoryBlock(
        allocator: nil, memoryBlock: nil, blockLength: size, blockAllocator: nil,
        customBlockSource: nil, offsetToData: 0, dataLength: size,
        flags: kCMBlockBufferAssureMemoryNowFlag, blockBufferOut: &block
    )
    guard status == noErr, let block else { throw Failure("could not allocate a video frame (\(status))") }
    var pointer: UnsafeMutablePointer<CChar>?
    CMBlockBufferGetDataPointer(
        block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil, dataPointerOut: &pointer
    )
    var out = UnsafeMutableRawPointer(pointer!)
    for unit in units {
        out.storeBytes(of: UInt32(unit.count).bigEndian, as: UInt32.self)
        (out + 4).copyMemory(from: frame.baseAddress! + unit.lowerBound, byteCount: unit.count)
        out += 4 + unit.count
    }

    var sample: CMSampleBuffer?
    status = CMSampleBufferCreateReady(
        allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1,
        sampleTimingEntryCount: 0, sampleTimingArray: nil,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample
    )
    guard status == noErr, let sample else { throw Failure("could not create a video sample (\(status))") }
    let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)! as NSArray
    let attachment = attachments[0] as! NSMutableDictionary
    attachment[kCMSampleAttachmentKey_DisplayImmediately] = true
    // Decoded all the same: the next frame depends on it.
    if !display { attachment[kCMSampleAttachmentKey_DoNotDisplay] = true }
    if !keyFrame { attachment[kCMSampleAttachmentKey_NotSync] = true }
    return sample
}
