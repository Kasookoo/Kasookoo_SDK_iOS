//
//  CallControlValidation.swift
//  KasookooSDK
//
//  Shared rules and errors for in-call controls (mute, speaker, audio route,
//  hold, DTMF), used by CallService and SipService. KSA-328.
//

import Foundation

internal enum CallControlValidation {

    /// States in which audio controls (mute, speaker, route) may be used.
    /// Muting before the other side answers is allowed.
    static let audioStates: Set<CallState> = [.initiating, .ringing, .connecting, .connected]

    /// States in which hold and DTMF may be used.
    static let connectedOnly: Set<CallState> = [.connected]

    /// The call id is not a live call on this device.
    static func unknownCall(callId: String, action: String) -> KasookooError {
        KasookooError.callFailed(
            message: "Cannot \(describe(action)): no active call with id \(callId).",
            retryable: false,
            details: ["action": action, "callId": callId, "reason": "unknown_call"]
        )
    }

    /// The call exists but is not in a state where the control applies.
    static func invalidState(callId: String, action: String, state: CallState) -> KasookooError {
        KasookooError.callFailed(
            message: "Cannot \(describe(action)) while the call is \(state.rawValue).",
            retryable: false,
            details: [
                "action": action,
                "callId": callId,
                "reason": "invalid_state",
                "state": state.rawValue
            ]
        )
    }

    /// Event data for `audio.routeChanged`.
    static func routeEventData(_ route: AudioRoute?, isSip: Bool) -> [String: AnyCodableValue] {
        var data: [String: AnyCodableValue] = ["isSip": .bool(isSip)]
        if let route {
            data["routeId"] = .string(route.id)
            data["routeName"] = .string(route.name)
            data["routeKind"] = .string(route.kind.rawValue)
        }
        return data
    }

    private static func describe(_ action: String) -> String {
        switch action {
        case "mute": return "mute"
        case "unmute": return "unmute"
        case "setSpeaker": return "change the speaker"
        case "setAudioRoute": return "change the audio route"
        case "hold": return "hold the call"
        case "resume": return "resume the call"
        case "dtmf": return "send keypad tones"
        default: return action
        }
    }
}
