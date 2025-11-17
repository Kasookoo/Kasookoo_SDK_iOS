import Foundation

final class LiveKitManager {
    private var isConnected = false

    func connect(with token: String, completion: @escaping (Bool) -> Void) {
        // Stubbed integration for now
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            self.isConnected = true
            completion(true)
        }
    }

    func disconnect() {
        isConnected = false
    }
}
