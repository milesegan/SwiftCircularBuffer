import Darwin
import Synchronization

/// Errors that can occur while creating a circular buffer.
public enum CircularBufferError: Error, Equatable, Sendable {
    /// The requested capacity was zero or negative.
    case invalidCapacity

    /// The requested capacity is too large to represent or allocate safely.
    case capacityTooLarge

    /// The initial virtual memory allocation failed.
    case allocationFailed(kern_return_t)

    /// The mirrored virtual memory mapping failed.
    case remapFailed(kern_return_t)
}

/// A single-producer, single-consumer byte ring buffer backed by mirrored virtual memory.
///
/// The buffer maps the same storage twice at adjacent virtual addresses. That means readable
/// and writable spans that wrap around the logical end of the ring can still be exposed as
/// contiguous raw buffer pointers.
///
/// Use producer APIs from one thread and consumer APIs from one other thread. The shared
/// occupancy count is atomic, but head and tail offsets are intentionally owned by their
/// respective producer and consumer sides.
public final class CircularBuffer: @unchecked Sendable {
    /// The usable byte capacity, rounded up to the host page size.
    public let capacity: Int

    private let baseAddress: UnsafeMutableRawPointer
    private let allocationLength: vm_size_t
    private let fillCount: Atomic<UInt32>
    private var headOffset: UInt32
    private var tailOffset: UInt32

    /// Creates a circular buffer with at least the requested byte capacity.
    ///
    /// The actual `capacity` is rounded up to the system page size because the mirrored
    /// mapping is page based.
    ///
    /// - Parameter requestedCapacity: The minimum usable capacity in bytes.
    /// - Throws: `CircularBufferError` if the capacity is invalid or virtual memory setup fails.
    public convenience init(capacity requestedCapacity: Int) throws {
        try self.init(
            capacity: requestedCapacity,
            attemptLimit: Self.mappingAttemptLimit,
            remap: Self.remapMirror
        )
    }

    /// Creates a circular buffer with an overridable mapping strategy.
    ///
    /// Tests use this to simulate the transient mapping failures the retry loop exists for.
    ///
    /// - Parameters:
    ///   - requestedCapacity: The minimum usable capacity in bytes.
    ///   - attemptLimit: The number of mapping attempts before the failure is reported.
    ///   - remap: The mirror mapping call to use.
    /// - Throws: `CircularBufferError` if the capacity is invalid or virtual memory setup fails.
    init(
        capacity requestedCapacity: Int,
        attemptLimit: Int,
        remap: RemapMirror
    ) throws {
        guard requestedCapacity > 0 else {
            throw CircularBufferError.invalidCapacity
        }

        let pageSize = Int(getpagesize())
        guard requestedCapacity <= Int(UInt32.max) else {
            throw CircularBufferError.capacityTooLarge
        }

        let roundedCapacity = ((requestedCapacity + pageSize - 1) / pageSize) * pageSize
        guard roundedCapacity <= Int(UInt32.max), roundedCapacity <= Int.max / 2 else {
            throw CircularBufferError.capacityTooLarge
        }

        let length = vm_size_t(roundedCapacity)
        let address = try Self.makeMirroredMapping(
            length: length,
            attemptLimit: attemptLimit,
            remap: remap
        )

        self.capacity = roundedCapacity
        self.baseAddress = UnsafeMutableRawPointer(bitPattern: UInt(address))!
        self.allocationLength = length * 2
        self.fillCount = Atomic(0)
        self.headOffset = 0
        self.tailOffset = 0
    }

    /// A mirror mapping call: maps `size` bytes of `source` at `target`, updating `target`
    /// with the address the kernel actually used.
    typealias RemapMirror = (
        _ target: inout vm_address_t,
        _ size: vm_size_t,
        _ source: vm_address_t
    ) -> kern_return_t

    /// How many times mirrored mapping setup is attempted before the failure is reported.
    ///
    /// Reserving the range and mapping the mirror into it are separate kernel calls, so an
    /// unrelated mapping in this process can claim the mirror's address range in between.
    /// That race is transient, so a fresh reservation is worth trying.
    private static let mappingAttemptLimit = 5

    /// Reserves `length * 2` bytes and maps the first half over the second half.
    ///
    /// - Parameters:
    ///   - length: The page-aligned length of one half of the mapping.
    ///   - attemptLimit: The number of reserve-and-remap attempts before giving up.
    ///   - remap: The mirror mapping call to use.
    /// - Returns: The base address of the mirrored mapping.
    /// - Throws: `CircularBufferError` if the reservation or every mapping attempt fails.
    private static func makeMirroredMapping(
        length: vm_size_t,
        attemptLimit: Int,
        remap: RemapMirror
    ) throws -> vm_address_t {
        precondition(attemptLimit > 0, "Mapping needs at least one attempt")
        var lastRemapResult = KERN_NO_SPACE

        for _ in 0..<attemptLimit {
            var address: vm_address_t = 0

            // Reserve two adjacent regions so the second half can be replaced with a mirror
            // of the first half.
            let allocationResult = vm_allocate(
                mach_task_self_,
                &address,
                length * 2,
                VM_FLAGS_ANYWHERE
            )
            guard allocationResult == KERN_SUCCESS else {
                throw CircularBufferError.allocationFailed(allocationResult)
            }

            let mirrorStart = address + vm_address_t(length)

            // Free the second half of the reservation while keeping the address range available
            // for the fixed-address remap below.
            let deallocateResult = vm_deallocate(mach_task_self_, mirrorStart, length)
            guard deallocateResult == KERN_SUCCESS else {
                vm_deallocate(mach_task_self_, address, length * 2)
                throw CircularBufferError.allocationFailed(deallocateResult)
            }

            // Map the first half again immediately after itself. Pointer arithmetic can then
            // read or write across the logical wrap point without splitting the operation.
            var mirrorAddress = mirrorStart
            let remapResult = remap(&mirrorAddress, length, address)

            if remapResult == KERN_SUCCESS, mirrorAddress == mirrorStart {
                return address
            }

            // Something else took the mirror's address range between the reservation and the
            // remap. Release everything and start over from a fresh reservation.
            if remapResult == KERN_SUCCESS {
                vm_deallocate(mach_task_self_, mirrorAddress, length)
                lastRemapResult = KERN_NO_SPACE
            } else {
                lastRemapResult = remapResult
            }
            vm_deallocate(mach_task_self_, address, length)
        }

        throw CircularBufferError.remapFailed(lastRemapResult)
    }

    /// Maps `source` at `target` with `vm_remap`, sharing rather than copying the pages.
    static func remapMirror(
        target: inout vm_address_t,
        size: vm_size_t,
        source: vm_address_t
    ) -> kern_return_t {
        var currentProtection: vm_prot_t = 0
        var maximumProtection: vm_prot_t = 0

        return vm_remap(
            mach_task_self_,
            &target,
            size,
            0,
            0,
            mach_task_self_,
            source,
            0,
            &currentProtection,
            &maximumProtection,
            VM_INHERIT_DEFAULT
        )
    }

    deinit {
        vm_deallocate(
            mach_task_self_,
            vm_address_t(UInt(bitPattern: baseAddress)),
            allocationLength
        )
    }

    /// The number of bytes currently available to the consumer.
    public var availableBytes: Int {
        Int(fillCount.load(ordering: .acquiring))
    }

    /// The number of bytes currently available to the producer.
    public var freeBytes: Int {
        capacity - availableBytes
    }

    /// Removes all unread data and resets both offsets to the beginning of the buffer.
    ///
    /// Call this only when producer and consumer access is externally synchronized.
    public func clear() {
        headOffset = 0
        tailOffset = 0
        fillCount.store(0, ordering: .releasing)
    }

    /// Returns the contiguous writable region at the producer head.
    ///
    /// The returned pointer is valid until the next producer operation on this buffer. After
    /// writing into the region, call `produce(_:)` with the number of bytes written.
    ///
    /// - Returns: A writable buffer, or `nil` when the ring is full.
    public func head() -> UnsafeMutableRawBufferPointer? {
        let count = freeBytes
        guard count > 0 else {
            return nil
        }

        let pointer = baseAddress.advanced(by: Int(headOffset))
        return UnsafeMutableRawBufferPointer(start: pointer, count: count)
    }

    /// Advances the producer head after bytes have been written through `head()`.
    ///
    /// - Parameter byteCount: The number of newly written bytes.
    /// - Precondition: `byteCount` is non-negative and no larger than `freeBytes`.
    public func produce(_ byteCount: Int) {
        precondition(byteCount >= 0, "Cannot produce a negative byte count")
        precondition(byteCount <= freeBytes, "Cannot produce more bytes than the buffer has free")
        guard byteCount > 0 else {
            return
        }

        let next = (UInt64(headOffset) + UInt64(byteCount)) % UInt64(capacity)
        headOffset = UInt32(next)
        fillCount.add(UInt32(byteCount), ordering: .releasing)
    }

    /// Returns the contiguous readable region at the consumer tail.
    ///
    /// The returned pointer is valid until the next consumer operation on this buffer. After
    /// reading from the region, call `consume(_:)` with the number of bytes read.
    ///
    /// - Returns: A readable buffer, or `nil` when the ring is empty.
    public func tail() -> UnsafeRawBufferPointer? {
        let count = availableBytes
        guard count > 0 else {
            return nil
        }

        let pointer = UnsafeRawPointer(baseAddress.advanced(by: Int(tailOffset)))
        return UnsafeRawBufferPointer(start: pointer, count: count)
    }

    /// Advances the consumer tail after bytes have been read through `tail()`.
    ///
    /// - Parameter byteCount: The number of bytes to remove from the buffer.
    /// - Precondition: `byteCount` is non-negative and no larger than `availableBytes`.
    public func consume(_ byteCount: Int) {
        precondition(byteCount >= 0, "Cannot consume a negative byte count")
        precondition(byteCount <= availableBytes, "Cannot consume more bytes than the buffer has available")
        guard byteCount > 0 else {
            return
        }

        let next = (UInt64(tailOffset) + UInt64(byteCount)) % UInt64(capacity)
        tailOffset = UInt32(next)
        fillCount.subtract(UInt32(byteCount), ordering: .releasing)
    }

    /// Copies all bytes from `source` into the ring if enough free space is available.
    ///
    /// - Parameter source: The bytes to append.
    /// - Returns: `true` when all bytes were written; otherwise `false` and the buffer is unchanged.
    @discardableResult
    public func write(_ source: borrowing UnsafeRawBufferPointer) -> Bool {
        guard source.count <= freeBytes, let destination = head() else {
            return false
        }

        UnsafeMutableRawBufferPointer(
            start: destination.baseAddress,
            count: source.count
        ).copyMemory(from: source)
        produce(source.count)
        return true
    }

    /// Copies bytes from the ring into `destination` and consumes the copied bytes.
    ///
    /// - Parameter destination: Storage that receives up to `destination.count` bytes.
    /// - Returns: The number of bytes copied and consumed.
    @discardableResult
    public func read(into destination: borrowing UnsafeMutableRawBufferPointer) -> Int {
        guard let source = tail() else {
            return 0
        }

        let byteCount = Swift.min(destination.count, source.count)
        UnsafeMutableRawBufferPointer(
            start: destination.baseAddress,
            count: byteCount
        ).copyMemory(from: UnsafeRawBufferPointer(start: source.baseAddress, count: byteCount))
        consume(byteCount)
        return byteCount
    }

    /// Copies a bitwise-copyable value into the ring.
    ///
    /// This is a byte-copy convenience, not a stable serialization format. Use it for values
    /// whose in-memory representation is meaningful within the current process and build.
    ///
    /// - Parameter value: The value to append.
    /// - Returns: `true` when the value was written; otherwise `false` and the buffer is unchanged.
    @discardableResult
    public func write<T: BitwiseCopyable>(_ value: borrowing T) -> Bool {
        withUnsafeBytes(of: value) { source in
            write(source)
        }
    }

    /// Reads one bitwise-copyable value from the ring.
    ///
    /// The value is copied out of byte storage, so the ring's tail does not need to be aligned
    /// for `T`.
    ///
    /// - Parameter type: The value type to read.
    /// - Returns: A value when enough bytes are available; otherwise `nil` and the buffer is unchanged.
    /// - Precondition: `T` has a nonzero byte size.
    public func read<T: BitwiseCopyable>(as type: T.Type = T.self) -> T? {
        let byteCount = MemoryLayout<T>.size
        precondition(byteCount > 0, "Cannot read a zero-sized value")
        guard availableBytes >= byteCount else {
            return nil
        }

        return withUnsafeTemporaryAllocation(
            byteCount: byteCount,
            alignment: MemoryLayout<T>.alignment
        ) { scratch in
            let readCount = read(into: scratch)
            precondition(readCount == byteCount, "Typed read consumed an unexpected byte count")
            return scratch.load(as: T.self)
        }
    }

    /// Copies a buffer of bitwise-copyable values into the ring.
    ///
    /// Values are appended as a packed sequence of each element's in-memory bytes. Padding
    /// between elements is not copied.
    ///
    /// - Parameter values: The values to append.
    /// - Returns: `true` when all values were written; otherwise `false` and the buffer is unchanged.
    @discardableResult
    public func write<T: BitwiseCopyable>(_ values: borrowing UnsafeBufferPointer<T>) -> Bool {
        guard !values.isEmpty else {
            return true
        }

        let byteCount = MemoryLayout<T>.size
        precondition(byteCount > 0, "Cannot write zero-sized values")
        guard values.count <= Int.max / byteCount, values.count * byteCount <= freeBytes else {
            return false
        }

        for index in values.indices {
            var value = values[index]
            let wrote = withUnsafeBytes(of: &value) { source in
                write(source)
            }
            precondition(wrote, "Typed buffer write failed after capacity preflight")
        }

        return true
    }

    /// Reads bitwise-copyable values from the ring into an initialized destination buffer.
    ///
    /// Only complete values are read. If fewer bytes than one value are available, this method
    /// returns zero and leaves the buffer unchanged.
    ///
    /// - Parameter destination: The destination values to overwrite.
    /// - Returns: The number of complete values copied and consumed.
    /// - Precondition: `T` has a nonzero byte size.
    @discardableResult
    public func read<T: BitwiseCopyable>(into destination: UnsafeMutableBufferPointer<T>) -> Int {
        guard !destination.isEmpty else {
            return 0
        }

        let byteCount = MemoryLayout<T>.size
        precondition(byteCount > 0, "Cannot read zero-sized values")

        let elementCount = Swift.min(destination.count, availableBytes / byteCount)
        guard elementCount > 0 else {
            return 0
        }

        for index in 0..<elementCount {
            let readCount = withUnsafeMutableBytes(of: &destination[index]) { bytes in
                read(into: bytes)
            }
            precondition(readCount == byteCount, "Typed buffer read consumed an unexpected byte count")
        }

        return elementCount
    }

    /// Provides the producer with a writable span and advances by the closure's result.
    ///
    /// - Parameters:
    ///   - maximumBytes: An optional upper bound for the writable span passed to `body`.
    ///   - body: A closure that writes bytes and returns the number of bytes produced.
    /// - Returns: The number of bytes produced.
    /// - Precondition: The closure returns a value from zero through the provided span length.
    @discardableResult
    public func write(
        maximumBytes: Int? = nil,
        _ body: (UnsafeMutableRawBufferPointer) throws -> Int
    ) rethrows -> Int {
        guard let writable = head() else {
            return 0
        }

        let byteLimit = Swift.min(maximumBytes ?? writable.count, writable.count)
        let produced = try body(
            UnsafeMutableRawBufferPointer(start: writable.baseAddress, count: byteLimit)
        )
        precondition(produced >= 0 && produced <= byteLimit, "Closure returned an invalid produced byte count")
        produce(produced)
        return produced
    }

    /// Provides the consumer with a readable span and advances by the closure's result.
    ///
    /// - Parameters:
    ///   - maximumBytes: An optional upper bound for the readable span passed to `body`.
    ///   - body: A closure that reads bytes and returns the number of bytes consumed.
    /// - Returns: The number of bytes consumed.
    /// - Precondition: The closure returns a value from zero through the provided span length.
    @discardableResult
    public func read(
        maximumBytes: Int? = nil,
        _ body: (UnsafeRawBufferPointer) throws -> Int
    ) rethrows -> Int {
        guard let readable = tail() else {
            return 0
        }

        let byteLimit = Swift.min(maximumBytes ?? readable.count, readable.count)
        let consumed = try body(
            UnsafeRawBufferPointer(start: readable.baseAddress, count: byteLimit)
        )
        precondition(consumed >= 0 && consumed <= byteLimit, "Closure returned an invalid consumed byte count")
        consume(consumed)
        return consumed
    }
}
