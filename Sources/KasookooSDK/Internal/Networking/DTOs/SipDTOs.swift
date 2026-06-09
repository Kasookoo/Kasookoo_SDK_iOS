//
//  SipDTOs.swift
//  KasookooSDK
//
//

import Foundation

// MARK: - SIP Make Outbound Call


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

/// Response for `POST /api/v1/sip/calls/make`.
internal struct SipMakeCallResponse: Decodable, Sendable {
    let success: Bool?
    let callId: String?
    let roomName: String?
    let status: String?
    let sipCallId: String?
    let participantIdentity: String?
    let token: String?
    let wsUrl: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case callId = "call_id"
        case roomName = "room_name"
        case status
        case sipCallId = "sip_call_id"
        case participantIdentity = "participant_identity"
        case token
        case wsUrl = "ws_url"
    }
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
