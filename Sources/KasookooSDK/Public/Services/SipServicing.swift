//
//  SipServicing.swift
//  KasookooSDK
//
//  Public protocol for SIP calling.
//  Section 4: sip.dial, sip.hangup, sip.getStatus
//

import Foundation

/// The public contract for SIP (PSTN) calling.
///
/// Accessed via `sdk.sip`. SIP calls connect to regular phone numbers via SIP trunks.
public protocol SipServicing: Sendable {
    
    /// Initiates a SIP call to a phone number.
    ///
    /// Emits `sip.calling`, then `sip.connected` on answer or `sip.ended` on failure.
    ///
    /// - Parameter params: SIP dial parameters.
    /// - Returns: The `CallInfo` for the SIP call.
    /// - Throws: `KasookooError.callFailed` on failure.
    @discardableResult
    func dial(params: SipDialParams) async throws -> CallInfo
    
    /// Hangs up an active SIP call.
    ///
    /// - Parameter callId: The ID of the call to hang up.
    /// - Throws: `KasookooError` if the call cannot be ended.
    func hangup(callId: String) async throws
    
    /// Returns the current state of a SIP call.
    ///
    /// - Parameter callId: The ID of the call.
    /// - Returns: The current `CallState`, or nil if the call is unknown.
    func getStatus(callId: String) async -> CallState?
    
    // MARK: - In-Call Audio Controls
    
    /// Mutes or unmutes the local microphone for an active SIP call.
    ///
    /// - Parameters:
    ///   - muted: `true` to mute, `false` to unmute.
    ///   - callId: The ID of the active SIP call.
    /// - Throws: `KasookooError.callFailed` if the call is unknown or not connected.
    func setMuted(_ muted: Bool, callId: String) async throws
    
    /// Routes SIP call audio to the loudspeaker or the earpiece.
    ///
    /// - Parameters:
    ///   - enabled: `true` for loudspeaker, `false` for earpiece.
    ///   - callId: The ID of the active SIP call.
    /// - Throws: `KasookooError.callFailed` if the call is unknown or audio routing fails.
    func setSpeakerEnabled(_ enabled: Bool, callId: String) async throws
}
