//
//  IncomingCallHandler.swift
//  KasookooSDK
//
//  Public protocol that consumers implement to handle incoming calls
//  after the SDK reports them to CallKit.
//

import Foundation

/// A protocol for handling incoming call decisions made by the user via CallKit.
///
/// When an incoming call push arrives, the SDK automatically reports it to CallKit
/// (the iOS native call UI). When the user answers or declines via that UI, CallKit
/// invokes the corresponding method on this handler.
///
/// ## Example
/// ```swift
/// class MyCallHandler: IncomingCallHandler {
///     func incomingCallAnswered(_ callInfo: IncomingCallInfo) async {
///         // Navigate to call screen, accept via SDK
///         try? await sdk.call.accept(callId: callInfo.callId)
///     }
///
///     func incomingCallDeclined(_ callInfo: IncomingCallInfo) async {
///         try? await sdk.call.reject(callId: callInfo.callId, reason: .declined)
///     }
///
///     func incomingCallEnded(_ callInfo: IncomingCallInfo) async {
///         try? await sdk.call.end(callId: callInfo.callId)
///     }
/// }
///
/// // Register the handler:
/// sdk.notifications.incomingCallHandler = MyCallHandler()
/// ```
public protocol IncomingCallHandler: AnyObject, Sendable {
    
    /// Called when the user answers an incoming call via CallKit.
    /// The SDK has already accepted the call at the OS level; the consumer
    /// should now navigate to the call UI and connect via `sdk.call.accept(callId:)`.
    func incomingCallAnswered(_ callInfo: IncomingCallInfo) async
    
    /// Called when the user declines an incoming call via CallKit.
    func incomingCallDeclined(_ callInfo: IncomingCallInfo) async
    
    /// Called when an active call is ended via CallKit's end-call button.
    func incomingCallEnded(_ callInfo: IncomingCallInfo) async
}

// MARK: - Incoming Call Info

/// Information about an incoming call extracted from a push notification.
///
/// Passed to `IncomingCallHandler` methods so the consumer knows which call
/// the user acted upon.
public struct IncomingCallInfo: Sendable, Hashable {
    
    /// The unique call ID.
    public let callId: String
    
    /// The room name to connect to.
    public let roomName: String
    
    /// The caller's identity.
    public let caller: Participant
    
    /// The callee's identity (the local user).
    public let callee: Participant
    
    /// Whether this is a SIP call (from PSTN) or a WebRTC call.
    public let isSipCall: Bool
    
    /// The LiveKit access token for joining the call's room.
    ///
    /// The backend delivers this inside the incoming-call push payload, because
    /// the callee cannot request a token before answering. The SDK uses it to
    /// join the room when the call is accepted.
    public let accessToken: String?
    
    /// The LiveKit WebSocket URL for the call's room.
    ///
    /// Delivered alongside `accessToken` in the push payload.
    public let wsUrl: String?
    
    /// The display name shown on the CallKit screen.
    public var displayName: String {
        return caller.name.isEmpty ? caller.phoneNumber : caller.name
    }
    
    /// Whether this call carries everything needed to join the media room.
    public var hasMediaCredentials: Bool {
        guard let token = accessToken, let url = wsUrl else { return false }
        return !token.isEmpty && !url.isEmpty
    }
    
    public init(
        callId: String,
        roomName: String,
        caller: Participant,
        callee: Participant,
        isSipCall: Bool = false,
        accessToken: String? = nil,
        wsUrl: String? = nil
    ) {
        self.callId = callId
        self.roomName = roomName
        self.caller = caller
        self.callee = callee
        self.isSipCall = isSipCall
        self.accessToken = accessToken
        self.wsUrl = wsUrl
    }
}
