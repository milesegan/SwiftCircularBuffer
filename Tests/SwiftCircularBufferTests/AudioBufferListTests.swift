#if canImport(CoreAudio)
import CoreAudio
@testable import SwiftCircularBuffer
import XCTest

private final class AudioBufferListBox {
    let rawList: UnsafeMutableRawPointer
    let list: UnsafeMutablePointer<AudioBufferList>
    private var dataPointers: [UnsafeMutableRawPointer] = []
    private let listByteCount: Int

    init(bufferCount: Int, bytesPerBuffer: Int, channelsPerBuffer: UInt32 = 1) {
        listByteCount =
            MemoryLayout<AudioBufferList>.size
            + (bufferCount - 1) * MemoryLayout<AudioBuffer>.stride
        rawList = UnsafeMutableRawPointer.allocate(
            byteCount: listByteCount,
            alignment: MemoryLayout<AudioBufferList>.alignment
        )
        rawList.initializeMemory(as: UInt8.self, repeating: 0, count: listByteCount)
        list = rawList.assumingMemoryBound(to: AudioBufferList.self)
        list.pointee.mNumberBuffers = UInt32(bufferCount)

        let buffers = UnsafeMutableAudioBufferListPointer(list)
        for index in 0..<bufferCount {
            let data = UnsafeMutableRawPointer.allocate(byteCount: bytesPerBuffer, alignment: 16)
            data.initializeMemory(as: UInt8.self, repeating: 0, count: bytesPerBuffer)
            dataPointers.append(data)
            buffers[index].mNumberChannels = channelsPerBuffer
            buffers[index].mDataByteSize = UInt32(bytesPerBuffer)
            buffers[index].mData = data
        }
    }

    deinit {
        for pointer in dataPointers {
            pointer.deallocate()
        }
        rawList.deallocate()
    }

    func fill(buffer index: Int, with values: [UInt8]) {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        values.withUnsafeBytes { source in
            buffers[index].mData!.copyMemory(from: source.baseAddress!, byteCount: source.count)
        }
        buffers[index].mDataByteSize = UInt32(values.count)
    }

    func bytes(buffer index: Int, count: Int) -> [UInt8] {
        let buffers = UnsafeMutableAudioBufferListPointer(list)
        let data = UnsafeRawBufferPointer(start: buffers[index].mData, count: count)
        return Array(data)
    }
}

final class AudioBufferListTests: XCTestCase {
    func testPrepareAndProduceAudioBufferList() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        var timestamp = AudioTimeStamp()
        timestamp.mFlags = [.sampleTimeValid]
        timestamp.mSampleTime = 128

        let list = try XCTUnwrap(
            buffer.prepareAudioBufferList(
                bufferCount: 2,
                bytesPerBuffer: 8,
                timestamp: timestamp
            ))
        XCTAssertEqual(list.count, 2)
        XCTAssertEqual(list[0].mDataByteSize, 8)
        XCTAssertEqual(list[1].mDataByteSize, 8)
        list[0].mData!.initializeMemory(as: UInt8.self, repeating: 1, count: 8)
        list[1].mData!.initializeMemory(as: UInt8.self, repeating: 2, count: 8)

        buffer.produceAudioBufferList()

        var outTimestamp = AudioTimeStamp()
        let next = try XCTUnwrap(buffer.nextAudioBufferList(timestamp: &outTimestamp))
        XCTAssertEqual(outTimestamp.mSampleTime, 128)
        XCTAssertEqual(next.count, 2)
        XCTAssertEqual(next[0].mDataByteSize, 8)
        XCTAssertEqual(next[1].mDataByteSize, 8)
    }

    func testCopyAndDequeueInterleavedAudioBufferList() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let format = interleavedFormat(bytesPerFrame: 2, channels: 2)
        let input = AudioBufferListBox(bufferCount: 1, bytesPerBuffer: 8, channelsPerBuffer: 2)
        input.fill(buffer: 0, with: [1, 2, 3, 4, 5, 6, 7, 8])

        var timestamp = AudioTimeStamp()
        timestamp.mFlags = [.sampleTimeValid]
        timestamp.mSampleTime = 44
        XCTAssertTrue(
            buffer.copyAudioBufferList(
                UnsafePointer(input.list),
                timestamp: timestamp,
                frames: 4,
                format: format
            ))

        let output = AudioBufferListBox(bufferCount: 1, bytesPerBuffer: 8, channelsPerBuffer: 2)
        var frames: UInt32 = 4
        var outTimestamp = AudioTimeStamp()
        buffer.dequeueAudioBufferListFrames(
            &frames,
            into: UnsafePointer(output.list),
            timestamp: &outTimestamp,
            format: format
        )

        XCTAssertEqual(frames, 4)
        XCTAssertEqual(outTimestamp.mSampleTime, 44)
        XCTAssertEqual(output.bytes(buffer: 0, count: 8), [1, 2, 3, 4, 5, 6, 7, 8])
        XCTAssertEqual(buffer.availableBytes, 0)
    }

    func testPrepareInterleavedAudioBufferListUsesFormatChannelCount() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let format = interleavedFormat(bytesPerFrame: 8, channels: 2)

        let list = try XCTUnwrap(buffer.prepareAudioBufferList(format: format, frameCount: 4))

        XCTAssertEqual(list.count, 1)
        XCTAssertEqual(list[0].mNumberChannels, 2)
        XCTAssertEqual(list[0].mDataByteSize, 32)
    }

    func testCopyRejectsSourceBuffersSmallerThanRequestedCopySize() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let input = AudioBufferListBox(bufferCount: 2, bytesPerBuffer: 8)
        input.fill(buffer: 0, with: [1, 2, 3, 4, 5, 6, 7, 8])
        input.fill(buffer: 1, with: [9, 10, 11, 12])

        XCTAssertFalse(buffer.copyAudioBufferList(UnsafePointer(input.list)))
        XCTAssertEqual(buffer.availableBytes, 0)
    }

    func testPartialConsumeUpdatesTimestamp() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let format = interleavedFormat(bytesPerFrame: 2, channels: 2)
        let input = AudioBufferListBox(bufferCount: 1, bytesPerBuffer: 8, channelsPerBuffer: 2)
        input.fill(buffer: 0, with: [10, 11, 12, 13, 14, 15, 16, 17])

        var timestamp = AudioTimeStamp()
        timestamp.mFlags = [.sampleTimeValid]
        timestamp.mSampleTime = 100
        XCTAssertTrue(
            buffer.copyAudioBufferList(
                UnsafePointer(input.list),
                timestamp: timestamp,
                frames: circularBufferCopyAllFrames,
                format: nil
            ))

        buffer.consumeNextAudioBufferListPartial(frames: 2, format: format)

        var outTimestamp = AudioTimeStamp()
        let list = try XCTUnwrap(buffer.nextAudioBufferList(timestamp: &outTimestamp))
        XCTAssertEqual(outTimestamp.mSampleTime, 102)
        XCTAssertEqual(list[0].mDataByteSize, 4)
        let remaining = UnsafeRawBufferPointer(start: list[0].mData, count: 4)
        XCTAssertEqual(Array(remaining), [14, 15, 16, 17])
    }

    func testNonInterleavedAvailableSpaceAndPeek() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let format = nonInterleavedFormat(bytesPerFrame: 4, channels: 2)

        XCTAssertGreaterThan(buffer.availableAudioBufferListFrames(format: format), 0)

        var timestamp = AudioTimeStamp()
        timestamp.mFlags = [.sampleTimeValid]
        timestamp.mSampleTime = 0
        let list = try XCTUnwrap(
            buffer.prepareAudioBufferList(
                format: format,
                frameCount: 4,
                timestamp: timestamp
            ))
        XCTAssertEqual(list.count, 2)
        buffer.produceAudioBufferList()

        var outTimestamp = AudioTimeStamp()
        XCTAssertEqual(buffer.peekAudioBufferListFrames(timestamp: &outTimestamp, format: format), 4)
        XCTAssertEqual(outTimestamp.mSampleTime, 0)
    }

    func testDequeueDropsSubFrameRemnantAndReachesNextBlock() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let format = interleavedFormat(bytesPerFrame: 4, channels: 1)
        let first = AudioBufferListBox(bufferCount: 1, bytesPerBuffer: 6)
        first.fill(buffer: 0, with: [1, 2, 3, 4, 5, 6])
        XCTAssertTrue(buffer.copyAudioBufferList(UnsafePointer(first.list)))
        let second = AudioBufferListBox(bufferCount: 1, bytesPerBuffer: 4)
        second.fill(buffer: 0, with: [9, 9, 9, 9])
        XCTAssertTrue(buffer.copyAudioBufferList(UnsafePointer(second.list)))

        let output = AudioBufferListBox(bufferCount: 1, bytesPerBuffer: 16)
        var frames: UInt32 = 4
        buffer.dequeueAudioBufferListFrames(&frames, into: UnsafePointer(output.list), format: format)

        XCTAssertEqual(frames, 2)
        XCTAssertEqual(output.bytes(buffer: 0, count: 8), [1, 2, 3, 4, 9, 9, 9, 9])
        XCTAssertEqual(buffer.availableBytes, 0)
    }

    func testDequeueAllFramesDoesNotOverflow() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let format = interleavedFormat(bytesPerFrame: 4, channels: 1)
        let input = AudioBufferListBox(bufferCount: 1, bytesPerBuffer: 8)
        XCTAssertTrue(buffer.copyAudioBufferList(UnsafePointer(input.list)))

        var frames = circularBufferCopyAllFrames
        buffer.dequeueAudioBufferListFrames(&frames, format: format)

        XCTAssertEqual(frames, 2)
        XCTAssertEqual(buffer.availableBytes, 0)
    }

    func testPrepareReturnsNilWhenByteCountOverflows() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let format = interleavedFormat(bytesPerFrame: 8, channels: 2)

        XCTAssertNil(buffer.prepareAudioBufferList(format: format, frameCount: UInt32.max))
    }

    func testZeroBytesPerFrameReportsNoFrames() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let format = interleavedFormat(bytesPerFrame: 0, channels: 1)
        let input = AudioBufferListBox(bufferCount: 1, bytesPerBuffer: 8)
        XCTAssertTrue(buffer.copyAudioBufferList(UnsafePointer(input.list)))

        XCTAssertEqual(buffer.availableAudioBufferListFrames(format: format), 0)
        XCTAssertEqual(buffer.peekAudioBufferListFrames(format: format), 0)
        var frames: UInt32 = 4
        buffer.dequeueAudioBufferListFrames(&frames, format: format)
        XCTAssertEqual(frames, 0)
    }

    func testPeekCountsOnlyWholeFramesPerBlock() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let format = interleavedFormat(bytesPerFrame: 4, channels: 1)
        for _ in 0..<2 {
            let input = AudioBufferListBox(bufferCount: 1, bytesPerBuffer: 6)
            XCTAssertTrue(buffer.copyAudioBufferList(UnsafePointer(input.list)))
        }

        XCTAssertEqual(buffer.peekAudioBufferListFrames(format: format), 2)
        var frames: UInt32 = 8
        buffer.dequeueAudioBufferListFrames(&frames, format: format)
        XCTAssertEqual(frames, 2)
    }

    func testZeroChannelNonInterleavedFormatReportsNoSpace() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let format = nonInterleavedFormat(bytesPerFrame: 4, channels: 0)

        XCTAssertEqual(buffer.availableAudioBufferListFrames(format: format), 0)
        XCTAssertNil(buffer.prepareAudioBufferList(format: format, frameCount: 4))
    }

    private func interleavedFormat(
        bytesPerFrame: UInt32,
        channels: UInt32
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsPacked,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 8 * bytesPerFrame / max(channels, 1),
            mReserved: 0
        )
    }

    private func nonInterleavedFormat(
        bytesPerFrame: UInt32,
        channels: UInt32
    ) -> AudioStreamBasicDescription {
        AudioStreamBasicDescription(
            mSampleRate: 48_000,
            mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: bytesPerFrame,
            mFramesPerPacket: 1,
            mBytesPerFrame: bytesPerFrame,
            mChannelsPerFrame: channels,
            mBitsPerChannel: 8 * bytesPerFrame,
            mReserved: 0
        )
    }
}
#endif
