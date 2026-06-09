//
//  ClientSessionDTOs.swift
//  KasookooSDK
//
//

import Foundation

// MARK: - Create Client Session

/// Request body for `POST /api/v1/sdk/auth/client-sessions`.
///
/// The backend uses a Stripe/Twilio-style minimal bootstrap: the client sends
/// only its publishable key and a subject identifier. The backend derives
/// scopes, TTL, email, audience, and issuer from the organization's
/// `settings.sdk_auth` configuration tied to the publishable key.
///
/// Real request shape (verified against live backend):
/// ```json
/// {
///   "publishable_key": "pk_xxx",
///   "subject": "user_or_device_id"
/// }
/// ```
internal struct CreateClientSessionRequest: Encodable, Sendable {
    
    /// The publishable key identifying the organization.
    /// Backend uses this to look up org settings (scopes, TTL, etc.).
    let publishableKey: String
    
    /// A stable identifier for this session's subject (user or device ID).
    /// For guests: a generated guest_xxx ID. For authenticated users: their ID/email.
    let subject: String
    
    enum CodingKeys: String, CodingKey {
        case publishableKey = "publishable_key"
        case subject
    }
}

/// Response body for `POST /api/v1/sdk/auth/client-sessions`.
///
/// Real response shape (verified against live backend):
/// ```json
/// {
///   "token": "eyJ...",
///   "token_type": "Bearer",
///   "session_id": "sess_xxx",
///   "expires_in": 600,
///   "audience": "kasookoo-sdk-backend",
///   "issuer": "kasookoo-integrator",
///   "allowed_scopes": ["webrtc:token:create", ...]
/// }
/// ```
internal struct CreateClientSessionResponse: Decodable, Sendable {
    
    /// The JWT access token.
    let token: String?
    
    /// Alternative field name some backends use.
    let accessToken: String?
    
    /// Token type, typically "Bearer".
    let tokenType: String?
    
    /// The session ID for token refresh/revoke.
    let sessionId: String?
    
    /// Token lifetime in seconds (backend returned 600 = 10 minutes).
    let expiresIn: Int?
    
    /// The intended audience of the token (e.g., "kasookoo-sdk-backend").
    let audience: String?
    
    /// The token issuer (e.g., "kasookoo-integrator").
    let issuer: String?
    
    /// The scopes the backend granted for this session.
    let allowedScopes: [String]?
    
    enum CodingKeys: String, CodingKey {
        case token
        case accessToken = "access_token"
        case tokenType = "token_type"
        case sessionId = "session_id"
        case expiresIn = "expires_in"
        case audience
        case issuer
        case allowedScopes = "allowed_scopes"
    }
    
    /// Returns the effective access token, preferring `token` over `access_token`.
    var effectiveToken: String? {
        return token ?? accessToken
    }
    
    /// Returns the effective TTL in seconds, defaulting to 600 if not provided.
    var effectiveTTL: Int {
        return expiresIn ?? 600
    }
}

// MARK: - Rotate Session Token

/// Response body for `POST /api/v1/sdk/auth/sessions/{session_id}/tokens`.
/// Same shape as session creation response.
internal typealias RotateSessionTokenResponse = CreateClientSessionResponse

// MARK: - Revoke Session

/// Response body for `DELETE /api/v1/sdk/auth/sessions/{session_id}`.
/// Backend typically returns an empty body or simple success.
internal struct RevokeSessionResponse: Decodable, Sendable {
    let success: Bool?
    let message: String?
}

// MARK: - Introspect Token

/// Response body for `GET /api/v1/sdk/auth/introspect`.
/// Used for debugging — returns information about the current token.
internal struct IntrospectTokenResponse: Decodable, Sendable {
    let active: Bool?
    let sub: String?
    let email: String?
    let organizationId: String?
    let scopes: [String]?
    let expiresAt: Int?
    
    enum CodingKeys: String, CodingKey {
        case active
        case sub
        case email
        case organizationId = "organization_id"
        case scopes
        case expiresAt = "exp"
    }
}
