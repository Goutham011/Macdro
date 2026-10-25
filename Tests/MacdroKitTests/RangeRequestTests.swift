import XCTest
@testable import MacdroKit

final class RangeRequestTests: XCTestCase {
    func testNoHeaderReturnsFull() {
        XCTAssertEqual(RangeRequest.parse(header: nil, fileSize: 100), .full)
    }

    func testPrefixRange() {
        XCTAssertEqual(
            RangeRequest.parse(header: "bytes=0-9", fileSize: 100),
            .partial(.init(start: 0, end: 9))
        )
    }

    func testOpenEndedRange() {
        XCTAssertEqual(
            RangeRequest.parse(header: "bytes=90-", fileSize: 100),
            .partial(.init(start: 90, end: 99))
        )
    }

    func testSuffixRange() {
        XCTAssertEqual(
            RangeRequest.parse(header: "bytes=-10", fileSize: 100),
            .partial(.init(start: 90, end: 99))
        )
    }

    func testEndIsClamped() {
        XCTAssertEqual(
            RangeRequest.parse(header: "bytes=95-200", fileSize: 100),
            .partial(.init(start: 95, end: 99))
        )
    }

    func testInvalidStartIsUnsatisfiable() {
        XCTAssertEqual(RangeRequest.parse(header: "bytes=100-", fileSize: 100), .unsatisfiable)
    }

    func testMultipleRangesFallBackToFull() {
        XCTAssertEqual(RangeRequest.parse(header: "bytes=0-2,4-6", fileSize: 100), .full)
    }
}
