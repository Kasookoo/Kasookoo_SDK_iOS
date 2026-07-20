//
//  Endpoint.swift
//  KasookooSDK
//
//

import Foundation

/// All backend endpoints consumed by the SDK.
///
/// Internal type — endpoints are an implementation detail and never exposed
/// to SDK consumers.
internal enum Endpoint: Sendable {
    
    // MARK: - Auth / Session
    
    /// `POST /api/v1/sdk/auth/client-sessions` — Bootstrap a new session.
    /// Public endpoint (no auth required).
    case createClientSession
    
    /// `POST /api/v1/sdk/auth/sessions/{session_id}/tokens` — Rotate session token.
    /// Requires `Authorization: Bearer {current_token}`.
    case rotateSessionToken(sessionId: String)
    
    /// `DELETE /api/v1/sdk/auth/sessions/{session_id}` — Revoke session.
    /// Requires authentication.
    case revokeSession(sessionId: String)
    
    /// `GET /api/v1/sdk/auth/introspect` — Validate current token.
    /// Useful for debugging session state.
    case introspectToken
    
    // MARK: - Identity (Users)
    
    /// `POST /api/v1/users/identify` — Upsert user by email.
    /// **Note:** This endpoint uses camelCase (phoneNumber, not phone_number).
    case identifyUser
    
    // MARK: - WebRTC Calling
    
    /// `POST /api/v1/webrtc/get-call-tokens` — Get call tokens (caller/callee).
    case getCallTokens
    
    /// `POST /api/v1/webrtc/get-call-tokens-anonymous` — Anonymous caller tokens.
    case getCallTokensAnonymous
    
    /// `POST /api/v1/webrtc/calls/{room_name}/end` — End an active call (admin/agent).
    case endCall(roomName: String)
    
    /// `POST /api/v1/webrtc/calls/caller-end` — Caller ending their own call.
    /// Different from `endCall` — used when caller hangs up before connection.
    case callerEndCall
    
    /// `GET /api/v1/webrtc/calls/{room_name}/status` — Get real-time call status.
    case getCallStatus(roomName: String)
    
    /// `POST /api/v1/webrtc/calls/reject` — Reject an incoming call.
    case rejectCall
    
    // MARK: - SIP Calling
    
    /// `POST /api/v1/sip/calls/make` — Initiate outbound SIP call (preferred for new calls).
    case sipMakeCall
    
    /// `POST /api/v1/sip/calls/dial` — Alternative outbound SIP dial endpoint.
    case sipDial
    
    /// `POST /api/v1/sip/calls/end` — End SIP call (graceful).
    case sipEndCall
    
    /// `POST /api/v1/sip/calls/hangup` — Hang up SIP call (force).
    case sipHangup
    
    // MARK: - Messaging
    
    /// `POST /api/v1/messaging/get-token` — Get messaging token.
    case messagingGetToken
    
    /// `POST /api/v1/messaging/send` — Send a message.
    /// **Note:** Uses sender_user_id / receiver_user_id (not emails).
    case messagingSend
    
    /// `GET /api/v1/messaging/conversations` — List conversations.
    /// Query params: skip, limit
    case messagingListConversations(skip: Int, limit: Int)
    
    /// `GET /api/v1/messaging/conversations/{conversation_id}/messages` — Get messages.
    /// Query params: skip, limit
    /// **Note:** Uses conversation_id (not room_name).
    case messagingGetMessages(conversationId: String, skip: Int, limit: Int)
    
    /// `POST /api/v1/messaging/mark-read` — Mark messages as read.
    case messagingMarkRead
    
    /// `GET /api/v1/messaging/unread-count` — Total unread count.
    case messagingUnreadCount
    
    // MARK: - Notifications (FCM-based)
    
    /// `POST /api/v1/notifications/register-token` — Register FCM device token.
    case registerDeviceToken
    
    /// `POST /api/v1/notifications/update-token` — Update FCM device token (rotation).
    case updateDeviceToken
    
    /// `POST /api/v1/notifications/unregister-token` — Unregister device.
    case unregisterDeviceToken
    
    // MARK: - Path
    
    /// The relative path for this endpoint.
    var path: String {
        switch self {
        // Auth
        case .createClientSession:
            return "/api/v1/sdk/auth/client-sessions"
        case .rotateSessionToken(let sessionId):
            return "/api/v1/sdk/auth/sessions/\(sessionId)/tokens"
        case .revokeSession(let sessionId):
            return "/api/v1/sdk/auth/sessions/\(sessionId)"
        case .introspectToken:
            return "/api/v1/sdk/auth/introspect"
            
        // Identity
        case .identifyUser:
            return "/api/v1/users/identify"
            
        // WebRTC
        case .getCallTokens:
            return "/api/v1/webrtc/get-call-tokens"
        case .getCallTokensAnonymous:
            return "/api/v1/webrtc/get-call-tokens-anonymous"
        case .endCall(let roomName):
            let encoded = roomName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomName
            return "/api/v1/webrtc/calls/\(encoded)/end"
        case .callerEndCall:
            return "/api/v1/webrtc/calls/caller-end"
        case .getCallStatus(let roomName):
            let encoded = roomName.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? roomName
            return "/api/v1/webrtc/calls/\(encoded)/status"
        case .rejectCall:
            return "/api/v1/webrtc/calls/reject"
            
        // SIP
        case .sipMakeCall:
            return "/api/v1/sip/calls/make"
        case .sipDial:
            return "/api/v1/sip/calls/dial"
        case .sipEndCall:
            return "/api/v1/sip/calls/end"
        case .sipHangup:
            return "/api/v1/sip/calls/hangup"
            
        // Messaging
        case .messagingGetToken:
            return "/api/v1/messaging/get-token"
        case .messagingSend:
            return "/api/v1/messaging/send"
        case .messagingListConversations(let skip, let limit):
            var components = URLComponents()
            components.path = "/api/v1/messaging/conversations"
            components.queryItems = [
                URLQueryItem(name: "skip", value: "\(skip)"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
            return components.string ?? "/api/v1/messaging/conversations"
        case .messagingGetMessages(let conversationId, let skip, let limit):
            let encoded = conversationId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conversationId
            var components = URLComponents()
            components.path = "/api/v1/messaging/conversations/\(encoded)/messages"
            components.queryItems = [
                URLQueryItem(name: "skip", value: "\(skip)"),
                URLQueryItem(name: "limit", value: "\(limit)")
            ]
            return components.string ?? "/api/v1/messaging/conversations/\(encoded)/messages"
        case .messagingMarkRead:
            return "/api/v1/messaging/mark-read"
        case .messagingUnreadCount:
            return "/api/v1/messaging/unread-count"
            
        // Notifications
        case .registerDeviceToken:
            return "/api/v1/notifications/register-token"
        case .updateDeviceToken:
            return "/api/v1/notifications/update-token"
        case .unregisterDeviceToken:
            return "/api/v1/notifications/unregister-token"
        }
    }
    
    // MARK: - HTTP Method
    
    /// The HTTP method to use for this endpoint.
    var method: HTTPMethod {
        switch self {
        case .revokeSession:
            return .delete
        case .introspectToken,
             .messagingListConversations,
             .messagingGetMessages,
             .messagingUnreadCount,
             .getCallStatus:
            return .get
        default:
            return .post
        }
    }
    
    // MARK: - Authentication Requirements
    
    /// Whether this endpoint requires an authentication token.
    /// Only `createClientSession` is unauthenticated (it bootstraps).
    var requiresAuth: Bool {
        switch self {
        case .createClientSession:
            return false
        default:
            return true
        }
    }
    
    // MARK: - Organization Context
    
    /// Whether this endpoint requires the `X-Organization-Id` header.
    ///
    /// As of the current backend contract, protected routes read the tenant
    /// `organization_id` from the SDK JWT (`get_organization_id`) — the explicit
    /// `X-Organization-Id` header must NOT be sent. It is therefore disabled for
    /// all endpoints. The switch is retained (rather than deleting the mechanism)
    /// so it can be re-enabled per-endpoint if the backend ever requires it again.
    var requiresOrganizationHeader: Bool {
        switch self {
        default:
            return false
        }
    }
    
    // MARK: - Timeout Classification
    
    /// The timeout class for this endpoint (Section 13).
    var timeoutClass: TimeoutClass {
        switch self {
        case .createClientSession,
             .rotateSessionToken,
             .revokeSession,
             .introspectToken:
            return .session
        case .getCallTokens,
             .getCallTokensAnonymous,
             .endCall,
             .callerEndCall,
             .getCallStatus,
             .rejectCall,
             .sipMakeCall,
             .sipDial,
             .sipEndCall,
             .sipHangup:
            return .call
        case .messagingGetToken,
             .messagingSend,
             .messagingListConversations,
             .messagingGetMessages,
             .messagingMarkRead,
             .messagingUnreadCount:
            return .messaging
        case .identifyUser,
             .registerDeviceToken,
             .updateDeviceToken,
             .unregisterDeviceToken:
            return .standard
        }
    }
}

// MARK: - Timeout Class

/// Classifies endpoints by expected latency for timeout configuration.
internal enum TimeoutClass: Sendable {
    case session    // Session bootstrap/rotation: 10s
    case call       // Call setup: 15s (WebRTC handshake takes longer)
    case messaging  // Messaging: 10s
    case standard   // Other: 10s
    
    var seconds: TimeInterval {
        switch self {
        case .session: return 10
        case .call: return 15
        case .messaging: return 10
        case .standard: return 10
        }
    }
}
