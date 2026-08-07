//
//  CallTokensDTOs.swift
//  KasookooSDK
//
//  DTOs for /api/v1/webrtc/* and /api/v1/users/identify endpoints.
//  Schema verified against Postman collection.
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
    
    /// LiveKit WebSocket URL (real backend field: `ws_url`).
    let wsUrl: String?

    /// LiveKit HTTP URL (real backend field: `http_url`).
    let httpUrl: String?

    /// How the callee receives its own token: `push` when delivered via FCM,
    /// otherwise `none`. Backend field: `callee_token_delivery`.
    let calleeTokenDelivery: String?

    /// Alternative LiveKit URL field name (older shape).
    let livekitUrl: String?
    
    /// The room name (echoed back, if returned).
    let roomName: String?
    
    /// A unique identifier for this call (if returned).
    let callId: String?
    
    
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
    
}

// MARK: - Caller End Call

/// Request body for `POST /api/v1/webrtc/calls/caller-end`.
///
/// Used when the caller hangs up their own call (before or during connection).
internal struct CallerEndCallRequest: Encodable, Sendable {
    let roomName: String
    let caller: ParticipantDTO
    let callee: ParticipantDTO
    
}

// MARK: - Reject Call

/// Request body for `POST /api/v1/webrtc/calls/reject`.
///
/// Same shape as caller-end: the backend identifies both parties by their
/// participant objects (email-keyed), not by user ids.
internal struct RejectCallRequest: Encodable, Sendable {
    let roomName: String
    let caller: ParticipantDTO
    let callee: ParticipantDTO
    
}

// MARK: - Get Call Status

/// Response for `GET /api/v1/webrtc/calls/{room_name}/status`.
internal struct GetCallStatusResponse: Decodable, Sendable {
    let roomName: String?
    let status: String?
    let participantCount: Int?
    let startedAt: String?
    let durationSeconds: Int?
    
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
/// Request body for `POST /api/v1/users/identify`.
///
/// Matches the backend contract (verified against the Postman collection):
/// ```json
/// { "organization_id": "...", "email": "...", "role": "customer" }
/// ```
///
/// NOTE: The backend does NOT accept `name` / `phone_number` / `type` here —
/// identify is a lightweight upsert keyed by (organization_id, email). The
/// richer `CallerProfile` fields are still kept locally in the SDK's state and
/// used when placing calls; they are simply not part of this request.
///
/// `organization_id` is taken from the SDK's own `KasookooConfig` — the host app
/// does not pass it again.
internal struct IdentifyUserRequest: Encodable, Sendable {
    let organizationId: String
    let email: String
    let role: String
    
    
    init(organizationId: String, profile: CallerProfile) {
        self.organizationId = organizationId
        self.email = profile.email
        self.role = Self.identifyRole(for: profile.type)
    }
    
    /// Maps a participant `type` onto the roles the `/users/identify` endpoint
    /// accepts.
    ///
    /// ⚠️ TEMPORARY MAPPING. The identify endpoint currently only accepts
    /// `customer`, `agent`, and `admin` — a narrower set than the participant
    /// `type` used everywhere else (which also includes `driver`, `bot`, etc.).
    /// Sending `driver` here returns a 422. Until the backend widens the accepted
    /// identify roles, non-matching types are mapped to the closest valid role:
    ///
    ///   driver → agent   (per product decision)
    ///
    /// This mapping applies ONLY to identify. The call/messaging `type` fields
    /// still send the real participant type (e.g. `driver`), which those
    /// endpoints accept. Remove this once the backend accepts the full type set.
    private static func identifyRole(for type: ParticipantType) -> String {
        switch type {
        case .customer:
            return "customer"
        case .agent:
            return "agent"
        case .driver:
            return "agent"        // TODO: revert to "driver" once backend accepts it
        case .bot, .system:
            return "agent"        // service-side roles → agent
        case .anonymous:
            return "customer"     // treat anonymous as an end user
        }
    }
}

/// Response for `POST /api/v1/users/identify`.
///
/// Verified shape:
/// ```json
/// { "id": "...", "email": "...", "phone_number": null,
///   "first_name": "...", "last_name": "...", "role": "agent",
///   "organization_id": "...", "caller_id": null,
///   "customer_id": null, "customer_name": "...",
///   "provisioning_source": null }
/// ```
internal struct IdentifyUserResponse: Decodable, Sendable {
    let id: String?
    let email: String?
    let phoneNumber: String?
    let firstName: String?
    let lastName: String?
    let role: String?
    let organizationId: String?
    let callerId: String?
    let customerId: String?
    let customerName: String?
    let provisioningSource: String?

    /// Legacy field name kept as a fallback for older responses.
    let userId: String?

    /// Returns the effective user id, preferring `id` over the legacy `user_id`.
    var effectiveUserId: String? {
        return id ?? userId
    }
}
