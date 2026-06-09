//
//  Conversation.swift
//  KasookooSDK
//
//  Represents a chat conversation between participants.
//

import Foundation

/// A chat conversation between two or more participants.
///
/// **ID concepts:**
/// - `conversationId` — The persistent identifier used for operations like
///   `markRead` and `getMessages`. This is the primary key for the conversation.
/// - `roomName` — The LiveKit room name used for messaging token issuance.
///   May be the same as conversationId or different depending on backend setup.
public struct Conversation: Sendable, Hashable, Identifiable {
    
    // MARK: - Identity
    
    /// The unique conversation identifier.
    public var id: String { conversationId }
    
    /// The persistent conversation ID. Use this for `markRead`, `getMessages`.
    public let conversationId: String
    
    /// The LiveKit room name for this conversation (for token issuance).
    public let roomName: String
    
    // MARK: - Participants
    
    /// All participants in the conversation, identified by email.
    public let participantEmails: [String]
    
    /// Backend user IDs of participants, when available.
    public let participantUserIds: [String]
    
    // MARK: - Last Activity
    
    /// The most recent message in the conversation, if any.
    public let lastMessage: Message?
    
    /// When the conversation was last updated.
    public let lastUpdatedAt: Date
    
    // MARK: - Counts
    
    /// The total number of messages in the conversation.
    public let messageCount: Int
    
    /// The number of unread messages for the current user.
    public let unreadCount: Int
    
    // MARK: - Metadata
    
    /// An optional display title for the conversation.
    public let title: String?
    
    // MARK: - Init
    
    public init(
        conversationId: String,
        roomName: String? = nil,
        participantEmails: [String] = [],
        participantUserIds: [String] = [],
        lastMessage: Message? = nil,
        lastUpdatedAt: Date = Date(),
        messageCount: Int = 0,
        unreadCount: Int = 0,
        title: String? = nil
    ) {
        self.conversationId = conversationId
        self.roomName = roomName ?? conversationId
        self.participantEmails = participantEmails
        self.participantUserIds = participantUserIds
        self.lastMessage = lastMessage
        self.lastUpdatedAt = lastUpdatedAt
        self.messageCount = messageCount
        self.unreadCount = unreadCount
        self.title = title
    }
    
    // MARK: - Computed
    
    /// Whether this conversation has any unread messages.
    public var hasUnread: Bool {
        return unreadCount > 0
    }
}
