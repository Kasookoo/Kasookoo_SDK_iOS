//
//  MessagingDTOs.swift
//  KasookooSDK
//
//  Data Transfer Objects for the messaging endpoints.
//  Schemas verified against the live backend (July 2026 contract update).
//
//  Decoding note: the shared response decoder uses `.convertFromSnakeCase`, so
//  response models use camelCase properties WITHOUT explicit snake_case CodingKeys.
//  Providing snake_case CodingKeys on top of that strategy is a known Codable
//  conflict that silently decodes fields as nil. Request models keep explicit
//  CodingKeys, which are safe with the encoder's `.convertToSnakeCase` strategy.
//

import Foundation

// MARK: - Get Messaging Token

/// Request body for `POST /api/v1/messaging/get-token`.
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
///
/// Verified shape:
/// ```json
/// { "access_token": "...", "ws_url": "wss://...", "http_url": "https://..." }
/// ```
internal struct GetMessagingTokenResponse: Decodable, Sendable {
    let accessToken: String?
    let wsUrl: String?
    let httpUrl: String?

    var effectiveToken: String? { accessToken }
}

// MARK: - Send Message

/// Request body for `POST /api/v1/messaging/send`.
///
/// Verified shape:
/// ```json
/// { "sender_user_id": "...", "receiver_user_id": "...", "room_name": "...",
///   "message": "...", "channel": "normal", "message_type": "text",
///   "metadata": {}, "is_push_notification": true }
/// ```
internal struct SendMessageRequest: Encodable, Sendable {
    let senderUserId: String
    let receiverUserId: String
    let roomName: String
    let message: String
    /// Delivery channel: `normal` or `whatsapp`.
    let channel: String
    /// Content kind: `text`, `image`, ...
    let messageType: String
    let metadata: [String: String]?
    let isPushNotification: Bool

    enum CodingKeys: String, CodingKey {
        case senderUserId = "sender_user_id"
        case receiverUserId = "receiver_user_id"
        case roomName = "room_name"
        case message
        case channel
        case messageType = "message_type"
        case metadata
        case isPushNotification = "is_push_notification"
    }
}

/// Response body for `POST /api/v1/messaging/send`.
///
/// Verified shape:
/// ```json
/// { "id": "...", "conversation_id": "...", "sender_user_id": "...",
///   "receiver_user_id": "...", "room_name": "...", "message": "...",
///   "channel": "normal", "message_type": "text", "metadata": {},
///   "created_at": "...", "read_at": null }
/// ```
internal struct SendMessageResponse: Decodable, Sendable {
    let id: String?
    let conversationId: String?
    let senderUserId: String?
    let receiverUserId: String?
    let roomName: String?
    let message: String?
    let channel: String?
    let messageType: String?
    let createdAt: String?
    let readAt: String?
    /// Not part of the current send response; kept optional so a status, if the
    /// backend ever includes one, decodes, and existing callers keep compiling.
    let status: String?

    var effectiveMessageId: String? { id }
    var effectiveTimestamp: String? { createdAt }
}

// MARK: - Message DTO (for list/get)

/// Backend representation of a message (list messages item and send response).
internal struct MessageDTO: Decodable, Sendable {
    let id: String
    let conversationId: String?
    let senderUserId: String?
    let receiverUserId: String?
    let roomName: String?
    let message: String?
    let channel: String?
    let messageType: String?
    let metadata: [String: String]?
    let createdAt: String?
    let readAt: String?

    /// Converts to the public `Message` model.
    /// Requires the current user's `user_id` to compute `isOutgoing`.
    func toModel(currentUserId: String?) -> Message {
        let content = message ?? ""
        let type = MessageType(rawValue: messageType ?? "") ?? .text
        let sentDate = parseIso8601(createdAt) ?? Date()
        let readDate = parseIso8601(readAt)
        let isOutgoing = currentUserId.map { $0 == senderUserId } ?? false
        let status: MessageStatus = (readDate != nil) ? .read : .sent

        // The backend message object identifies participants by user id and does
        // not carry emails, so the email fields are left empty here.
        return Message(
            id: id,
            roomName: roomName ?? conversationId ?? "",
            senderEmail: "",
            receiverEmail: "",
            content: content,
            messageType: type,
            mediaURL: nil,
            sentAt: sentDate,
            deliveredAt: nil,
            readAt: readDate,
            status: status,
            isOutgoing: isOutgoing,
            conversationId: conversationId,
            metadata: metadata
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

/// Backend representation of a conversation (list conversations item).
///
/// Verified shape:
/// ```json
/// { "conversation_id": "...", "room_name": "...",
///   "participant_user_id": "...", "participant_name": "...",
///   "participant_email": "...", "channel": "normal",
///   "associated_number_id": null, "last_message": "...",
///   "last_message_at": "...", "unread_count": 0,
///   "created_at": "...", "updated_at": "..." }
/// ```
internal struct ConversationDTO: Decodable, Sendable {
    let conversationId: String?
    let roomName: String?
    let participantUserId: String?
    let participantName: String?
    let participantEmail: String?
    let channel: String?
    let associatedNumberId: String?
    /// The most recent message text (a preview string, not a full object).
    let lastMessage: String?
    let lastMessageAt: String?
    let unreadCount: Int?
    let createdAt: String?
    let updatedAt: String?

    /// The other participant's email, wrapped as an array for the public model.
    var participantEmails: [String]? { participantEmail.map { [$0] } }

    /// The other participant's user id, wrapped as an array for the public model.
    var participantUserIds: [String]? { participantUserId.map { [$0] } }

    func toModel(currentUserId: String?) -> Conversation {
        let convId = conversationId ?? roomName ?? ""
        let room = roomName ?? convId
        let lastUpdated = parseIso8601(updatedAt ?? lastMessageAt) ?? Date()

        // Build a lightweight preview of the last message from the text and
        // timestamp the backend provides on the conversation.
        var preview: Message?
        if let text = lastMessage {
            let at = parseIso8601(lastMessageAt) ?? lastUpdated
            preview = Message(
                id: "",
                roomName: room,
                senderEmail: "",
                receiverEmail: "",
                content: text,
                messageType: .text,
                mediaURL: nil,
                sentAt: at,
                deliveredAt: nil,
                readAt: nil,
                status: .sent,
                isOutgoing: false
            )
        }

        return Conversation(
            conversationId: convId,
            roomName: room,
            participantEmails: participantEmails ?? [],
            participantUserIds: participantUserIds ?? [],
            lastMessage: preview,
            lastUpdatedAt: lastUpdated,
            messageCount: 0,
            unreadCount: unreadCount ?? 0,
            title: participantName
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

// MARK: - Pagination

/// Standard pagination envelope returned by the list endpoints.
internal struct PaginationDTO: Decodable, Sendable {
    let total: Int?
    let skip: Int?
    let limit: Int?
}

// MARK: - List Conversations

/// Response for `GET /api/v1/messaging/conversations`.
///
/// Verified shape: `{ "items": [ ... ], "pagination": { total, skip, limit } }`.
internal struct ListConversationsResponse: Decodable, Sendable {
    let items: [ConversationDTO]?
    let pagination: PaginationDTO?

    /// Present only on some list responses; kept optional for compatibility.
    let hasMore: Bool?
    let nextCursor: String?

    var effectiveConversations: [ConversationDTO] { items ?? [] }
    var effectiveTotal: Int? { pagination?.total }
}

// MARK: - Get Messages

/// Response for `GET /api/v1/messaging/conversations/{id}/messages`.
///
/// Verified shape:
/// `{ "items": [ ... ], "pagination": { ... }, "conversation_id": "...",
///    "messaging_tokens": null }`.
internal struct GetMessagesResponse: Decodable, Sendable {
    let items: [MessageDTO]?
    let pagination: PaginationDTO?
    let conversationId: String?

    /// Present only on some list responses; kept optional for compatibility.
    let hasMore: Bool?
    let nextCursor: String?

    var effectiveMessages: [MessageDTO] { items ?? [] }
    var effectiveTotal: Int? { pagination?.total }
}

// MARK: - Mark Read

/// Request body for `POST /api/v1/messaging/mark-read`.
///
/// Verified shape:
/// `{ "user_id": "...", "conversation_id": "...", "message_ids": null }`.
/// `message_ids: null` marks all unread messages as read.
internal struct MarkReadRequest: Encodable, Sendable {
    let userId: String
    let conversationId: String
    let messageIds: [String]?

    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case conversationId = "conversation_id"
        case messageIds = "message_ids"
    }
}

/// Response for marking messages as read.
///
/// Verified shape:
/// `{ "success": true, "conversation_id": "...", "messages_marked_read": 0 }`.
internal struct MarkReadResponse: Decodable, Sendable {
    let success: Bool?
    let conversationId: String?
    let messagesMarkedRead: Int?
}

// MARK: - Unread Count

/// Response for `GET /api/v1/messaging/unread-count`.
internal struct UnreadCountResponse: Decodable, Sendable {
    let unreadCount: Int?
    let count: Int?
    let total: Int?

    var effectiveCount: Int { unreadCount ?? count ?? total ?? 0 }
}
