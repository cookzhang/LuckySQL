import XCTest
@testable import LuckySQL

final class LuckySQLTests: XCTestCase {
    func testIdentifierQuoting() throws {
        XCTAssertEqual(try SQLIdentifier.quote("orders"), "`orders`")
        XCTAssertEqual(try SQLIdentifier.quote("odd`name"), "`odd``name`")
        XCTAssertThrowsError(try SQLIdentifier.quote(""))
    }
}
