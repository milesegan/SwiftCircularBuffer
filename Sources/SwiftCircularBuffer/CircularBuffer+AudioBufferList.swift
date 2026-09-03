#if canImport(CoreAudio)
import CoreAudio
import Darwin

/// A sentinel value that asks audio copy APIs to copy every available frame.
public let circularBufferCopyAllFrames = UInt32.max

// Stored at the front of every queued audio block. The field order is the serialized
// in-buffer layout used by AudioBlockLayout offsets below.
private struct AudioBlockHeader {
    var timestamp: AudioTimeStamp
    var totalLength: UInt32
    var bufferList: AudioBufferList
}

private enum AudioBlockLayout {
    static let timestampOffset = MemoryLayout<AudioBlockHeader>.offset(of: \.timestamp)!
    static let totalLengthOffset = MemoryLayout<AudioBlockHeader>.offset(of: \.totalLength)!
    static let bufferListOffset = MemoryLayout<AudioBlockHeader>.offset(of: \.bufferList)!

    static func align16(_ value: Int) -> Int {
        (value + 15) & ~15
    }

    static func audioBufferListByteCount(bufferCount: Int) -> Int {
        precondition(bufferCount > 0, "AudioBufferList must contain at least one buffer")
        return MemoryLayout<AudioBufferList>.size
            + (bufferCount - 1) * MemoryLayout<AudioBuffer>.stride
    }

    static func metadataLength(bufferCount: Int) -> Int {
        bufferListOffset + audioBufferListByteCount(bufferCount: bufferCount)
    }

    static func timestampPointer(
        in block: UnsafeMutableRawPointer
    ) -> UnsafeMutablePointer<AudioTimeStamp> {
        block.advanced(by: timestampOffset).assumingMemoryBound(to: AudioTimeStamp.self)
    }

    static func totalLengthPointer(
        in block: UnsafeMutableRawPointer
    ) -> UnsafeMutablePointer<UInt32> {
        block.advanced(by: totalLengthOffset).assumingMemoryBound(to: UInt32.self)
    }

    static func bufferListPointer(
        in block: UnsafeMutableRawPointer
    ) -> UnsafeMutablePointer<AudioBufferList> {
        block.advanced(by: bufferListOffset).assumingMemoryBound(to: AudioBufferList.self)
    }
}

private let hostTicksPerSecond: Double = {
    var timebase = mach_timebase_info_data_t()
    mach_timebase_info(&timebase)
    return 1.0 / ((Double(timebase.numer) / Double(timebase.denom)) * 1.0e-9)
}()

extension CircularBuffer {
    /// Reserves space at the producer head for an `AudioBufferList` with uniform buffer sizes.
    ///
    /// The returned list points directly into the circular buffer's storage. Fill the buffers,
    /// optionally adjust each buffer's `mDataByteSize`, then call `produceAudioBufferList()`.
    /// Only the block metadata is initialized; the audio payload holds whatever the storage
    /// last contained until the caller writes it.
    ///
    /// - Parameters:
    ///   - bufferCount: The number of audio buffers in the list.
    ///   - bytesPerBuffer: The reserved data size for each buffer.
    ///   - timestamp: An optional timestamp to store with the queued audio block.
    /// - Returns: A mutable audio buffer list, or `nil` when there is not enough free space.
    public func prepareAudioBufferList(
        bufferCount: UInt32,
        bytesPerBuffer: UInt32,
        timestamp: AudioTimeStamp? = nil
    ) -> UnsafeMutableAudioBufferListPointer? {
        guard bufferCount > 0,
            let writable = head(),
            let block = writable.baseAddress
        else {
            return nil
        }

        let bufferCountInt = Int(bufferCount)
        let metadataLength = AudioBlockLayout.metadataLength(bufferCount: bufferCountInt)
        let dataOffset = AudioBlockLayout.align16(metadataLength)
        let dataBytes = bufferCountInt * Int(bytesPerBuffer)
        let totalLength = AudioBlockLayout.align16(dataOffset + dataBytes)
        guard totalLength <= writable.count, totalLength <= Int(UInt32.max) else {
            return nil
        }

        // Keep audio payloads 16-byte aligned so callers can use vectorized audio routines
        // without a separate copy. Zero just the header and list: the caller overwrites the
        // payload, so clearing it first would only add a second pass over every frame.
        block.initializeMemory(as: UInt8.self, repeating: 0, count: dataOffset)
        AudioBlockLayout.timestampPointer(in: block).pointee = timestamp ?? AudioTimeStamp()
        AudioBlockLayout.totalLengthPointer(in: block).pointee = UInt32(totalLength)

        let listPointer = AudioBlockLayout.bufferListPointer(in: block)
        listPointer.pointee.mNumberBuffers = bufferCount
        let list = UnsafeMutableAudioBufferListPointer(listPointer)
        var dataPointer = block.advanced(by: dataOffset)
        for index in 0..<bufferCountInt {
            list[index].mNumberChannels = 1
            list[index].mDataByteSize = bytesPerBuffer
            list[index].mData = dataPointer
            dataPointer = dataPointer.advanced(by: Int(bytesPerBuffer))
        }

        return list
    }

    /// Reserves space at the producer head for an `AudioBufferList` matching an audio format.
    ///
    /// Interleaved formats receive one buffer whose channel count is `mChannelsPerFrame`.
    /// Non-interleaved formats receive one single-channel buffer per channel.
    ///
    /// - Parameters:
    ///   - format: The audio stream format that determines buffer and channel layout.
    ///   - frameCount: The number of frames to reserve.
    ///   - timestamp: An optional timestamp to store with the queued audio block.
    /// - Returns: A mutable audio buffer list, or `nil` when there is not enough free space.
    public func prepareAudioBufferList(
        format: AudioStreamBasicDescription,
        frameCount: UInt32,
        timestamp: AudioTimeStamp? = nil
    ) -> UnsafeMutableAudioBufferListPointer? {
        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bufferCount = isNonInterleaved ? format.mChannelsPerFrame : 1
        guard
            let list = prepareAudioBufferList(
                bufferCount: bufferCount,
                bytesPerBuffer: frameCount * format.mBytesPerFrame,
                timestamp: timestamp
            )
        else {
            return nil
        }

        let channelsPerBuffer: UInt32 = isNonInterleaved ? 1 : format.mChannelsPerFrame
        for index in 0..<list.count {
            list[index].mNumberChannels = channelsPerBuffer
        }

        return list
    }

    /// Commits the `AudioBufferList` most recently returned by `prepareAudioBufferList`.
    ///
    /// - Parameter timestamp: An optional timestamp that replaces the prepared timestamp.
    /// - Precondition: A prepared list exists at the producer head and contains audio data.
    public func produceAudioBufferList(timestamp: AudioTimeStamp? = nil) {
        guard let writable = head(), let block = writable.baseAddress else {
            preconditionFailure("No prepared AudioBufferList is available to produce")
        }

        if let timestamp {
            AudioBlockLayout.timestampPointer(in: block).pointee = timestamp
        }

        let list = UnsafeMutableAudioBufferListPointer(AudioBlockLayout.bufferListPointer(in: block))
        precondition(!list.isEmpty, "Prepared AudioBufferList has no buffers")
        precondition(list[0].mDataByteSize > 0, "Prepared AudioBufferList has no audio data")

        let lastBuffer = list[list.count - 1]
        let lastData = UnsafeMutableRawPointer(lastBuffer.mData!)
        let calculatedLength = AudioBlockLayout.align16(
            lastData - block + Int(lastBuffer.mDataByteSize)
        )
        let storedLength = Int(AudioBlockLayout.totalLengthPointer(in: block).pointee)
        precondition(calculatedLength <= storedLength, "AudioBufferList exceeds prepared storage")
        precondition(calculatedLength <= writable.count, "AudioBufferList exceeds available storage")

        AudioBlockLayout.totalLengthPointer(in: block).pointee = UInt32(calculatedLength)
        produce(calculatedLength)
    }

    /// Copies an existing `AudioBufferList` into the ring and commits it as one queued block.
    ///
    /// When `frames` is `circularBufferCopyAllFrames`, the byte count is taken from the first
    /// source buffer and every source buffer must contain at least that many bytes.
    ///
    /// - Parameters:
    ///   - source: The source audio buffer list.
    ///   - timestamp: An optional timestamp to store with the copied block.
    ///   - frames: The number of frames to copy, or `circularBufferCopyAllFrames`.
    ///   - format: Required when copying a frame subset so byte counts can be derived.
    /// - Returns: `true` when the block was copied or had no audio data; otherwise `false`.
    /// - Precondition: `format` is provided when `frames` is not `circularBufferCopyAllFrames`.
    @discardableResult
    public func copyAudioBufferList(
        _ source: UnsafePointer<AudioBufferList>,
        timestamp: AudioTimeStamp? = nil,
        frames: UInt32 = circularBufferCopyAllFrames,
        format: AudioStreamBasicDescription? = nil
    ) -> Bool {
        let sourceList = UnsafeMutableAudioBufferListPointer(
            UnsafeMutablePointer(mutating: source)
        )
        guard !sourceList.isEmpty else {
            return true
        }

        let bytesPerBuffer: UInt32
        if frames == circularBufferCopyAllFrames {
            bytesPerBuffer = sourceList[0].mDataByteSize
        } else {
            guard let format else {
                preconditionFailure("A format is required when copying a frame subset")
            }
            bytesPerBuffer = frames * format.mBytesPerFrame
            precondition(bytesPerBuffer <= sourceList[0].mDataByteSize)
        }

        guard bytesPerBuffer > 0 else {
            return true
        }
        for index in 0..<sourceList.count {
            guard sourceList[index].mDataByteSize >= bytesPerBuffer,
                sourceList[index].mData != nil
            else {
                return false
            }
        }

        guard
            let destination = prepareAudioBufferList(
                bufferCount: UInt32(sourceList.count),
                bytesPerBuffer: bytesPerBuffer,
                timestamp: timestamp
            )
        else {
            return false
        }

        for index in 0..<sourceList.count {
            let sourceData = sourceList[index].mData!
            let destinationData = destination[index].mData!

            destinationData.copyMemory(
                from: sourceData,
                byteCount: Int(bytesPerBuffer)
            )
            destination[index].mNumberChannels = sourceList[index].mNumberChannels
        }

        produceAudioBufferList()
        return true
    }

    /// Returns the next queued `AudioBufferList` without consuming it.
    ///
    /// The returned list points directly into the ring and remains valid until the next consumer
    /// operation.
    ///
    /// - Parameter timestamp: Optional storage for the block timestamp.
    /// - Returns: The next queued list, or `nil` when the ring is empty.
    public func nextAudioBufferList(
        timestamp: UnsafeMutablePointer<AudioTimeStamp>? = nil
    ) -> UnsafeMutableAudioBufferListPointer? {
        guard let readable = tail(),
            let rawBlock = readable.baseAddress
        else {
            timestamp?.pointee = AudioTimeStamp()
            return nil
        }

        let block = UnsafeMutableRawPointer(mutating: rawBlock)
        timestamp?.pointee = AudioBlockLayout.timestampPointer(in: block).pointee
        return UnsafeMutableAudioBufferListPointer(AudioBlockLayout.bufferListPointer(in: block))
    }

    /// Returns the queued `AudioBufferList` after another list previously returned by this buffer.
    ///
    /// - Parameters:
    ///   - preceding: A list pointer returned by `nextAudioBufferList`.
    ///   - timestamp: Optional storage for the next block's timestamp.
    /// - Returns: The following queued list, or `nil` when `preceding` is the last readable block.
    /// - Precondition: `preceding` points inside the currently readable region.
    public func nextAudioBufferList(
        after preceding: UnsafePointer<AudioBufferList>,
        timestamp: UnsafeMutablePointer<AudioTimeStamp>? = nil
    ) -> UnsafeMutableAudioBufferListPointer? {
        guard let readable = tail(),
            let tailBlockRaw = readable.baseAddress
        else {
            return nil
        }

        let tailBlock = UnsafeMutableRawPointer(mutating: tailBlockRaw)
        let precedingBlock = UnsafeMutableRawPointer(mutating: preceding)
            .advanced(by: -AudioBlockLayout.bufferListOffset)
        precondition(precedingBlock >= tailBlock)
        precondition(precedingBlock < tailBlock.advanced(by: readable.count))

        let nextBlock = precedingBlock.advanced(
            by: Int(AudioBlockLayout.totalLengthPointer(in: precedingBlock).pointee)
        )
        guard nextBlock < tailBlock.advanced(by: readable.count) else {
            return nil
        }

        timestamp?.pointee = AudioBlockLayout.timestampPointer(in: nextBlock).pointee
        return UnsafeMutableAudioBufferListPointer(AudioBlockLayout.bufferListPointer(in: nextBlock))
    }

    /// Consumes the next queued `AudioBufferList`, if one is available.
    public func consumeNextAudioBufferList() {
        guard let readable = tail(), let blockRaw = readable.baseAddress else {
            return
        }

        let block = UnsafeMutableRawPointer(mutating: blockRaw)
        consume(Int(AudioBlockLayout.totalLengthPointer(in: block).pointee))
    }

    /// Consumes frames from the next queued `AudioBufferList`.
    ///
    /// If fewer frames than the next block contains are consumed, the block remains queued with
    /// its data pointers, byte sizes, and timestamp advanced.
    ///
    /// - Parameters:
    ///   - frames: The number of frames to consume.
    ///   - format: The format used to convert frames to bytes.
    public func consumeNextAudioBufferListPartial(
        frames: UInt32,
        format: AudioStreamBasicDescription
    ) {
        guard frames > 0,
            let readable = tail(),
            let blockRaw = readable.baseAddress
        else {
            return
        }

        let block = UnsafeMutableRawPointer(mutating: blockRaw)
        let list = UnsafeMutableAudioBufferListPointer(AudioBlockLayout.bufferListPointer(in: block))
        guard !list.isEmpty else {
            return
        }

        let bytesToConsume = Swift.min(
            frames * format.mBytesPerFrame,
            list[0].mDataByteSize
        )
        guard bytesToConsume > 0 else {
            return
        }

        if bytesToConsume == list[0].mDataByteSize {
            consumeNextAudioBufferList()
            return
        }

        for index in 0..<list.count {
            precondition(bytesToConsume <= list[index].mDataByteSize)
            list[index].mData = UnsafeMutableRawPointer(list[index].mData!)
                .advanced(by: Int(bytesToConsume))
            list[index].mDataByteSize -= bytesToConsume
        }

        var timestamp = AudioBlockLayout.timestampPointer(in: block).pointee
        if timestamp.mFlags.contains(.sampleTimeValid) {
            timestamp.mSampleTime += Float64(frames)
        }
        if timestamp.mFlags.contains(.hostTimeValid) {
            timestamp.mHostTime += UInt64((Double(frames) / format.mSampleRate) * hostTicksPerSecond)
        }

        // The metadata header must remain at the readable tail. Move it forward only to a
        // 16-byte boundary so the remaining audio payload stays aligned.
        let movedBlock = UnsafeMutableRawPointer(
            bitPattern: (UInt(bitPattern: block) + UInt(bytesToConsume)) & ~UInt(15)
        )!
        let metadataLength = AudioBlockLayout.metadataLength(bufferCount: list.count)
        memmove(movedBlock, block, metadataLength)
        AudioBlockLayout.timestampPointer(in: movedBlock).pointee = timestamp

        let bytesFreed = movedBlock - block
        AudioBlockLayout.totalLengthPointer(in: movedBlock).pointee -= UInt32(bytesFreed)
        consume(bytesFreed)
    }

    /// Dequeues up to `frameCount` frames from queued audio blocks.
    ///
    /// If `output` is provided, copied frames are appended into each output buffer. The method
    /// updates `frameCount` to the number of frames actually dequeued.
    ///
    /// - Parameters:
    ///   - frameCount: On input, the requested frame count. On output, the dequeued frame count.
    ///   - output: Optional destination audio buffers.
    ///   - timestamp: Optional storage for the first dequeued block's timestamp.
    ///   - format: The format used to convert frames to bytes.
    /// - Precondition: Every output buffer has room for the requested copied bytes.
    public func dequeueAudioBufferListFrames(
        _ frameCount: inout UInt32,
        into output: UnsafePointer<AudioBufferList>? = nil,
        timestamp: UnsafeMutablePointer<AudioTimeStamp>? = nil,
        format: AudioStreamBasicDescription
    ) {
        var bytesRemaining = frameCount * format.mBytesPerFrame
        var bytesCopied: UInt32 = 0
        var capturedTimestamp = false

        while bytesRemaining > 0 {
            let timestampPointer = capturedTimestamp ? nil : timestamp
            guard let list = nextAudioBufferList(timestamp: timestampPointer), !list.isEmpty else {
                break
            }

            capturedTimestamp = true
            let bytesToCopy = Swift.min(bytesRemaining, list[0].mDataByteSize)

            if let output {
                let outputList = UnsafeMutableAudioBufferListPointer(
                    UnsafeMutablePointer(mutating: output)
                )
                for index in 0..<Swift.min(outputList.count, list.count) {
                    guard let destinationData = outputList[index].mData,
                        let sourceData = list[index].mData
                    else {
                        continue
                    }
                    precondition(bytesCopied + bytesToCopy <= outputList[index].mDataByteSize)
                    destinationData
                        .advanced(by: Int(bytesCopied))
                        .copyMemory(from: sourceData, byteCount: Int(bytesToCopy))
                }
            }

            consumeNextAudioBufferListPartial(
                frames: bytesToCopy / format.mBytesPerFrame,
                format: format
            )
            bytesRemaining -= bytesToCopy
            bytesCopied += bytesToCopy
        }

        frameCount = bytesCopied / format.mBytesPerFrame
    }

    /// Returns the number of readable frames across queued audio blocks.
    ///
    /// - Parameters:
    ///   - timestamp: Optional storage for the first block's timestamp.
    ///   - format: The format used to convert bytes to frames.
    /// - Returns: The number of readable frames.
    public func peekAudioBufferListFrames(
        timestamp: UnsafeMutablePointer<AudioTimeStamp>? = nil,
        format: AudioStreamBasicDescription
    ) -> UInt32 {
        peekContiguousAudioBufferListFrames(
            timestamp: timestamp,
            format: format,
            contiguousToleranceSampleTime: UInt32.max,
            wrapPoint: 0
        )
    }

    /// Returns the number of readable frames while queued block timestamps remain contiguous.
    ///
    /// - Parameters:
    ///   - timestamp: Optional storage for the first block's timestamp.
    ///   - format: The format used to convert bytes to frames.
    ///   - contiguousToleranceSampleTime: The allowed timestamp difference in frames.
    ///   - wrapPoint: An optional sample-time wrap point.
    /// - Returns: The number of contiguous readable frames.
    public func peekContiguousAudioBufferListFrames(
        timestamp: UnsafeMutablePointer<AudioTimeStamp>? = nil,
        format: AudioStreamBasicDescription,
        contiguousToleranceSampleTime: UInt32,
        wrapPoint: UInt32 = 0
    ) -> UInt32 {
        guard let readable = tail(),
            let tailBlockRaw = readable.baseAddress
        else {
            timestamp?.pointee = AudioTimeStamp()
            return 0
        }

        var block = UnsafeMutableRawPointer(mutating: tailBlockRaw)
        let end = block.advanced(by: readable.count)
        timestamp?.pointee = AudioBlockLayout.timestampPointer(in: block).pointee

        var byteCount: UInt32 = 0
        while true {
            let list = UnsafeMutableAudioBufferListPointer(AudioBlockLayout.bufferListPointer(in: block))
            guard !list.isEmpty else {
                break
            }

            byteCount += list[0].mDataByteSize
            let nextBlock = block.advanced(
                by: Int(AudioBlockLayout.totalLengthPointer(in: block).pointee)
            )
            guard nextBlock < end else {
                break
            }

            if contiguousToleranceSampleTime != UInt32.max {
                let timestamp = AudioBlockLayout.timestampPointer(in: block).pointee
                let nextTimestamp = AudioBlockLayout.timestampPointer(in: nextBlock).pointee
                let frames = list[0].mDataByteSize / format.mBytesPerFrame
                var expectedSampleTime = timestamp.mSampleTime + Float64(frames)
                if wrapPoint > 0, expectedSampleTime > Float64(wrapPoint) {
                    expectedSampleTime = expectedSampleTime.truncatingRemainder(dividingBy: Float64(wrapPoint))
                }

                let diff = abs(nextTimestamp.mSampleTime - expectedSampleTime)
                let tolerance = Float64(contiguousToleranceSampleTime)
                if diff > tolerance,
                    wrapPoint == 0 || abs(diff - Float64(wrapPoint)) > tolerance
                {
                    break
                }
            }

            block = nextBlock
        }

        return byteCount / format.mBytesPerFrame
    }

    /// Returns the number of frames that can fit in a newly prepared audio buffer list.
    ///
    /// - Parameter format: The audio stream format that determines buffer and channel layout.
    /// - Returns: The maximum frame count currently writable at the producer head.
    public func availableAudioBufferListFrames(
        format: AudioStreamBasicDescription
    ) -> UInt32 {
        guard let writable = head(), let block = writable.baseAddress else {
            return 0
        }

        let isNonInterleaved = format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0
        let bufferCount = Int(isNonInterleaved ? format.mChannelsPerFrame : 1)
        let dataOffset = AudioBlockLayout.align16(
            AudioBlockLayout.metadataLength(bufferCount: bufferCount)
        )
        guard dataOffset < writable.count else {
            return 0
        }

        let dataStart = block.advanced(by: dataOffset)
        let dataEnd = block.advanced(by: writable.count)
        let availableAudioBytes = dataEnd - dataStart
        let availableBytesPerBuffer = (availableAudioBytes / bufferCount) & ~15
        return availableBytesPerBuffer > 0
            ? UInt32(availableBytesPerBuffer) / format.mBytesPerFrame
            : 0
    }
}
#endif
