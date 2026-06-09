//
//  CallService.swift
//  KasookooSDK
//
//

import Foundation

/// Concrete implementation of `CallServicing`.
///
/// Threading model: Implemented as an `actor` to serialize call operations.
/// Multiple concurrent `start`/`end` calls won't corrupt internal state.
internal actor CallService: CallServicing {
    
    // MARK: - Dependencies
    
    private let apiClient: ApiClient
    private let stateStore: StateStore
    private let eventBus: EventBus
    private let logger: Logger
    private let config: KasookooConfig
    
    // MARK: - Per-Call LiveKit Managers
    
    /// One LiveKit room manager per active call.
    /// Multi-call support: user can have multiple calls (one active, others on hold).
    private var roomManagers: [String: LiveKitRoomManager] = [:]
    
    // MARK: - Init
    
    init(
        apiClient: ApiClient,
        stateStore: StateStore,
        eventBus: EventBus,
        logger: Logger,
        config: KasookooConfig
    ) {
        self.apiClient = apiClient
        self.stateStore = stateStore
        self.eventBus = eventBus
        self.logger = logger
        self.config = config
    }
    
    // MARK: - CallServicing: start
    
    @discardableResult
    func start(params: StartCallParams) async throws -> CallInfo {
        // Validate input
        try params.validate()
        
        guard config.features.calling else {
            throw KasookooError.callFailed(
                message: "Calling is disabled in SDK configuration.",
                retryable: false
            )
        }
        
        logger.info("Starting call to \(params.callee.email) in room \(params.roomName)")
        
        // Build initial CallInfo
        let callId = UUID().uuidString
        var callInfo = CallInfo(
            id: callId,
            roomName: params.roomName,
            caller: params.caller,
            callee: params.callee,
            state: .initiating,
            direction: .outgoing,
            isRecording: params.isCallRecording,
            isPushNotification: params.isPushNotification
        )
        
        await stateStore.addCall(callInfo)
        
        do {
            // 1. Get tokens from backend
            let tokensResponse = try await fetchCallTokens(params: params)
            
            // Unwrap critical fields with clear errors
            guard let callerToken = tokensResponse.effectiveCallerToken else {
                throw KasookooError.callFailed(
                    message: "Backend did not return a caller token",
                    retryable: false
                )
            }
            guard let wsUrl = tokensResponse.effectiveWsUrl else {
                throw KasookooError.callFailed(
                    message: "Backend did not return a WebSocket URL",
                    retryable: false
                )
            }
            let effectiveRoomName = tokensResponse.roomName ?? params.roomName
            
            // Use server-provided callId if present
            let serverCallId = tokensResponse.callId ?? callId
            if serverCallId != callId {
                // Re-key in state store
                await stateStore.removeCall(callId)
                callInfo = CallInfo(
                    id: serverCallId,
                    roomName: effectiveRoomName,
                    caller: params.caller,
                    callee: params.callee,
                    state: .initiating,
                    direction: .outgoing,
                    createdAt: callInfo.createdAt,
                    isRecording: params.isCallRecording,
                    isPushNotification: params.isPushNotification
                )
                await stateStore.addCall(callInfo)
            }
            
            // 2. Transition to ringing
            callInfo = try await transitionState(callId: serverCallId, to: .ringing) ?? callInfo
            
            // 3. Connect to LiveKit
            let roomManager = await LiveKitRoomManager(logger: logger)
            roomManagers[serverCallId] = roomManager
            await roomManager.setDelegate(self, callId: serverCallId)
            
            try await roomManager.connect(
                wsUrl: wsUrl,
                token: callerToken,
                roomName: effectiveRoomName,
                localIdentity: params.caller.email
            )
            
            // 4. Transition to connecting (waiting for callee to join)
            callInfo = try await transitionState(callId: serverCallId, to: .connecting) ?? callInfo
            
            return callInfo
            
        } catch let sdkError as KasookooError {
            await failCall(callId: callId, error: sdkError)
            throw sdkError
        } catch {
            let wrapped = KasookooError.callFailed(
                message: "Unexpected error starting call: \(error.localizedDescription)",
                retryable: false,
                underlyingError: error
            )
            await failCall(callId: callId, error: wrapped)
            throw wrapped
        }
    }
    
    // MARK: - CallServicing: accept
    
    @discardableResult
    func accept(callId: String) async throws -> CallInfo {
        guard let call = await stateStore.getCall(callId) else {
            throw KasookooError.callFailed(
                message: "Cannot accept unknown call: \(callId)",
                retryable: false
            )
        }
        
        guard call.direction == .incoming else {
            throw KasookooError.callFailed(
                message: "Cannot accept outgoing call.",
                retryable: false
            )
        }
        
        guard call.state == .ringing else {
            throw KasookooError.callFailed(
                message: "Call is not in ringing state (current: \(call.state.rawValue))",
                retryable: false
            )
        }
        
        logger.info("Accepting incoming call: \(callId)")
        
        // For incoming calls, the call tokens should have been delivered via push.
        // Here we transition state and trust that LiveKit connection happens via
        // a separate flow (handled by NotificationService when push arrives).
        // For now, we mark connecting and rely on remote participant join event.
        
        let updated = try await transitionState(callId: callId, to: .connecting)
        return updated ?? call
    }
    
    // MARK: - CallServicing: reject
    
    func reject(callId: String, reason: CallRejectReason) async throws {
        guard let call = await stateStore.getCall(callId) else {
            throw KasookooError.callFailed(
                message: "Cannot reject unknown call: \(callId)",
                retryable: false
            )
        }
        
        guard call.direction == .incoming else {
            throw KasookooError.callFailed(
                message: "Cannot reject outgoing call.",
                retryable: false
            )
        }
        
        logger.info("Rejecting call \(callId), reason: \(reason.rawValue)")
        
        // Resolve user IDs for the reject request.
        // Real backend expects caller_user_id and called_user_id.
        let calleeUserId = await stateStore.resolveUserId(from: call.callee.userReference)
            ?? call.callee.email  // Fallback to email as identity
        let callerUserId = await stateStore.resolveUserId(from: call.caller.userReference)
            ?? call.caller.email
        
        let request = RejectCallRequest(
            roomName: call.roomName,
            participantIdentity: call.callee.email,
            participantIdentityName: call.callee.name,
            participantIdentityType: call.callee.type.rawValue,
            callerUserId: callerUserId,
            calledUserId: calleeUserId
        )
        
        // Notify backend of the rejection (dedicated reject endpoint)
        do {
            _ = try await apiClient.send(
                endpoint: .rejectCall,
                body: request,
                responseType: EndCallResponse.self,
                retryPolicy: .none
            )
        } catch {
            // Don't fail the rejection if backend notification fails
            logger.warning("Failed to notify backend of rejection: \(error.localizedDescription)")
        }
        
        try await transitionState(callId: callId, to: .rejected, extraData: [
            "reason": .string(reason.rawValue)
        ])
    }
    
    // MARK: - CallServicing: end
    
    func end(callId: String) async throws {
        guard let call = await stateStore.getCall(callId) else {
            logger.warning("end() called for unknown call: \(callId)")
            return // Silently succeed — call already gone
        }
        
        logger.info("Ending call: \(callId) (direction: \(call.direction.rawValue))")
        
        // Mark as ending
        try await transitionState(callId: callId, to: .ending)
        
        // Disconnect LiveKit
        if let manager = roomManagers[callId] {
            await manager.disconnect()
            roomManagers.removeValue(forKey: callId)
        }
        
        // Choose endpoint based on call direction:
        // - Outgoing call hangup by caller → /webrtc/calls/caller-end
        // - Incoming call ended after pickup → /webrtc/calls/{room}/end
        do {
            if call.direction == .outgoing {
                // Caller ending their own call
                let callerUserId = await stateStore.resolveUserId(from: call.caller.userReference)
                    ?? call.caller.email
                let calledUserId = await stateStore.resolveUserId(from: call.callee.userReference)
                    ?? call.callee.email
                
                let request = CallerEndCallRequest(
                    roomName: call.roomName,
                    participantIdentity: call.caller.email,
                    participantIdentityType: "caller",
                    callerUserId: callerUserId,
                    calledUserId: calledUserId
                )
                
                _ = try await apiClient.send(
                    endpoint: .callerEndCall,
                    body: request,
                    responseType: EndCallResponse.self,
                    retryPolicy: .default
                )
            } else {
                // Incoming call being ended (agent/admin endpoint)
                try await apiClient.sendVoid(
                    endpoint: .endCall(roomName: call.roomName),
                    retryPolicy: .default
                )
            }
        } catch {
            logger.warning("Backend end-call notification failed: \(error.localizedDescription)")
        }
        
        // Transition to ended
        try await transitionState(callId: callId, to: .ended)
    }
    
    // MARK: - CallServicing: getActiveCall
    
    func getActiveCall() async -> CallInfo? {
        return await stateStore.mostRecentActiveCall()
    }
    
    // MARK: - Private: State Transitions
    
    /// Transitions a call to a new state, validating and emitting events.
    @discardableResult
    private func transitionState(
        callId: String,
        to newState: CallState,
        extraData: [String: AnyCodableValue] = [:]
    ) async throws -> CallInfo? {
        
        guard let current = await stateStore.getCall(callId) else {
            return nil
        }
        
        // Validate transition
        try CallStateMachine.validateTransition(from: current.state, to: newState)
        
        // Compute timestamps
        let now = Date()
        let connectedAt = (newState == .connected && current.connectedAt == nil) ? now : current.connectedAt
        let endedAt = (newState.isTerminal && current.endedAt == nil) ? now : current.endedAt
        
        // Update state store
        let updated = await stateStore.updateCall(callId) { existing in
            CallInfo(
                id: existing.id,
                roomName: existing.roomName,
                caller: existing.caller,
                callee: existing.callee,
                state: newState,
                direction: existing.direction,
                createdAt: existing.createdAt,
                connectedAt: connectedAt,
                endedAt: endedAt,
                isRecording: existing.isRecording,
                isPushNotification: existing.isPushNotification
            )
        }
        
        // Emit appropriate event
        if let eventName = CallStateMachine.eventName(for: newState) {
            await emitCallEvent(eventName, call: updated ?? current, extra: extraData)
        }
        
        return updated
    }
    
    // MARK: - Private: Failure Handling
    
    private func failCall(callId: String, error: KasookooError) async {
        // Cleanup LiveKit
        if let manager = roomManagers[callId] {
            await manager.disconnect()
            roomManagers.removeValue(forKey: callId)
        }
        
        // Mark failed (force, even if invalid transition)
        if let current = await stateStore.getCall(callId) {
            await stateStore.updateCall(callId) { existing in
                CallInfo(
                    id: existing.id,
                    roomName: existing.roomName,
                    caller: existing.caller,
                    callee: existing.callee,
                    state: .failed,
                    direction: existing.direction,
                    createdAt: existing.createdAt,
                    connectedAt: existing.connectedAt,
                    endedAt: Date(),
                    isRecording: existing.isRecording,
                    isPushNotification: existing.isPushNotification
                )
            }
            
            await emitCallEvent(EventName.callFailed, call: current, extra: [
                "errorCode": .string(error.code.rawValue),
                "errorMessage": .string(error.message)
            ])
        }
    }
    
    // MARK: - Private: API Calls
    
    private func fetchCallTokens(params: StartCallParams) async throws -> GetCallTokensResponse {
        let request = GetCallTokensRequest(
            roomName: params.roomName,
            caller: ParticipantDTO(from: params.caller),
            callee: ParticipantDTO(from: params.callee),
            deviceType: DeviceType.mobile.rawValue,
            isPushNotification: params.isPushNotification,
            isCallRecording: params.isCallRecording
        )
        
        return try await apiClient.send(
            endpoint: .getCallTokens,
            body: request,
            responseType: GetCallTokensResponse.self,
            retryPolicy: .default
        )
    }
    
    // MARK: - Private: Event Emission
    
    private func emitCallEvent(
        _ name: String,
        call: CallInfo,
        extra: [String: AnyCodableValue] = [:]
    ) async {
        var data: [String: AnyCodableValue] = [
            "callId": .string(call.id),
            "roomName": .string(call.roomName),
            "callerEmail": .string(call.caller.email),
            "calleeEmail": .string(call.callee.email),
            "direction": .string(call.direction.rawValue),
            "state": .string(call.state.rawValue)
        ]
        // Merge extra data
        for (key, value) in extra {
            data[key] = value
        }
        
        let event = SDKEvent(
            name: name,
            organizationId: config.organizationId,
            userEmail: await stateStore.currentUserEmail(),
            data: data
        )
        await eventBus.emit(event)
    }
    
    // MARK: - LiveKit Event Handling
    
    /// Called by LiveKitRoomManager when room events occur.
    fileprivate func handleLiveKitEvent(callId: String, event: LiveKitRoomEvent) async {
        switch event {
        case .remoteParticipantJoined:
            // Callee joined → call is now connected
            try? await transitionState(callId: callId, to: .connected)
            
        case .remoteParticipantLeft:
            // Callee left → call ended on their side
            // Trigger our own end flow
            try? await end(callId: callId)
            
        case .roomConnected:
            logger.debug("Room connected for call \(callId)")
            
        case .roomDisconnected(let error):
            if let error = error {
                logger.warning("Room disconnected with error: \(error.localizedDescription)")
                let sdkError = KasookooError.callFailed(
                    message: "Call dropped: \(error.localizedDescription)",
                    retryable: true,
                    underlyingError: error
                )
                await failCall(callId: callId, error: sdkError)
            } else {
                // Clean disconnect — already handled by end()
                logger.debug("Room disconnected cleanly for call \(callId)")
            }
            
        case .roomReconnecting:
            logger.info("Room reconnecting for call \(callId)")
            
        case .roomReconnected:
            logger.info("Room reconnected for call \(callId)")
        }
    }
}

// MARK: - LiveKit Delegate Bridge

/// Helper extension to allow `LiveKitRoomManager` to call back into the actor.
extension CallService: LiveKitRoomManagerDelegate {
    
    nonisolated func roomManager(
        _ manager: LiveKitRoomManager,
        didReceiveEvent event: LiveKitRoomEvent
    ) async {
        // Look up which callId this manager belongs to
        let callId = await self.callIdForManager(manager)
        guard let callId = callId else {
            return
        }
        await handleLiveKitEvent(callId: callId, event: event)
    }
    
    /// Looks up the call ID associated with a given room manager.
    private func callIdForManager(_ manager: LiveKitRoomManager) -> String? {
        for (callId, m) in roomManagers where m === manager {
            return callId
        }
        return nil
    }
}

// MARK: - LiveKitRoomManager Delegate Setter

extension LiveKitRoomManager {
    /// Helper used by CallService to wire the delegate without exposing internal types.
    func setDelegate(_ delegate: LiveKitRoomManagerDelegate, callId: String) {
        self.delegate = delegate
    }
}
