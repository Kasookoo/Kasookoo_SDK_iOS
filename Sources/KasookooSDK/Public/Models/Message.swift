//
//  Message.swift
//  KasookooSDK
//
//  Represents a single message in a conversation.
//

import Foundation

/// A single message in a conversation.
public struct Message: Sendable, Hashable, Identifiable {
    
    // MARK: - Identity
    
    /// A unique server-assigned identifier for this message.
    public let id: String
    
    /// The conversation/room this message belongs to.
    public let roomName: String
    
    // MARK: - Sender / Receiver
    
    /// The email of the sender.
    public let senderEmail: String
    
    /// The email of the intended receiver.
    public let receiverEmail: String
    
    // MARK: - Content
    
    /// The message content.
    public let content: String
    
    /// The type of content (text, image, file, etc.).
    public let messageType: MessageType
    
    /// Optional URL for media-type messages (image/file/audio/video).
    public let mediaURL: URL?
    
    // MARK: - Timing
    
    /// When the message was sent.
    public let sentAt: Date
    
    /// When the message was delivered to the receiver, if known.
    public let deliveredAt: Date?
    
    /// When the message was read by the receiver, if known.
    public let readAt: Date?
    
    // MARK: - Status
    
    /// The current delivery/read status.
    public let status: MessageStatus
    
    /// Whether the local user is the sender of this message.
    public let isOutgoing: Bool
    
    // MARK: - Init
    
    public init(
        id: String,
        roomName: String,
        senderEmail: String,
        receiverEmail: String,
        content: String,
        messageType: MessageType = .text,
        mediaURL: URL? = nil,
        sentAt: Date = Date(),
        deliveredAt: Date? = nil,
        readAt: Date? = nil,
        status: MessageStatus = .sending,
        isOutgoing: Bool = true
    ) {
        self.id = id
        self.roomName = roomName
        self.senderEmail = senderEmail
        self.receiverEmail = receiverEmail
        self.content = content
        self.messageType = messageType
        self.mediaURL = mediaURL
        self.sentAt = sentAt
        self.deliveredAt = deliveredAt
        self.readAt = readAt
        self.status = status
        self.isOutgoing = isOutgoing
    }
}

// MARK: - Message Type

/// The type of message content.
public enum MessageType: String, Sendable, Hashable, Codable {
    case text = "text"
    case image = "image"
    case file = "file"
    case audio = "audio"
    case video = "video"
    case system = "system"
}

// MARK: - Message Status

/// The delivery and read status of a message.
public enum MessageStatus: String, Sendable, Hashable, Codable {
    
    /// Message is being sent (in flight).
    case sending = "sending"
    
    /// Message has been sent to the server.
    case sent = "sent"
    
    /// Message has been delivered to the receiver's device.
    case delivered = "delivered"
    
    /// Message has been read by the receiver.
    case read = "read"
    
    /// Message failed to send.
    case failed = "failed"
}
