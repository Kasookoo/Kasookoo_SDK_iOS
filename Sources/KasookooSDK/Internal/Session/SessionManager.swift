//
//  SessionManager.swift
//  KasookooSDK
//
//  Owns the session/token lifecycle (Section 6 of the spec).
//
//  This is the most critical class in the SDK:
//  - Acquires sessions on connect()
//  - Pre-emptively refreshes at 80-90% TTL
//  - Handles 401/403 forced refreshes
//  - Emits session.expiring, session.refreshed, session.expired events
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
        if let existing = storage.load(), existing.isValid {
            logger.info("Reusing existing valid session: \(existing.sessionId)")
            await scheduleRefresh(for: existing)
            return
        }
        
        logger.info("No valid session; bootstrapping new session")
        _ = try await acquireNewSession()
    }
    
    /// Disconnects: revokes the session on the backend and clears local state.
    func disconnect() async {
        await scheduler.cancel()
        
        if let token = storage.load() {
            do {
                try await apiClient.sendVoid(
                    endpoint: .revokeSession(sessionId: token.sessionId),
                    retryPolicy: .none
                )
                logger.info("Session revoked: \(token.sessionId)")
            } catch {
                logger.warning("Failed to revoke session (continuing): \(error.localizedDescription)")
            }
        }
        
        storage.clear()
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
        if let stored = storage.load(), !stored.willExpireSoon(threshold: 5) {
            return stored.token
        }
        
        // Slow path: refresh needed
        let refreshed = try await coalescingRefresh()
        return refreshed.token
    }
    
    /// Forces a refresh regardless of current token state.
    /// Used after a 401 response.
    func forceRefresh() async throws -> String {
        logger.info("Force refresh requested (likely after 401)")
        let refreshed = try await coalescingRefresh()
        return refreshed.token
    }
    
    // MARK: - Refresh Coalescing
    
    /// Coalesces concurrent refresh requests into a single network call.
    private func coalescingRefresh() async throws -> StoredToken {
        // If a refresh is already in flight, wait for it
        if let task = inFlightRefresh {
            logger.debug("Joining in-flight refresh")
            return try await task.value
        }
        
        // Start a new refresh
        let task = Task { [weak self] () throws -> StoredToken in
            guard let self = self else {
                throw KasookooError.unknown(message: "SessionManager deallocated")
            }
            return try await self.performRefresh()
        }
        inFlightRefresh = task
        
        do {
            let result = try await task.value
            inFlightRefresh = nil
            return result
        } catch {
            inFlightRefresh = nil
            throw error
        }
    }
    
    // MARK: - Refresh Implementation
    
    /// Performs an actual refresh: rotate if possible, otherwise bootstrap new session.
    private func performRefresh() async throws -> StoredToken {
        if let current = storage.load() {
            // Try rotating first (cheaper, preserves session ID)
            do {
                return try await rotateToken(sessionId: current.sessionId)
            } catch let error as KasookooError where error.code == .sessionInvalid || error.code == .sessionExpired {
                // Rotation failed — session is gone. Bootstrap a new one.
                logger.warning("Token rotation failed; bootstrapping new session")
                await emit(EventName.sessionExpired)
                return try await acquireNewSession()
            }
        } else {
            // No existing session; bootstrap fresh
            return try await acquireNewSession()
        }
    }
    
    /// Bootstraps a brand-new session via `POST /sdk/auth/client-sessions`.
    ///
    /// The backend uses a minimal bootstrap: we send only the publishable key
    /// and a subject identifier. The backend derives scopes, TTL, email,
    /// audience, and issuer from the organization's settings.
    private func acquireNewSession() async throws -> StoredToken {
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
        storage.save(stored)
        await scheduleRefresh(for: stored)
        await emit(EventName.sessionRefreshed, data: ["sessionId": .string(stored.sessionId)])
        
        logger.info("Session created: \(stored.sessionId), TTL: \(response.effectiveTTL)s")
        return stored
    }
    
    /// Rotates the existing session token via the rotation endpoint.
    private func rotateToken(sessionId: String) async throws -> StoredToken {
        logger.debug("Rotating token for session: \(sessionId)")
        
        let response = try await apiClient.send(
            endpoint: .rotateSessionToken(sessionId: sessionId),
            responseType: RotateSessionTokenResponse.self,
            retryPolicy: .aggressive
        )
        
        let stored = try makeStoredToken(from: response, fallbackSessionId: sessionId)
        storage.save(stored)
        await scheduleRefresh(for: stored)
        await emit(EventName.sessionRefreshed, data: ["sessionId": .string(stored.sessionId)])
        
        logger.info("Token rotated: \(stored.sessionId), TTL: \(response.effectiveTTL)s")
        return stored
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
        // Previously this fell back to `UUID().uuidString` when the backend id
        // was missing — which produced a random UUID like
        // "7AF6DD15-33D2-4C17-..." that the backend then rejected with
        // 401 "Invalid SDK token" on the next refresh. We now prefer the
        // response id, fall back to the known id from the prior token (on
        // rotation the backend may omit it and expect the same session), and
        // only fail loudly if neither exists — never invent a fake id.
        guard let sessionId = response.sessionId ?? fallbackSessionId else {
            throw KasookooError(
                code: .sessionInvalid,
                message: "Session response did not contain a session_id, and no existing session id was available. Cannot build refresh URL.",
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
        await scheduler.schedule(expiresAt: token.expiresAt) { [weak self] in
            await self?.handleScheduledRefresh()
        }
    }
    
    private func handleScheduledRefresh() async {
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
