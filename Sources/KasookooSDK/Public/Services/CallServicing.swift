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
    
    // MARK: - State
    
    /// Returns the currently active call, if any.
    ///
    /// - Returns: The active `CallInfo`, or nil if no call is active.
    func getActiveCall() async -> CallInfo?
}
