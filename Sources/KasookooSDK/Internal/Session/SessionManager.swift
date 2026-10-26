//
//  SessionManager.swift
//  KasookooSDK
//
//  Owns the session/token lifecycle (Section 6 of the spec).
//
//  This is the most critical class in the SDK:
//  - Acquires sessions on connect()
//  - Pre-emptively refreshes at 85% of the token lifetime
//  - Handles 401 forced refreshes
//  - Emits session.expiring, session.refreshed, session.expired events
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY THE SESSION ENDPOINTS USE AN EXPLICIT BEARER
//  ─────────────────────────────────────────────────────────────────────────────
//  Rotation and revocation are authenticated with the *current* token. They are
//  sent with `bearerToken:` so `ApiClient` never asks this actor for a token
//  while a refresh is running. Going through the provider would make the
//  refresh wait on itself: rotate → ensureValidToken/forceRefresh → join the
//  in-flight refresh, which is the one waiting. That hang had no timeout and
//  froze every API call in the SDK once a token expired while the app was
//  suspended, or after any 401.
//

import Foundation

/// Owns the session and token lifecycle.
///
/// Implemented as an `actor` to ensure all token mutations are serialized,
/// preventing race conditions when multiple services request tokens concurrently.
internal actor SessionManager {
    
    // MARK: - Dependencies
    
    private let apiClient: ApiClient
    private let storage: TokenStorage
    private let scheduler: RefreshScheduler
    private let eventBus: EventBus
    private let logger: Logger
    private let config: KasookooConfig
    
    // MARK: - State
    
    /// Where the session is in its lifecycle.
    ///
    /// - `idle`: never connected. A request may lazily bootstrap a session,
    ///   which preserves the behaviour of calling APIs before `connect()`.
    /// - `active`: `connect()` was called.
    /// - `disconnected`: `disconnect()` was called. Nothing may create a new
    ///   session until `connect()` is called again, so a refresh that was in
    ///   flight, or a stray request, cannot silently sign the user back in.
    private enum Lifecycle {
        case idle
        case active
        case disconnected
    }
    
    private var lifecycle: Lifecycle = .idle
    
    /// Incremented on every disconnect. A refresh remembers the generation it
    /// started in and discards its result if a disconnect happened meanwhile.
    private var generation = 0
    
    /// In-flight refresh task. If set, callers await this instead of starting a new refresh.
    /// This prevents the "thundering herd" problem when many requests trigger refresh simultaneously.
    private var inFlightRefresh: Task<StoredToken, Error>?
    
    // MARK: - Init
    
    init(
        apiClient: ApiClient,
        storage: TokenStorage,
        scheduler: RefreshScheduler,
        eventBus: EventBus,
        logger: Logger,
        config: KasookooConfig
    ) {
        self.apiClient = apiClient
        self.storage = storage
        self.scheduler = scheduler
        self.eventBus = eventBus
        self.logger = logger
        self.config = config
    }
    
    // MARK: - Public API
    
    /// Connects: acquires an initial session if one doesn't exist.
    func connect() async throws {
        lifecycle = .active
        
        if let existing = storage.load(), !existing.willExpireSoon(threshold: Self.expiryThreshold) {
            logger.info("Reusing existing valid session: \(existing.sessionId)")
            await scheduleRefresh(for: existing)
            return
        }
        
        logger.info("No valid session; acquiring one")
        _ = try await coalescingRefresh()
    }
    
    /// Disconnects: revokes the session on the backend and clears local state.
    func disconnect() async {
        lifecycle = .disconnected
        generation += 1
        
        inFlightRefresh?.cancel()
        inFlightRefresh = nil
        await scheduler.cancel()
        
        // Clear before the network call so nothing that runs while we await
        // the revoke can pick the token up again.
        let token = storage.load()
        storage.clear()
        
        guard let token, token.isValid else { return }
        do {
            try await apiClient.sendVoid(
                endpoint: .revokeSession(sessionId: token.sessionId),
                retryPolicy: .none,
                bearerToken: token.token
            )
            logger.info("Session revoked: \(token.sessionId)")
        } catch {
            logger.warning("Failed to revoke session (continuing): \(error.localizedDescription)")
        }
    }
    
    /// Returns the current session ID, if any. Nil if not connected.
    func currentSessionId() -> String? {
        return storage.load()?.sessionId
    }
    
    // MARK: - AuthTokenProvider Conformance
    
    /// Returns a valid token, refreshing if necessary.
    /// Multiple concurrent callers share the same in-flight refresh.
    func ensureValidToken() async throws -> String {
        // Fast path: existing token still valid
        if let stored = storage.load(), !stored.willExpireSoon(threshold: Self.expiryThreshold) {
            return stored.token
        }
        
        try requireNotDisconnected()
        let refreshed = try await coalescingRefresh()
        return refreshed.token
    }
    
    /// Forces a refresh regardless of current token state.
    /// Used after a 401 response.
    func forceRefresh() async throws -> String {
        try requireNotDisconnected()
        logger.info("Force refresh requested (likely after 401)")
        let refreshed = try await coalescingRefresh()
        return refreshed.token
    }
    
    // MARK: - Refresh Coalescing
    
    /// Seconds before expiry at which a token is treated as expired.
    private static let expiryThreshold: TimeInterval = 5
    
    private func requireNotDisconnected() throws {
        if lifecycle == .disconnected {
            throw KasookooError(
                code: .sessionInvalid,
                message: "The SDK is disconnected. Call connect() before making requests.",
                retryable: false
            )
        }
    }
    
    /// Coalesces concurrent refresh requests into a single network call.
    private func coalescingRefresh() async throws -> StoredToken {
        // If a refresh is already in flight, wait for it
        if let task = inFlightRefresh {
            logger.debug("Joining in-flight refresh")
            return try await task.value
        }
        
        // Start a new refresh
        let startedIn = generation
        let task = Task { [weak self] () throws -> StoredToken in
            guard let self = self else {
                throw KasookooError.unknown(message: "SessionManager deallocated")
            }
            return try await self.performRefresh(generation: startedIn)
        }
        inFlightRefresh = task
        
        do {
            let result = try await task.value
            clearInFlight(task)
            return result
        } catch {
            clearInFlight(task)
            throw error
        }
    }
    
    /// Clears the in-flight slot only if it still holds `task`. A disconnect
    /// followed by a new connect may already have replaced it.
    private func clearInFlight(_ task: Task<StoredToken, Error>) {
        if inFlightRefresh == task {
            inFlightRefresh = nil
        }
    }
    
    // MARK: - Refresh Implementation
    
    /// Performs an actual refresh: rotate if possible, otherwise bootstrap new session.
    private func performRefresh(generation startedIn: Int) async throws -> StoredToken {
        // Rotation is authenticated with the current token, so it only makes
        // sense while that token is still valid. An expired one goes straight
        // to a new session instead of a round trip that is bound to 401.
        guard let current = storage.load(), current.isValid else {
            return try await acquireNewSession(generation: startedIn)
        }
        
        do {
            return try await rotateToken(current: current, generation: startedIn)
        } catch let error as KasookooError where Self.meansSessionIsGone(error) {
            // Rotation failed — session is gone. Bootstrap a new one.
            logger.warning("Token rotation rejected (\(error.code.rawValue)); bootstrapping new session")
            await emit(EventName.sessionExpired)
            return try await acquireNewSession(generation: startedIn)
        }
    }
    
    /// Errors from the rotate endpoint that mean the session itself can no
    /// longer be used, as opposed to a transient failure.
    private static func meansSessionIsGone(_ error: KasookooError) -> Bool {
        switch error.code {
        case .sessionInvalid, .sessionExpired, .unauthorized, .permissionDenied:
            return true
        default:
            return false
        }
    }
    
    /// Bootstraps a brand-new session via `POST /sdk/auth/client-sessions`.
    ///
    /// The backend uses a minimal bootstrap: we send only the publishable key
    /// and a subject identifier. The backend derives scopes, TTL, email,
    /// audience, and issuer from the organization's settings.
    private func acquireNewSession(generation startedIn: Int) async throws -> StoredToken {
        let request = CreateClientSessionRequest(
            publishableKey: config.publishableKey,
            subject: subjectIdentifier()
        )
        
        logger.debug("Bootstrapping session (subject: \(request.subject))")
        
        let response: CreateClientSessionResponse
        do {
            response = try await apiClient.send(
                endpoint: .createClientSession,
                body: request,
                responseType: CreateClientSessionResponse.self,
                retryPolicy: .aggressive
            )
        } catch {
            logger.error("Session bootstrap failed: \(error.localizedDescription)")
            throw error
        }
        
        let stored = try makeStoredToken(from: response)
        try commit(stored, generation: startedIn)
        await scheduleRefresh(for: stored)
        await emit(EventName.sessionRefreshed, data: ["sessionId": .string(stored.sessionId)])
        
        logger.info("Session created: \(stored.sessionId), TTL: \(response.effectiveTTL)s")
        return stored
    }
    
    /// Rotates the existing session token via the rotation endpoint.
    private func rotateToken(current: StoredToken, generation startedIn: Int) async throws -> StoredToken {
        logger.debug("Rotating token for session: \(current.sessionId)")
        
        let response = try await apiClient.send(
            endpoint: .rotateSessionToken(sessionId: current.sessionId),
            responseType: RotateSessionTokenResponse.self,
            retryPolicy: .aggressive,
            bearerToken: current.token
        )
        
        let stored = try makeStoredToken(from: response, fallbackSessionId: current.sessionId)
        try commit(stored, generation: startedIn)
        await scheduleRefresh(for: stored)
        await emit(EventName.sessionRefreshed, data: ["sessionId": .string(stored.sessionId)])
        
        logger.info("Token rotated: \(stored.sessionId), TTL: \(response.effectiveTTL)s")
        return stored
    }
    
    /// Saves a freshly issued token, unless a disconnect happened while it was
    /// being fetched. In that case the token is dropped and the refresh fails.
    private func commit(_ token: StoredToken, generation startedIn: Int) throws {
        guard startedIn == generation, lifecycle != .disconnected else {
            logger.info("Discarding session token issued after disconnect")
            throw KasookooError(
                code: .sessionInvalid,
                message: "The SDK was disconnected while the session was being refreshed.",
                retryable: false
            )
        }
        storage.save(token)
    }
    
    /// Builds a `StoredToken` from a session response, safely unwrapping the
    /// optional fields the backend returns.
    private func makeStoredToken(
        from response: CreateClientSessionResponse,
        fallbackSessionId: String? = nil
    ) throws -> StoredToken {
        guard let accessToken = response.effectiveToken else {
            throw KasookooError(
                code: .sessionExpired,
                message: "Session response did not contain a token.",
                retryable: true
            )
        }
        
        // The session id MUST come from the backend (`session_id`, e.g.
        // "sess_46954fbb..."). It is used to build the rotate/revoke URL:
        //   POST /api/v1/sdk/auth/sessions/{session_id}/tokens
        //
        // Never invent one: a random UUID here is rejected by the backend with
        // 401 "Invalid SDK token" on the next refresh. Sources, in order:
        //   1. `session_id` in the response body.
        //   2. The `sid` claim of the token. The create-session endpoint
        //      returns only `{token, token_type, expires_in, created_at}`, but
        //      the JWT carries `"sid": "sess_..."` for exactly this session.
        //   3. The previous session id (rotation keeps the session).
        let sessionId: String
        if let id = response.sessionId {
            sessionId = id
        } else if let id = JWTClaims.string("sid", in: accessToken) {
            logger.debug("Session id taken from the token's `sid` claim: \(id)")
            sessionId = id
        } else if let id = fallbackSessionId {
            sessionId = id
        } else {
            throw KasookooError(
                code: .sessionInvalid,
                message: "Session response contained no session_id, the token carried no `sid` claim, and no existing session id was available. Cannot build refresh URL.",
                retryable: false
            )
        }
        
        let ttl = response.effectiveTTL
        
        return StoredToken(
            token: accessToken,
            sessionId: sessionId,
            expiresAt: Date().addingTimeInterval(TimeInterval(ttl))
        )
    }
    
    // MARK: - Refresh Scheduling
    
    private func scheduleRefresh(for token: StoredToken) async {
        guard lifecycle != .disconnected else { return }
        await scheduler.schedule(expiresAt: token.expiresAt) { [weak self] in
            await self?.handleScheduledRefresh()
        }
    }
    
    private func handleScheduledRefresh() async {
        guard lifecycle != .disconnected else { return }
        await emit(EventName.sessionExpiring)
        do {
            _ = try await coalescingRefresh()
        } catch {
            logger.error("Scheduled refresh failed: \(error.localizedDescription)")
            await emit(EventName.sessionExpired)
        }
    }
    
    // MARK: - Event Emission
    
    private func emit(_ name: String, data: [String: AnyCodableValue] = [:]) async {
        let event = SDKEvent(
            name: name,
            organizationId: config.organizationId,
            userEmail: nil,
            data: data
        )
        await eventBus.emit(event)
    }
    
    // MARK: - Helpers
    
    /// Returns the subject identifier for session creation.
    /// For guest mode, generates a stable random ID. For authenticated mode,
    /// the user's email (set later via identify) takes over.
    private func subjectIdentifier() -> String {
        switch config.userMode {
        case .guest:
            return "guest_\(UUID().uuidString.prefix(8).lowercased())"
        case .authenticated:
            // Will be replaced once identify() is called
            return "pending_\(UUID().uuidString.prefix(8).lowercased())"
        }
    }
}

// MARK: - AuthTokenProvider Conformance

extension SessionManager: AuthTokenProvider {}
