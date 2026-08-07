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
/// Real backend shape (verified against live response):
/// ```json
//{
//    "success": true,
//    "message": "Call initiated successfully",
//    "data": {
//        "success": true,
//        "call_details": {
//            "participant_identity": "webrtc-user-1785444414",
//            "room_name": "sip_call_123",
//            "dialed_number": "+923190835238",
//            "caller_id": "+442070786177"
//        },
//        "room_name": "sip_call_123",
//        "room_session_id": "RM_rRiF5kCCfFsA",
//        "dialed_number": "+923190835238",
//        "caller_id": "+442070786177",
//        "participant_identity": "webrtc-user-1785444414",
//        "status": "waiting_for_webrtc",
//        "access_token": "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJuYW1lIjoiSm9obiBEb2UiLCJraW5kIjoidXNlciIsInZpZGVvIjp7InJvb21Kb2luIjp0cnVlLCJyb29tIjoic2lwX2NhbGxfMTIzIiwiY2FuUHVibGlzaCI6dHJ1ZSwiY2FuU3Vic2NyaWJlIjp0cnVlLCJjYW5QdWJsaXNoRGF0YSI6dHJ1ZX0sInN1YiI6IndlYnJ0Yy11c2VyLTE3ODU0NDQ0MTQiLCJpc3MiOiJBUElEbmZKajY3Z2hGVVkiLCJuYmYiOjE3ODU0NDQ0MTQsImV4cCI6MTc4NTQ2NjAxNH0.tUXd9b0bb-CxR4Xhv6SEaB90sBcvPpoNs1CRwhWCjAU",
//        "ws_url": "wss://inapp-test.kasookoo.ai",
//        "http_url": "https://inapp-test.kasookoo.ai"
//    },
//    "error": null
//}
/// ```
///
/// The critical media fields for the SDK are `data.room_token` + `data.wsUrl`,
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
