import XCTest
@testable import bbMusic

final class SmokeTests: XCTestCase {
    func testExecutableTargetIsImportable() {
        XCTAssertEqual(SearchKind.song.label, "歌曲")
    }
}
