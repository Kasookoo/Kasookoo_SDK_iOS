//
//  NotificationService.swift
//  KasookooSDK
//
//  Implements NotificationServicing — FCM-based push notification management.
//

import Foundation
import UIKit
import CallKit

/// Concrete implementation of `NotificationServicing`.
internal actor NotificationService: NotificationServicing {
    
    // MARK: - Dependencies
    
    private let apiClient: ApiClient
    private let stateStore: StateStore
    private let eventBus: EventBus
    private let logger: Logger
    private let config: KasookooConfig
    private let payloadParser: PushPayloadParser
    
    private var callKitProvider: CallKitProvider?
    private var _incomingCallHandler: IncomingCallHandler?
    
    private weak var callService: CallService?
    private weak var sipService: SipService?
    
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
        self.payloadParser = PushPayloadParser(logger: logger)
    }
    
    // MARK: - Service Wiring
    
    func setServices(callService: CallService, sipService: SipService) {
        self.callService = callService
        self.sipService = sipService
    }
    
    // MARK: - Incoming Call Handler
    
    func setIncomingCallHandler(_ handler: IncomingCallHandler?) async {
        _incomingCallHandler = handler
        
        if handler != nil && callKitProvider == nil {
            await initializeCallKit()
        }
    }
    
    private func initializeCallKit() async {
        let appName = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Kasookoo"
        
        // CallKitProvider is now a regular class (not @MainActor), so init and
        // setDelegate are synchronous — no actor crossing required.
        let provider = CallKitProvider(appName: appName, logger: logger)
        provider.setDelegate(self)
        self.callKitProvider = provider
        
        // Dismiss the system call UI whenever a call ends outside CallKit:
        // remote hang-up, failure, or the host app's own end button. Without
        // this the CallKit call (and the green status pill) outlived the call.
        let endEvents: [(String, CXCallEndedReason)] = [
            (EventName.callEnded, .remoteEnded),
            (EventName.sipEnded, .remoteEnded),
            (EventName.callFailed, .failed),
            (EventName.sipFailed, .failed)
        ]
        for (eventName, reason) in endEvents {
            _ = eventBus.subscribe(to: eventName) { [weak provider] event in
                guard let callId = event.string("callId") else { return }
                provider?.reportCallEnded(callId: callId, reason: reason)
            }
        }
        
        logger.info("CallKit initialized")
    }
    
    // MARK: - Device Registration (FCM)
    
    // MARK: - Convenience: Register Using the Identified User
    
    /// Registers this device without the caller having to know the backend's
    /// user id — it is resolved from the identity established by `identify()`.
    func registerDevice(
        fcmToken: String,
        deviceInfo: DeviceInfo? = nil
    ) async throws {
        guard let profile = await stateStore.identifiedUser else {
            throw KasookooError.configInvalid(
                "Cannot register for push: no user is identified. Call identify() before registerDevice()."
            )
        }
        
        guard let userId = await stateStore.resolveUserId(forEmail: profile.email) else {
            throw KasookooError.configInvalid(
                "Cannot register for push: the backend user id of the identified user is not known. Ensure identify() completed successfully."
            )
        }
        
        try await registerDevice(
            fcmToken: fcmToken,
            userId: userId,
            userType: profile.type,
            deviceInfo: deviceInfo ?? DeviceInfo.current()
        )
    }
    
    func registerDevice(
        fcmToken: String,
        userId: String,
        userType: ParticipantType,
        deviceInfo: DeviceInfo?
    ) async throws {
        guard config.features.pushNotifications else {
            throw KasookooError(
                code: .configInvalid,
                message: "Push notifications are disabled in SDK configuration.",
                retryable: false
            )
        }
        
        guard !fcmToken.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw KasookooError.configInvalid("fcmToken cannot be empty")
        }
        guard !userId.trimmingCharacters(in: .whitespaces).isEmpty else {
            throw KasookooError.configInvalid("userId cannot be empty")
        }
        
        logger.info("Registering FCM device: userId=\(userId), userType=\(userType.rawValue)")
        
        let info = await mergedDeviceInfo(deviceInfo)
        let request = RegisterDeviceTokenRequest(
            userId: userId,
            userType: userType.rawValue,
            deviceToken: fcmToken,
            deviceType: DeviceTypeFCM.ios.rawValue,
            newDeviceToken: nil,
            deviceInfo: info
        )
        
        _ = try await apiClient.send(
            endpoint: .registerDeviceToken,
            body: request,
            responseType: RegisterDeviceTokenResponse.self,
            retryPolicy: .default
        )
        
        logger.info("FCM device registered successfully")
    }
    
    func updateDevice(
        oldFcmToken: String,
        newFcmToken: String,
        userId: String,
        userType: ParticipantType,
        deviceInfo: DeviceInfo?
    ) async throws {
        guard !oldFcmToken.isEmpty, !newFcmToken.isEmpty else {
            throw KasookooError.configInvalid("Both old and new FCM tokens must be provided")
        }
        
        logger.info("Updating FCM token: userId=\(userId)")
        
        let info = await mergedDeviceInfo(deviceInfo)
        let request = UpdateDeviceTokenRequest(
            userId: userId,
            userType: userType.rawValue,
            deviceToken: oldFcmToken,
            deviceType: DeviceTypeFCM.ios.rawValue,
            newDeviceToken: newFcmToken,
            deviceInfo: info
        )
        
        _ = try await apiClient.send(
            endpoint: .updateDeviceToken,
            body: request,
            responseType: UpdateDeviceTokenResponse.self,
            retryPolicy: .default
        )
    }
    
    func unregisterDevice(
        fcmToken: String,
        userId: String,
        userType: ParticipantType
    ) async throws {
        guard !fcmToken.isEmpty else {
            throw KasookooError.configInvalid("fcmToken cannot be empty")
        }
        
        logger.info("Unregistering FCM device: userId=\(userId)")
        
        let request = UnregisterDeviceTokenRequest(
            userId: userId,
            userType: userType.rawValue,
            deviceToken: fcmToken,
            deviceType: DeviceTypeFCM.ios.rawValue
        )
        
        _ = try await apiClient.send(
            endpoint: .unregisterDeviceToken,
            body: request,
            responseType: UnregisterDeviceTokenResponse.self,
            retryPolicy: .default
        )
    }
    
    // MARK: - Push Handling
    
    @discardableResult
    func handlePushNotification(payload: PushPayload) async -> Bool {
        let parsed = payloadParser.parse(payload)
        return await handleParsedPush(parsed, isVoIP: false)
    }
    
    @discardableResult
    func handleVoIPPush(payload: PushPayload) async -> Bool {
        let parsed = payloadParser.parse(payload)
        
        // CallKit first, before any state or event work: PushKit gives the
        // app a few seconds to report a call and terminates it otherwise.
        // Every VoIP push must report one, so a push that is not an incoming
        // call is satisfied with a placeholder that ends immediately.
        switch parsed {
        case .incomingCall(let info), .incomingSipCall(let info):
            await reportToCallKit(info: info)
        default:
            await reportPlaceholderToCallKit()
        }
        
        return await handleParsedPush(parsed, isVoIP: true)
    }
    
    // MARK: - Push Dispatch
    
    private func handleParsedPush(_ parsed: PushNotificationType, isVoIP: Bool) async -> Bool {
        switch parsed {
        case .incomingCall(let info):
            await handleIncomingCallPush(info: info, isSip: false, isVoIP: isVoIP)
            return true
            
        case .incomingSipCall(let info):
            await handleIncomingCallPush(info: info, isSip: true, isVoIP: isVoIP)
            return true
            
        case .callCancelled(let callId):
            await handleCallCancelled(callId: callId)
            return true
            
        case .messageReceived(let message):
            await handleMessageReceived(message: message)
            return true
            
        case .generic(let data):
            // Not a Kasookoo call or message. Still surfaced as an event, but
            // reported as unhandled so the host app processes it itself.
            await emitNotificationReceived(data: data)
            return false
            
        case .unknown:
            logger.debug("Push payload not recognized as Kasookoo notification")
            return false
        }
    }
    
    // MARK: - Incoming Call Push
    
    private func handleIncomingCallPush(info: IncomingCallInfo, isSip: Bool, isVoIP: Bool) async {
        logger.info("Handling incoming call push: \(info.callId), isSip: \(isSip), isVoIP: \(isVoIP)")
        
        // The same call can arrive twice (FCM and PushKit, or a redelivered
        // push). Only the first one creates state and a `call.incoming` event.
        if let existing = await stateStore.getCall(info.callId), !existing.state.isTerminal {
            logger.debug("Duplicate incoming-call push for \(info.callId) — ignoring")
            if isVoIP {
                await reportToCallKit(info: info)  // no-op if already reported
            }
            return
        }
        
        let callInfo = CallInfo(
            id: info.callId,
            roomName: info.roomName,
            caller: info.caller,
            callee: info.callee,
            state: .ringing,
            direction: .incoming,
            createdAt: Date(),
            isSip: isSip
        )
        await stateStore.addCall(callInfo)
        
        // ─── Persist the LiveKit credentials that arrived with the push ──────
        //
        // This is what makes an accepted incoming call actually produce audio.
        // The callee never calls a token endpoint — the backend hands the token
        // over inside the push. `CallService.accept()` reads these back to join
        // the room. Without this step, accept() has no token and the call
        // connects silently with no media.
        if let token = info.accessToken, let wsUrl = info.wsUrl,
           !token.isEmpty, !wsUrl.isEmpty {
            await stateStore.setCallCredentials(
                CallMediaCredentials(accessToken: token, wsUrl: wsUrl),
                for: info.callId
            )
            logger.debug("Incoming call \(info.callId): media credentials captured from push")
        } else {
            logger.warning("Incoming call \(info.callId): push carried no LiveKit credentials — accepting this call will not produce audio")
        }
        
        await emitCallIncomingEvent(callInfo: callInfo, isSip: isSip)
        
        if isVoIP {
            await reportToCallKit(info: info)
        }
    }
    
    private func reportToCallKit(info: IncomingCallInfo) async {
        if callKitProvider == nil {
            await initializeCallKit()
        }
        
        guard let provider = callKitProvider else {
            logger.error("Failed to initialize CallKit; cannot report incoming call")
            return
        }
        
        guard !provider.isReported(callId: info.callId) else { return }
        
        do {
            try await provider.reportIncomingCall(info)
            logger.info("Incoming call reported to CallKit: \(info.callId)")
        } catch {
            logger.error("Failed to report incoming call to CallKit: \(error.localizedDescription)")
        }
    }
    
    private func reportPlaceholderToCallKit() async {
        if callKitProvider == nil {
            await initializeCallKit()
        }
        await callKitProvider?.reportPlaceholderCallAndEnd()
    }
    
    // MARK: - Call Cancelled
    
    private func handleCallCancelled(callId: String) async {
        logger.info("Call cancelled: \(callId)")
        
        if let provider = callKitProvider {
            provider.reportCallEnded(callId: callId, reason: .remoteEnded)
        }
        
        // Already answered: end it properly, which disconnects the media room
        // and emits `call.ended`. Marking an answered call "missed" left its
        // room (and microphone) running.
        if let call = await stateStore.getCall(callId),
           call.state != .ringing,
           !call.state.isTerminal {
            try? await callService?.end(callId: callId)
            return
        }
        
        if await stateStore.getCall(callId) != nil {
            await stateStore.updateCall(callId) { existing in
                CallInfo(
                    id: existing.id,
                    roomName: existing.roomName,
                    caller: existing.caller,
                    callee: existing.callee,
                    state: .missed,
                    direction: existing.direction,
                    createdAt: existing.createdAt,
                    endedAt: Date(),
                    isRecording: existing.isRecording,
                    isPushNotification: existing.isPushNotification
                )
            }
        }
        
        let event = SDKEvent(
            name: EventName.callEnded,
            organizationId: config.organizationId,
            userEmail: await stateStore.currentUserEmail(),
            data: [
                "callId": .string(callId),
                "reason": .string("cancelled_by_caller")
            ]
        )
        await eventBus.emit(event)
    }
    
    // MARK: - Message Received
    
    private func handleMessageReceived(message: Message) async {
        let currentEmail = await stateStore.currentUserEmail()
        let isOutgoing = currentEmail == message.senderEmail
        
        guard !isOutgoing else { return }
        
        let event = SDKEvent(
            name: EventName.messageReceived,
            organizationId: config.organizationId,
            userEmail: currentEmail,
            data: [
                "messageId": .string(message.id),
                "roomName": .string(message.roomName),
                "senderEmail": .string(message.senderEmail),
                "content": .string(message.content),
                "messageType": .string(message.messageType.rawValue),
                "sentAt": .string(ISO8601DateFormatter().string(from: message.sentAt))
            ]
        )
        await eventBus.emit(event)
    }
    
    // MARK: - Generic Notification
    
    private func emitNotificationReceived(data: [String: String]) async {
        var eventData: [String: AnyCodableValue] = [:]
        for (key, value) in data {
            eventData[key] = .string(value)
        }
        
        let event = SDKEvent(
            name: EventName.notificationReceived,
            organizationId: config.organizationId,
            userEmail: await stateStore.currentUserEmail(),
            data: eventData
        )
        await eventBus.emit(event)
    }
    
    // MARK: - Event Emission Helpers
    
    private func emitCallIncomingEvent(callInfo: CallInfo, isSip: Bool) async {
        // Everything the host app needs to present an incoming-call screen.
        // Note the callee/type fields: without them a host app cannot tell which
        // of its own users the call is for, nor render the caller's role.
        let event = SDKEvent(
            name: EventName.callIncoming,
            organizationId: config.organizationId,
            userEmail: await stateStore.currentUserEmail(),
            data: [
                "callId": .string(callInfo.id),
                "roomName": .string(callInfo.roomName),
                "callerEmail": .string(callInfo.caller.email),
                "callerName": .string(callInfo.caller.name),
                "callerPhoneNumber": .string(callInfo.caller.phoneNumber),
                "callerType": .string(callInfo.caller.type.rawValue),
                "calleeEmail": .string(callInfo.callee.email),
                "calleeName": .string(callInfo.callee.name),
                "calleeType": .string(callInfo.callee.type.rawValue),
                "isSipCall": .bool(isSip)
            ]
        )
        await eventBus.emit(event)
    }
    
    // MARK: - Device Info Helpers
    
    /// Merges consumer-provided device info with auto-detected values.
    private func mergedDeviceInfo(_ provided: DeviceInfo?) async -> DeviceInfoDTO {
        let appVersion = provided?.appVersion
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        
        // Extract await to its own statement (can't appear right of ?? in Swift 6)
        let osVersion: String?
        if let provided = provided?.osVersion {
            osVersion = provided
        } else {
            osVersion = await MainActor.run { UIDevice.current.systemVersion }
        }
        
        let deviceModel = provided?.deviceModel ?? Self.deviceModel()
        
        return DeviceInfoDTO(
            appVersion: appVersion,
            osVersion: osVersion,
            deviceModel: deviceModel
        )
    }
    
    private nonisolated static func deviceModel() -> String {
        var systemInfo = utsname()
        uname(&systemInfo)
        let modelCode = withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) { ptr in
                String(validatingUTF8: ptr) ?? "unknown"
            }
        }
        return modelCode
    }
}

// MARK: - CallKitProviderDelegate

extension NotificationService: CallKitProviderDelegate {
    
    nonisolated func callKitDidAnswerCall(uuid: UUID) async {
        await processAnswer(uuid: uuid)
    }
    
    nonisolated func callKitDidEndCall(uuid: UUID) async {
        await processEnd(uuid: uuid)
    }
    
    nonisolated func callKitDidSetMuted(uuid: UUID, muted: Bool) async {
        await processMute(uuid: uuid, muted: muted)
    }
    
    nonisolated func callKitDidPlayDTMF(uuid: UUID, digits: String) async {
        await processDTMF(uuid: uuid, digits: digits)
    }
    
    nonisolated func callKitDidActivateAudioSession() async {
        // LiveKit handles audio session as part of call connection
    }
    
    nonisolated func callKitDidDeactivateAudioSession() async {
        // LiveKit handles audio session teardown
    }
    
    private func processAnswer(uuid: UUID) async {
        guard let provider = callKitProvider else {
            logger.warning("Answer received but CallKit not initialized: \(uuid)")
            return
        }
        guard let info = provider.callInfo(for: uuid) else {
            logger.warning("Answer received for unknown UUID: \(uuid)")
            return
        }
        
        logger.info("User answered call via CallKit: \(info.callId)")
        await _incomingCallHandler?.incomingCallAnswered(info)
    }
    
    /// Applies the mute button on the system call screen to the media room.
    /// Previously ignored, which left the microphone live while the system UI
    /// showed the call as muted. Calls reported to CallKit are incoming calls,
    /// and incoming calls (WebRTC and SIP) are owned by `CallService`.
    private func processMute(uuid: UUID, muted: Bool) async {
        guard let callId = callKitProvider?.callId(for: uuid) else {
            logger.warning("Mute received for unknown UUID: \(uuid)")
            return
        }
        do {
            try await callService?.setMuted(muted, callId: callId)
        } catch {
            logger.warning("Could not apply CallKit mute to call \(callId): \(error.localizedDescription)")
        }
    }
    
    /// Sends keypad digits entered on the system call screen (SIP calls).
    private func processDTMF(uuid: UUID, digits: String) async {
        guard let callId = callKitProvider?.callId(for: uuid) else { return }
        for digit in digits {
            do {
                try await callService?.sendDTMF(String(digit), callId: callId)
            } catch {
                logger.warning("Could not send DTMF for call \(callId): \(error.localizedDescription)")
                return
            }
        }
    }
    
    private func processEnd(uuid: UUID) async {
        guard let provider = callKitProvider else {
            logger.warning("End received but CallKit not initialized: \(uuid)")
            return
        }
        guard let info = provider.callInfo(for: uuid) else {
            logger.warning("End received for unknown UUID: \(uuid)")
            return
        }
        
        logger.info("User ended call via CallKit: \(info.callId)")
        
        let currentState = await stateStore.getCall(info.callId)?.state
        
        if currentState == .ringing {
            await _incomingCallHandler?.incomingCallDeclined(info)
        } else {
            await _incomingCallHandler?.incomingCallEnded(info)
        }
    }
}
