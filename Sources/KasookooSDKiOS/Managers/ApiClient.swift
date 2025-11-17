import Foundation

final class ApiClient {
    private var baseURL: String = ""

    func configure(baseURL: String) {
        self.baseURL = baseURL
    }

    func getCallerToken(for userId: String, completion: @escaping (String?) -> Void) {
        // Stubbed: host app should replace with real API call
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            completion("stubbed_token_\(userId)")
        }
    }
}
