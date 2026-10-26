//
//  CallKitProvider.swift
//  KasookooSDK
//
//

import Foundation
import CallKit
import AVFoundation

// MARK: - Delegate Protocol

/// Internal delegate for CallKit user actions.
/// `NotificationService` implements this to receive CallKit callbacks.
internal protocol CallKitProviderDelegate: AnyObject, Sendable {
    func callKitDidAnswerCall(uuid: UUID) async
    func callKitDidEndCall(uuid: UUID) async
    func callKitDidSetMuted(uuid: UUID, muted: Bool) async
    func callKitDidPlayDTMF(uuid: UUID, digits: String) async
    func callKitDidActivateAudioSession() async
    func callKitDidDeactivateAudioSession() async
}

// MARK: - CallKit Provider

/// Wraps `CXProvider` to manage incoming-call UI and bridge user actions.
internal final class CallKitProvider: NSObject, @unchecked Sendable {
    
    // MARK: - Properties
    
    private let provider: CXProvider
    private let callController: CXCallController
    private let logger: Logger
    
    /// Lock protecting all mutable state.
    /// IMPORTANT: This lock is ONLY accessed via synchronous helper methods
    /// below. Async methods call those helpers; the lock never spans an `await`.
    private let lock = NSLock()
    
    private var callIdToUUID: [String: UUID] = [:]
    private var uuidToCallId: [UUID: String] = [:]
    private var callInfoByUUID: [UUID: IncomingCallInfo] = [:]
    private weak var delegate: CallKitProviderDelegate?
    
    // MARK: - Init
    
    init(appName: String, logger: Logger) {
        self.logger = logger
        
        let configuration = CXProviderConfiguration()
        configuration.supportsVideo = false
        configuration.supportedHandleTypes = [.phoneNumber, .emailAddress, .generic]
        configuration.maximumCallGroups = 1
        configuration.maximumCallsPerCallGroup = 1
        
        self.provider = CXProvider(configuration: configuration)
        self.callController = CXCallController()
        
        super.init()
        
        // CallKit invokes delegate methods on the main queue by default (queue: nil)
        provider.setDelegate(self, queue: nil)
        logger.info("CallKit provider initialized for app: \(appName)")
    }
    
    // MARK: - Synchronous Lock-Protected Helpers
    //
    // These are the ONLY places where the lock is touched. All public/internal
    // methods (including async ones) access shared state through these helpers,
    // so the lock is never held across `await`.
    
    private func storeMappings(callId: String, uuid: UUID, info: IncomingCallInfo) {
        lock.lock()
        defer { lock.unlock() }
        callIdToUUID[callId] = uuid
        uuidToCallId[uuid] = callId
        callInfoByUUID[uuid] = info
    }
    
    private func uuidForCallId(_ callId: String) -> UUID? {
        lock.lock()
        defer { lock.unlock() }
        return callIdToUUID[callId]
    }
    
    private func callInfoForUUID(_ uuid: UUID) -> IncomingCallInfo? {
        lock.lock()
        defer { lock.unlock() }
        return callInfoByUUID[uuid]
    }
    
    private func callIdForUUID(_ uuid: UUID) -> String? {
        lock.lock()
        defer { lock.unlock() }
        return uuidToCallId[uuid]
    }
    
    private func removeMapping(uuid: UUID) {
        lock.lock()
        defer { lock.unlock() }
        if let callId = uuidToCallId[uuid] {
            callIdToUUID.removeValue(forKey: callId)
        }
        uuidToCallId.removeValue(forKey: uuid)
        callInfoByUUID.removeValue(forKey: uuid)
    }
    
    private func clearAllMappings() {
        lock.lock()
        defer { lock.unlock() }
        callIdToUUID.removeAll()
        uuidToCallId.removeAll()
        callInfoByUUID.removeAll()
    }
    
    private func setDelegateInternal(_ delegate: CallKitProviderDelegate?) {
        lock.lock()
        defer { lock.unlock() }
        self.delegate = delegate
    }
    
    private func currentDelegate() -> CallKitProviderDelegate? {
        lock.lock()
        defer { lock.unlock() }
        return delegate
    }
    
    // MARK: - Public API
    
    /// Sets the delegate that receives CallKit user actions.
    /// Synchronous; safe to call from any context including actors.
    func setDelegate(_ delegate: CallKitProviderDelegate) {
        setDelegateInternal(delegate)
    }
    
    /// Returns the IncomingCallInfo for a UUID, if known.
    /// Synchronous; safe to call from any context.
    func callInfo(for uuid: UUID) -> IncomingCallInfo? {
        return callInfoForUUID(uuid)
    }
    
    /// Returns the SDK call ID for a UUID, if known.
    func callId(for uuid: UUID) -> String? {
        return callIdForUUID(uuid)
    }
    
    /// Whether a call with this SDK id has already been reported to CallKit.
    /// Used to de-duplicate a call that arrives over both FCM and PushKit.
    func isReported(callId: String) -> Bool {
        return uuidForCallId(callId) != nil
    }
    
    // MARK: - Report Incoming Call
    
    /// Reports an incoming call to CallKit. iOS displays the native incoming-call UI.
    /// MUST be called within 5 seconds of a VoIP push.
    func reportIncomingCall(_ info: IncomingCallInfo) async throws {
        let uuid = UUID()
        
        // Save mappings via sync helper (lock contained inside)
        storeMappings(callId: info.callId, uuid: uuid, info: info)
        
        let update = CXCallUpdate()
        update.remoteHandle = handleForCaller(info.caller)
        update.localizedCallerName = info.displayName
        update.hasVideo = false
        update.supportsDTMF = info.isSipCall
        // Hold is not implemented (no CXSetHeldCallAction handling and no
        // LiveKit-side hold), so it is not advertised.
        update.supportsHolding = false
        update.supportsGrouping = false
        update.supportsUngrouping = false
        
        logger.info("Reporting incoming call to CallKit: \(info.callId)")
        
        do {
            try await provider.reportNewIncomingCall(with: uuid, update: update)
        } catch {
            // Rejected by the system (Do Not Disturb, blocked caller, duplicate
            // UUID…). Forget the mapping so a later push can report again.
            removeMapping(uuid: uuid)
            throw error
        }
    }
    
    /// Reports a call and ends it at once.
    ///
    /// Since iOS 13 every PushKit VoIP push must result in a call being
    /// reported to CallKit, or the system terminates the app and eventually
    /// stops delivering VoIP pushes to it. A VoIP push that is not an incoming
    /// call (a cancellation, an unrecognised payload) is satisfied this way.
    func reportPlaceholderCallAndEnd() async {
        let uuid = UUID()
        let update = CXCallUpdate()
        update.remoteHandle = CXHandle(type: .generic, value: "Call ended")
        update.localizedCallerName = "Call ended"
        update.hasVideo = false
        do {
            try await provider.reportNewIncomingCall(with: uuid, update: update)
        } catch {
            logger.debug("Placeholder call not reported: \(error.localizedDescription)")
            return
        }
        provider.reportCall(with: uuid, endedAt: Date(), reason: .remoteEnded)
    }
    
    /// Reports that a previously-reported incoming call was cancelled.
    ///
    /// Called for every way a call can end outside CallKit (remote hang-up,
    /// failure, cancellation push, the host app's own end button), so the
    /// system call UI never outlives the call. A call the user already ended
    /// from the CallKit UI has no mapping any more and is ignored.
    func reportCallEnded(callId: String, reason: CXCallEndedReason) {
        guard let uuid = uuidForCallId(callId) else {
            logger.debug("reportCallEnded: no CallKit call for \(callId)")
            return
        }
        
        logger.info("Reporting call ended to CallKit: \(callId), reason: \(reason.rawValue)")
        provider.reportCall(with: uuid, endedAt: Date(), reason: reason)
        
        removeMapping(uuid: uuid)
    }
    
    // MARK: - Helpers
    
    private func handleForCaller(_ caller: Participant) -> CXHandle {
        if !caller.phoneNumber.isEmpty {
            return CXHandle(type: .phoneNumber, value: caller.phoneNumber)
        }
        if !caller.email.isEmpty {
            return CXHandle(type: .emailAddress, value: caller.email)
        }
        return CXHandle(type: .generic, value: caller.name)
    }
}

// MARK: - CXProviderDelegate

extension CallKitProvider: CXProviderDelegate {
    
    func providerDidReset(_ provider: CXProvider) {
        logger.warning("CallKit provider reset")
        clearAllMappings()
    }
    
    func provider(_ provider: CXProvider, perform action: CXAnswerCallAction) {
        // Extract Sendable value synchronously
        let uuid: UUID = action.callUUID
        
        // Fulfill synchronously (required: CallKit has tight timing)
        action.fulfill()
        
        logger.info("CallKit: user answered call \(uuid)")
        
        // Notify delegate via detached Task with only Sendable UUID
        let del = currentDelegate()
        Task {
            await del?.callKitDidAnswerCall(uuid: uuid)
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXEndCallAction) {
        let uuid: UUID = action.callUUID
        action.fulfill()
        
        logger.info("CallKit: user ended call \(uuid)")
        
        let del = currentDelegate()
        Task {
            await del?.callKitDidEndCall(uuid: uuid)
        }
        
        removeMapping(uuid: uuid)
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetMutedCallAction) {
        let uuid: UUID = action.callUUID
        let muted = action.isMuted
        action.fulfill()
        
        logger.info("CallKit: user \(muted ? "muted" : "unmuted") call \(uuid)")
        
        let del = currentDelegate()
        Task {
            await del?.callKitDidSetMuted(uuid: uuid, muted: muted)
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXPlayDTMFCallAction) {
        let uuid: UUID = action.callUUID
        let digits = action.digits
        action.fulfill()
        
        let del = currentDelegate()
        Task {
            await del?.callKitDidPlayDTMF(uuid: uuid, digits: digits)
        }
    }
    
    func provider(_ provider: CXProvider, perform action: CXSetHeldCallAction) {
        // Hold is not supported (see `supportsHolding`).
        action.fail()
    }
    
    func provider(_ provider: CXProvider, didActivate audioSession: AVAudioSession) {
        logger.debug("CallKit: audio session activated")
        let del = currentDelegate()
        Task {
            await del?.callKitDidActivateAudioSession()
        }
    }
    
    func provider(_ provider: CXProvider, didDeactivate audioSession: AVAudioSession) {
        logger.debug("CallKit: audio session deactivated")
        let del = currentDelegate()
        Task {
            await del?.callKitDidDeactivateAudioSession()
        }
    }
}
