//
//  TestSupport.swift
//  KasookooSDKTests
//
//  Shared helpers: an in-process HTTP stub, JWT builder, and a timeout that
//  fails a test instead of hanging it.
//

import Foundation
@testable import KasookooSDK

// MARK: - HTTP stub

/// Answers every request made through `StubURLProtocol` and records it.
///
/// A single shared instance, so suites that use it are `.serialized`.
final class StubServer: @unchecked Sendable {
    
    typealias Responder = @Sendable (URLRequest) -> (status: Int, body: Data)
    
    static let shared = StubServer()
    
    private let lock = NSLock()
    private var responder: Responder?
    private var requests: [URLRequest] = []
    
    /// Clears recorded requests and installs a new responder.
    func reset(_ responder: @escaping Responder) {
        lock.lock()
        defer { lock.unlock() }
        self.responder = responder
        self.requests = []
    }
    
    var recorded: [URLRequest] {
        lock.lock()
        defer { lock.unlock() }
        return requests
    }
    
    func handle(_ request: URLRequest) -> (status: Int, body: Data) {
        lock.lock()
        requests.append(request)
        let current = responder
        lock.unlock()
        return current?(request) ?? (500, Data())
    }
}

final class StubURLProtocol: URLProtocol {
    
    override class func canInit(with request: URLRequest) -> Bool { true }
    
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    
    override func startLoading() {
        let result = StubServer.shared.handle(request)
        let response = HTTPURLResponse(
            url: request.url ?? URL(string: "https://stub.test")!,
            statusCode: result.status,
            httpVersion: "HTTP/1.1",
            headerFields: ["Content-Type": "application/json"]
        )!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: result.body)
        client?.urlProtocolDidFinishLoading(self)
    }
    
    override func stopLoading() {}
}

/// A URLSession whose every request is answered by `StubServer.shared`.
func makeStubSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [StubURLProtocol.self]
    return URLSession(configuration: configuration)
}

// MARK: - Fixtures

let testLogger = Logger(config: .silent)

let testConfig = KasookooConfig(
    publishableKey: "pk_test_unit",
    organizationId: "org_test",
    environment: .staging,
    logging: .silent,
    customBaseURL: URL(string: "https://stub.test")!,
    telemetry: .disabled
)

/// Builds an unsigned JWT carrying the given claims. The SDK only reads the
/// payload, so the signature is a placeholder.
func makeJWT(_ claims: [String: String]) -> String {
    func base64url(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
    let header = base64url(Data(#"{"alg":"HS256","typ":"JWT"}"#.utf8))
    let payload = base64url(try! JSONSerialization.data(withJSONObject: claims))
    return "\(header).\(payload).signature"
}

/// JSON body of a session create/rotate response.
func sessionResponse(token: String, expiresIn: Int = 600) -> Data {
    let object: [String: Any] = ["token": token, "token_type": "Bearer", "expires_in": expiresIn]
    return try! JSONSerialization.data(withJSONObject: object)
}

// MARK: - Timeout

struct TestTimeout: Error {}

/// Resumes exactly once, from whichever side finishes first.
private final class OnceContinuation<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?
    
    init(_ continuation: CheckedContinuation<T, Error>) {
        self.continuation = continuation
    }
    
    func resume(with result: Result<T, Error>) {
        lock.lock()
        let pending = continuation
        continuation = nil
        lock.unlock()
        pending?.resume(with: result)
    }
}

/// Runs `operation`, throwing `TestTimeout` if it has not finished in time.
///
/// Unlike a task group, this returns even if `operation` never completes
/// (for example a task awaiting itself), so a regression fails the test
/// rather than hanging the whole run.
func withTimeout<T: Sendable>(
    seconds: Double = 10,
    _ operation: @escaping @Sendable () async throws -> T
) async throws -> T {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<T, Error>) in
        let once = OnceContinuation(continuation)
        Task {
            do {
                once.resume(with: .success(try await operation()))
            } catch {
                once.resume(with: .failure(error))
            }
        }
        Task {
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            once.resume(with: .failure(TestTimeout()))
        }
    }
}
