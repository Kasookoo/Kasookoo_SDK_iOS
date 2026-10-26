//
//  ApiClient.swift
//  KasookooSDK
//

import Foundation

/// Provides authenticated tokens to the ApiClient.
///
/// Defined as a protocol to break the circular dependency between
/// `SessionManager` and `ApiClient`. Class bound so `ApiClient` can hold it
/// weakly: `SessionManager` already owns the `ApiClient`, and a strong
/// reference back would keep the whole graph alive after `destroy()`.
internal protocol AuthTokenProvider: AnyObject, Sendable {
    /// Returns a valid token, refreshing if necessary.
    func ensureValidToken() async throws -> String
    
    /// Forces a refresh, used after a 401.
    func forceRefresh() async throws -> String
}

/// The core HTTP client used by all SDK services.
///
/// Responsibilities:
/// - Build authenticated requests
/// - Execute via URLSession
/// - Decode responses into typed values or `KasookooError`
/// - Auto-retry on 401 (once) by refreshing the session
/// - Apply retry policies for network failures, without ever repeating a
///   non-idempotent request the server may already have acted on
/// - Attach correlation headers (X-Request-ID, X-Call-Trace-ID, X-User-ID, X-Feature-Type)
///
/// There is exactly one request path. `Endpoint` values are converted to an
/// `APIRequest` (see `Endpoint.apiRequest`) and go through the same code as
/// module-owned requests, so auth, retry and telemetry behave identically.
internal final class ApiClient: @unchecked Sendable {
    
    // MARK: - Properties
    
    private let session: URLSession
    private let requestBuilder: RequestBuilder
    private let responseDecoder: ResponseDecoder
    private let logger: Logger
    
    /// Provided after construction to break the circular dependency with
    /// SessionManager. Weak on purpose, see `AuthTokenProvider`.
    private weak var authProvider: AuthTokenProvider?
    private let authProviderLock = NSLock()
    
    /// End user id sent as `X-User-ID` for backend log correlation.
    /// Set after a successful `identify()`, cleared on disconnect.
    private var correlationUserId: String?
    private let correlationLock = NSLock()
    
    /// Emits a client span per HTTP attempt and named log events such as
    /// `SESSION_EXPIRED`. Never throws and never blocks the request.
    private let telemetry: TelemetryReporting
    
    // MARK: - Init
    
    init(
        baseURL: URL,
        publishableKey: String,
        organizationId: String,
        logger: Logger,
        session: URLSession = .shared,
        telemetry: TelemetryReporting = NoopTelemetry()
    ) {
        self.session = session
        self.telemetry = telemetry
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
    
    // MARK: - Correlation Wiring
    
    /// Sets the end user id attached as `X-User-ID` on every request.
    /// Call with the identified user id after `identify()` succeeds, and with
    /// `nil` on disconnect / sign out.
    func setCorrelationUserId(_ userId: String?) {
        correlationLock.lock()
        defer { correlationLock.unlock() }
        self.correlationUserId = userId
    }
    
    private func currentCorrelationUserId() -> String? {
        correlationLock.lock()
        defer { correlationLock.unlock() }
        return correlationUserId
    }
    
    // MARK: - Endpoint Requests
    //
    // `bearerToken` sends that exact token and bypasses the auth provider,
    // including the automatic refresh on 401. The session endpoints (rotate,
    // revoke) MUST use it: they are called from inside a refresh, and asking
    // the provider for a token there would make the refresh wait on itself.
    
    /// Sends a request with an `Encodable` body and decodes the response.
    func send<Request: Encodable & Sendable, Response: Decodable & Sendable>(
        endpoint: Endpoint,
        body: Request,
        responseType: Response.Type,
        retryPolicy: RetryPolicy = .default,
        bearerToken: String? = nil
    ) async throws -> Response {
        return try await performRequest(
            request: endpoint.apiRequest,
            body: body,
            responseType: Response.self,
            retryPolicy: retryPolicy,
            explicitBearer: bearerToken
        )
    }
    
    /// Sends a request without a body and decodes the response.
    func send<Response: Decodable & Sendable>(
        endpoint: Endpoint,
        responseType: Response.Type,
        retryPolicy: RetryPolicy = .default,
        bearerToken: String? = nil
    ) async throws -> Response {
        return try await performRequest(
            request: endpoint.apiRequest,
            body: Optional<EmptyBody>.none,
            responseType: Response.self,
            retryPolicy: retryPolicy,
            explicitBearer: bearerToken
        )
    }
    
    /// Sends a request that returns no decoded body (status-only).
    func sendVoid(
        endpoint: Endpoint,
        retryPolicy: RetryPolicy = .default,
        bearerToken: String? = nil
    ) async throws {
        _ = try await performRequest(
            request: endpoint.apiRequest,
            body: Optional<EmptyBody>.none,
            responseType: EmptyResponse.self,
            retryPolicy: retryPolicy,
            explicitBearer: bearerToken
        )
    }
    
    // MARK: - APIRequest Requests (module-owned requests, Map §14 seam #2)
    
    /// Sends an `APIRequest` with an `Encodable` body and decodes the response.
    func send<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        apiRequest: APIRequest,
        body: Body,
        responseType: Response.Type,
        retryPolicy: RetryPolicy = .default
    ) async throws -> Response {
        return try await performRequest(
            request: apiRequest,
            body: body,
            responseType: Response.self,
            retryPolicy: retryPolicy,
            explicitBearer: nil
        )
    }
    
    /// Sends an `APIRequest` without a body and decodes the response.
    func send<Response: Decodable & Sendable>(
        apiRequest: APIRequest,
        responseType: Response.Type,
        retryPolicy: RetryPolicy = .default
    ) async throws -> Response {
        return try await performRequest(
            request: apiRequest,
            body: Optional<EmptyBody>.none,
            responseType: Response.self,
            retryPolicy: retryPolicy,
            explicitBearer: nil
        )
    }
    
    /// Sends an `APIRequest` that returns no decoded body (status-only).
    func sendVoid(
        apiRequest: APIRequest,
        retryPolicy: RetryPolicy = .default
    ) async throws {
        _ = try await performRequest(
            request: apiRequest,
            body: Optional<EmptyBody>.none,
            responseType: EmptyResponse.self,
            retryPolicy: retryPolicy,
            explicitBearer: nil
        )
    }
    
    // MARK: - Retry Classification
    
    /// URL loading failures that happen before a request can reach the
    /// server (no route, no DNS, no TCP/TLS connection). Repeating a POST
    /// after one of these cannot duplicate a side effect.
    ///
    /// Deliberately absent: `.timedOut` and `.networkConnectionLost`. Both can
    /// fire after the server received the request and acted on it.
    private static let preTransmissionURLErrorCodes: Set<Int> = [
        URLError.Code.notConnectedToInternet.rawValue,
        URLError.Code.cannotFindHost.rawValue,
        URLError.Code.cannotConnectToHost.rawValue,
        URLError.Code.dnsLookupFailed.rawValue,
        URLError.Code.dataNotAllowed.rawValue,
        URLError.Code.internationalRoamingOff.rawValue,
        URLError.Code.secureConnectionFailed.rawValue
    ]
    
    /// Whether a failed attempt may be repeated.
    ///
    /// Repeatable requests (GETs, DELETEs, and POSTs marked
    /// `isRepeatable`) retry on any retryable error. Other requests retry only
    /// when the server cannot have acted on them: the request was never
    /// transmitted, or the server explicitly refused it with 429. A timeout or
    /// 5xx on `sip/calls/make` may already have dialed a real phone, so it is
    /// never repeated.
    static func isRetryable(_ error: Error, isRepeatable: Bool) -> Bool {
        guard let sdkError = error as? KasookooError, sdkError.retryable else {
            return false
        }
        if sdkError.code == .permissionDenied { return false }
        // A 401 is never fixed by resending the same request. The provider
        // path already refreshed once inside `executeOnce`; an explicit-bearer
        // caller (rotation) must see the 401 at once and bootstrap instead of
        // sitting through the backoff schedule.
        if sdkError.code == .sessionExpired || sdkError.httpStatus == 401 { return false }
        if isRepeatable { return true }
        return requestNeverReachedServer(sdkError)
    }
    
    /// Whether the error proves the server did not process the request.
    static func requestNeverReachedServer(_ error: KasookooError) -> Bool {
        if error.httpStatus == 429 { return true }
        guard let urlError = error.underlyingError as? URLError else { return false }
        return preTransmissionURLErrorCodes.contains(urlError.code.rawValue)
    }
    
    // MARK: - Core Request Execution
    
    private func performRequest<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        request: APIRequest,
        body: Body?,
        responseType: Response.Type,
        retryPolicy: RetryPolicy,
        explicitBearer: String?
    ) async throws -> Response {
        
        // One id for every attempt of this logical request. It is also sent as
        // `Idempotency-Key` on POST/PATCH, so a backend that honours the header
        // can collapse duplicates even if one slips through.
        let requestId = TraceContext.newId()
        let isRepeatable = request.isRepeatable
        
        logger.debug("→ \(request.method.rawValue) \(ApiClient.route(request.resolvedPath)) [reqId: \(requestId)]")
        
        return try await Retrier.execute(
            policy: retryPolicy,
            isRetryable: { error in
                ApiClient.isRetryable(error, isRepeatable: isRepeatable)
            }
        ) { [weak self] in
            guard let self = self else {
                throw KasookooError.unknown(message: "ApiClient was deallocated.")
            }
            return try await self.executeOnce(
                request: request,
                body: body,
                responseType: Response.self,
                requestId: requestId,
                explicitBearer: explicitBearer
            )
        }
    }
    
    /// Executes a single request attempt, with one automatic session refresh
    /// on 401 when the token came from the auth provider.
    private func executeOnce<Body: Encodable & Sendable, Response: Decodable & Sendable>(
        request: APIRequest,
        body: Body?,
        responseType: Response.Type,
        requestId: String,
        explicitBearer: String?
    ) async throws -> Response {
        
        // Correlation context for this attempt.
        let trace = TraceContext.current
        let correlationUser = currentCorrelationUserId()
        let route = ApiClient.route(request.resolvedPath)
        
        // One client span per attempt. It nests under whichever feature span is
        // active, so a slow or failed request is visible inside the user action
        // that caused it.
        let span = telemetry.startSpan("http.\(request.method.rawValue)", attributes: [
            "http.route": .string(route),
            TelemetryKey.requestId: .string(requestId)
        ])
        defer { span.end() }
        
        // Resolve the bearer token.
        var authToken: String?
        var tokenFromProvider = false
        if request.requiresAuth {
            if let explicitBearer {
                authToken = explicitBearer
            } else {
                guard let provider = currentAuthProvider() else {
                    throw KasookooError(
                        code: .sessionInvalid,
                        message: "Auth provider not configured. Did you call connect()?",
                        retryable: false
                    )
                }
                authToken = try await provider.ensureValidToken()
                tokenFromProvider = true
            }
        }
        
        let (data, response) = try await transmit(
            request: request,
            body: body,
            authToken: authToken,
            requestId: requestId,
            trace: trace,
            correlationUser: correlationUser,
            span: span,
            isRetry: false
        )
        
        do {
            let decoded = try responseDecoder.decode(
                Response.self,
                from: data,
                response: response,
                requestId: requestId
            )
            logger.debug("← \(route) success [reqId: \(requestId)]")
            span.setAttribute(TelemetryKey.result, .string("ok"))
            return decoded
        } catch let error as KasookooError {
            span.setAttribute(TelemetryKey.errorCode, .string(error.code.rawValue))
            
            // Only a provider-issued token is refreshed here. An explicit
            // bearer belongs to the caller (the session layer), which decides
            // for itself what a 401 means.
            guard error.code == .sessionExpired,
                  tokenFromProvider,
                  let provider = currentAuthProvider() else {
                span.setError(error.message)
                throw error
            }
            
            logger.info("Got 401 on \(route), attempting one-time session refresh")
            
            let newToken: String
            do {
                newToken = try await provider.forceRefresh()
            } catch {
                // Refresh failed. Surface the refresh error.
                logger.warning("Session refresh failed: \(error.localizedDescription)")
                span.setError("Session refresh failed")
                logSessionExpired(route: route, reason: "Session refresh failed after a 401.")
                throw error
            }
            
            let (retryData, retryResponse) = try await transmit(
                request: request,
                body: body,
                authToken: newToken,
                requestId: requestId,
                trace: trace,
                correlationUser: correlationUser,
                span: span,
                isRetry: true
            )
            
            if let http = retryResponse as? HTTPURLResponse, http.statusCode == 401 {
                span.setError("Unauthorized after refresh")
                logSessionExpired(route: route, reason: "Still unauthorized after refreshing the session.")
                throw KasookooError(
                    code: .unauthorized,
                    message: "Authentication failed after refreshing the session.",
                    retryable: false,
                    httpStatus: 401
                )
            }
            
            let retryDecoded = try responseDecoder.decode(
                Response.self,
                from: retryData,
                response: retryResponse,
                requestId: requestId
            )
            span.setAttribute(TelemetryKey.result, .string("ok_after_refresh"))
            return retryDecoded
        }
    }
    
    /// Builds and sends one HTTP request. Transport failures are normalised to
    /// `KasookooError.networkUnavailable` (keeping the `URLError` so retry
    /// classification can inspect it); cancellation propagates as-is.
    private func transmit<Body: Encodable & Sendable>(
        request: APIRequest,
        body: Body?,
        authToken: String?,
        requestId: String,
        trace: TraceContext?,
        correlationUser: String?,
        span: TelemetrySpanHandle,
        isRetry: Bool
    ) async throws -> (Data, URLResponse) {
        var urlRequest = try requestBuilder.build(
            apiRequest: request,
            body: body,
            authToken: authToken,
            requestId: requestId
        )
        urlRequest.applyCorrelation(trace: trace, userId: correlationUser)
        
        logRequest(urlRequest, method: request.method, requestId: requestId, isRetry: isRetry)
        
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                span.setError("Cancelled")
                throw CancellationError()
            }
            logger.warning("Network error on \(ApiClient.route(request.resolvedPath)): \(error.localizedDescription)")
            span.setError("Network request failed")
            throw KasookooError.networkUnavailable(
                message: "Network request failed: \(error.localizedDescription)",
                underlyingError: error
            )
        }
        
        if let http = response as? HTTPURLResponse {
            span.setAttribute("http.status_code", .int(http.statusCode))
        }
        
        logResponse(data, response: response, path: request.resolvedPath, requestId: requestId, isRetry: isRetry)
        return (data, response)
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
        method: HTTPMethod,
        requestId: String,
        isRetry: Bool
    ) {
#if DEBUG
        let tag = isRetry ? "↻ RETRY ➡️" : "➡️"
        let url = request.url?.absoluteString ?? "<no url>"
        
        var lines = ["\(tag) \(method.rawValue) \(url) [reqId: \(requestId)]"]
        
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
        path: String,
        requestId: String,
        isRetry: Bool
    ) {
#if DEBUG
        let tag = isRetry ? "↻ RETRY ⬅️" : "⬅️"
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        let icon = (200..<300).contains(status) ? "✅" : "❌"
        
        let raw = String(data: data, encoding: .utf8)
        ?? "<non-UTF8 body, \(data.count) bytes>"
        let body = raw.isEmpty ? "<empty>" : raw
        
        logger.debug("\(tag) \(icon) \(status) \(path) [reqId: \(requestId)]\n   Resp: \(body)")
        print("Log Response \(tag) \(icon) \(status) \(path) [reqId: \(requestId)]\n   Resp: \(body)")
#endif
    }
    
    // MARK: - Telemetry Helpers
    
    /// The path with any query string removed.
    ///
    /// Query items carry user ids, room names and paging values. They belong in
    /// explicit span attributes, not silently inside a route label.
    static func route(_ path: String) -> String {
        guard let queryStart = path.firstIndex(of: "?") else { return path }
        return String(path[path.startIndex..<queryStart])
    }
    
    /// Records a `SESSION_EXPIRED` event. Emitted only when the session could
    /// not be recovered, so it means "the user must re-authenticate" rather
    /// than "a token was refreshed", which happens routinely.
    private func logSessionExpired(route: String, reason: String) {
        telemetry.log(
            event: TelemetryEvent.sessionExpired,
            message: reason,
            severity: .error,
            attributes: ["http.route": .string(route)]
        )
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

/// Empty body sentinel for requests without a payload.
private struct EmptyBody: Encodable, Sendable {}
