import XCTest
@testable import UchidenLinkCore

final class RingBufferTests: XCTestCase {
    func testWriteRead() {
        let ring = SpscRingBuffer(capacity: 64)
        XCTAssertEqual(ring.write([1, 2, 3, 4]), 4)
        XCTAssertEqual(ring.availableToRead, 4)
        var out = [Float](repeating: -1, count: 6)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0, count: 6) }
        XCTAssertEqual(out, [1, 2, 3, 4, 0, 0]) // underflow is silence
        XCTAssertEqual(ring.availableToRead, 0)
    }

    func testWrapAround() {
        let ring = SpscRingBuffer(capacity: 8)
        ring.write([1, 2, 3, 4, 5, 6])
        var first = [Float](repeating: 0, count: 4)
        first.withUnsafeMutableBufferPointer { ring.read(into: $0, count: 4) }
        XCTAssertEqual(first, [1, 2, 3, 4])
        ring.write([7, 8, 9, 10])
        var rest = [Float](repeating: 0, count: 6)
        rest.withUnsafeMutableBufferPointer { ring.read(into: $0, count: 6) }
        XCTAssertEqual(rest, [5, 6, 7, 8, 9, 10])
    }

    func testFullDrops() {
        let ring = SpscRingBuffer(capacity: 4)
        XCTAssertEqual(ring.write([1, 2, 3, 4, 5]), 4)
        XCTAssertEqual(ring.write([9]), 0)
    }
}

final class JitterBufferTests: XCTestCase {
    private func frame(_ value: Int16) -> [Int16] { [Int16](repeating: value, count: 160) }

    func testPrefetchThenInOrderPlayout() {
        let jb = JitterBuffer(prefetchFrames: 3)
        jb.push(sequenceNumber: 10, frame: frame(1))
        XCTAssertEqual(jb.popFrame(), [Int16](repeating: 0, count: 160)) // not started
        jb.push(sequenceNumber: 11, frame: frame(2))
        jb.push(sequenceNumber: 12, frame: frame(3))
        XCTAssertEqual(jb.popFrame(), frame(1))
        XCTAssertEqual(jb.popFrame(), frame(2))
        XCTAssertEqual(jb.popFrame(), frame(3))
    }

    func testReorderAndDuplicate() {
        let jb = JitterBuffer(prefetchFrames: 2)
        jb.push(sequenceNumber: 21, frame: frame(2))
        jb.push(sequenceNumber: 20, frame: frame(1))
        jb.push(sequenceNumber: 20, frame: frame(9)) // duplicate, dropped
        XCTAssertEqual(jb.popFrame(), frame(1))
        XCTAssertEqual(jb.popFrame(), frame(2))
    }

    func testPlcRepeatsLastFrame() {
        let jb = JitterBuffer(prefetchFrames: 1)
        jb.push(sequenceNumber: 5, frame: frame(7))
        XCTAssertEqual(jb.popFrame(), frame(7))
        XCTAssertEqual(jb.popFrame(), frame(3)) // seq 6 missing -> PLC (減衰した直前フレーム 7>>1)
        jb.push(sequenceNumber: 6, frame: frame(8)) // late, dropped
        jb.push(sequenceNumber: 7, frame: frame(9))
        XCTAssertEqual(jb.popFrame(), frame(9))
    }

    func testSequenceWrap() {
        let jb = JitterBuffer(prefetchFrames: 2)
        jb.push(sequenceNumber: 65535, frame: frame(1))
        jb.push(sequenceNumber: 0, frame: frame(2))
        XCTAssertEqual(jb.popFrame(), frame(1))
        XCTAssertEqual(jb.popFrame(), frame(2))
    }
}

final class RingUnderrunTests: XCTestCase {
    func testUnderrunCountedOnlyAfterFirstWrite() {
        let ring = SpscRingBuffer(capacity: 64)
        var out = [Float](repeating: 0, count: 8)
        out.withUnsafeMutableBufferPointer { ring.read(into: $0, count: 8) }
        XCTAssertEqual(ring.underruns, 0) // 未開始は数えない
        ring.write([1, 2, 3])
        out.withUnsafeMutableBufferPointer { ring.read(into: $0, count: 8) }
        XCTAssertEqual(ring.underruns, 1)
        XCTAssertEqual(ring.underrunSamples, 5)
        ring.write([Float](repeating: 1, count: 8))
        out.withUnsafeMutableBufferPointer { ring.read(into: $0, count: 8) }
        XCTAssertEqual(ring.underruns, 1)
        ring.reset()
        XCTAssertEqual(ring.underruns, 0)
    }
}
