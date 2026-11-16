import Synchronization

/// Lock-free single-producer / single-consumer ring buffer of Float samples.
/// The audio render block (real-time thread) is the consumer; a feeder timer
/// is the producer. Isolated as @unchecked Sendable per design §3.1: the only
/// shared mutable state is the atomic head/tail pair plus the preallocated
/// sample storage, which is never reallocated after init.
public final class SpscRingBuffer: @unchecked Sendable {
    private let storage: UnsafeMutableBufferPointer<Float>
    private let capacity: Int // power of two
    private let mask: Int
    private let head = Atomic<Int>(0) // read position (monotonic)
    private let tail = Atomic<Int>(0) // write position (monotonic)
    /// 一度でも書かれた後に、読み出し要求に対してデータが足りなかった回数 (レンダー側のアンダーラン)。
    private let underrunCount = Atomic<Int>(0)
    /// 足りずに無音で埋めたサンプル数の合計。
    private let underrunSamplesCount = Atomic<Int>(0)

    public init(capacity: Int = 16384) {
        precondition(capacity > 0 && (capacity & (capacity - 1)) == 0, "capacity must be a power of two")
        self.capacity = capacity
        self.mask = capacity - 1
        self.storage = UnsafeMutableBufferPointer<Float>.allocate(capacity: capacity)
        self.storage.initialize(repeating: 0)
    }

    deinit {
        storage.deallocate()
    }

    public var availableToRead: Int {
        tail.load(ordering: .acquiring) - head.load(ordering: .acquiring)
    }

    /// Producer side. Drops samples that do not fit; returns the count written.
    @discardableResult
    public func write(_ samples: [Float]) -> Int {
        let t = tail.load(ordering: .relaxed)
        let h = head.load(ordering: .acquiring)
        let free = capacity - (t - h)
        let n = min(free, samples.count)
        guard n > 0 else { return 0 }
        for i in 0..<n {
            storage[(t + i) & mask] = samples[i]
        }
        tail.store(t + n, ordering: .releasing)
        return n
    }

    /// Consumer side (render block). Always fills `count` samples; positions
    /// beyond the available data are silence (and are not consumed).
    public func read(into buffer: UnsafeMutableBufferPointer<Float>, count: Int) {
        let h = head.load(ordering: .relaxed)
        let t = tail.load(ordering: .acquiring)
        let avail = t - h
        let n = min(avail, count)
        for i in 0..<count {
            buffer[i] = i < n ? storage[(h + i) & mask] : 0
        }
        if n < count && t > 0 {
            underrunCount.wrappingAdd(1, ordering: .relaxed)
            underrunSamplesCount.wrappingAdd(count - n, ordering: .relaxed)
        }
        if n > 0 {
            head.store(h + n, ordering: .releasing)
        }
    }

    public func reset() {
        head.store(0, ordering: .relaxed)
        tail.store(0, ordering: .relaxed)
        underrunCount.store(0, ordering: .relaxed)
        underrunSamplesCount.store(0, ordering: .relaxed)
    }

    /// レンダー側のアンダーラン回数 (call_stats の playUnderrun)。
    public var underruns: Int { underrunCount.load(ordering: .relaxed) }
    public var underrunSamples: Int { underrunSamplesCount.load(ordering: .relaxed) }
}
