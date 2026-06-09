//
//  CallInfo.swift
//  KasookooSDK
//
//  Represents an active or recent call.
//

import Foundation

/// Represents the state and metadata of a call.
///
/// Returned by `sdk.call.getActiveCall()` and included in call event payloads.
public struct CallInfo: Sendable, Hashable, Identifiable {
    
    // MARK: - Identity
    
    /// A unique identifier for this call. Stable across the call's lifetime.
    public let id: String
    
    /// The room name on the WebRTC server.
    public let roomName: String
    
    // MARK: - Participants
    
    /// The participant who initiated the call.
    public let caller: Participant
    
    /// The participant being called.
    public let callee: Participant
    
    // MARK: - State
    
    /// The current state of the call.
    public let state: CallState
    
    /// The direction of the call from the local user's perspective.
    public let direction: CallDirection
    
    // MARK: - Timing
    
    /// When the call was created.
    public let createdAt: Date
    
    /// When the call connected, if it has connected.
    public let connectedAt: Date?
    
    /// When the call ended, if it has ended.
    public let endedAt: Date?
    
    // MARK: - Configuration
    
    /// Whether call recording is enabled.
    public let isRecording: Bool
    
    /// Whether push notifications were sent for this call.
    public let isPushNotification: Bool
    
    /// Whether this is a SIP (PSTN) call vs WebRTC.
    public let isSip: Bool
    
    // MARK: - Computed
    
    /// The duration of the call. Returns `nil` if the call hasn't connected.
    public var duration: TimeInterval? {
        guard let connected = connectedAt else { return nil }
        let endTime = endedAt ?? Date()
        return endTime.timeIntervalSince(connected)
    }
    
    // MARK: - Init
    
    public init(
        id: String,
        roomName: String,
        caller: Participant,
        callee: Participant,
        state: CallState,
        direction: CallDirection,
        createdAt: Date = Date(),
        connectedAt: Date? = nil,
        endedAt: Date? = nil,
        isRecording: Bool = false,
        isPushNotification: Bool = true,
        isSip: Bool = false
    ) {
        self.id = id
        self.roomName = roomName
        self.caller = caller
        self.callee = callee
        self.state = state
        self.direction = direction
        self.createdAt = createdAt
        self.connectedAt = connectedAt
        self.endedAt = endedAt
        self.isRecording = isRecording
        self.isPushNotification = isPushNotification
        self.isSip = isSip
    }
}

// MARK: - Call State

/// The current state of a call.
public enum CallState: String, Sendable, Hashable, Codable {
    
    /// Call has been initiated but not yet ringing.
    case initiating = "initiating"
    
    /// Call is ringing on the callee's device.
    case ringing = "ringing"
    
    /// Call has been answered and is connecting (negotiating media).
    case connecting = "connecting"
    
    /// Call is active and media is flowing.
    case connected = "connected"
    
    /// Call is being ended.
    case ending = "ending"
    
    /// Call has ended normally.
    case ended = "ended"
    
    /// Call failed to connect or was dropped abnormally.
    case failed = "failed"
    
    /// Call was rejected by the callee.
    case rejected = "rejected"
    
    /// Call was missed (callee didn't answer in time).
    case missed = "missed"
    
    /// Whether this state is a terminal state (no further transitions).
    public var isTerminal: Bool {
        switch self {
        case .ended, .failed, .rejected, .missed:
            return true
        default:
            return false
        }
    }
    
    /// Whether the call is currently active (in progress).
    public var isActive: Bool {
        switch self {
        case .initiating, .ringing, .connecting, .connected:
            return true
        default:
            return false
        }
    }
}

// MARK: - Call Direction

/// The direction of a call from the local user's perspective.
public enum CallDirection: String, Sendable, Hashable, Codable {
    
    /// The local user initiated the call.
    case outgoing = "outgoing"
    
    /// The local user is receiving the call.
    case incoming = "incoming"
}

// MARK: - Call Reject Reason

/// Reasons why a call may be rejected.
public enum CallRejectReason: String, Sendable, Hashable, Codable {
    
    /// User actively rejected the call.
    case declined = "declined"
    
    /// User is busy on another call.
    case busy = "busy"
    
    /// Call was rejected due to user being unavailable.
    case unavailable = "unavailable"
    
    /// Other unspecified reason.
    case other = "other"
}
