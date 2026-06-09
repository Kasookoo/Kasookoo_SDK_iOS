//
//  MessagingServicing.swift
//  KasookooSDK
//
//  Public protocol for the messaging service.
//

import Foundation

/// The public contract for in-app messaging.
///
/// Accessed via `sdk.messaging`.
///
/// ## Identity Model
///
/// The backend uses **user_id** for messaging operations but consumers typically
/// think in **emails**. The SDK accepts `UserReference` (which is either an
/// email or a userId) and resolves emails to userIds via its internal cache.
///
/// **The cache is populated by:**
/// 1. `sdk.identify()` — caches the current user's email → userId
/// 2. `listConversations()` — caches participant emails → userIds
///
/// If you pass an email that hasn't been cached yet, send will fail with
/// `.messageSendFailed`. To avoid this, identify and list conversations first.
public protocol MessagingServicing: Sendable {
    
    // MARK: - Connection
    
    /// Establishes the messaging session.
    ///
    /// Optional. The SDK is stateless for messaging — this is a no-op currently
    /// but may be used in the future if WebSocket support is added.
    func connect() async throws
    
    // MARK: - Sending
    
    /// Sends a message.
    ///
    /// Emits `message.sent` on success, `message.sent` with `errorMessage` on failure.
    ///
    /// - Parameter params: The message parameters.
    /// - Returns: The sent `Message` with server-assigned ID.
    /// - Throws: `KasookooError.messageSendFailed` if sending fails.
    @discardableResult
    func send(params: SendMessageParams) async throws -> Message
    
    // MARK: - Token Acquisition
    
    /// Acquires a messaging token for a room.
    ///
    /// Most consumers don't need to call this directly — `send` handles it
    /// automatically. Exposed for advanced use cases.
    func getToken(params: MessagingTokenParams) async throws
    
    // MARK: - Listing
    
    /// Lists conversations for the current user.
    ///
    /// **Side effect:** This populates the email → userId cache for participants.
    /// Call this once after identify() to enable sending messages by email.
    ///
    /// - Parameter filters: Optional filters for paging and search.
    /// - Returns: A paginated list of conversations.
    func listConversations(filters: ConversationFilters) async throws -> PaginatedResult<Conversation>
    
    /// Fetches messages from a conversation.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation identifier (from `Conversation.conversationId`).
    ///   - paging: Pagination options.
    /// - Returns: A paginated list of messages.
    func getMessages(
        conversationId: String,
        paging: MessagePaging
    ) async throws -> PaginatedResult<Message>
    
    // MARK: - Read State
    
    /// Marks messages in a conversation as read.
    ///
    /// Pass `messageIds: nil` to mark all unread messages in the conversation.
    /// Pass specific IDs to mark only those.
    ///
    /// Emits `message.read`.
    ///
    /// - Parameters:
    ///   - conversationId: The conversation to mark as read.
    ///   - messageIds: Optional specific message IDs; nil means all unread.
    func markRead(conversationId: String, messageIds: [String]?) async throws
    
    /// Returns the total unread message count for the current user.
    func getUnreadCount() async throws -> Int
}
