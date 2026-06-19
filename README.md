# SwiftCircularBuffer

`SwiftCircularBuffer` is a pure Swift, single-producer/single-consumer circular buffer for audio applications. It is intended as a Swift-native replacement for [`TPCircularBuffer`](https://github.com/michaeltyson/TPCircularBuffer), with a smaller and more ergonomic API surface for modern Swift code.

It follows the core idea from `TPCircularBuffer`: the storage is mapped twice in virtual memory, so data that wraps at the logical end of the ring can still be read or written through one contiguous pointer. Shared occupancy is tracked with `Synchronization.Atomic`, while the producer owns the head offset and the consumer owns the tail offset.

## Features

- Lock-free SPSC byte ring buffer
- VM-mirrored storage for contiguous wraparound reads and writes
- No C shim target or external dependencies
- Closure-based read/write helpers for ergonomic Swift usage
- CoreAudio `AudioBufferList` helpers for queued audio blocks
- SwiftPM package with XCTest coverage

## Requirements

- Swift 6.3
- macOS 15, iOS 18, tvOS 18, visionOS 2, or watchOS 11
- Apple platforms only

## Basic Usage

```swift
import SwiftCircularBuffer

let buffer = try CircularBuffer(capacity: 16 * 1024)

let input: [UInt8] = [1, 2, 3, 4]
input.withUnsafeBytes { bytes in
    buffer.write(bytes)
}

var output = [UInt8](repeating: 0, count: 4)
let readCount = output.withUnsafeMutableBytes { bytes in
    buffer.read(into: bytes)
}
```

## Typed Value Usage

`CircularBuffer` can also copy `BitwiseCopyable` values and buffers as raw bytes:

```swift
struct Packet: BitwiseCopyable {
    var id: UInt32
    var sampleTime: UInt64
}

let packet = Packet(id: 7, sampleTime: 12_345)
buffer.write(packet)

let nextPacket = buffer.read(as: Packet.self)

let frames: [Float] = [0.0, 0.25, 0.5, 0.25]
frames.withUnsafeBufferPointer { values in
    buffer.write(values)
}

var outputFrames = [Float](repeating: 0, count: 4)
let framesRead = outputFrames.withUnsafeMutableBufferPointer { values in
    buffer.read(into: values)
}
```

Typed reads and writes are byte-copy conveniences, not a stable serialization format. Use them for
plain in-memory values whose representation is meaningful within the same process and build. Do not
use them for values that contain references, pointers that must survive across processes, or data
that needs a portable on-disk or network representation.

## AudioBufferList Usage

```swift
import CoreAudio
import SwiftCircularBuffer

var format = AudioStreamBasicDescription(
    mSampleRate: 48_000,
    mFormatID: kAudioFormatLinearPCM,
    mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
    mBytesPerPacket: 8,
    mFramesPerPacket: 1,
    mBytesPerFrame: 8,
    mChannelsPerFrame: 2,
    mBitsPerChannel: 32,
    mReserved: 0
)

let frameCount: UInt32 = 512
if let list = buffer.prepareAudioBufferList(format: format, frameCount: frameCount) {
    // Fill list[0].mData here on the producer thread.
    buffer.produceAudioBufferList()
}
```

The buffer is designed for one producer and one consumer. It is not a general-purpose multi-producer or multi-consumer queue.

## Concurrency Model

`CircularBuffer` is designed for exactly one producer thread and exactly one consumer thread:

- The producer owns calls that write data and advance the head.
- The consumer owns calls that read data and advance the tail.
- The shared fill count is atomic.

Do not call producer APIs from multiple threads at once, and do not call consumer APIs from multiple threads at once.

## Development

Run the test suite with:

```sh
swift test
```

When using a restricted sandbox, the Swift module cache may need to be redirected:

```sh
swift test -Xswiftc -module-cache-path -Xswiftc /tmp/swift-module-cache
```

## License

SwiftCircularBuffer is available under the MIT license. See [LICENSE](LICENSE).
