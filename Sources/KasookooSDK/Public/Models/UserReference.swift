//
//  UserReference.swift
//  KasookooSDK
//
//  Abstraction for referring to a user by either email or backend user ID.
//
//  The backend uses `user_id` for messaging operations but `email` for identity.
//  This type lets consumers pass either, and the SDK resolves between them
//  internally (caching the email → user_id mapping from identify responses).
//

import Foundation

/// A reference to a user, by either email or backend user ID.
///
/// Consumers typically work with emails. The SDK internally resolves emails
/// to user IDs when calling backend endpoints that require user IDs.
///
/// ## Example
/// ```swift
/// // By email (most common):
/// let target: UserReference = .email("agent@example.com")
///
/// // By user ID (if you've already obtained it):
/// let target: UserReference = .userId("user_abc123")
/// ```
public enum UserReference: Sendable, Hashable {
    
    /// Reference by email address.
    /// The SDK will resolve this to a user ID when needed.
    case email(String)
    
    /// Reference by backend user ID.
    /// Direct usage — no resolution needed.
    case userId(String)
    
    /// Returns the underlying string value (email or user ID).
    public var value: String {
        switch self {
        case .email(let e): return e
        case .userId(let id): return id
        }
    }
    
    /// Convenience: true if this is an email reference.
    public var isEmail: Bool {
        if case .email = self { return true }
        return false
    }
    
    /// Convenience: true if this is a user ID reference.
    public var isUserId: Bool {
        if case .userId = self { return true }
        return false
    }
}
