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
    
    /// Calls whose teardown is currently in flight.
    ///
    /// See the guard in `end(callId:)` — prevents duplicate end requests when
    /// the UI (or our own room teardown) triggers the path twice.
    private var endingCallIds: Set<String> = []
    
    /// Local call ids that were re-keyed to a backend id during `start`.
    private var callIdAliases: [String: String] = [:]
    
    /// Incoming calls whose `accept()` is in flight.
    private var acceptingCallIds: Set<String> = []
    
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
        
        logger.info("Starting call in room \(params.roomName)")
        
        // Build initial CallInfo under a local id. It may be re-keyed to the
        // backend's id below; `activeCallId` always names the live record so
        // cleanup and failure handling act on the right one.
        let localCallId = UUID().uuidString
        var activeCallId = localCallId
        // Set once the backend has created the call (tokens returned), so a
        // hang-up during setup knows the callee may already be ringing.
        var backendRoomName: String?
        var callInfo = CallInfo(
            id: localCallId,
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
            backendRoomName = tokensResponse.roomName ?? params.roomName
            
            // The caller may have hung up while the tokens were in flight.
            try await requireStillLive(activeCallId)
            
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
            let serverCallId = tokensResponse.callId ?? localCallId
            if serverCallId != localCallId {
                let rekeyed = CallInfo(
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
                guard await stateStore.replaceCall(localCallId, with: rekeyed) else {
                    throw CallSetupCancelled()
                }
                callInfo = rekeyed
                activeCallId = serverCallId
                // A host that grabbed the local id from getActiveCall() can
                // still end the call with it.
                callIdAliases[localCallId] = serverCallId
            }
            
            // 2. Transition to ringing
            guard let ringing = try await transitionState(callId: activeCallId, to: .ringing) else {
                throw CallSetupCancelled()
            }
            callInfo = ringing
            
            // 3. Connect to LiveKit. The manager is registered before connecting
            //    so a concurrent end() can tear it down mid-connect.
            let roomManager = await LiveKitRoomManager(logger: logger)
            roomManagers[activeCallId] = roomManager
            await roomManager.setDelegate(self, callId: activeCallId)
            
            try await roomManager.connect(
                wsUrl: wsUrl,
                token: callerToken,
                roomName: effectiveRoomName,
                localIdentity: params.caller.email
            )
            
            // An end() that arrived during the connect must not leave a live
            // room with a published microphone behind.
            try await requireStillLive(activeCallId)
            
            // 4. Transition to connecting (waiting for callee to join)
            callInfo = try await transitionState(callId: activeCallId, to: .connecting) ?? callInfo
            
            return callInfo
            
        } catch {
            let endedByUser: Bool
            if error is CallSetupCancelled {
                endedByUser = true
            } else {
                endedByUser = await wasEndedDuringSetup(activeCallId)
            }
            
            if endedByUser {
                await teardownRoom(callId: activeCallId)
                // end() may have reached the backend before the call existed
                // there, in which case the callee would keep ringing. Now that
                // the backend has created it, tell it again (best effort; a
                // duplicate caller-end is harmless).
                if let backendRoomName {
                    await notifyCallerEnded(
                        roomName: backendRoomName,
                        caller: params.caller,
                        callee: params.callee
                    )
                }
                logger.info("Call \(activeCallId) was ended before it connected")
                throw KasookooError.callFailed(
                    message: "The call was ended before it connected.",
                    retryable: false
                )
            }
            
            let sdkError = (error as? KasookooError) ?? KasookooError.callFailed(
                message: "Unexpected error starting call: \(error.localizedDescription)",
                retryable: false,
                underlyingError: error
            )
            await failCall(callId: activeCallId, error: sdkError)
            throw sdkError
        }
    }
    
    // MARK: - Setup Cancellation
    
    /// Thrown internally when the call was ended (or re-keyed away) while
    /// `start` or `accept` was suspended. Never escapes to the caller.
    private struct CallSetupCancelled: Error {}
    
    /// Throws `CallSetupCancelled` if the call has been ended, or is being
    /// ended, since setup began.
    private func requireStillLive(_ callId: String) async throws {
        if await wasEndedDuringSetup(callId) {
            throw CallSetupCancelled()
        }
    }
    
    /// Whether the call is gone, ending, or already terminal.
    private func wasEndedDuringSetup(_ callId: String) async -> Bool {
        if endingCallIds.contains(callId) { return true }
        guard let call = await stateStore.getCall(callId) else { return true }
        return call.state == .ending || call.state.isTerminal
    }
    
    /// Disconnects and forgets the room manager for a call, if any.
    private func teardownRoom(callId: String) async {
        if let manager = roomManagers.removeValue(forKey: callId) {
            await manager.disconnect()
        }
    }
    
    /// Maps an id the host may hold (a pre-re-key local id) to the live id.
    private func canonicalId(_ callId: String) -> String {
        return callIdAliases[callId] ?? callId
    }
    
    /// Best-effort `caller-end` for an outgoing call.
    private func notifyCallerEnded(roomName: String, caller: Participant, callee: Participant) async {
        let request = CallerEndCallRequest(
            roomName: roomName,
            caller: ParticipantDTO(from: caller),
            callee: ParticipantDTO(from: callee)
        )
        do {
            _ = try await apiClient.send(
                endpoint: .callerEndCall,
                body: request,
                responseType: EndCallResponse.self,
                retryPolicy: .default
            )
        } catch {
            logger.warning("Backend caller-end notification failed: \(error.localizedDescription)")
        }
    }
    
    // MARK: - Teardown
    
    /// Ends every call this service owns. Used by `disconnect()` and
    /// `destroy()` so no LiveKit room, and no microphone, outlives the SDK
    /// session. Backend notification is best effort.
    func endAll() async {
        // Calls with a media room, plus outgoing calls still being set up
        // (no room yet): ending those makes `start` abandon them.
        var callIds = Set(roomManagers.keys)
        for call in await stateStore.allActiveCalls() where !call.isSip && call.direction == .outgoing {
            callIds.insert(call.id)
        }
        for callId in callIds {
            try? await end(callId: callId)
        }
        // Anything left (e.g. a room whose call record is already gone).
        let leftovers = roomManagers
        roomManagers.removeAll()
        for (_, manager) in leftovers {
            await manager.disconnect()
        }
        callIdAliases.removeAll()
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
        
        // A double tap (or CallKit plus an in-app button) must not join the
        // room twice and orphan the first connection.
        guard !acceptingCallIds.contains(callId), roomManagers[callId] == nil else {
            logger.debug("accept() already in progress for \(callId) — ignoring duplicate")
            return call
        }
        acceptingCallIds.insert(callId)
        defer { acceptingCallIds.remove(callId) }
        
        logger.info("Accepting incoming call: \(callId)")
        
        // ─── Retrieve the LiveKit credentials delivered with the push ────────
        //
        // Unlike an outgoing call (which fetches tokens from /get-call-tokens),
        // the callee receives the token inside the incoming-call push payload.
        // NotificationService stored it when the push arrived. Without it we
        // cannot join the room — the call would connect with no audio.
        guard let credentials = await stateStore.getCallCredentials(for: callId) else {
            let error = KasookooError.callFailed(
                message: "Cannot accept call: no media credentials were delivered with the incoming-call push.",
                retryable: false
            )
            await failCall(callId: callId, error: error)
            throw error
        }
        
        // Local identity: prefer the identified user, fall back to the callee
        // profile that came with the push.
        let identifiedEmail = await stateStore.currentUserEmail()
        let calleeEmail: String? = call.callee.email.isEmpty ? nil : call.callee.email
        let localIdentity = identifiedEmail ?? calleeEmail ?? call.callee.name
        
        do {
            // ─── Join the LiveKit room (this is what produces audio) ─────────
            let roomManager = await LiveKitRoomManager(logger: logger)
            roomManagers[callId] = roomManager
            await roomManager.setDelegate(self, callId: callId)
            
            try await roomManager.connect(
                wsUrl: credentials.wsUrl,
                token: credentials.accessToken,
                roomName: call.roomName,
                localIdentity: localIdentity
            )
            
            // The caller may have cancelled, or the user ended the call,
            // while we were joining.
            try await requireStillLive(callId)
            
            logger.info("Incoming call \(callId): joined room '\(call.roomName)'")
            
            // The call becomes `.connected` once the remote participant is seen
            // (handled by handleLiveKitEvent), mirroring the outgoing flow.
            let updated = try await transitionState(callId: callId, to: .connecting)
            return updated ?? call
            
        } catch {
            let endedMeanwhile: Bool
            if error is CallSetupCancelled {
                endedMeanwhile = true
            } else {
                endedMeanwhile = await wasEndedDuringSetup(callId)
            }
            
            if endedMeanwhile {
                await teardownRoom(callId: callId)
                logger.info("Incoming call \(callId) ended while it was being accepted")
                throw KasookooError.callFailed(
                    message: "The call ended before it could be accepted.",
                    retryable: false
                )
            }
            
            let sdkError = (error as? KasookooError) ?? KasookooError.callFailed(
                message: "Failed to join room for incoming call: \(error.localizedDescription)",
                retryable: true,
                underlyingError: error
            )
            await failCall(callId: callId, error: sdkError)
            throw sdkError
        }
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
        
        // The backend identifies both parties by participant objects (email-keyed),
        // not by user ids. Sending ids here previously caused a 500
        // ("not a valid ObjectId") whenever the id could not be resolved and the
        // email was used as a fallback.
        let request = RejectCallRequest(
            roomName: call.roomName,
            caller: ParticipantDTO(from: call.caller),
            callee: ParticipantDTO(from: call.callee)
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
    
    func end(callId requestedId: String) async throws {
        let callId = canonicalId(requestedId)
        guard let call = await stateStore.getCall(callId) else {
            logger.warning("end() called for unknown call: \(callId)")
            return // Silently succeed — call already gone
        }
        
        // Guard against a second end() racing the first.
        //
        // UIs commonly call this from more than one place (a hang-up button and
        // a teardown handler, say), and disconnecting the room can itself
        // trigger a "remote left" path that ends the call again. The first call
        // is still awaiting its API request when the second arrives, so a state
        // check alone doesn't catch it — hence tracking in-flight ids.
        guard !endingCallIds.contains(callId) else {
            logger.debug("end() already in flight for \(callId) — ignoring duplicate")
            return
        }
        endingCallIds.insert(callId)
        defer { endingCallIds.remove(callId) }
        
        logger.info("Ending call: \(callId) (direction: \(call.direction.rawValue))")
        
        // Mark as ending
        try await transitionState(callId: callId, to: .ending)
        
        // Disconnect LiveKit
        await teardownRoom(callId: callId)
        
        // Choose endpoint based on call direction:
        // - Outgoing call hangup by caller → /webrtc/calls/caller-end
        // - Incoming call ended after pickup → /webrtc/calls/{room}/end
        do {
            if call.direction == .outgoing {
                // Caller ending their own call. The backend expects full
                // participant objects for both parties (see Postman collection);
                // the older flat `caller_user_id` / `called_user_id` shape now
                // returns 422 "Field required: caller / callee".
                let request = CallerEndCallRequest(
                    roomName: call.roomName,
                    caller: ParticipantDTO(from: call.caller),
                    callee: ParticipantDTO(from: call.callee)
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
        callIdAliases = callIdAliases.filter { $0.value != callId }
    }
    
    // MARK: - CallServicing: In-Call Audio Controls
    
    func setMuted(_ muted: Bool, callId requestedId: String) async throws {
        let callId = canonicalId(requestedId)
        guard let manager = roomManagers[callId] else {
            throw KasookooError.callFailed(
                message: "Cannot toggle mute for unknown or inactive call: \(callId)",
                retryable: false
            )
        }
        // LiveKit uses "microphone enabled" semantics; muted == mic disabled.
        try await manager.setMicrophoneEnabled(!muted)
        logger.info("Call \(callId) microphone \(muted ? "muted" : "unmuted")")
    }
    
    func isMuted(callId requestedId: String) async -> Bool {
        guard let manager = roomManagers[canonicalId(requestedId)] else {
            return false
        }
        // muted == microphone NOT enabled.
        let micEnabled = await manager.isMicrophoneEnabled
        return !micEnabled
    }
    
    func setSpeakerEnabled(_ enabled: Bool, callId requestedId: String) async throws {
        let callId = canonicalId(requestedId)
        guard let manager = roomManagers[callId] else {
            throw KasookooError.callFailed(
                message: "Cannot toggle speaker for unknown or inactive call: \(callId)",
                retryable: false
            )
        }
        try await manager.setSpeakerEnabled(enabled)
        logger.info("Call \(callId) speaker \(enabled ? "on" : "off")")
    }
    
    /// Sends a DTMF digit on an active call. Used for incoming SIP calls,
    /// which `CallService` owns once accepted (keypad on the CallKit screen).
    func sendDTMF(_ digit: String, callId requestedId: String) async throws {
        let callId = canonicalId(requestedId)
        guard let manager = roomManagers[callId] else {
            throw KasookooError.callFailed(
                message: "Cannot send DTMF for unknown or inactive call: \(callId)",
                retryable: false
            )
        }
        try await manager.sendDTMF(digit)
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
        await teardownRoom(callId: callId)
        
        // Mark failed (force, even if invalid transition). A call that is
        // already being ended is left to `end()`: a room error caused by our
        // own teardown is not a failure.
        if let current = await stateStore.getCall(callId), current.state != .ending {
            let updated = await stateStore.updateCall(callId) { existing in
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
            
            await emitCallEvent(EventName.callFailed, call: updated ?? current, extra: [
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
            // The remote side left the room → end the call on our side too.
            //
            // This fires in two situations:
            //   1. The callee genuinely hung up first (we should end).
            //   2. WE ended the call — our own `end()` disconnected the room,
            //      which makes LiveKit report the remote participant leaving.
            //
            // In case 2 the call is already `.ending`/terminal, and calling
            // `end()` again throws an invalid-transition error that gets logged
            // as a noisy stack trace. Guard on the current state so this handler
            // is idempotent and only acts when the call is genuinely still live.
            if let call = await stateStore.getCall(callId),
               !call.state.isTerminal,
               call.state != .ending {
                try? await end(callId: callId)
            } else {
                logger.debug("Remote participant left for call \(callId) — already ending/ended, ignoring")
            }
            
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
