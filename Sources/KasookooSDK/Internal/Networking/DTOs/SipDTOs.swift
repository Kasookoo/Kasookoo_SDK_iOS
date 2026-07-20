//
//  SipDTOs.swift
//  KasookooSDK
//
//

import Foundation

// MARK: - SIP Make Outbound Call

/// Request body for `POST /api/v1/sip/calls/make`.
///
/// Per Postman:
/// ```json
/// {
///   "phone_number": "+1234567890",
///   "room_name": "sip_call_123",
///   "participant_name": "John Doe"
/// }
/// ```
internal struct SipMakeCallRequest: Encodable, Sendable {
    let phoneNumber: String
    let roomName: String
    let participantName: String
    
    enum CodingKeys: String, CodingKey {
        case phoneNumber = "phone_number"
        case roomName = "room_name"
        case participantName = "participant_name"
    }
}

/// Response for `POST .../sdk-sip/calls/make`.
///
/// Real backend shape (verified against live response):
/// ```json
/// {
///   "success": true,
///   "message": "Call initiated successfully",
///   "data": {
///     "success": true,
///     "call_details": {
///       "participant_identity": "68feddf6cc0ae9923d3609a3",
///       "room_name": "sdk-room",
///       "phone_number": "966966"
///     },
///     "room_token": "eyJhbGc...",
///     "room_name": "sdk-room",
///     "room_session_id": "RM_k82hgrbMJdLP",
///     "phone_number": "966966",
///     "participant_identity": "68feddf6cc0ae9923d3609a3",
///     "status": "waiting_for_webrtc",
///     "wsUrl": "wss://inapp-test.kasookoo.ai"
///   },
///   "wsUrl": "wss://inapp-test.kasookoo.ai",
///   "error": null
/// }
/// ```
///
/// The critical media fields for the SDK are `data.room_token` + `data.wsUrl`,
/// which the SDK uses to join the LiveKit room so audio can bridge to the PSTN leg.
internal struct SipMakeCallResponse: Decodable, Sendable {
    let success: Bool?
    let message: String?
    let data: SipMakeCallData?
    /// Top-level `wsUrl` duplicate (backend currently sends it in both places).
    let wsUrlTopLevel: String?
    let error: SipErrorPayload?
    
    enum CodingKeys: String, CodingKey {
        case success
        case message
        case data
        case wsUrlTopLevel = "wsUrl"
        case error
    }
    
    // MARK: - Convenience Accessors
    //
    // These shield the rest of the SDK from the backend's duplicated/mixed-case
    // fields. If the contract is cleaned up later, only these accessors change.
    
    /// The LiveKit access token used to join the room. Nil if the call failed.
    var effectiveRoomToken: String? {
        data?.roomToken
    }
    
    /// The LiveKit WebSocket URL.
    ///
    /// ⚠️ The backend sends `wsUrl` in **two** places with **different schemes**:
    ///   - `data.wsUrl`  → "https://inapp.kasookoo.ai"  (WRONG — LiveKit cannot use http/https)
    ///   - top-level     → "wss://inapp.kasookoo.ai"    (CORRECT)
    ///
    /// LiveKit requires a `ws://` or `wss://` URL. We therefore prefer whichever
    /// candidate already has a WebSocket scheme, and only fall back to coercing
    /// an http(s) URL if no proper one was supplied. Verified against a live
    /// `POST /api/v1/sip/calls/make` response.
    var effectiveWsUrl: String? {
        let candidates = [wsUrlTopLevel, data?.wsUrl].compactMap { $0 }
        
        // 1. Prefer a candidate that is already a WebSocket URL.
        if let wsNative = candidates.first(where: {
            $0.hasPrefix("wss://") || $0.hasPrefix("ws://")
        }) {
            return wsNative
        }
        
        // 2. Otherwise coerce an http(s) URL into its WebSocket equivalent.
        if let httpUrl = candidates.first {
            if httpUrl.hasPrefix("https://") {
                return "wss://" + httpUrl.dropFirst("https://".count)
            }
            if httpUrl.hasPrefix("http://") {
                return "ws://" + httpUrl.dropFirst("http://".count)
            }
            return httpUrl
        }
        
        return nil
    }
    
    /// The room the SIP call is bridged into.
    var effectiveRoomName: String? {
        data?.roomName ?? data?.callDetails?.roomName
    }
    
    /// A stable identifier for this SIP call (used for hangup/status).
    var effectiveCallId: String? {
        data?.roomSessionId
    }
    
    /// The participant identity assigned by the backend for the local leg.
    var effectiveParticipantIdentity: String? {
        data?.participantIdentity ?? data?.callDetails?.participantIdentity
    }
    
    /// The backend-reported status, e.g. "waiting_for_webrtc".
    var effectiveStatus: String? {
        data?.status
    }
}

/// The `data` object inside a SIP make-call response.
internal struct SipMakeCallData: Decodable, Sendable {
    let success: Bool?
    let callDetails: SipCallDetails?
    let roomToken: String?
    let roomName: String?
    let roomSessionId: String?
    let phoneNumber: String?
    let participantIdentity: String?
    let status: String?
    let wsUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case callDetails = "call_details"
        case roomToken = "room_token"
        case roomName = "room_name"
        case roomSessionId = "room_session_id"
        case phoneNumber = "phone_number"
        case participantIdentity = "participant_identity"
        case status
        case wsUrl = "wsUrl"   // NOTE: backend sends this camelCase; all else is snake_case.
    }
}

/// The `call_details` sub-object.
internal struct SipCallDetails: Decodable, Sendable {
    let participantIdentity: String?
    let roomName: String?
    let phoneNumber: String?
    
    enum CodingKeys: String, CodingKey {
        case participantIdentity = "participant_identity"
        case roomName = "room_name"
        case phoneNumber = "phone_number"
    }
}

/// Error payload shape for SIP responses (best-effort; backend `error` is null on success).
internal struct SipErrorPayload: Decodable, Sendable {
    let code: String?
    let message: String?
}

// MARK: - SIP Dial

/// Request body for `POST /api/v1/sip/calls/dial`.
/// Same shape as make-call per Postman.
internal typealias SipDialRequest = SipMakeCallRequest
internal typealias SipDialResponse = SipMakeCallResponse

// MARK: - SIP End Call (Graceful)

/// Request body for `POST /api/v1/sip/calls/end`.
internal struct SipEndCallRequest: Encodable, Sendable {
    let participantIdentity: String
    let roomName: String
    
    enum CodingKeys: String, CodingKey {
        case participantIdentity = "participant_identity"
        case roomName = "room_name"
    }
}

// MARK: - SIP Hangup (Force)

/// Request body for `POST /api/v1/sip/calls/hangup`.
internal struct SipHangupRequest: Encodable, Sendable {
    let participantIdentity: String
    let roomName: String
    
    enum CodingKeys: String, CodingKey {
        case participantIdentity = "participant_identity"
        case roomName = "room_name"
    }
}

/// Response for SIP end/hangup endpoints.
internal struct SipEndResponse: Decodable, Sendable {
    let success: Bool?
    let endedAt: String?
    let message: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case endedAt = "ended_at"
        case message
    }
}
