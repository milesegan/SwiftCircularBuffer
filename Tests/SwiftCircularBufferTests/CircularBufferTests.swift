import Darwin
import Synchronization
import XCTest

@testable import SwiftCircularBuffer

private struct TypedPacket: BitwiseCopyable, Equatable {
    var marker: UInt8
    var value: UInt64
    var code: UInt16
}

final class CircularBufferTests: XCTestCase {
    func testCapacityRoundsToPageSize() throws {
        let buffer = try CircularBuffer(capacity: 1)

        XCTAssertGreaterThanOrEqual(buffer.capacity, Int(getpagesize()))
        XCTAssertEqual(buffer.availableBytes, 0)
        XCTAssertEqual(buffer.freeBytes, buffer.capacity)
    }

    func testHugeCapacityThrowsCapacityTooLarge() {
        XCTAssertThrowsError(try CircularBuffer(capacity: Int.max)) { error in
            XCTAssertEqual(error as? CircularBufferError, .capacityTooLarge)
        }
    }

    func testWriteReadAndClear() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let input = Array(UInt8(0)..<UInt8(64))

        let wrote = input.withUnsafeBytes { buffer.write($0) }
        XCTAssertTrue(wrote)
        XCTAssertEqual(buffer.availableBytes, input.count)

        var output = [UInt8](repeating: 0, count: input.count)
        let read = output.withUnsafeMutableBytes { buffer.read(into: $0) }
        XCTAssertEqual(read, input.count)
        XCTAssertEqual(output, input)
        XCTAssertEqual(buffer.availableBytes, 0)

        input.withUnsafeBytes { XCTAssertTrue(buffer.write($0)) }
        buffer.clear()
        XCTAssertEqual(buffer.availableBytes, 0)
        XCTAssertEqual(buffer.freeBytes, buffer.capacity)
    }

    func testEmptyWriteSucceedsWhenFull() throws {
        let buffer = try CircularBuffer(capacity: 1)
        buffer.produce(buffer.capacity)

        XCTAssertTrue([UInt8]().withUnsafeBytes { buffer.write($0) })
        XCTAssertEqual(buffer.availableBytes, buffer.capacity)
    }

    func testMirroredWraparoundReadWrite() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        assertMirrorWrapsCorrectly(buffer)
    }

    func testClosureBasedAPIs() throws {
        let buffer = try CircularBuffer(capacity: 4096)

        let produced = buffer.write(maximumBytes: 16) { writable in
            for index in 0..<writable.count {
                writable[index] = UInt8(index)
            }
            return writable.count
        }
        XCTAssertEqual(produced, 16)

        var values: [UInt8] = []
        let consumed = buffer.read(maximumBytes: 16) { readable in
            values = Array(readable)
            return readable.count
        }

        XCTAssertEqual(consumed, 16)
        XCTAssertEqual(values, Array(UInt8(0)..<UInt8(16)))
    }

    func testTypedValueReadWrite() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let packet = TypedPacket(marker: 0xAB, value: 0x0102_0304_0506_0708, code: 0xCAFE)

        XCTAssertTrue(buffer.write(packet))
        XCTAssertEqual(buffer.availableBytes, MemoryLayout<TypedPacket>.size)

        let output = buffer.read(as: TypedPacket.self)
        XCTAssertEqual(output, packet)
        XCTAssertEqual(buffer.availableBytes, 0)
    }

    func testTypedReadReturnsNilWhenIncompleteValueIsAvailable() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let byte = [UInt8(0x01)]

        byte.withUnsafeBytes { XCTAssertTrue(buffer.write($0)) }

        let value = buffer.read(as: UInt16.self)
        XCTAssertNil(value)
        XCTAssertEqual(buffer.availableBytes, 1)
    }

    func testTypedBufferReadWrite() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let values: [UInt32] = [10, 20, 30, 40, 50]

        values.withUnsafeBufferPointer { valueBuffer in
            XCTAssertTrue(buffer.write(valueBuffer))
        }
        XCTAssertEqual(buffer.availableBytes, values.count * MemoryLayout<UInt32>.size)

        var firstOutput = [UInt32](repeating: 0, count: 3)
        let firstRead = firstOutput.withUnsafeMutableBufferPointer { outputBuffer in
            buffer.read(into: outputBuffer)
        }
        XCTAssertEqual(firstRead, 3)
        XCTAssertEqual(firstOutput, [10, 20, 30])

        var secondOutput = [UInt32](repeating: 0, count: 4)
        let secondRead = secondOutput.withUnsafeMutableBufferPointer { outputBuffer in
            buffer.read(into: outputBuffer)
        }
        XCTAssertEqual(secondRead, 2)
        XCTAssertEqual(Array(secondOutput.prefix(2)), [40, 50])
        XCTAssertEqual(buffer.availableBytes, 0)
    }

    func testTypedBufferWriteFailsWithoutEnoughFreeSpace() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let values = [UInt64](repeating: 42, count: buffer.capacity / MemoryLayout<UInt64>.size + 1)

        values.withUnsafeBufferPointer { valueBuffer in
            XCTAssertFalse(buffer.write(valueBuffer))
        }
        XCTAssertEqual(buffer.availableBytes, 0)
    }

    func testEmptyTypedBufferOperationsAreNoops() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let values: [UInt32] = []

        values.withUnsafeBufferPointer { valueBuffer in
            XCTAssertTrue(buffer.write(valueBuffer))
        }

        var output: [UInt32] = []
        let read = output.withUnsafeMutableBufferPointer { outputBuffer in
            buffer.read(into: outputBuffer)
        }
        XCTAssertEqual(read, 0)
        XCTAssertEqual(buffer.availableBytes, 0)
    }

    func testSingleProducerSingleConsumerStress() throws {
        let buffer = try CircularBuffer(capacity: 4096)
        let total = 50_000
        let producerDone = Atomic(false)
        let failure = Atomic(false)

        let producer = Thread {
            for value in 0..<total {
                let byte = UInt8(truncatingIfNeeded: value)
                while true {
                    var local = byte
                    let wrote = withUnsafeBytes(of: &local) { buffer.write($0) }
                    if wrote {
                        break
                    }
                    sched_yield()
                }
            }
            producerDone.store(true, ordering: .releasing)
        }

        let consumer = Thread {
            var expected = 0
            var byte = UInt8.zero
            while expected < total {
                let read = withUnsafeMutableBytes(of: &byte) { buffer.read(into: $0) }
                if read == 0 {
                    if producerDone.load(ordering: .acquiring) {
                        sched_yield()
                    }
                    continue
                }

                if byte != UInt8(truncatingIfNeeded: expected) {
                    failure.store(true, ordering: .releasing)
                    return
                }
                expected += 1
            }
        }

        producer.start()
        consumer.start()

        while !producer.isFinished || !consumer.isFinished {
            Thread.sleep(forTimeInterval: 0.001)
        }

        XCTAssertFalse(failure.load(ordering: .acquiring))
        XCTAssertEqual(buffer.availableBytes, 0)
    }

    func testTransientRemapFailureIsRetried() throws {
        var attempts = 0
        let buffer = try CircularBuffer(capacity: 4096, attemptLimit: 5) { target, size, source in
            attempts += 1
            guard attempts > 2 else {
                return KERN_NO_SPACE
            }
            return CircularBuffer.remapMirror(target: &target, size: size, source: source)
        }

        XCTAssertEqual(attempts, 3)
        assertMirrorWrapsCorrectly(buffer)
    }

    func testRemapLandingAtWrongAddressIsRetried() throws {
        var attempts = 0
        let buffer = try CircularBuffer(capacity: 4096, attemptLimit: 5) { target, size, source in
            attempts += 1
            guard attempts > 1 else {
                // vm_remap can report success while placing the mapping somewhere other than
                // the requested address, which is just as unusable as an outright failure.
                var elsewhere: vm_address_t = 0
                let result = vm_allocate(mach_task_self_, &elsewhere, size, VM_FLAGS_ANYWHERE)
                guard result == KERN_SUCCESS else {
                    return result
                }
                guard elsewhere != target else {
                    vm_deallocate(mach_task_self_, elsewhere, size)
                    return KERN_NO_SPACE
                }
                target = elsewhere
                return KERN_SUCCESS
            }
            return CircularBuffer.remapMirror(target: &target, size: size, source: source)
        }

        XCTAssertEqual(attempts, 2)
        assertMirrorWrapsCorrectly(buffer)
    }

    func testRemapFailureThrowsAfterAttemptLimit() {
        var attempts = 0
        XCTAssertThrowsError(
            try CircularBuffer(capacity: 4096, attemptLimit: 3) { _, _, _ in
                attempts += 1
                return KERN_NO_SPACE
            }
        ) { error in
            XCTAssertEqual(error as? CircularBufferError, .remapFailed(KERN_NO_SPACE))
        }

        XCTAssertEqual(attempts, 3)
    }

    func testFailedAttemptsReleaseTheirReservations() throws {
        // Each failed attempt reserves 2 MB, so a leak of even one attempt per buffer would
        // grow the address space by gigabytes over this loop.
        func churn(_ iterations: Int) throws {
            for _ in 0..<iterations {
                var attempts = 0
                _ = try CircularBuffer(capacity: 1 << 20, attemptLimit: 5) { target, size, source in
                    attempts += 1
                    guard attempts > 3 else {
                        return KERN_NO_SPACE
                    }
                    return CircularBuffer.remapMirror(target: &target, size: size, source: source)
                }
            }
        }

        // Warm up first so lazily grown allocator regions do not count as growth.
        try churn(200)
        let before = try taskVirtualSize()
        try churn(5000)
        let after = try taskVirtualSize()

        // Unrelated allocator activity can shrink the footprint, so compare signed.
        XCTAssertLessThan(Int64(after) - Int64(before), 64 << 20)
    }

    /// The task's total mapped address space, used to detect leaked virtual memory mappings.
    private func taskVirtualSize() throws -> UInt64 {
        var info = mach_task_basic_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info>.size / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
            }
        }
        try XCTSkipUnless(result == KERN_SUCCESS, "task_info is unavailable")
        return info.virtual_size
    }

    /// Writes across the ring's wrap point to confirm the mirrored mapping is intact.
    private func assertMirrorWrapsCorrectly(
        _ buffer: CircularBuffer,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        let filler = [UInt8](repeating: 0xAA, count: buffer.capacity - 8)
        filler.withUnsafeBytes { XCTAssertTrue(buffer.write($0), file: file, line: line) }
        buffer.consume(filler.count)

        let wrapped = (0..<64).map(UInt8.init)
        wrapped.withUnsafeBytes { XCTAssertTrue(buffer.write($0), file: file, line: line) }

        var output = [UInt8](repeating: 0, count: wrapped.count)
        let read = output.withUnsafeMutableBytes { buffer.read(into: $0) }
        XCTAssertEqual(read, wrapped.count, file: file, line: line)
        XCTAssertEqual(output, wrapped, file: file, line: line)
    }
}
