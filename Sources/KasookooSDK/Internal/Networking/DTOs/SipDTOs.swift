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
    
}

/// Response for `POST /api/v1/sip/calls/make` on the SDK backend.
///
/// Real backend shape (values replaced with placeholders — never paste live
/// tokens, phone numbers or hostnames into source):
/// ```json
/// {
///     "success": true,
///     "message": "Call initiated successfully",
///     "data": {
///         "success": true,
///         "call_details": {
///             "participant_identity": "webrtc-user-<id>",
///             "room_name": "sip_call_123",
///             "dialed_number": "+<destination>",
///             "caller_id": "+<caller-id>"
///         },
///         "room_name": "sip_call_123",
///         "room_session_id": "RM_<id>",
///         "dialed_number": "+<destination>",
///         "caller_id": "+<caller-id>",
///         "participant_identity": "webrtc-user-<id>",
///         "status": "waiting_for_webrtc",
///         "access_token": "<LiveKit JWT>",
///         "ws_url": "wss://<livekit-host>",
///         "http_url": "https://<livekit-host>"
///     },
///     "error": null
/// }
/// ```
///
/// The critical media fields for the SDK are `data.access_token` + `data.ws_url`,
/// which the SDK uses to join the LiveKit room so audio can bridge to the PSTN leg.
internal struct SipMakeCallResponse: Decodable, Sendable {
    let success: Bool?
    let message: String?
    let data: SipMakeCallData?
    let error: SipErrorPayload?

    // MARK: - Convenience Accessors

    /// LiveKit access token for the local leg. Nil if the call failed.
    var effectiveRoomToken: String? {
        data?.accessToken
    }

    /// LiveKit WebSocket URL. The backend now returns a correct `wss://` value.
    var effectiveWsUrl: String? {
        data?.wsUrl
    }

    /// LiveKit HTTP URL (`https://`).
    var effectiveHttpUrl: String? {
        data?.httpUrl
    }

    /// The room the SIP call is bridged into.
    var effectiveRoomName: String? {
        data?.roomName ?? data?.callDetails?.roomName
    }

    /// A stable identifier for this SIP call (used for end/status).
    var effectiveCallId: String? {
        data?.roomSessionId
    }

    /// The participant identity for the local leg.
    var effectiveParticipantIdentity: String? {
        data?.participantIdentity ?? data?.callDetails?.participantIdentity
    }

    /// The number actually dialled.
    var effectiveDialedNumber: String? {
        data?.dialedNumber ?? data?.callDetails?.dialedNumber
    }

    /// The caller id shown to the callee.
    var effectiveCallerId: String? {
        data?.callerId ?? data?.callDetails?.callerId
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
    let roomName: String?
    let roomSessionId: String?
    let dialedNumber: String?
    let callerId: String?
    let participantIdentity: String?
    let status: String?
    /// LiveKit access token for the local leg (`access_token`).
    let accessToken: String?
    let wsUrl: String?
    let httpUrl: String?
}

/// The `call_details` sub-object.
internal struct SipCallDetails: Decodable, Sendable {
    let participantIdentity: String?
    let roomName: String?
    let dialedNumber: String?
    let callerId: String?
}

/// Error payload shape for SIP responses (best-effort; backend `error` is null on success).
internal struct SipErrorPayload: Decodable, Sendable {
    let code: String?
    let message: String?
}

// MARK: - SIP End Call (Graceful)

/// Request body for `POST /api/v1/sip/calls/end`.
internal struct SipEndCallRequest: Encodable, Sendable {
    let participantIdentity: String
    let roomName: String
    
}

/// Response for SIP end/hangup endpoints.
internal struct SipEndResponse: Decodable, Sendable {
    let success: Bool?
    let endedAt: String?
    let message: String?
    
}
