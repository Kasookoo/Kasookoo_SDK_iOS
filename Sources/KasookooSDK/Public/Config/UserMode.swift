//
//  UserMode.swift
//  KasookooSDK
//
//  Defines the user authentication mode for the SDK session (Section 5).
//

import Foundation

/// The user authentication mode for the SDK session.
public enum UserMode: String, Sendable, Codable {
    
    /// Guest mode. The user is anonymous; the SDK uses anonymous backend flows.
    /// Suitable for support widgets and pre-authentication scenarios.
    case guest = "guest"
    
    /// Authenticated mode. The user has been identified via `identify(...)`.
    /// All flows use the authenticated user's identity.
    case authenticated = "authenticated"
}
