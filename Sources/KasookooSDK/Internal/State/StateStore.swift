//
//  StateStore.swift
//  KasookooSDK
//
//

import Foundation

/// Thread-safe holder for SDK runtime state.
///
/// Owns:
/// - The high-level SDK state (idle/connecting/connected/etc.)
/// - The current identified user (`CallerProfile`)
/// - Email-to-userId mapping cache (populated from identify responses)
/// - Active calls keyed by call ID
/// - Active conversations cache
///
/// All services read and mutate state through this actor, ensuring no race conditions.
internal actor StateStore {
    
    // MARK: - SDK State
    
    private(set) var sdkState: SDKState = .idle
    
    // MARK: - Identity
    
    private(set) var identifiedUser: CallerProfile?
    
    /// The backend-assigned user ID for the currently identified user.
    /// Populated when identify() succeeds.
    private(set) var currentUserId: String?
    
    // MARK: - Email-to-UserID Cache
    
    /// Maps email addresses to backend user IDs.
    /// Populated whenever the SDK learns of a user ID:
    /// - From identify() responses (current user)
    /// - From call/message responses (other users)
    ///
    /// This lets the SDK accept emails from consumers and resolve them
    /// to user IDs when calling backend endpoints that require user IDs.
    private var emailToUserIdCache: [String: String] = [:]
    
    // MARK: - Active Calls
    
    private var activeCalls: [String: CallInfo] = [:]
    
    // MARK: - Call Media Credentials
    
    /// LiveKit media credentials for calls whose tokens arrive out-of-band.
    ///
    /// For **incoming** calls the backend delivers the LiveKit `accessToken` and
    /// `wsUrl` inside the push notification payload — there is no separate token
    /// endpoint to call. `NotificationService` stores them here when the push
    /// arrives, and `CallService.accept()` reads them back to join the room.
    ///
    /// Keyed by callId. Cleared automatically when the call is removed.
    private var callCredentials: [String: CallMediaCredentials] = [:]
    
    // MARK: - Conversations Cache
    
    private var conversationsCache: [String: Conversation] = [:]
    
    // MARK: - Logger
    
    private let logger: Logger
    
    // MARK: - Init
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    // MARK: - SDK State Management
    
    @discardableResult
    func setState(_ newState: SDKState) -> SDKState {
        let oldState = sdkState
        sdkState = newState
        logger.info("SDK state: \(oldState.description) → \(newState.description)")
        print("SDK state: \(oldState.description) → \(newState.description)")
        return oldState
    }
    
    func getState() -> SDKState {
        return sdkState
    }
    
    // MARK: - Identity Management
    
    /// Stores the identified user profile and their backend user ID.
    func setIdentifiedUser(_ profile: CallerProfile?, userId: String? = nil) {
        if let profile = profile {
            logger.debug("User identified: \(profile.email) [userId: \(userId ?? "unknown")]")
            // Cache the email → user_id mapping
            if let userId = userId {
                emailToUserIdCache[profile.email.lowercased()] = userId
            }
        } else {
            logger.debug("Identity cleared")
        }
        identifiedUser = profile
        currentUserId = userId
    }
    
    /// Returns the email of the identified user, if any.
    func currentUserEmail() -> String? {
        return identifiedUser?.email
    }
    
    // MARK: - Email-to-UserID Resolution
    
    /// Caches an email → user_id mapping.
    /// Called whenever the SDK learns of a user ID from any backend response.
    func cacheUserId(email: String, userId: String) {
        let key = email.lowercased()
        emailToUserIdCache[key] = userId
        logger.debug("Cached userId for \(email): \(userId)")
    }
    
    /// Resolves an email to a user ID, if known.
    /// Returns nil if the mapping isn't cached yet.
    func resolveUserId(forEmail email: String) -> String? {
        return emailToUserIdCache[email.lowercased()]
    }
    
    /// Resolves a `UserReference` to a user ID string.
    /// Returns nil if the reference is an email that hasn't been resolved yet.
    func resolveUserId(from reference: UserReference) -> String? {
        switch reference {
        case .userId(let id):
            return id
        case .email(let email):
            return resolveUserId(forEmail: email)
        }
    }
    
    /// Bulk-caches multiple email → user_id mappings.
    /// Useful when listing conversations returns multiple participants.
    func cacheUserIds(_ mappings: [String: String]) {
        for (email, userId) in mappings {
            emailToUserIdCache[email.lowercased()] = userId
        }
    }
    
    // MARK: - Active Calls Management
    
    func addCall(_ call: CallInfo) {
        activeCalls[call.id] = call
        logger.debug("Active call added: \(call.id) [state: \(call.state.rawValue)]")
    }
    
    @discardableResult
    func updateCall(_ callId: String, transform: (CallInfo) -> CallInfo) -> CallInfo? {
        guard let existing = activeCalls[callId] else {
            logger.warning("Tried to update unknown call: \(callId)")
            return nil
        }
        let updated = transform(existing)
        activeCalls[callId] = updated
        
        if updated.state.isTerminal {
            activeCalls.removeValue(forKey: callId)
            logger.debug("Call removed (terminal): \(callId) [state: \(updated.state.rawValue)]")
        } else {
            logger.debug("Call updated: \(callId) [state: \(updated.state.rawValue)]")
        }
        
        return updated
    }
    
    func removeCall(_ callId: String) {
        if activeCalls.removeValue(forKey: callId) != nil {
            logger.debug("Call removed: \(callId)")
        }
        // Media credentials are scoped to the call's lifetime.
        callCredentials.removeValue(forKey: callId)
    }
    
    func getCall(_ callId: String) -> CallInfo? {
        return activeCalls[callId]
    }
    
    // MARK: - Call Media Credentials
    
    /// Stores the LiveKit credentials delivered with an incoming-call push,
    /// so `CallService.accept()` can join the room later.
    func setCallCredentials(_ credentials: CallMediaCredentials, for callId: String) {
        callCredentials[callId] = credentials
        logger.debug("Media credentials stored for call: \(callId)")
    }
    
    /// Returns the LiveKit credentials for a call, if they were delivered via push.
    func getCallCredentials(for callId: String) -> CallMediaCredentials? {
        return callCredentials[callId]
    }
    
    func allActiveCalls() -> [CallInfo] {
        return activeCalls.values.filter { $0.state.isActive }
    }
    
    func mostRecentActiveCall() -> CallInfo? {
        return allActiveCalls().max(by: { $0.createdAt < $1.createdAt })
    }
    
    func clearAllCalls() {
        let count = activeCalls.count
        activeCalls.removeAll()
        if count > 0 {
            logger.debug("Cleared \(count) call(s)")
        }
    }
    
    // MARK: - Conversation Cache
    
    func cacheConversation(_ conversation: Conversation) {
        conversationsCache[conversation.conversationId] = conversation
    }
    
    func cachedConversation(_ conversationId: String) -> Conversation? {
        return conversationsCache[conversationId]
    }
    
    func clearConversationsCache() {
        conversationsCache.removeAll()
    }
    
    // MARK: - Reset
    
    /// Resets all state. Called during `sdk.destroy()`.
    func reset() {
        sdkState = .idle
        identifiedUser = nil
        currentUserId = nil
        emailToUserIdCache.removeAll()
        activeCalls.removeAll()
        conversationsCache.removeAll()
        logger.debug("StateStore reset")
    }
}

// MARK: - Call Media Credentials

/// LiveKit connection credentials for a call.
///
/// For **outgoing** calls these come from `POST /webrtc/get-call-tokens`.
/// For **incoming** calls the backend embeds them directly in the push payload
/// (`accessToken` + `wsUrl`), because the callee has no opportunity to request
/// a token before answering.
internal struct CallMediaCredentials: Sendable, Hashable {
    
    /// The LiveKit access token used to join the room.
    let accessToken: String
    
    /// The LiveKit WebSocket URL.
    let wsUrl: String
    
    init(accessToken: String, wsUrl: String) {
        self.accessToken = accessToken
        self.wsUrl = wsUrl
    }
}
