//
//  SDKState.swift
//  KasookooSDK
//
//  The current high-level state of the SDK, returned by sdk.getState().
//

import Foundation

/// The current high-level state of the SDK.
///
/// Returned by `sdk.getState()`. Useful for UI logic and debugging.
public enum SDKState: Sendable, Hashable {
    
    /// SDK has not been initialized yet.
    case idle
    
    /// SDK has been initialized but not connected.
    case initialized
    
    /// SDK is in the process of connecting (acquiring session).
    case connecting
    
    /// SDK is connected and ready for use.
    case connected
    
    /// SDK is in the process of disconnecting.
    case disconnecting
    
    /// SDK has been disconnected normally.
    case disconnected
    
    /// SDK has encountered an unrecoverable error.
    case error(KasookooError)
    
    // MARK: - Computed
    
    /// Whether the SDK is currently usable for protected operations (calls/messages).
    public var isReady: Bool {
        if case .connected = self {
            return true
        }
        return false
    }
    
    /// Whether the SDK is in a transitional state.
    public var isTransitioning: Bool {
        switch self {
        case .connecting, .disconnecting:
            return true
        default:
            return false
        }
    }
    
    /// A short human-readable description of the state.
    public var description: String {
        switch self {
        case .idle: return "idle"
        case .initialized: return "initialized"
        case .connecting: return "connecting"
        case .connected: return "connected"
        case .disconnecting: return "disconnecting"
        case .disconnected: return "disconnected"
        case .error(let error): return "error(\(error.code.rawValue))"
        }
    }
}

// MARK: - Equatable Manual Implementation

// `KasookooError` is not `Equatable` (contains underlyingError), so we
// implement custom equality that compares state cases by code.
extension SDKState {
    public static func == (lhs: SDKState, rhs: SDKState) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle),
             (.initialized, .initialized),
             (.connecting, .connecting),
             (.connected, .connected),
             (.disconnecting, .disconnecting),
             (.disconnected, .disconnected):
            return true
        case (.error(let lhsErr), .error(let rhsErr)):
            return lhsErr.code == rhsErr.code
        default:
            return false
        }
    }
    
    public func hash(into hasher: inout Hasher) {
        switch self {
        case .idle: hasher.combine(0)
        case .initialized: hasher.combine(1)
        case .connecting: hasher.combine(2)
        case .connected: hasher.combine(3)
        case .disconnecting: hasher.combine(4)
        case .disconnected: hasher.combine(5)
        case .error(let err):
            hasher.combine(6)
            hasher.combine(err.code)
        }
    }
}
