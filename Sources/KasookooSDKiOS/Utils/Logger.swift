import Foundation

enum Logger {
    static func log(_ message: String) {
        #if DEBUG
        print("[KasookooSDK] \(message)")
        #endif
    }
}
