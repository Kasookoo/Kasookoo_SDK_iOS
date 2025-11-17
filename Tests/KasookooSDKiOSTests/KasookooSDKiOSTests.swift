import XCTest
@testable import KasookooSDKiOS

final class KasookooSDKiOSTests: XCTestCase {
    func testInitialization() {
        KasookooSDK.shared.configure(apiBaseURL: "https://test.com")
        XCTAssertFalse(KasookooSDK.shared.isCallActive)
    }
}
