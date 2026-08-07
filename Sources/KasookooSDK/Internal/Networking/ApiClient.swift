//
//  ApiClient.swift
//  KasookooSDK
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
        print("→ \(endpoint.method.rawValue) \(endpoint.path) [Body \(body)] \n [Auth Token: \(authToken)] \n [reqId: \(requestId)]")
        // Build the request
        let urlRequest = try requestBuilder.build(
            endpoint: endpoint,
            body: body,
            authToken: authToken,
            requestId: requestId
        )
        
        logRequest(urlRequest, endpoint: endpoint, requestId: requestId)
        
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
        
        logResponse(data, response: response, endpoint: endpoint, requestId: requestId)
        
        // Try to decode the response
        do {
            let decoded = try responseDecoder.decode(
                Response.self,
                from: data,
                response: response,
                requestId: requestId
            )
            print("← \(endpoint.path) success [reqId: \(requestId)]")
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
                
                logRequest(retryRequest, endpoint: endpoint, requestId: requestId, isRetry: true)
                
                let (retryData, retryResponse) = try await session.data(for: retryRequest)
                
                logResponse(retryData, response: retryResponse, endpoint: endpoint, requestId: requestId, isRetry: true)
                
                if let http = retryResponse as? HTTPURLResponse, http.statusCode == 401 {
                    throw KasookooError(
                        code: .unauthorized,
                        message: "Authentication failed after refreshing the session.",
                        retryable: false,
                        httpStatus: 401
                    )
                }
                
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
    
    // MARK: - Wire Logging (DEBUG builds only)
    //
    // Logs the full request and response bodies — invaluable when diagnosing
    // backend contract mismatches.
    //
    // ⚠️ Compiled out of RELEASE builds on purpose: these bodies carry the
    // publishable key, session JWTs, and LiveKit access tokens. Logging them in
    // a shipped app would leak credentials into the device console.
    
    private func logRequest(
        _ request: URLRequest,
        endpoint: Endpoint,
        requestId: String,
        isRetry: Bool = false
    ) {
#if DEBUG
        let tag = isRetry ? "↻ RETRY ➡️" : "➡️"
        let method = endpoint.method.rawValue
        let url = request.url?.absoluteString ?? endpoint.path
        
        var lines = ["\(tag) \(method) \(url) [reqId: \(requestId)]"]
        
        if let headers = request.allHTTPHeaderFields, !headers.isEmpty {
            let rendered = headers
                .map { "\($0.key): \(redactHeaderValue(key: $0.key, value: $0.value))" }
                .sorted()
                .joined(separator: "\n      ")
            lines.append("   Headers:\n      \(rendered)")
        }
        
        if let bodyData = request.httpBody,
           let json = String(data: bodyData, encoding: .utf8),
           !json.isEmpty {
            lines.append("   Body: \(json)")
        }
        
        logger.debug(lines.joined(separator: "\n"))
        print(lines.joined(separator: "\n"))
#endif
    }
    
    private func logResponse(
        _ data: Data,
        response: URLResponse,
        endpoint: Endpoint,
        requestId: String,
        isRetry: Bool = false
    ) {
#if DEBUG
        let tag = isRetry ? "↻ RETRY ⬅️" : "⬅️"
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let icon = (200..<300).contains(status) ? "✅" : "❌"
        
        let raw = String(data: data, encoding: .utf8)
        ?? "<non-UTF8 body, \(data.count) bytes>"
        let body = raw.isEmpty ? "<empty>" : raw
        
        logger.debug("\(tag) \(icon) \(status) \(endpoint.path) [reqId: \(requestId)]\n   Resp: \(body)")
        print("Log Response \(tag) \(icon) \(status) \(endpoint.path) [reqId: \(requestId)]\n   Resp: \(body)")
#endif
    }
    
    /// Masks obviously sensitive header values so a shared debug log can't leak a
    /// full bearer token. Bodies are still logged in full — DEBUG only.
    private func redactHeaderValue(key: String, value: String) -> String {
        let sensitive = ["authorization", "x-api-key", "cookie"]
        guard sensitive.contains(key.lowercased()) else { return value }
        guard value.count > 16 else { return "***" }
        return "\(value.prefix(12))…\(value.suffix(4))"
    }
}

// MARK: - Empty Body Helper

private struct EmptyBody: Encodable, Sendable {}

// MARK: - APIRequest support (ADDITIVE — Map §14, seam #2)
//
// New send(...) methods that take an `APIRequest` descriptor instead of an
// `Endpoint`. These mirror the Endpoint-based methods above exactly — same auth
// flow, same one-time 401 refresh, same retry policy — and reuse RequestBuilder /
// ResponseDecoder / the auth provider.
//
// Same-file extension so it can reach ApiClient's private members (session,
// requestBuilder, responseDecoder, logger, currentAuthProvider()).
//
// TRANSITIONAL: services still call the Endpoint methods. As each migrates to
// APIRequest, its calls move here. When the last one moves, the Endpoint methods
// (and the enum) are deleted and this becomes the only path — no logic is
// duplicated permanently, only during the migration window (Map §14.7).

extension ApiClient {

    /// Sends an `APIRequest` with an `Encodable` body and decodes the response.
    func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        apiRequest: APIRequest,
        body: Body,
        responseType: Response.Type,
        retryPolicy: RetryPolicy = .default
    ) async throws -> Response {
        return try await performRequest(
            apiRequest: apiRequest,
            body: body,
            responseType: Response.self,
            retryPolicy: retryPolicy
        )
    }

    /// Sends an `APIRequest` without a body and decodes the response.
    func send<Response: Decodable & Sendable>(
        apiRequest: APIRequest,
        responseType: Response.Type,
        retryPolicy: RetryPolicy = .default
    ) async throws -> Response {
        return try await performRequest(
            apiRequest: apiRequest,
            body: Optional<APIRequestEmptyBodyAC>.none,
            responseType: Response.self,
            retryPolicy: retryPolicy
        )
    }

    /// Sends an `APIRequest` that returns no decoded body (status-only).
    func sendVoid(
        apiRequest: APIRequest,
        retryPolicy: RetryPolicy = .default
    ) async throws {
        _ = try await performRequest(
            apiRequest: apiRequest,
            body: Optional<APIRequestEmptyBodyAC>.none,
            responseType: EmptyResponse.self,
            retryPolicy: retryPolicy
        )
    }

    // MARK: - Core (APIRequest)

    private func performRequest<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        apiRequest: APIRequest,
        body: Body?,
        responseType: Response.Type,
        retryPolicy: RetryPolicy
    ) async throws -> Response {

        let requestId = UUID().uuidString
        logger.debug("→ \(apiRequest.method.rawValue) \(apiRequest.resolvedPath) [reqId: \(requestId)]")

        return try await Retrier.execute(
            policy: retryPolicy,
            isRetryable: { error in
                guard let sdkError = error as? KasookooError else { return false }
                if sdkError.code == .permissionDenied { return false }
                return sdkError.retryable
            }
        ) { [weak self] in
            guard let self = self else {
                throw KasookooError.unknown(message: "ApiClient was deallocated.")
            }
            return try await self.executeOnce(
                apiRequest: apiRequest,
                body: body,
                responseType: Response.self,
                requestId: requestId
            )
        }
    }

    /// One request attempt with a single auto-refresh on 401 — mirrors the
    /// Endpoint-based `executeOnce`.
    private func executeOnce<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        apiRequest: APIRequest,
        body: Body?,
        responseType: Response.Type,
        requestId: String
    ) async throws -> Response {

        // Auth token if needed.
        var authToken: String?
        if apiRequest.requiresAuth {
            guard let provider = currentAuthProvider() else {
                throw KasookooError(
                    code: .sessionInvalid,
                    message: "Auth provider not configured. Did you call connect()?",
                    retryable: false
                )
            }
            authToken = try await provider.ensureValidToken()
        }

        let urlRequest = try requestBuilder.build(
            apiRequest: apiRequest,
            body: body,
            authToken: authToken,
            requestId: requestId
        )

        // Execute.
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            logger.warning("Network error on \(apiRequest.resolvedPath): \(error.localizedDescription)")
            throw KasookooError.networkUnavailable(
                message: "Network request failed: \(error.localizedDescription)",
                underlyingError: error
            )
        }

        // Decode.
        do {
            let decoded = try responseDecoder.decode(
                Response.self,
                from: data,
                response: response,
                requestId: requestId
            )
            logger.debug("← \(apiRequest.resolvedPath) success [reqId: \(requestId)]")
            return decoded
        } catch let error as KasookooError {
            // 401: refresh once and retry.
            if error.code == .sessionExpired,
               apiRequest.requiresAuth,
               let provider = currentAuthProvider() {
                logger.info("Got 401 on \(apiRequest.resolvedPath), attempting one-time session refresh")

                let newToken: String
                do {
                    newToken = try await provider.forceRefresh()
                } catch {
                    logger.warning("Session refresh failed: \(error.localizedDescription)")
                    throw error
                }

                let retryRequest = try requestBuilder.build(
                    apiRequest: apiRequest,
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
            throw error
        }
    }
}

/// Empty body sentinel for the APIRequest path (separate name to avoid clashing
/// with the file's private `EmptyBody`).
private struct APIRequestEmptyBodyAC: Encodable, Sendable {}
