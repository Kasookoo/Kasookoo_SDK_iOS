//
//  CallTokensDTOs.swift
//  KasookooSDK
//
//

import Foundation

// MARK: - Participant DTO (Internal Wire Format)

/// Backend wire format for a participant in call/messaging contexts.
/// Uses snake_case for fields.
internal struct ParticipantDTO: Codable, Sendable {
    let name: String
    let email: String
    let phoneNumber: String
    let type: String
    
    enum CodingKeys: String, CodingKey {
        case name
        case email
        case phoneNumber = "phone_number"
        case type
    }
    
    /// Creates a DTO from a public Participant model.
    init(from participant: Participant) {
        self.name = participant.name
        self.email = participant.email
        self.phoneNumber = participant.phoneNumber
        self.type = participant.type.rawValue
    }
    
    /// Converts to a public Participant model.
    func toModel() -> Participant {
        return Participant(
            name: name,
            email: email,
            phoneNumber: phoneNumber,
            type: ParticipantType(rawValue: type) ?? .customer
        )
    }
}

// MARK: - Device Type

/// Device type values accepted by WebRTC and messaging endpoints.
/// Backend uses `"mobile"` or `"web"` for these contexts.
internal enum DeviceType: String, Sendable {
    case mobile = "mobile"
    case web = "web"
}

// MARK: - Get Call Tokens

/// Request body for `POST /api/v1/webrtc/get-call-tokens`.
///
/// Per Postman collection:
/// ```json
/// {
///   "room_name": "call_room_123",
///   "caller": { ... },
///   "callee": { ... },
///   "device_type": "mobile",
///   "is_push_notification": true,
///   "is_call_recording": true
/// }
/// ```
internal struct GetCallTokensRequest: Encodable, Sendable {
    let roomName: String
    let caller: ParticipantDTO
    let callee: ParticipantDTO
    let deviceType: String
    let isPushNotification: Bool
    let isCallRecording: Bool
    
    enum CodingKeys: String, CodingKey {
        case roomName = "room_name"
        case caller
        case callee
        case deviceType = "device_type"
        case isPushNotification = "is_push_notification"
        case isCallRecording = "is_call_recording"
    }
}

/// Response body for `POST /api/v1/webrtc/get-call-tokens`.
///
/// **Note:** Exact response schema not in Postman samples. These fields are
/// based on LiveKit's typical token endpoint response. Confirm with backend.
/// Response body for `POST /api/v1/webrtc/get-call-tokens`.
///
/// **Real backend response shape** (verified via Postman):
/// ```json
/// {
///   "accessToken": "eyJ...",
///   "wsUrl": "wss://inapp-test.kasookoo.ai"
/// }
/// ```
///
/// Backend uses camelCase (not snake_case) for this endpoint, and returns
/// a single `accessToken` for the caller (callee gets its own token via
/// notification flow).
internal struct GetCallTokensResponse: Decodable, Sendable {
    
    /// LiveKit access token (real backend field: `accessToken`).
    let accessToken: String?
    
    /// Legacy field name kept for fallback (older `caller_token` shape).
    let callerToken: String?
    
    /// LiveKit access token for the callee (if applicable — older shape).
    let calleeToken: String?
    
    /// LiveKit WebSocket URL (real backend field: `wsUrl`).
    let wsUrl: String?
    
    /// Alternative LiveKit URL field name (older shape).
    let livekitUrl: String?
    
    /// The room name (echoed back, if returned).
    let roomName: String?
    
    /// A unique identifier for this call (if returned).
    let callId: String?
    
    enum CodingKeys: String, CodingKey {
        // Real backend uses camelCase
        case accessToken
        case wsUrl
        // Legacy/fallback snake_case keys (kept for safety)
        case callerToken = "caller_token"
        case calleeToken = "callee_token"
        case livekitUrl = "livekit_url"
        case roomName = "room_name"
        case callId = "call_id"
    }
    
    /// Returns the effective caller token, preferring `accessToken` over
    /// the legacy `caller_token`.
    var effectiveCallerToken: String? {
        return accessToken ?? callerToken
    }
    
    /// Returns the effective WebSocket URL, trying multiple field names.
    var effectiveWsUrl: String? {
        return wsUrl ?? livekitUrl
    }
}

// MARK: - Anonymous Call Tokens

/// Request body for `POST /api/v1/webrtc/get-call-tokens-anonymous`.
///
/// Per Postman collection — different shape from authenticated version:
/// ```json
/// {
///   "room_name": "call_room_guest",
///   "participant_identity": "guest_session_1",
///   "participant_identity_name": "Guest",
///   "called_user_id": "called_user_456",
///   "device_type": "web",
///   "is_push_notification": false,
///   "is_call_recording": true
/// }
/// ```
internal struct GetCallTokensAnonymousRequest: Encodable, Sendable {
    let roomName: String
    let participantIdentity: String
    let participantIdentityName: String
    let calledUserId: String
    let deviceType: String
    let isPushNotification: Bool
    let isCallRecording: Bool
    
    enum CodingKeys: String, CodingKey {
        case roomName = "room_name"
        case participantIdentity = "participant_identity"
        case participantIdentityName = "participant_identity_name"
        case calledUserId = "called_user_id"
        case deviceType = "device_type"
        case isPushNotification = "is_push_notification"
        case isCallRecording = "is_call_recording"
    }
}

/// Response shape identical to authenticated version.
internal typealias GetCallTokensAnonymousResponse = GetCallTokensResponse

// MARK: - End Call (Agent/Admin ending)

/// Response for `POST /api/v1/webrtc/calls/{room_name}/end`.
/// Request body is empty.
internal struct EndCallResponse: Decodable, Sendable {
    let success: Bool?
    let endedAt: String?
    let message: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case endedAt = "ended_at"
        case message
    }
}

// MARK: - Caller End Call

/// Request body for `POST /api/v1/webrtc/calls/caller-end`.
///
/// Used when the caller hangs up their own call (before or during connection).
internal struct CallerEndCallRequest: Encodable, Sendable {
    let roomName: String
    let participantIdentity: String
    let participantIdentityType: String  // typically "caller"
    let callerUserId: String
    let calledUserId: String
    
    enum CodingKeys: String, CodingKey {
        case roomName = "room_name"
        case participantIdentity = "participant_identity"
        case participantIdentityType = "participant_identity_type"
        case callerUserId = "caller_user_id"
        case calledUserId = "called_user_id"
    }
}

// MARK: - Reject Call

/// Request body for `POST /api/v1/webrtc/calls/reject`.
internal struct RejectCallRequest: Encodable, Sendable {
    let roomName: String
    let participantIdentity: String
    let participantIdentityName: String
    let participantIdentityType: String
    let callerUserId: String
    let calledUserId: String
    
    enum CodingKeys: String, CodingKey {
        case roomName = "room_name"
        case participantIdentity = "participant_identity"
        case participantIdentityName = "participant_identity_name"
        case participantIdentityType = "participant_identity_type"
        case callerUserId = "caller_user_id"
        case calledUserId = "called_user_id"
    }
}

// MARK: - Get Call Status

/// Response for `GET /api/v1/webrtc/calls/{room_name}/status`.
internal struct GetCallStatusResponse: Decodable, Sendable {
    let roomName: String?
    let status: String?
    let participantCount: Int?
    let startedAt: String?
    let durationSeconds: Int?
    
    enum CodingKeys: String, CodingKey {
        case roomName = "room_name"
        case status
        case participantCount = "participant_count"
        case startedAt = "started_at"
        case durationSeconds = "duration_seconds"
    }
}

// MARK: - Identify User
//
// CRITICAL: This endpoint uses camelCase fields, unlike most other endpoints.
// Per Postman:
// {
//   "name": "John Caller",
//   "email": "john.caller@example.com",
//   "phoneNumber": "+447700900111",   ← camelCase!
//   "type": "customer"
// }

/// Request body for `POST /api/v1/users/identify`.
///
/// **WARNING:** This endpoint uses **camelCase** field names, unlike most
/// other endpoints which use snake_case. This is a backend quirk.
internal struct IdentifyUserRequest: Encodable, Sendable {
    let name: String
    let email: String
    let phoneNumber: String
    let type: String
    
    // CamelCase — explicit CodingKeys to override JSONEncoder defaults
    enum CodingKeys: String, CodingKey {
        case name
        case email
        case phoneNumber   // intentionally camelCase
        case type
    }
    
    init(from profile: CallerProfile) {
        self.name = profile.name
        self.email = profile.email
        self.phoneNumber = profile.phoneNumber
        self.type = profile.type.rawValue
    }
}

/// Response for `POST /api/v1/users/identify`.
///
/// **Confirm exact shape with backend team.**
internal struct IdentifyUserResponse: Decodable, Sendable {
    let success: Bool?
    let userId: String?
    let id: String?
    let email: String?
    let name: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case userId = "user_id"
        case id
        case email
        case name
    }
    
    /// Returns the effective user ID, trying multiple field names.
    var effectiveUserId: String? {
        return userId ?? id
    }
}
