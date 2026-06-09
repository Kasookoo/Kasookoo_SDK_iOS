//
//  EventToken.swift
//  KasookooSDK
//
//  An opaque token returned by event subscription methods.
//  Used to unsubscribe from events without exposing internal state.
//

import Foundation

/// An opaque token representing an event subscription.
///
/// Returned by `sdk.on(...)` and used to unsubscribe via `sdk.off(token)`.
/// Tokens are unique per subscription and cannot be reused.
///
/// ## Example
/// ```swift
/// let token = sdk.on(EventName.callIncoming) { event in
///     // Handle event
/// }
///
/// // Later, when no longer needed:
/// sdk.off(token)
/// ```
public struct EventToken: Sendable, Hashable {
    
    /// Internal unique identifier for this subscription.
    internal let id: UUID
    
    /// The event name this token is subscribed to.
    /// Stored for efficient lookup during unsubscribe.
    internal let eventName: String
    
    internal init(eventName: String) {
        self.id = UUID()
        self.eventName = eventName
    }
}
