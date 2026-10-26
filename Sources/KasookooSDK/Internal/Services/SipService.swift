//
//  SipService.swift
//  KasookooSDK
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
    
    /// Calls whose hangup is currently in flight.
    ///
    /// Prevents the teardown race described in `hangup(callId:)` — our own room
    /// disconnect triggers `remoteParticipantLeft`, which would otherwise issue
    /// a second hangup before the first has finished.
    private var endingSipCallIds: Set<String> = []
    
    /// Local call ids that were re-keyed to the backend's `room_session_id`.
    private var callIdAliases: [String: String] = [:]
    
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
        let localCallId = UUID().uuidString  // SDK-side ID; may be re-keyed to backend's room_session_id below.
        var activeCallId = localCallId
        
        logger.info("Dialing SIP call [room: \(roomName)]")
        
        // ─── Build initial CallInfo (state: initiating) ───────────────
        let calleePlaceholder = Participant(
            name: params.destinationNumber,
            email: "",
            phoneNumber: params.destinationNumber,
            type: .anonymous
        )
        
        var callInfo = CallInfo(
            id: localCallId,
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
            //
            // Not retried on timeout or 5xx (see `Endpoint.isRepeatable`): the
            // backend may already have dialed, and a retry would ring the
            // destination twice.
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
            
            let effectiveRoomName = response.effectiveRoomName ?? roomName
            let participantIdentity = response.effectiveParticipantIdentity ?? params.caller.email
            
            // The user may have hung up while the backend was dialing. The PSTN
            // leg now exists, so it has to be ended explicitly.
            if await wasEndedDuringDial(activeCallId) {
                await endBackendLeg(roomName: effectiveRoomName, participantIdentity: participantIdentity)
                throw SipDialCancelled()
            }
            
            // ─── Unwrap critical media fields ─────────────────────────
            guard let roomToken = response.effectiveRoomToken,
                  let wsUrl = response.effectiveWsUrl else {
                await endBackendLeg(roomName: effectiveRoomName, participantIdentity: participantIdentity)
                throw KasookooError.callFailed(
                    message: response.effectiveRoomToken == nil
                        ? "SIP backend did not return a room token."
                        : "SIP backend did not return a WebSocket URL.",
                    retryable: false
                )
            }
            
            // Re-key to the backend's stable call identifier if provided.
            let serverCallId = response.effectiveCallId ?? localCallId
            if serverCallId != localCallId {
                let rekeyed = CallInfo(
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
                guard await stateStore.replaceCall(localCallId, with: rekeyed) else {
                    await endBackendLeg(roomName: effectiveRoomName, participantIdentity: participantIdentity)
                    throw SipDialCancelled()
                }
                callInfo = rekeyed
                activeCallId = serverCallId
                callIdAliases[localCallId] = serverCallId
            }
            
            // Save context for hangup/end. From here on endCall() takes the
            // normal path and ends the backend leg itself.
            sipCallContexts[activeCallId] = SipCallContext(
                roomName: effectiveRoomName,
                participantIdentity: participantIdentity
            )
            
            logger.info("SIP backend status: \(response.effectiveStatus ?? "unknown") — joining room \(effectiveRoomName)")
            
            // ─── 2. Join the LiveKit room (this makes audio flow) ─────
            let roomManager = await LiveKitRoomManager(logger: logger)
            roomManagers[activeCallId] = roomManager
            await roomManager.setDelegate(self, callId: activeCallId)
            
            try await roomManager.connect(
                wsUrl: wsUrl,
                token: roomToken,
                roomName: effectiveRoomName,
                localIdentity: participantIdentity
            )
            
            // endCall() may have run during the connect; it already ended the
            // backend leg, so only the local room is left to clean up.
            if await wasEndedDuringDial(activeCallId) {
                throw SipDialCancelled()
            }
            
            // ─── 3. Transition to connecting (waiting for PSTN answer) ─
            // The call becomes `.connected` when the remote participant (the PSTN
            // bridge) joins the room — handled in handleLiveKitEvent below.
            await stateStore.updateCall(activeCallId) { existing in
                CallInfo(
                    id: existing.id,
                    roomName: existing.roomName,
                    caller: existing.caller,
                    callee: existing.callee,
                    state: existing.state == .connected ? .connected : .connecting,
                    direction: existing.direction,
                    createdAt: existing.createdAt,
                    connectedAt: existing.connectedAt,
                    isRecording: existing.isRecording,
                    isPushNotification: existing.isPushNotification,
                    isSip: true
                )
            }
            
            let updated = await stateStore.getCall(activeCallId) ?? callInfo
            logger.info("SIP call connecting (in room, awaiting PSTN answer): \(activeCallId)")
            return updated
            
        } catch {
            let endedByUser: Bool
            if error is SipDialCancelled {
                endedByUser = true
            } else {
                endedByUser = await wasEndedDuringDial(activeCallId)
            }
            
            if endedByUser {
                if let manager = roomManagers.removeValue(forKey: activeCallId) {
                    await manager.disconnect()
                }
                sipCallContexts.removeValue(forKey: activeCallId)
                logger.info("SIP call \(activeCallId) was ended before it connected")
                throw KasookooError.callFailed(
                    message: "The SIP call was ended before it connected.",
                    retryable: false
                )
            }
            
            let sdkError = (error as? KasookooError) ?? KasookooError.callFailed(
                message: "Unexpected error dialing SIP: \(error.localizedDescription)",
                retryable: false,
                underlyingError: error
            )
            await failSipCall(callId: activeCallId, error: sdkError)
            throw sdkError
        }
    }
    
    // MARK: - Dial Cancellation
    
    /// Thrown internally when the call was ended while `dial` was suspended.
    private struct SipDialCancelled: Error {}
    
    /// Whether the call has been ended (or is being ended) since dialing began.
    private func wasEndedDuringDial(_ callId: String) async -> Bool {
        if endingSipCallIds.contains(callId) { return true }
        guard let call = await stateStore.getCall(callId) else { return true }
        return call.state == .ending || call.state.isTerminal
    }
    
    /// Best-effort request to end the backend's PSTN leg.
    private func endBackendLeg(roomName: String, participantIdentity: String) async {
        let request = SipEndCallRequest(
            participantIdentity: participantIdentity,
            roomName: roomName
        )
        do {
            _ = try await apiClient.send(
                endpoint: .sipEndCall,
                body: request,
                responseType: SipEndResponse.self,
                retryPolicy: .default
            )
        } catch {
            logger.warning("SIP end API failed: \(error.localizedDescription)")
        }
    }
    
    /// Maps an id the host may hold (a pre-re-key local id) to the live id.
    private func canonicalId(_ callId: String) -> String {
        return callIdAliases[callId] ?? callId
    }
    
    // MARK: - SipServicing: endCall
    
    func endCall(callId requestedId: String) async throws {
        let callId = canonicalId(requestedId)
        
        guard let context = sipCallContexts[callId] else {
            // No backend context yet: the dial request is still in flight.
            // Mark the call ended now; `dial` sees this when the backend
            // answers and ends the PSTN leg it just created.
            if let call = await stateStore.getCall(callId),
               !call.state.isTerminal,
               !endingSipCallIds.contains(callId) {
                logger.info("Hanging up SIP call during dial: \(callId)")
                await markEnded(callId: callId)
                return
            }
            logger.warning("hangup: unknown SIP callId \(callId)")
            throw KasookooError.callFailed(
                message: "Unknown SIP call ID.",
                retryable: false
            )
        }
        
        // Guard against a second hangup racing the first.
        //
        // Tearing down the LiveKit room makes the PSTN bridge look like it left,
        // which fires `remoteParticipantLeft` → another hangup. A state check
        // isn't enough: the first hangup is still awaiting its API call when the
        // second arrives, so the state hasn't changed yet. Tracking in-flight
        // ids closes that window — otherwise the backend receives two hangups
        // and answers the loser with "Failed to end call".
        guard !endingSipCallIds.contains(callId) else {
            logger.debug("hangup already in flight for \(callId) — ignoring duplicate")
            return
        }
        endingSipCallIds.insert(callId)
        defer { endingSipCallIds.remove(callId) }
        
        logger.info("Hanging up SIP call: \(callId)")
        
        // Tear down the local LiveKit room first so audio stops immediately.
        if let manager = roomManagers.removeValue(forKey: callId) {
            await manager.disconnect()
        }
        
        // Notify the backend to end the PSTN leg. (The backend removed the
        // dedicated hangup endpoint; end and hangup were duplicates.)
        await endBackendLeg(
            roomName: context.roomName,
            participantIdentity: context.participantIdentity
        )
        
        sipCallContexts.removeValue(forKey: callId)
        await markEnded(callId: callId)
        callIdAliases = callIdAliases.filter { $0.value != callId }
    }
    
    /// Moves a call to `.ended` and emits `sip.ended`.
    private func markEnded(callId: String) async {
        let endedCall = await stateStore.updateCall(callId) { existing in
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
        
        if let endedCall {
            await emitSipEvent(EventName.sipEnded, callInfo: endedCall)
        } else {
            await emitSipEndedSimple(callId: callId)
        }
    }
    
    // MARK: - Teardown
    
    /// Ends every SIP call this service owns. Used by `disconnect()` and
    /// `destroy()` so no PSTN leg or microphone outlives the SDK session.
    func endAll() async {
        // Connected or connecting calls, plus dials still waiting for the
        // backend (no context yet): ending those makes `dial` hang up the
        // PSTN leg as soon as it exists.
        var callIds = Set(sipCallContexts.keys)
        for call in await stateStore.allActiveCalls() where call.isSip && call.direction == .outgoing {
            callIds.insert(call.id)
        }
        for callId in callIds {
            try? await endCall(callId: callId)
        }
        let leftovers = roomManagers
        roomManagers.removeAll()
        for (_, manager) in leftovers {
            await manager.disconnect()
        }
        sipCallContexts.removeAll()
        callIdAliases.removeAll()
    }
    
    // MARK: - SipServicing: getStatus
    
    func getStatus(callId: String) async -> CallState? {
        return await stateStore.getCall(callId)?.state
    }
    
    // MARK: - In-Call Audio Controls (SIP)
    
    /// Mutes or unmutes the local microphone for a SIP call.
    func setMuted(_ muted: Bool, callId requestedId: String) async throws {
        let callId = canonicalId(requestedId)
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
    func setSpeakerEnabled(_ enabled: Bool, callId requestedId: String) async throws {
        let callId = canonicalId(requestedId)
        guard let manager = roomManagers[callId] else {
            throw KasookooError.callFailed(
                message: "Cannot toggle speaker for unknown or inactive SIP call: \(callId)",
                retryable: false
            )
        }
        try await manager.setSpeakerEnabled(enabled)
        logger.info("SIP call \(callId) speaker \(enabled ? "on" : "off")")
    }
    
    // MARK: - DTMF
    
    func sendDTMF(_ digit: String, callId requestedId: String) async throws {
        let callId = canonicalId(requestedId)
        guard let manager = roomManagers[callId] else {
            throw KasookooError.callFailed(
                message: "Cannot send DTMF for unknown or inactive SIP call: \(callId)",
                retryable: false
            )
        }
        try await manager.sendDTMF(digit)
    }
    
    // MARK: - Private: Failure Handling
    
    private func failSipCall(callId: String, error: KasookooError) async {
        // A room error caused by our own hangup is not a failure.
        if endingSipCallIds.contains(callId) { return }
        
        // Cleanup LiveKit, and end the PSTN leg if the backend created one, so
        // a failed local join does not leave the destination phone ringing.
        if let manager = roomManagers.removeValue(forKey: callId) {
            await manager.disconnect()
        }
        if let context = sipCallContexts.removeValue(forKey: callId) {
            await endBackendLeg(
                roomName: context.roomName,
                participantIdentity: context.participantIdentity
            )
        }
        
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
            // Emitted only by whichever path failed the call first (the dial
            // itself or the room delegate), never twice.
            await emitSipFailedEvent(callId: callId, error: error)
        }
    }
    
    // MARK: - LiveKit Event Handling
    
    fileprivate func handleLiveKitEvent(callId: String, event: LiveKitRoomEvent) async {
        switch event {
        case .remoteParticipantJoined:
            // The PSTN bridge joined the room → the callee has effectively answered.
            guard let current = await stateStore.getCall(callId),
                  !current.state.isTerminal,
                  current.state != .ending,
                  !endingSipCallIds.contains(callId) else {
                return
            }
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
            // The PSTN bridge left the room → end our side too.
            //
            // This also fires when WE hang up (our own teardown disconnects the
            // room), so guard on state to keep the handler idempotent — otherwise
            // hangup() runs twice and the second one errors on an already-ended
            // call.
            if let call = await stateStore.getCall(callId),
               !call.state.isTerminal,
               call.state != .ending {
                try? await endCall(callId: callId)
            } else {
                logger.debug("PSTN bridge left for SIP call \(callId) — already ending/ended, ignoring")
            }
            
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
