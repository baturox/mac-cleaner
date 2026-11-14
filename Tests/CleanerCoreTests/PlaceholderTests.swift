// PLACEHOLDER — replaced by the real engine tests.
import XCTest
@testable import CleanerCore

final class PlaceholderTests: XCTestCase {
    func testDiskInfoIsSane() {
        let info = LiveEngine().diskInfo()
        XCTAssertGreaterThan(info.totalBytes, 0)
        XCTAssertGreaterThanOrEqual(info.availableWithPurgeableBytes, info.freeBytes)
    }
}
