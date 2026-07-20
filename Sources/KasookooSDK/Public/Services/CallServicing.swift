//
//  CallServicing.swift
//  KasookooSDK
//
//  Public protocol for the call service.
//  Section 4: call.start, call.accept, call.reject, call.end, call.getActiveCall
//

import Foundation

/// The public contract for app-to-app WebRTC calling.
///
/// Accessed via `sdk.call`. Methods are async and may throw `KasookooError`.
///
/// ## Example
/// ```swift
/// try await sdk.call.start(params: callParams)
/// // ... later
/// try await sdk.call.end(callId: someCallId)
/// ```
public protocol CallServicing: Sendable {
    
    // MARK: - Outgoing
    
    /// Starts an outgoing call.
    ///
    /// Acquires call tokens from the backend and connects to the WebRTC server.
    /// Emits `call.connected` on success or `call.failed` on failure.
    ///
    /// - Parameter params: Call parameters including caller, callee, and room name.
    /// - Returns: The `CallInfo` for the started call.
    /// - Throws: `KasookooError` with code `.callFailed`, `.networkUnavailable`, etc.
    @discardableResult
    func start(params: StartCallParams) async throws -> CallInfo
    
    // MARK: - Incoming
    
    /// Accepts an incoming call.
    ///
    /// Should be called when handling a `call.incoming` event.
    ///
    /// - Parameter callId: The ID of the incoming call.
    /// - Returns: The updated `CallInfo`.
    /// - Throws: `KasookooError` if the call cannot be found or accepted.
    @discardableResult
    func accept(callId: String) async throws -> CallInfo
    
    /// Rejects an incoming call.
    ///
    /// - Parameters:
    ///   - callId: The ID of the incoming call.
    ///   - reason: The reason for rejection.
    /// - Throws: `KasookooError` if the call cannot be found.
    func reject(callId: String, reason: CallRejectReason) async throws
    
    // MARK: - End
    
    /// Ends an active call.
    ///
    /// - Parameter callId: The ID of the call to end.
    /// - Throws: `KasookooError` if the call cannot be ended.
    func end(callId: String) async throws
    
    // MARK: - In-Call Audio Controls
    
    /// Mutes or unmutes the local microphone for an active call.
    ///
    /// - Parameters:
    ///   - muted: `true` to mute (stop sending audio), `false` to unmute.
    ///   - callId: The ID of the active call.
    /// - Throws: `KasookooError.callFailed` if the call is unknown or not connected.
    func setMuted(_ muted: Bool, callId: String) async throws
    
    /// Returns whether the local microphone is currently muted for a call.
    ///
    /// - Parameter callId: The ID of the active call.
    /// - Returns: `true` if muted, `false` if unmuted or the call is unknown.
    func isMuted(callId: String) async -> Bool
    
    /// Routes call audio to the loudspeaker or the earpiece.
    ///
    /// - Parameters:
    ///   - enabled: `true` for loudspeaker, `false` for earpiece.
    ///   - callId: The ID of the active call.
    /// - Throws: `KasookooError.callFailed` if the call is unknown or audio routing fails.
    func setSpeakerEnabled(_ enabled: Bool, callId: String) async throws
    
    // MARK: - State
    
    /// Returns the currently active call, if any.
    ///
    /// - Returns: The active `CallInfo`, or nil if no call is active.
    func getActiveCall() async -> CallInfo?
}

// MARK: - Convenience: Active-Call Audio Controls

public extension CallServicing {
    
    /// Mutes or unmutes the microphone for the currently active call.
    ///
    /// Convenience for the common single-call case. Resolves the active call
    /// automatically. Does nothing if there is no active call.
    ///
    /// - Parameter muted: `true` to mute, `false` to unmute.
    /// - Throws: `KasookooError.callFailed` if toggling fails.
    func setMuted(_ muted: Bool) async throws {
        guard let active = await getActiveCall() else {
            throw KasookooError.callFailed(
                message: "No active call to mute.",
                retryable: false
            )
        }
        try await setMuted(muted, callId: active.id)
    }
    
    /// Whether the microphone is muted for the currently active call.
    ///
    /// - Returns: `true` if muted, `false` if unmuted or there is no active call.
    func isMuted() async -> Bool {
        guard let active = await getActiveCall() else { return false }
        return await isMuted(callId: active.id)
    }
    
    /// Routes audio to the loudspeaker or earpiece for the active call.
    ///
    /// - Parameter enabled: `true` for loudspeaker, `false` for earpiece.
    /// - Throws: `KasookooError.callFailed` if routing fails.
    func setSpeakerEnabled(_ enabled: Bool) async throws {
        guard let active = await getActiveCall() else {
            throw KasookooError.callFailed(
                message: "No active call to route audio for.",
                retryable: false
            )
        }
        try await setSpeakerEnabled(enabled, callId: active.id)
    }
}
