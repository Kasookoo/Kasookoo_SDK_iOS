//
//  MessagingParams.swift
//  KasookooSDK
//
//  Parameter objects for messaging operations.
//  Matches the contracts shown in Section 17.D.
//

import Foundation

// MARK: - Messaging Token Params

/// Parameters for `sdk.messaging.getToken(params:)`.
///
/// Matches the `/api/v1/messaging/get-token` backend contract.
public struct MessagingTokenParams: Sendable, Hashable {
    
    /// The room name for the chat.
    public let roomName: String
    
    /// The sender's identity.
    public let sender: Participant
    
    /// The receiver's identity.
    public let receiver: Participant
    
    /// Whether to send push notifications. Defaults to `true`.
    public let isPushNotification: Bool
    
    public init(
        roomName: String,
        sender: Participant,
        receiver: Participant,
        isPushNotification: Bool = true
    ) {
        self.roomName = roomName
        self.sender = sender
        self.receiver = receiver
        self.isPushNotification = isPushNotification
    }
    
    public func validate() throws {
        var errors: [String: String] = [:]
        
        if roomName.trimmingCharacters(in: .whitespaces).isEmpty {
            errors["roomName"] = "roomName cannot be empty"
        }
        
        do { try sender.validate() } catch let e as KasookooError {
            errors["sender"] = e.message
        }
        
        do { try receiver.validate() } catch let e as KasookooError {
            errors["receiver"] = e.message
        }
        
        if sender.email == receiver.email {
            errors["receiver"] = "sender and receiver cannot have the same email"
        }
        
        if !errors.isEmpty {
            throw KasookooError.configInvalid(
                "Invalid messaging token parameters.",
                details: errors
            )
        }
    }
}

// MARK: - Send Message Params

/// Parameters for `sdk.messaging.send(params:)`.
///
/// **Identity model:** This struct uses `UserReference` so consumers can pass
/// either an email or a user_id. The SDK resolves emails to user IDs internally
/// using its cache (populated from identify and listConversations responses).
///
/// If you pass `.email(...)` and the SDK doesn't have a cached user_id for it,
/// the send will fail with `.messageSendFailed`. To avoid this:
/// 1. Call `sdk.identify(callerProfile:)` for the local user first
/// 2. Call `sdk.messaging.listConversations()` to populate the cache for contacts
/// 3. Or pass `.userId(...)` directly if you already have the user_id
public struct SendMessageParams: Sendable, Hashable {
    
    /// The room name for the chat (used for token issuance and routing).
    public let roomName: String
    
    /// The sender's identity (email or user_id).
    public let sender: UserReference
    
    /// The receiver's identity (email or user_id).
    public let receiver: UserReference
    
    /// The message content.
    public let message: String
    
    /// The type of message. Defaults to `.text`.
    public let messageType: MessageType
    
    /// Whether to send push notification. Defaults to `true`.
    public let isPushNotification: Bool
    
    /// Optional metadata to attach to the message.
    public let metadata: [String: String]?
    
    public init(
        roomName: String,
        sender: UserReference,
        receiver: UserReference,
        message: String,
        messageType: MessageType = .text,
        isPushNotification: Bool = true,
        metadata: [String: String]? = nil
    ) {
        self.roomName = roomName
        self.sender = sender
        self.receiver = receiver
        self.message = message
        self.messageType = messageType
        self.isPushNotification = isPushNotification
        self.metadata = metadata
    }
    
    /// Convenience initializer using emails directly.
    public init(
        roomName: String,
        senderEmail: String,
        receiverEmail: String,
        message: String,
        messageType: MessageType = .text,
        isPushNotification: Bool = true,
        metadata: [String: String]? = nil
    ) {
        self.init(
            roomName: roomName,
            sender: .email(senderEmail),
            receiver: .email(receiverEmail),
            message: message,
            messageType: messageType,
            isPushNotification: isPushNotification,
            metadata: metadata
        )
    }
    
    public func validate() throws {
        var errors: [String: String] = [:]
        
        if roomName.trimmingCharacters(in: .whitespaces).isEmpty {
            errors["roomName"] = "roomName cannot be empty"
        }
        
        if sender.value.trimmingCharacters(in: .whitespaces).isEmpty {
            errors["sender"] = "sender cannot be empty"
        }
        
        if receiver.value.trimmingCharacters(in: .whitespaces).isEmpty {
            errors["receiver"] = "receiver cannot be empty"
        }
        
        if message.isEmpty && messageType == .text {
            errors["message"] = "text message cannot be empty"
        }
        
        if !errors.isEmpty {
            throw KasookooError.configInvalid(
                "Invalid send message parameters.",
                details: errors
            )
        }
    }
}

// MARK: - List Conversations Filters

/// Filter options for `sdk.messaging.listConversations(filters:)`.
public struct ConversationFilters: Sendable, Hashable {
    
    /// Pagination skip count.
    public let skip: Int
    
    /// Pagination limit.
    public let limit: Int
    
    /// Optional search query (matches title or last message content).
    public let search: String?
    
    /// Whether to only return conversations with unread messages.
    public let unreadOnly: Bool
    
    public init(
        skip: Int = 0,
        limit: Int = 20,
        search: String? = nil,
        unreadOnly: Bool = false
    ) {
        self.skip = skip
        self.limit = limit
        self.search = search
        self.unreadOnly = unreadOnly
    }
    
    /// A default filter that returns the first 20 conversations.
    public static let `default` = ConversationFilters()
}

// MARK: - Get Messages Pagination

/// Pagination for `sdk.messaging.getMessages(conversationId:paging:)`.
public struct MessagePaging: Sendable, Hashable {
    
    /// Number of messages to skip from the most recent.
    public let skip: Int
    
    /// Maximum number of messages to return.
    public let limit: Int
    
    /// Optional cursor for cursor-based pagination.
    public let cursor: String?
    
    public init(skip: Int = 0, limit: Int = 50, cursor: String? = nil) {
        self.skip = skip
        self.limit = limit
        self.cursor = cursor
    }
    
    /// Default paging: most recent 50 messages.
    public static let `default` = MessagePaging()
}

// MARK: - Paginated Result

/// A generic paginated result wrapper.
public struct PaginatedResult<Item: Sendable>: Sendable {
    
    /// The items in this page.
    public let items: [Item]
    
    /// The total count, if known by the backend.
    public let totalCount: Int?
    
    /// Whether there are more items beyond this page.
    public let hasMore: Bool
    
    /// Optional cursor for fetching the next page.
    public let nextCursor: String?
    
    public init(
        items: [Item],
        totalCount: Int? = nil,
        hasMore: Bool,
        nextCursor: String? = nil
    ) {
        self.items = items
        self.totalCount = totalCount
        self.hasMore = hasMore
        self.nextCursor = nextCursor
    }
}
