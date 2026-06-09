//
//  ApiClient.swift
//  KasookooSDK
//
//

import Foundation

/// Provides authenticated tokens to the ApiClient.
///
/// Defined as a protocol to break the circular dependency between
/// `SessionManager` and `ApiClient`.
internal protocol AuthTokenProvider: Sendable {
    /// Returns a valid token, refreshing if necessary.
    func ensureValidToken() async throws -> String
    
    /// Forces a refresh, used after 401/403 retry.
    func forceRefresh() async throws -> String
}

/// The core HTTP client used by all SDK services.
///
/// Responsibilities:
/// - Build authenticated requests
/// - Execute via URLSession
/// - Decode responses into typed values or `KasookooError`
/// - Auto-retry on 401 (once) by refreshing the session
/// - Apply retry policies for network failures
internal final class ApiClient: @unchecked Sendable {
    
    // MARK: - Properties
    
    private let session: URLSession
    private let requestBuilder: RequestBuilder
    private let responseDecoder: ResponseDecoder
    private let logger: Logger
    
    /// Provided after construction to break the circular dependency with SessionManager.
    private var authProvider: AuthTokenProvider?
    private let authProviderLock = NSLock()
    
    // MARK: - Init
    
    init(
        baseURL: URL,
        publishableKey: String,
        organizationId: String,
        logger: Logger,
        session: URLSession = .shared
    ) {
        self.session = session
        self.requestBuilder = RequestBuilder(
            baseURL: baseURL,
            publishableKey: publishableKey,
            organizationId: organizationId
        )
        self.responseDecoder = ResponseDecoder()
        self.logger = logger
    }
    
    // MARK: - Auth Provider Wiring
    
    /// Injects the auth token provider after initialization.
    /// Called once by the SDK during setup to wire up SessionManager.
    func setAuthProvider(_ provider: AuthTokenProvider) {
        authProviderLock.lock()
        defer { authProviderLock.unlock() }
        self.authProvider = provider
    }
    
    private func currentAuthProvider() -> AuthTokenProvider? {
        authProviderLock.lock()
        defer { authProviderLock.unlock() }
        return authProvider
    }
    
    // MARK: - Public Request Methods
    
    /// Sends a request with an `Encodable` body and decodes the response.
    func send<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        endpoint: Endpoint,
        body: Request,
        responseType: Response.Type,
        retryPolicy: RetryPolicy = .default
    ) async throws -> Response {
        return try await performRequest(
            endpoint: endpoint,
            body: body,
            responseType: Response.self,
            retryPolicy: retryPolicy
        )
    }
    
    /// Sends a request without a body and decodes the response.
    func send<Response: Decodable & Sendable>(
        endpoint: Endpoint,
        responseType: Response.Type,
        retryPolicy: RetryPolicy = .default
    ) async throws -> Response {
        return try await performRequest(
            endpoint: endpoint,
            body: Optional<EmptyBody>.none,
            responseType: Response.self,
            retryPolicy: retryPolicy
        )
    }
    
    /// Sends a request that returns no decoded body (status-only).
    func sendVoid(
        endpoint: Endpoint,
        retryPolicy: RetryPolicy = .default
    ) async throws {
        _ = try await performRequest(
            endpoint: endpoint,
            body: Optional<EmptyBody>.none,
            responseType: EmptyResponse.self,
            retryPolicy: retryPolicy
        )
    }
    
    // MARK: - Core Request Execution
    
    private func performRequest<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        endpoint: Endpoint,
        body: Body?,
        responseType: Response.Type,
        retryPolicy: RetryPolicy
    ) async throws -> Response {
        
        let requestId = UUID().uuidString
        logger.debug("→ \(endpoint.method.rawValue) \(endpoint.path) [reqId: \(requestId)]")
        
        return try await Retrier.execute(
            policy: retryPolicy,
            isRetryable: { error in
                guard let sdkError = error as? KasookooError else { return false }
                // Don't retry permission errors via the network retry path
                if sdkError.code == .permissionDenied { return false }
                return sdkError.retryable
            }
        ) { [weak self] in
            guard let self = self else {
                throw KasookooError.unknown(message: "ApiClient was deallocated.")
            }
            return try await self.executeOnce(
                endpoint: endpoint,
                body: body,
                responseType: Response.self,
                requestId: requestId
            )
        }
    }
    
    /// Executes a single request attempt with one auto-refresh on 401.
    private func executeOnce<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        endpoint: Endpoint,
        body: Body?,
        responseType: Response.Type,
        requestId: String
    ) async throws -> Response {
        
        // Get auth token if needed
        var authToken: String?
        if endpoint.requiresAuth {
            guard let provider = currentAuthProvider() else {
                throw KasookooError(
                    code: .sessionInvalid,
                    message: "Auth provider not configured. Did you call connect()?",
                    retryable: false
                )
            }
            authToken = try await provider.ensureValidToken()
        }
        
        // Build the request
        let urlRequest = try requestBuilder.build(
            endpoint: endpoint,
            body: body,
            authToken: authToken,
            requestId: requestId
        )
        
        // Execute the request
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            logger.warning("Network error on \(endpoint.path): \(error.localizedDescription)")
            throw KasookooError.networkUnavailable(
                message: "Network request failed: \(error.localizedDescription)",
                underlyingError: error
            )
        }
        
        // Try to decode the response
        do {
            let decoded = try responseDecoder.decode(
                Response.self,
                from: data,
                response: response,
                requestId: requestId
            )
            logger.debug("← \(endpoint.path) success [reqId: \(requestId)]")
            return decoded
        } catch let error as KasookooError {
            // Handle 401: refresh token and retry ONCE
            if error.code == .sessionExpired,
               endpoint.requiresAuth,
               let provider = currentAuthProvider() {
                logger.info("Got 401 on \(endpoint.path), attempting one-time session refresh")
                
                let newToken: String
                do {
                    newToken = try await provider.forceRefresh()
                } catch {
                    // Refresh failed — propagate the original 401
                    logger.warning("Session refresh failed: \(error.localizedDescription)")
                    throw error
                }
                
                // Retry the original request with the new token
                let retryRequest = try requestBuilder.build(
                    endpoint: endpoint,
                    body: body,
                    authToken: newToken,
                    requestId: requestId
                )
                
                let (retryData, retryResponse) = try await session.data(for: retryRequest)
                return try responseDecoder.decode(
                    Response.self,
                    from: retryData,
                    response: retryResponse,
                    requestId: requestId
                )
            }
            
            // Not a 401 or no provider — rethrow
            throw error
        }
    }
}

// MARK: - Empty Body Helper

private struct EmptyBody: Encodable, Sendable {}
