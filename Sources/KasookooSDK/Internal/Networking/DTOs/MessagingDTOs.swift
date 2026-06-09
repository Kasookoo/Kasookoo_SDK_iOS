//
//  MessagingDTOs.swift
//  KasookooSDK
//
//

import Foundation

// MARK: - Get Messaging Token

/// Request body for `POST /api/v1/messaging/get-token`.
///
/// Per Postman collection:
/// ```json
/// {
///   "room_name": "chat_room_123",
///   "participant_identity": "sender@example.com",
///   "participant_identity_name": "John Sender",
///   "participant_identity_type": "customer",
///   "sender": { ... },
///   "receiver": { ... },
///   "device_type": "mobile",
///   "is_push_notification": true
/// }
/// ```
internal struct GetMessagingTokenRequest: Encodable, Sendable {
    let roomName: String
    let participantIdentity: String
    let participantIdentityName: String
    let participantIdentityType: String
    let sender: ParticipantDTO
    let receiver: ParticipantDTO
    let deviceType: String
    let isPushNotification: Bool
    
    enum CodingKeys: String, CodingKey {
        case roomName = "room_name"
        case participantIdentity = "participant_identity"
        case participantIdentityName = "participant_identity_name"
        case participantIdentityType = "participant_identity_type"
        case sender
        case receiver
        case deviceType = "device_type"
        case isPushNotification = "is_push_notification"
    }
}

/// Response body for `POST /api/v1/messaging/get-token`.
/// **Confirm exact shape with backend team.**
internal struct GetMessagingTokenResponse: Decodable, Sendable {
    let token: String?
    let accessToken: String?
    let roomName: String?
    let expiresIn: Int?
    let wsUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case token
        case accessToken = "access_token"
        case roomName = "room_name"
        case expiresIn = "expires_in"
        case wsUrl = "ws_url"
    }
    
    var effectiveToken: String? {
        return token ?? accessToken
    }
}

// MARK: - Send Message

/// Request body for `POST /api/v1/messaging/send`.
///
/// Per Postman collection — uses user IDs, not emails:
/// ```json
/// {
///   "sender_user_id": "user123",
///   "receiver_user_id": "user456",
///   "room_name": "chat_room_123",
///   "message": "Hello",
///   "message_type": "text",
///   "metadata": {},
///   "is_push_notification": true
/// }
/// ```
internal struct SendMessageRequest: Encodable, Sendable {
    let senderUserId: String
    let receiverUserId: String
    let roomName: String
    let message: String
    let messageType: String
    let metadata: [String: String]?
    let isPushNotification: Bool
    
    enum CodingKeys: String, CodingKey {
        case senderUserId = "sender_user_id"
        case receiverUserId = "receiver_user_id"
        case roomName = "room_name"
        case message
        case messageType = "message_type"
        case metadata
        case isPushNotification = "is_push_notification"
    }
}

/// Response body for `POST /api/v1/messaging/send`.
/// **Confirm exact shape with backend team.**
internal struct SendMessageResponse: Decodable, Sendable {
    let messageId: String?
    let id: String?
    let roomName: String?
    let conversationId: String?
    let sentAt: String?
    let createdAt: String?
    let status: String?
    
    enum CodingKeys: String, CodingKey {
        case messageId = "message_id"
        case id
        case roomName = "room_name"
        case conversationId = "conversation_id"
        case sentAt = "sent_at"
        case createdAt = "created_at"
        case status
    }
    
    var effectiveMessageId: String? {
        return messageId ?? id
    }
    
    var effectiveTimestamp: String? {
        return sentAt ?? createdAt
    }
}

// MARK: - Message DTO (for list/get)

/// Backend representation of a message.
internal struct MessageDTO: Decodable, Sendable {
    let id: String
    let conversationId: String?
    let roomName: String?
    let senderUserId: String?
    let receiverUserId: String?
    let senderEmail: String?
    let receiverEmail: String?
    let senderName: String?
    let content: String?
    let message: String?
    let messageType: String?
    let metadata: [String: String]?
    let sentAt: String?
    let createdAt: String?
    let deliveredAt: String?
    let readAt: String?
    let status: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case roomName = "room_name"
        case senderUserId = "sender_user_id"
        case receiverUserId = "receiver_user_id"
        case senderEmail = "sender_email"
        case receiverEmail = "receiver_email"
        case senderName = "sender_name"
        case content
        case message
        case messageType = "message_type"
        case metadata
        case sentAt = "sent_at"
        case createdAt = "created_at"
        case deliveredAt = "delivered_at"
        case readAt = "read_at"
        case status
    }
    
    /// Converts to public Message model.
    /// Requires the current user's user_id to compute `isOutgoing`.
    func toModel(currentUserId: String?) -> Message {
        let effectiveContent = content ?? message ?? ""
        let effectiveSenderEmail = senderEmail ?? ""
        let effectiveReceiverEmail = receiverEmail ?? ""
        let effectiveRoomName = roomName ?? conversationId ?? ""
        
        let typeEnum = MessageType(rawValue: messageType ?? "") ?? .text
        let statusEnum = MessageStatus(rawValue: status ?? "") ?? .sent
        
        let sentDate = parseIso8601(sentAt ?? createdAt) ?? Date()
        let deliveredDate = parseIso8601(deliveredAt)
        let readDate = parseIso8601(readAt)
        
        let isOutgoing = currentUserId.map { $0 == senderUserId } ?? false
        
        return Message(
            id: id,
            roomName: effectiveRoomName,
            senderEmail: effectiveSenderEmail,
            receiverEmail: effectiveReceiverEmail,
            content: effectiveContent,
            messageType: typeEnum,
            mediaURL: nil,
            sentAt: sentDate,
            deliveredAt: deliveredDate,
            readAt: readDate,
            status: statusEnum,
            isOutgoing: isOutgoing
        )
    }
    
    private func parseIso8601(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - Conversation DTO

/// Backend representation of a conversation.
internal struct ConversationDTO: Decodable, Sendable {
    let id: String?
    let conversationId: String?
    let roomName: String?
    let participantUserIds: [String]?
    let participantEmails: [String]?
    let lastMessage: MessageDTO?
    let lastUpdatedAt: String?
    let updatedAt: String?
    let messageCount: Int?
    let unreadCount: Int?
    let title: String?
    
    enum CodingKeys: String, CodingKey {
        case id
        case conversationId = "conversation_id"
        case roomName = "room_name"
        case participantUserIds = "participant_user_ids"
        case participantEmails = "participant_emails"
        case lastMessage = "last_message"
        case lastUpdatedAt = "last_updated_at"
        case updatedAt = "updated_at"
        case messageCount = "message_count"
        case unreadCount = "unread_count"
        case title
    }
    
    func toModel(currentUserId: String?) -> Conversation {
        let effectiveConvId = conversationId ?? id ?? roomName ?? ""
        let effectiveRoomName = roomName ?? effectiveConvId
        let lastUpdated = parseIso8601(lastUpdatedAt ?? updatedAt) ?? Date()
        
        return Conversation(
            conversationId: effectiveConvId,
            roomName: effectiveRoomName,
            participantEmails: participantEmails ?? [],
            participantUserIds: participantUserIds ?? [],
            lastMessage: lastMessage?.toModel(currentUserId: currentUserId),
            lastUpdatedAt: lastUpdated,
            messageCount: messageCount ?? 0,
            unreadCount: unreadCount ?? 0,
            title: title
        )
    }
    
    private func parseIso8601(_ string: String?) -> Date? {
        guard let string = string else { return nil }
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: string)
    }
}

// MARK: - List Conversations

/// Response for listing conversations.
/// Backend may return either a raw array or a wrapped envelope.
internal struct ListConversationsResponse: Decodable, Sendable {
    let conversations: [ConversationDTO]?
    let items: [ConversationDTO]?
    let data: [ConversationDTO]?
    let totalCount: Int?
    let total: Int?
    let hasMore: Bool?
    let nextCursor: String?
    
    enum CodingKeys: String, CodingKey {
        case conversations
        case items
        case data
        case totalCount = "total_count"
        case total
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
    
    /// Returns the conversation list from whichever field the backend populated.
    var effectiveConversations: [ConversationDTO] {
        return conversations ?? items ?? data ?? []
    }
    
    var effectiveTotal: Int? {
        return totalCount ?? total
    }
}

// MARK: - Get Messages

/// Response for fetching messages from a conversation.
internal struct GetMessagesResponse: Decodable, Sendable {
    let messages: [MessageDTO]?
    let items: [MessageDTO]?
    let data: [MessageDTO]?
    let totalCount: Int?
    let total: Int?
    let hasMore: Bool?
    let nextCursor: String?
    
    enum CodingKeys: String, CodingKey {
        case messages
        case items
        case data
        case totalCount = "total_count"
        case total
        case hasMore = "has_more"
        case nextCursor = "next_cursor"
    }
    
    var effectiveMessages: [MessageDTO] {
        return messages ?? items ?? data ?? []
    }
    
    var effectiveTotal: Int? {
        return totalCount ?? total
    }
}

// MARK: - Mark Read

/// Request body for `POST /api/v1/messaging/mark-read`.
///
/// Per Postman:
/// ```json
/// {
///   "conversation_id": "conv_123",
///   "message_ids": null
/// }
/// ```
/// `message_ids: null` means mark all unread messages as read.
internal struct MarkReadRequest: Encodable, Sendable {
    let conversationId: String
    let messageIds: [String]?
    
    enum CodingKeys: String, CodingKey {
        case conversationId = "conversation_id"
        case messageIds = "message_ids"
    }
}

/// Response for marking messages as read.
internal struct MarkReadResponse: Decodable, Sendable {
    let success: Bool?
    let markedCount: Int?
    
    enum CodingKeys: String, CodingKey {
        case success
        case markedCount = "marked_count"
    }
}

// MARK: - Unread Count

/// Response for getting total unread count.
internal struct UnreadCountResponse: Decodable, Sendable {
    let unreadCount: Int?
    let count: Int?
    let total: Int?
    
    enum CodingKeys: String, CodingKey {
        case unreadCount = "unread_count"
        case count
        case total
    }
    
    var effectiveCount: Int {
        return unreadCount ?? count ?? total ?? 0
    }
}
