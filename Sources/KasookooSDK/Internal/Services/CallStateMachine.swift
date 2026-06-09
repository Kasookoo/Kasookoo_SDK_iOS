//
//  CallStateMachine.swift
//  KasookooSDK
//
//

import Foundation

/// Validates call state transitions.
///
/// Real-time calls have strict transition rules:
/// - `initiating` can go to `ringing`, `failed`, `ended`
/// - `ringing` can go to `connecting`, `rejected`, `missed`, `failed`, `ended`
/// - `connecting` can go to `connected`, `failed`, `ended`
/// - `connected` can go to `ending`, `ended`, `failed`
/// - Terminal states cannot transition anywhere
///
/// This struct ensures the SDK never produces invalid state sequences.
internal struct CallStateMachine {
    
    /// Returns whether a transition from `from` to `to` is valid.
    static func canTransition(from: CallState, to: CallState) -> Bool {
        // Same state is always valid (idempotent updates)
        if from == to { return true }
        
        // Terminal states cannot transition
        if from.isTerminal { return false }
        
        // Define allowed transitions
        switch from {
        case .initiating:
            return [.ringing, .connecting, .connected, .ending, .failed, .ended].contains(to)
            
        case .ringing:
            return [.connecting, .connected, .ending, .rejected, .missed, .failed, .ended].contains(to)
            
        case .connecting:
            return [.connected, .ending, .failed, .ended].contains(to)
            
        case .connected:
            return [.ending, .ended, .failed].contains(to)
            
        case .ending:
            return [.ended, .failed].contains(to)
            
        case .ended, .failed, .rejected, .missed:
            // Already handled by isTerminal check above, but explicit for clarity
            return false
        }
    }
    
    /// Validates a transition or throws.
    ///
    /// - Throws: `KasookooError.callFailed` if the transition is invalid.
    static func validateTransition(from: CallState, to: CallState) throws {
        guard canTransition(from: from, to: to) else {
            throw KasookooError.callFailed(
                message: "Invalid state transition: \(from.rawValue) → \(to.rawValue)",
                retryable: false,
                details: ["from": from.rawValue, "to": to.rawValue]
            )
        }
    }
    
    /// Returns the appropriate event name for a state transition.
    /// Returns nil if no event should be emitted for this transition.
    static func eventName(for state: CallState) -> String? {
        switch state {
        case .ringing: return EventName.callRinging
        case .connected: return EventName.callConnected
        case .ended, .rejected, .missed: return EventName.callEnded
        case .failed: return EventName.callFailed
        case .initiating, .connecting, .ending: return nil
        }
    }
}
