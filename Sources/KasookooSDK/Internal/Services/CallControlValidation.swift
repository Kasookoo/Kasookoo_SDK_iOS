//
//  CallControlValidation.swift
//  KasookooSDK
//
//  Shared rules and errors for in-call controls (mute, speaker, audio route,
//  hold, DTMF), used by CallService and SipService. KSA-328.
//

import Foundation
import AVFoundation

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

    // MARK: - Microphone Permission (KSA-175)

    /// Throws before a call is placed, answered or dialled when the user has
    /// turned microphone access off, so the call fails with a clear reason
    /// instead of connecting without audio.
    ///
    /// Only an explicit denial is rejected. When the user has not been asked
    /// yet, iOS shows its own prompt as the call starts, exactly as before.
    static func requireMicrophoneNotDenied(action: String) throws {
        guard microphonePermissionDenied else { return }
        throw KasookooError.callFailed(
            message: "Microphone access is turned off for this app.",
            retryable: false,
            details: ["action": action, "reason": "microphone_permission_denied"]
        )
    }

    private static var microphonePermissionDenied: Bool {
        if #available(iOS 17.0, *) {
            return AVAudioApplication.shared.recordPermission == .denied
        }
        return AVAudioSession.sharedInstance().recordPermission == .denied
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
