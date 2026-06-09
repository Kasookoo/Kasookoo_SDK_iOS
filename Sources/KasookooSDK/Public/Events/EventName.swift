//
//  EventName.swift
//  KasookooSDK
//
//  Defines all event name constants used by the SDK (Section 7 of the spec).
//  These names MUST be identical across React, Kotlin, and Swift SDKs.
//

import Foundation

/// Event name constants for all events the Kasookoo SDK can emit.
///
/// **Cross-platform contract:** The string values here MUST match exactly with
/// the React and Kotlin SDKs to maintain event parity (Section 14).
///
/// ## Example
/// ```swift
/// sdk.on(EventName.callIncoming) { event in
///     // Handle incoming call
/// }
/// ```
public enum EventName {
    
    // MARK: - SDK Lifecycle Events
    
    /// Emitted when the SDK is fully initialized and ready to use.
    public static let sdkReady = "sdk.ready"
    
    /// Emitted when the SDK's connection state changes.
    public static let sdkConnectionChanged = "sdk.connection.changed"
    
    /// Emitted when an unrecoverable error occurs in the SDK.
    public static let sdkError = "sdk.error"
    
    // MARK: - Session Events
    
    /// Emitted when the session is approaching expiry (typically at 80-90% of TTL).
    public static let sessionExpiring = "session.expiring"
    
    /// Emitted when the session has been successfully refreshed.
    public static let sessionRefreshed = "session.refreshed"
    
    /// Emitted when the session has expired and could not be refreshed.
    public static let sessionExpired = "session.expired"
    
    // MARK: - Call Events (App-to-App / WebRTC)
    
    /// Emitted when an incoming call is received.
    public static let callIncoming = "call.incoming"
    
    /// Emitted when an outgoing call starts ringing on the callee's side.
    public static let callRinging = "call.ringing"
    
    /// Emitted when a call has been successfully connected.
    public static let callConnected = "call.connected"
    
    /// Emitted when a call has ended normally.
    public static let callEnded = "call.ended"
    
    /// Emitted when a call failed to connect or was dropped abnormally.
    public static let callFailed = "call.failed"
    
    // MARK: - SIP Events
    
    /// Emitted when an outgoing SIP call is being placed.
    public static let sipCalling = "sip.calling"
    
    /// Emitted when a SIP call has been connected.
    public static let sipConnected = "sip.connected"
    
    /// Emitted when a SIP call has ended.
    public static let sipEnded = "sip.ended"
    
    // MARK: - Messaging Events
    
    /// Emitted when a new message is received.
    public static let messageReceived = "message.received"
    
    /// Emitted when an outgoing message has been delivered.
    public static let messageSent = "message.sent"
    
    /// Emitted when a message has been read by the recipient.
    public static let messageRead = "message.read"
    
    /// Emitted when a conversation's metadata changes (new message, read status, etc.).
    public static let conversationUpdated = "conversation.updated"
    
    // MARK: - Notification Events
    
    /// Emitted when a push notification is received and processed by the SDK.
    public static let notificationReceived = "notification.received"
    
    // MARK: - Helpers
    
    /// All event names supported by the SDK. Useful for validation and testing.
    public static let allEventNames: Set<String> = [
        sdkReady, sdkConnectionChanged, sdkError,
        sessionExpiring, sessionRefreshed, sessionExpired,
        callIncoming, callRinging, callConnected, callEnded, callFailed,
        sipCalling, sipConnected, sipEnded,
        messageReceived, messageSent, messageRead, conversationUpdated,
        notificationReceived
    ]
}
