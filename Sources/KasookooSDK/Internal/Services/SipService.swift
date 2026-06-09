//
//  SipService.swift
//  KasookooSDK
//
//

import Foundation

internal actor SipService: SipServicing {
    
    // MARK: - Dependencies
    
    private let apiClient: ApiClient
    private let stateStore: StateStore
    private let eventBus: EventBus
    private let logger: Logger
    private let config: KasookooConfig
    
    /// Tracks ongoing SIP calls (callId → roomName + participantIdentity).
    /// Needed because hangup/end requires participant_identity and room_name.
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
        
        // Generate room name if consumer didn't provide one
        let roomName = params.roomName ?? "sip_\(UUID().uuidString.lowercased())"
        let participantName = params.caller.name
        let callId = UUID().uuidString  // SDK-side ID
        
        logger.info("Dialing SIP: \(params.destinationNumber) [room: \(roomName)]")
        
        // ─── Build outbound call request ──────────────────────────────
        
        let request = SipMakeCallRequest(
            phoneNumber: params.destinationNumber,
            roomName: roomName,
            participantName: participantName
        )
        
        // ─── Emit sip.calling event ───────────────────────────────────
        
        let calleePlaceholder = Participant(
            name: params.destinationNumber,
            email: "",
            phoneNumber: params.destinationNumber,
            type: .anonymous
        )
        
        let initialCallInfo = CallInfo(
            id: callId,
            roomName: roomName,
            caller: params.caller,
            callee: calleePlaceholder,
            state: .connecting,
            direction: .outgoing,
            createdAt: Date(),
            isRecording: params.isCallRecording,
            isPushNotification: false,
            isSip: true
        )
        await stateStore.addCall(initialCallInfo)
        await emitSipEvent(EventName.sipCalling, callInfo: initialCallInfo)
        
        // ─── Send to backend ──────────────────────────────────────────
        
        let response: SipMakeCallResponse
        do {
            response = try await apiClient.send(
                endpoint: .sipMakeCall,
                body: request,
                responseType: SipMakeCallResponse.self,
                retryPolicy: .default
            )
        } catch let sdkError as KasookooError {
            // Failed to even initiate
            await stateStore.updateCall(callId) { existing in
                var updated = existing
                updated = CallInfo(
                    id: existing.id,
                    roomName: existing.roomName,
                    caller: existing.caller,
                    callee: existing.callee,
                    state: .failed,
                    direction: existing.direction,
                    createdAt: existing.createdAt,
                    endedAt: Date(),
                    isRecording: existing.isRecording,
                    isPushNotification: existing.isPushNotification,
                    isSip: true
                )
                return updated
            }
            
            await emitSipFailedEvent(callId: callId, error: sdkError)
            throw sdkError
        }
        
        // ─── Save context for hangup/end ──────────────────────────────
        
        let participantIdentity = response.participantIdentity ?? params.caller.email
        sipCallContexts[callId] = SipCallContext(
            roomName: response.roomName ?? roomName,
            participantIdentity: participantIdentity
        )
        
        // ─── Emit sip.connected ───────────────────────────────────────
        // Note: Real connection status depends on backend webhook updates.
        // For now we treat dial response as "connecting" → "connected".
        
        await stateStore.updateCall(callId) { existing in
            CallInfo(
                id: existing.id,
                roomName: existing.roomName,
                caller: existing.caller,
                callee: existing.callee,
                state: .connected,
                direction: existing.direction,
                createdAt: existing.createdAt,
                connectedAt: Date(),
                isRecording: existing.isRecording,
                isPushNotification: existing.isPushNotification,
                isSip: true
            )
        }
        
        let updatedCall = await stateStore.getCall(callId) ?? initialCallInfo
        await emitSipEvent(EventName.sipConnected, callInfo: updatedCall)
        
        logger.info("SIP call connected: \(callId)")
        return updatedCall
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
            // Even on backend failure, clean up locally
        }
        
        // Update state
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
        
        // Remove from active context map
        sipCallContexts.removeValue(forKey: callId)
        
        if let final = await stateStore.getCall(callId) {
            await emitSipEvent(EventName.sipEnded, callInfo: final)
        } else {
            // Already removed; emit a simple event
            await emitSipEndedSimple(callId: callId)
        }
    }
    
    // MARK: - SipServicing: getStatus
    
    func getStatus(callId: String) async -> CallState? {
        return await stateStore.getCall(callId)?.state
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
            name: EventName.sipEnded,
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
