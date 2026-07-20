//
//  SipService.swift
//  KasookooSDK
//
//
//  Implements SipServicing — aligned with real backend.
//
//  SIP call flow (mirrors CallService's proven WebRTC pattern):
//    1. POST make-call → backend initiates the PSTN leg, returns room_token + wsUrl
//       and status "waiting_for_webrtc".
//    2. The SDK joins that LiveKit room using room_token + wsUrl (this is the piece
//       that actually makes audio flow — without it the PSTN side has no one to talk to).
//    3. When the remote (PSTN bridge) participant joins the room, the call is
//       considered connected.
//    4. hangup() tears down both the backend call and the local LiveKit room.
//
//  The backend's SIP make-call request takes 3 fields:
//    - phone_number     (destination)
//    - room_name        (LiveKit room for the call)
//    - participant_name (display name of the caller in the room)
//

import Foundation

internal actor SipService: SipServicing {
    
    // MARK: - Dependencies
    
    private let apiClient: ApiClient
    private let stateStore: StateStore
    private let eventBus: EventBus
    private let logger: Logger
    private let config: KasookooConfig
    
    // MARK: - Per-Call LiveKit Managers
    
    /// One LiveKit room manager per active SIP call.
    /// Mirrors CallService — each SIP call joins its own room so audio bridges
    /// to the PSTN leg.
    private var roomManagers: [String: LiveKitRoomManager] = [:]
    
    // MARK: - Per-Call Context (for hangup/end)
    
    /// Tracks backend-side identifiers needed to end a SIP call.
    private struct SipCallContext {
        let roomName: String
        let participantIdentity: String
    }
    private var sipCallContexts: [String: SipCallContext] = [:]
    
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
    
    // MARK: - SipServicing: dial
    
    @discardableResult
    func dial(params: SipDialParams) async throws -> CallInfo {
        try params.validate()
        
        guard config.features.sipCalling else {
            throw KasookooError.callFailed(
                message: "SIP calling is disabled in SDK configuration.",
                retryable: false
            )
        }
        
        // Generate a room name if the consumer didn't provide one.
        let roomName = params.roomName ?? "sip_\(UUID().uuidString.lowercased())"
        let participantName = params.caller.name
        let callId = UUID().uuidString  // SDK-side ID; may be re-keyed to backend's room_session_id below.
        
        logger.info("Dialing SIP: \(params.destinationNumber) [room: \(roomName)]")
        
        // ─── Build initial CallInfo (state: initiating) ───────────────
        let calleePlaceholder = Participant(
            name: params.destinationNumber,
            email: "",
            phoneNumber: params.destinationNumber,
            type: .anonymous
        )
        
        var callInfo = CallInfo(
            id: callId,
            roomName: roomName,
            caller: params.caller,
            callee: calleePlaceholder,
            state: .initiating,
            direction: .outgoing,
            isRecording: params.isCallRecording,
            isPushNotification: false,
            isSip: true
        )
        await stateStore.addCall(callInfo)
        await emitSipEvent(EventName.sipCalling, callInfo: callInfo)
        
        do {
            // ─── 1. Ask backend to initiate the PSTN leg ──────────────
            let request = SipMakeCallRequest(
                phoneNumber: params.destinationNumber,
                roomName: roomName,
                participantName: participantName
            )
            
            let response = try await apiClient.send(
                endpoint: .sipMakeCall,
                body: request,
                responseType: SipMakeCallResponse.self,
                retryPolicy: .default
            )
            
            // ─── Unwrap critical media fields ─────────────────────────
            guard let roomToken = response.effectiveRoomToken else {
                throw KasookooError.callFailed(
                    message: "SIP backend did not return a room token.",
                    retryable: false
                )
            }
            guard let wsUrl = response.effectiveWsUrl else {
                throw KasookooError.callFailed(
                    message: "SIP backend did not return a WebSocket URL.",
                    retryable: false
                )
            }
            
            let effectiveRoomName = response.effectiveRoomName ?? roomName
            let participantIdentity = response.effectiveParticipantIdentity ?? params.caller.email
            
            // Re-key to the backend's stable call identifier if provided.
            let serverCallId = response.effectiveCallId ?? callId
            if serverCallId != callId {
                await stateStore.removeCall(callId)
                callInfo = CallInfo(
                    id: serverCallId,
                    roomName: effectiveRoomName,
                    caller: params.caller,
                    callee: calleePlaceholder,
                    state: .initiating,
                    direction: .outgoing,
                    createdAt: callInfo.createdAt,
                    isRecording: params.isCallRecording,
                    isPushNotification: false,
                    isSip: true
                )
                await stateStore.addCall(callInfo)
            }
            
            // Save context for hangup/end.
            sipCallContexts[serverCallId] = SipCallContext(
                roomName: effectiveRoomName,
                participantIdentity: participantIdentity
            )
            
            logger.info("SIP backend status: \(response.effectiveStatus ?? "unknown") — joining room \(effectiveRoomName)")
            
            // ─── 2. Join the LiveKit room (this makes audio flow) ─────
            let roomManager = await LiveKitRoomManager(logger: logger)
            roomManagers[serverCallId] = roomManager
            await roomManager.setDelegate(self, callId: serverCallId)
            
            try await roomManager.connect(
                wsUrl: wsUrl,
                token: roomToken,
                roomName: effectiveRoomName,
                localIdentity: participantIdentity
            )
            
            // ─── 3. Transition to connecting (waiting for PSTN answer) ─
            // The call becomes `.connected` when the remote participant (the PSTN
            // bridge) joins the room — handled in handleLiveKitEvent below.
            await stateStore.updateCall(serverCallId) { existing in
                CallInfo(
                    id: existing.id,
                    roomName: existing.roomName,
                    caller: existing.caller,
                    callee: existing.callee,
                    state: .connecting,
                    direction: existing.direction,
                    createdAt: existing.createdAt,
                    isRecording: existing.isRecording,
                    isPushNotification: existing.isPushNotification,
                    isSip: true
                )
            }
            
            let updated = await stateStore.getCall(serverCallId) ?? callInfo
            logger.info("SIP call connecting (in room, awaiting PSTN answer): \(serverCallId)")
            return updated
            
        } catch let sdkError as KasookooError {
            await failSipCall(callId: callInfo.id, error: sdkError)
            throw sdkError
        } catch {
            let wrapped = KasookooError.callFailed(
                message: "Unexpected error dialing SIP: \(error.localizedDescription)",
                retryable: false,
                underlyingError: error
            )
            await failSipCall(callId: callInfo.id, error: wrapped)
            throw wrapped
        }
    }
    
    // MARK: - SipServicing: hangup
    
    func hangup(callId: String) async throws {
        guard let context = sipCallContexts[callId] else {
            logger.warning("hangup: unknown SIP callId \(callId)")
            throw KasookooError.callFailed(
                message: "Unknown SIP call ID.",
                retryable: false
            )
        }
        
        logger.info("Hanging up SIP call: \(callId)")
        
        // Tear down the local LiveKit room first so audio stops immediately.
        if let manager = roomManagers[callId] {
            await manager.disconnect()
            roomManagers.removeValue(forKey: callId)
        }
        
        // Notify the backend to end the PSTN leg.
        let request = SipHangupRequest(
            participantIdentity: context.participantIdentity,
            roomName: context.roomName
        )
        
        do {
            _ = try await apiClient.send(
                endpoint: .sipHangup,
                body: request,
                responseType: SipEndResponse.self,
                retryPolicy: .default
            )
        } catch {
            logger.warning("SIP hangup API failed: \(error.localizedDescription) — cleaning up locally anyway")
        }
        
        // Update state → ended.
        await stateStore.updateCall(callId) { existing in
            CallInfo(
                id: existing.id,
                roomName: existing.roomName,
                caller: existing.caller,
                callee: existing.callee,
                state: .ended,
                direction: existing.direction,
                createdAt: existing.createdAt,
                connectedAt: existing.connectedAt,
                endedAt: Date(),
                isRecording: existing.isRecording,
                isPushNotification: existing.isPushNotification,
                isSip: true
            )
        }
        
        sipCallContexts.removeValue(forKey: callId)
        
        if let final = await stateStore.getCall(callId) {
            await emitSipEvent(EventName.sipEnded, callInfo: final)
        } else {
            await emitSipEndedSimple(callId: callId)
        }
    }
    
    // MARK: - SipServicing: getStatus
    
    func getStatus(callId: String) async -> CallState? {
        return await stateStore.getCall(callId)?.state
    }
    
    // MARK: - In-Call Audio Controls (SIP)
    
    /// Mutes or unmutes the local microphone for a SIP call.
    func setMuted(_ muted: Bool, callId: String) async throws {
        guard let manager = roomManagers[callId] else {
            throw KasookooError.callFailed(
                message: "Cannot toggle mute for unknown or inactive SIP call: \(callId)",
                retryable: false
            )
        }
        try await manager.setMicrophoneEnabled(!muted)
        logger.info("SIP call \(callId) microphone \(muted ? "muted" : "unmuted")")
    }
    
    /// Routes SIP call audio to the loudspeaker (true) or earpiece (false).
    func setSpeakerEnabled(_ enabled: Bool, callId: String) async throws {
        guard let manager = roomManagers[callId] else {
            throw KasookooError.callFailed(
                message: "Cannot toggle speaker for unknown or inactive SIP call: \(callId)",
                retryable: false
            )
        }
        try await manager.setSpeakerEnabled(enabled)
        logger.info("SIP call \(callId) speaker \(enabled ? "on" : "off")")
    }
    
    // MARK: - Private: Failure Handling
    
    private func failSipCall(callId: String, error: KasookooError) async {
        // Cleanup LiveKit.
        if let manager = roomManagers[callId] {
            await manager.disconnect()
            roomManagers.removeValue(forKey: callId)
        }
        sipCallContexts.removeValue(forKey: callId)
        
        if await stateStore.getCall(callId) != nil {
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
                    isPushNotification: existing.isPushNotification,
                    isSip: true
                )
            }
        }
        
        await emitSipFailedEvent(callId: callId, error: error)
    }
    
    // MARK: - LiveKit Event Handling
    
    fileprivate func handleLiveKitEvent(callId: String, event: LiveKitRoomEvent) async {
        switch event {
        case .remoteParticipantJoined:
            // The PSTN bridge joined the room → the callee has effectively answered.
            await stateStore.updateCall(callId) { existing in
                CallInfo(
                    id: existing.id,
                    roomName: existing.roomName,
                    caller: existing.caller,
                    callee: existing.callee,
                    state: .connected,
                    direction: existing.direction,
                    createdAt: existing.createdAt,
                    connectedAt: existing.connectedAt ?? Date(),
                    isRecording: existing.isRecording,
                    isPushNotification: existing.isPushNotification,
                    isSip: true
                )
            }
            if let call = await stateStore.getCall(callId) {
                await emitSipEvent(EventName.sipConnected, callInfo: call)
            }
            logger.info("SIP call connected (PSTN bridge joined): \(callId)")
            
        case .remoteParticipantLeft:
            // The PSTN side hung up → end our side too.
            try? await hangup(callId: callId)
            
        case .roomConnected:
            logger.debug("SIP room connected for call \(callId)")
            
        case .roomDisconnected(let error):
            if let error = error {
                logger.warning("SIP room disconnected with error: \(error.localizedDescription)")
                let sdkError = KasookooError.callFailed(
                    message: "SIP call dropped: \(error.localizedDescription)",
                    retryable: true,
                    underlyingError: error
                )
                await failSipCall(callId: callId, error: sdkError)
            } else {
                logger.debug("SIP room disconnected cleanly for call \(callId)")
            }
            
        case .roomReconnecting:
            logger.info("SIP room reconnecting for call \(callId)")
            
        case .roomReconnected:
            logger.info("SIP room reconnected for call \(callId)")
        }
    }
    
    private func sipCallIdForManager(_ manager: LiveKitRoomManager) -> String? {
        for (callId, m) in roomManagers where m === manager {
            return callId
        }
        return nil
    }
    
    // MARK: - Event Emission
    
    private func emitSipEvent(_ name: String, callInfo: CallInfo) async {
        let event = SDKEvent(
            name: name,
            organizationId: config.organizationId,
            userEmail: await stateStore.currentUserEmail(),
            data: [
                "callId": .string(callInfo.id),
                "roomName": .string(callInfo.roomName),
                "destinationNumber": .string(callInfo.callee.phoneNumber),
                "state": .string(callInfo.state.rawValue)
            ]
        )
        await eventBus.emit(event)
    }
    
    private func emitSipFailedEvent(callId: String, error: KasookooError) async {
        let event = SDKEvent(
            name: EventName.sipFailed,
            organizationId: config.organizationId,
            userEmail: await stateStore.currentUserEmail(),
            data: [
                "callId": .string(callId),
                "state": .string("failed"),
                "errorCode": .string(error.code.rawValue),
                "errorMessage": .string(error.message)
            ]
        )
        await eventBus.emit(event)
    }
    
    private func emitSipEndedSimple(callId: String) async {
        let event = SDKEvent(
            name: EventName.sipEnded,
            organizationId: config.organizationId,
            userEmail: await stateStore.currentUserEmail(),
            data: [
                "callId": .string(callId),
                "state": .string("ended")
            ]
        )
        await eventBus.emit(event)
    }
}

// MARK: - LiveKit Delegate Bridge

/// Allows `LiveKitRoomManager` to call back into the SipService actor,
/// mirroring the CallService bridge.
extension SipService: LiveKitRoomManagerDelegate {
    
    nonisolated func roomManager(
        _ manager: LiveKitRoomManager,
        didReceiveEvent event: LiveKitRoomEvent
    ) async {
        let callId = await self.sipCallIdForManager(manager)
        guard let callId = callId else {
            return
        }
        await handleLiveKitEvent(callId: callId, event: event)
    }
}
