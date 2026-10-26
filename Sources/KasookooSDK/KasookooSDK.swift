//
//  KasookooSDK.swift
//  KasookooSDK
//
//  The public entry point for the Kasookoo iOS SDK.
//
//  This class is the only type consumers need to import directly. All other
//  public types (Participant, CallInfo, KasookooError, etc.) are reachable
//  through this class or its service properties.
//

import Foundation

/// The main entry point for the Kasookoo SDK.
///
/// ## Quick Start
///
/// ```swift
/// import KasookooSDK
///
/// // 1. Create and initialize
/// let sdk = KasookooSDK()
/// try await sdk.initialize(config: KasookooConfig(
///     publishableKey: "pk_test_xxx",
///     organizationId: "org_123",
///     environment: .production
/// ))
///
/// // 2. Connect (acquires session token)
/// try await sdk.connect()
///
/// // 3. Identify the user
/// try await sdk.identify(callerProfile: CallerProfile(
///     name: "Jane Doe",
///     email: "jane@example.com",
///     phoneNumber: "+447700900111"
/// ))
///
/// // 4. Subscribe to events
/// let token = sdk.on(EventName.callIncoming) { event in
///     print("Incoming call: \(event.string("callId") ?? "")")
/// }
///
/// // 5. Use services
/// try await sdk.call.start(params: callParams)
///
/// // 6. Cleanup
/// sdk.off(token)
/// try await sdk.disconnect()
/// ```
///
/// ## Thread Safety
///
/// All public methods are safe to call from any thread.
/// Event handlers registered via `on(_:handler:)` are invoked on the **main actor**,
/// in emission order, so they can update UI directly without dispatching.
public final class KasookooSDK: @unchecked Sendable {
    
    // MARK: - Internal State
    
    /// Assembled component graph. Set during `initialize()`.
    /// Access only via lock-protected sync helpers below.
    private var assembled: AssembledSDK?
    
    /// One consumer subscription: the bus token plus the stream that carries
    /// its events to the main actor in order.
    private struct Delivery {
        let token: EventToken
        let continuation: AsyncStream<SDKEvent>.Continuation
    }
    
    /// Active event subscriptions, keyed by token id, for `off()` and cleanup.
    private var subscriptions: [UUID: Delivery] = [:]
    
    /// Synchronous lock guarding `assembled` and `subscriptions`.
    /// IMPORTANT: This lock is ONLY used inside non-async helper methods
    /// below. Async public methods access state via these helpers, so the
    /// lock is never held across `await` suspension points.
    private let lock = NSLock()
    
    // MARK: - Init
    
    /// Creates a new SDK instance.
    ///
    /// The SDK is not usable until `initialize(config:)` and `connect()` are called.
    public init() {}
    
    deinit {
        // Best-effort cleanup if the consumer didn't call destroy(). Nothing
        // here may outlive the instance: no media room, no microphone, no
        // refresh timer.
        for (_, delivery) in subscriptions {
            delivery.continuation.finish()
        }
        if let a = assembled {
            a.eventBus.unsubscribeAll()
            Task.detached {
                await a.callService.endAll()
                await a.sipService.endAll()
                await a.sessionManager.disconnect()
                await a.notificationService.setIncomingCallHandler(nil)
                a.logger.setExport(level: .none, sink: nil)
                a.telemetry.shutdown()
            }
        }
    }
    
    // MARK: - Synchronous Lock-Protected Helpers
    //
    // These are the ONLY places where the lock is touched. All async methods
    // access shared state through these helpers, which keeps lock acquisition
    // strictly synchronous (never spanning an `await`).
    
    /// Reads the current assembled bundle. Returns nil if not initialized.
    private func readAssembled() -> AssembledSDK? {
        lock.lock()
        defer { lock.unlock() }
        return assembled
    }
    
    /// Sets the assembled bundle. Returns the previous value (for caller to clean up).
    @discardableResult
    private func writeAssembled(_ newValue: AssembledSDK?) -> AssembledSDK? {
        lock.lock()
        defer { lock.unlock() }
        let old = assembled
        assembled = newValue
        return old
    }
    
    /// Atomically sets the assembled bundle if currently nil.
    /// Returns true if the write happened, false if a bundle was already set.
    private func compareAndSetAssembled(_ newValue: AssembledSDK) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        guard assembled == nil else { return false }
        assembled = newValue
        return true
    }
    
    /// Stores a subscription.
    private func storeSubscription(_ delivery: Delivery) {
        lock.lock()
        defer { lock.unlock() }
        subscriptions[delivery.token.id] = delivery
    }
    
    /// Removes and returns a subscription.
    private func removeSubscription(id: UUID) -> Delivery? {
        lock.lock()
        defer { lock.unlock() }
        return subscriptions.removeValue(forKey: id)
    }
    
    /// Removes all subscriptions. Returns them for cleanup.
    private func clearSubscriptions() -> [Delivery] {
        lock.lock()
        defer { lock.unlock() }
        let current = Array(subscriptions.values)
        subscriptions.removeAll()
        return current
    }
    
    // MARK: - Lifecycle: Initialize
    
    /// Initializes the SDK with a configuration.
    ///
    /// This sets up all internal components but does NOT acquire a session.
    /// Call `connect()` afterwards to actually authenticate with the backend.
    ///
    /// - Parameter config: The SDK configuration.
    /// - Throws: `KasookooError.configInvalid` if the configuration is invalid.
    ///           `KasookooError` if already initialized.
    public func initialize(config: KasookooConfig) async throws {
        // Validate before any side effects
        try config.validate()
        
        // Check for double-initialization (sync, lock-safe)
        if readAssembled() != nil {
            throw KasookooError.configInvalid(
                "SDK is already initialized. Call destroy() before re-initializing."
            )
        }
        
        // Build the component graph (this is async — no lock held)
        let built = await SDKBuilder.build(config: config)
        
        // Atomic compare-and-set: only one initialize() wins if called concurrently
        let didSet = compareAndSetAssembled(built)
        guard didSet else {
            throw KasookooError.configInvalid(
                "SDK was initialized concurrently from another caller."
            )
        }
        
        // Transition state and emit ready
        await built.stateStore.setState(.initialized)
        await emitSDKEvent(
            EventName.sdkConnectionChanged,
            data: ["state": .string("initialized")]
        )
    }
    
    // MARK: - Lifecycle: Connect
    
    /// Connects to the backend by acquiring a session token.
    ///
    /// Must be called after `initialize(config:)`. Idempotent — calling
    /// connect() multiple times reuses the existing session if valid.
    ///
    /// - Throws: `KasookooError.networkUnavailable` if backend is unreachable.
    ///           `KasookooError.configInvalid` if the SDK was not initialized.
    public func connect() async throws {
        let bundle = try requireAssembled()
        
        await bundle.stateStore.setState(.connecting)
        await emitSDKEvent(
            EventName.sdkConnectionChanged,
            data: ["state": .string("connecting")]
        )
        
        do {
            try await bundle.sessionManager.connect()
        } catch {
            let sdkError = (error as? KasookooError) ?? KasookooError.unknown(underlyingError: error)
            await bundle.stateStore.setState(.error(sdkError))
            await emitSDKEvent(
                EventName.sdkError,
                data: [
                    "errorCode": .string(sdkError.code.rawValue),
                    "errorMessage": .string(sdkError.message)
                ]
            )
            await emitSDKEvent(
                EventName.sdkConnectionChanged,
                data: [
                    "state": .string("error"),
                    "errorCode": .string(sdkError.code.rawValue),
                    "errorMessage": .string(sdkError.message)
                ]
            )
            throw error
        }
        
        await bundle.stateStore.setState(.connected)
        
        // Emit sdk.ready — consumer can now use protected APIs
        await emitSDKEvent(EventName.sdkReady, data: [:])
        await emitSDKEvent(
            EventName.sdkConnectionChanged,
            data: ["state": .string("connected")]
        )
    }
    
    // MARK: - Lifecycle: Disconnect
    
    /// Disconnects from the backend.
    ///
    /// Ends any active calls (disconnecting their media rooms), revokes the
    /// session, and stops the refresh scheduler. The SDK remains initialized
    /// and can be reconnected with `connect()`.
    public func disconnect() async throws {
        let bundle = try requireAssembled()
        
        await bundle.stateStore.setState(.disconnecting)
        await emitSDKEvent(
            EventName.sdkConnectionChanged,
            data: ["state": .string("disconnecting")]
        )
        
        // Calls first, while the session is still valid, so the backend is
        // told each call ended and no LiveKit room keeps the microphone open.
        await bundle.callService.endAll()
        await bundle.sipService.endAll()
        
        // Tell SessionManager to revoke + clear
        await bundle.sessionManager.disconnect()
        
        // Clear any remaining call records (e.g. unanswered incoming calls)
        await bundle.stateStore.clearAllCalls()
        
        // Stop correlating, then export whatever the batch processors still
        // hold so a disconnect does not lose the records that explain it.
        bundle.apiClient.setCorrelationUserId(nil)
        bundle.telemetry.setUserId(nil)
        bundle.telemetry.flush()
        
        await bundle.stateStore.setState(.disconnected)
        await emitSDKEvent(
            EventName.sdkConnectionChanged,
            data: ["state": .string("disconnected")]
        )
    }
    
    // MARK: - Lifecycle: Destroy
    
    /// Fully tears down the SDK.
    ///
    /// After calling this, the SDK instance is no longer usable. Create a new
    /// `KasookooSDK()` and call `initialize(config:)` again to restart.
    public func destroy() async {
        // Atomically extract the bundle and clear our subscriptions map.
        // After this, future calls to requireAssembled() will throw.
        let bundle = writeAssembled(nil)
        let deliveries = clearSubscriptions()
        
        guard let bundle = bundle else {
            deliveries.forEach { $0.continuation.finish() }
            return
        }
        
        // End calls and the session whatever state the SDK is in. Checking
        // for `.connected` only left the refresh timer running (and minting
        // tokens) after destroy when the SDK was connecting or in error.
        await bundle.callService.endAll()
        await bundle.sipService.endAll()
        await bundle.sessionManager.disconnect()
        
        // Unsubscribe all events
        for delivery in deliveries {
            bundle.eventBus.unsubscribe(delivery.token)
            delivery.continuation.finish()
        }
        bundle.eventBus.unsubscribeAll()
        
        // Clear state
        await bundle.stateStore.reset()
        
        // Clear notification handler
        await bundle.notificationService.setIncomingCallHandler(nil)
        
        // Drop module registrations
        bundle.pushRouter.removeAll()
        bundle.container.removeAll()
        
        // Flush and stop the telemetry pipeline last, so anything emitted
        // during teardown still leaves the device.
        bundle.logger.setExport(level: .none, sink: nil)
        bundle.telemetry.shutdown()
    }
    
    // MARK: - Identity
    
    /// Identifies the current user with the backend.
    ///
    /// Creates or updates a user record by email (upsert). The profile becomes
    /// the default identity for subsequent calls and messages.
    ///
    /// - Parameter callerProfile: The user profile.
    /// - Throws: `KasookooError.configInvalid` on bad profile.
    ///           `KasookooError.networkUnavailable` on transport failure.
    public func identify(callerProfile: CallerProfile) async throws {
        try callerProfile.validate()
        let bundle = try requireAssembled()

        // One lifecycle covers the token refresh and the identify call, so both
        // carry the same `call_trace_id` into the backend's logs.
        try await TraceContext.run(.authenticationCalling) {
            let span = bundle.telemetry.startSpan(TelemetrySpan.identify)
            defer { span.end() }

            do {
                try await self.performIdentify(callerProfile: callerProfile, bundle: bundle)
                span.setAttribute(TelemetryKey.result, .string("ok"))
            } catch let error as KasookooError {
                span.setError(error.message)
                span.setAttribute(TelemetryKey.errorCode, .string(error.code.rawValue))
                bundle.telemetry.log(
                    event: error.code == .userNotFound
                        ? TelemetryEvent.userNotFound
                        : TelemetryEvent.identifyFailed,
                    message: error.message,
                    severity: .error,
                    attributes: [TelemetryKey.errorCode: .string(error.code.rawValue)]
                )
                throw error
            }
        }
    }

    private func performIdentify(callerProfile: CallerProfile, bundle: AssembledSDK) async throws {
        // The `organization_id` sent here MUST match the organization the session
        // was authenticated for (the backend returns 403 otherwise). The
        // authoritative source is the session JWT itself, so we read it from the
        // token rather than trusting a host-app configured value, falling back to
        // the configured value only if the token can't be parsed.
        let token = try await bundle.sessionManager.ensureValidToken()
        let orgId = Self.organizationId(fromJWT: token) ?? bundle.config.organizationId

        let request = IdentifyUserRequest(
            organizationId: orgId,
            profile: callerProfile
        )

        // On an unregistered user the backend returns HTTP 404 "not_found", which the
        // response decoder maps to `KasookooError.userNotFound`, so this call throws
        // before any identity is set. The app can catch `.userNotFound` to prompt
        // registration.
        let response = try await bundle.apiClient.send(
            endpoint: .identifyUser,
            body: request,
            responseType: IdentifyUserResponse.self,
            retryPolicy: .default
        )

        // A successful response with no user_id would leave the SDK in a half
        // identified state that messaging and calling cannot use, so fail cleanly
        // instead of caching an identity without an id.
        // (No email in the log line or the error: both can leave the device,
        // the error via telemetry.)
        guard let userId = response.effectiveUserId else {
            bundle.logger.warning("Identify returned no user_id")
            throw KasookooError.userNotFound(
                message: "Identify did not return a user id. The user may not be registered with this organization."
            )
        }

        // From here on every API request carries `X-User-ID`, and every span
        // and log record carries `user_id`, so backend logs in Loki and client
        // telemetry join on the same user.
        bundle.apiClient.setCorrelationUserId(userId)
        bundle.telemetry.setUserId(userId)

        // Cache email → user_id so subsequent messaging.send() can resolve emails.
        await bundle.stateStore.setIdentifiedUser(callerProfile, userId: userId)
        bundle.logger.info("User identified [userId: \(userId)]")
    }
    /// Clears the identified user.
    ///
    /// The SDK reverts to guest-mode behavior. Does not revoke the session;
    /// call `disconnect()` separately if you want to fully sign out.
    public func clearIdentity() async throws {
        let bundle = try requireAssembled()
        await bundle.stateStore.setIdentifiedUser(nil)
        bundle.apiClient.setCorrelationUserId(nil)
        bundle.telemetry.setUserId(nil)
        bundle.logger.info("Identity cleared")
    }
    
    // MARK: - State Inspection
    
    /// Returns the current SDK state.
    public func getState() async -> SDKState {
        guard let bundle = readAssembled() else {
            return .idle
        }
        return await bundle.stateStore.getState()
    }
    
    /// Returns the currently identified user, if any.
    public func getIdentifiedUser() async -> CallerProfile? {
        guard let bundle = readAssembled() else { return nil }
        return await bundle.stateStore.identifiedUser
    }
    
    // MARK: - Service Accessors
    
    /// The call service. Use for WebRTC app-to-app calls.
    ///
    /// - Returns: A `CallServicing` instance.
    /// - Throws: If the SDK is not initialized.
    public var call: CallServicing {
        get throws {
            try requireAssembled().callService
        }
    }
    
    /// The messaging service. Use for in-app messaging.
    /// Resolved from the module service container (messaging runs on the module
    /// registry); other services still come from `AssembledSDK` for now.
    public var messaging: MessagingServicing {
        get throws {
            try requireAssembled().container.resolve(MessagingServicing.self)
        }
    }
    
    /// The SIP service. Use for PSTN (regular phone number) calls.
    public var sip: SipServicing {
        get throws {
            try requireAssembled().sipService
        }
    }
    
    /// The notifications service. Use for push registration and incoming-call handling.
    public var notifications: NotificationServicing {
        get throws {
            try requireAssembled().notificationService
        }
    }
    
    // MARK: - Event Subscription (Closure Style)
    
    /// Subscribes to a specific event by name.
    ///
    /// Handlers are invoked on the **main actor**, one at a time and in the
    /// order the events were emitted, so UI updates inside the handler
    /// require no additional dispatching.
    ///
    /// The subscription is live when this method returns. Call it after
    /// `initialize(config:)`: before initialization there is nothing to
    /// subscribe to and the returned token is inert.
    ///
    /// - Parameters:
    ///   - eventName: The event name. See `EventName` for available constants.
    ///   - handler: The closure to run when the event fires.
    /// - Returns: An `EventToken` for unsubscribing via `off(_:)`.
    @discardableResult
    public func on(
        _ eventName: String,
        handler: @escaping @MainActor (SDKEvent) -> Void
    ) -> EventToken {
        guard let bundle = readAssembled() else {
            return EventToken(eventName: eventName)
        }
        
        // One stream per subscription, drained by one main-actor task. A task
        // per event (the previous approach) gave no ordering guarantee, so
        // `call.connected` could be handled before `call.ringing`.
        var capturedContinuation: AsyncStream<SDKEvent>.Continuation?
        let stream = AsyncStream<SDKEvent> { capturedContinuation = $0 }
        guard let continuation = capturedContinuation else {
            return EventToken(eventName: eventName)
        }
        
        Task { @MainActor in
            for await event in stream {
                handler(event)
            }
        }
        
        let token = bundle.eventBus.subscribe(to: eventName) { event in
            continuation.yield(event)
        }
        storeSubscription(Delivery(token: token, continuation: continuation))
        return token
    }
    
    /// Subscribes to all events. Useful for logging or analytics.
    @discardableResult
    public func onAll(handler: @escaping @MainActor (SDKEvent) -> Void) -> EventToken {
        return on(EventBus.wildcardEventName, handler: handler)
    }
    
    /// Unsubscribes a previously-registered handler. Takes effect immediately:
    /// no event emitted after this returns reaches the handler.
    public func off(_ token: EventToken) {
        guard let delivery = removeSubscription(id: token.id) else {
            return
        }
        readAssembled()?.eventBus.unsubscribe(delivery.token)
        delivery.continuation.finish()
    }
    
    // MARK: - Internal Helpers
    
    /// Returns the assembled bundle or throws if the SDK is not initialized.
    /// Synchronous — safe to call from both sync and async contexts.
    private func requireAssembled() throws -> AssembledSDK {
        guard let bundle = readAssembled() else {
            throw KasookooError.configInvalid(
                "SDK not initialized. Call initialize(config:) first."
            )
        }
        return bundle
    }
    
    /// Emits an SDK-level event.
    private func emitSDKEvent(_ name: String, data: [String: AnyCodableValue]) async {
        guard let bundle = readAssembled() else { return }
        
        let event = SDKEvent(
            name: name,
            organizationId: bundle.config.organizationId,
            userEmail: await bundle.stateStore.currentUserEmail(),
            data: data
        )
        await bundle.eventBus.emit(event)
    }
    
    // MARK: - JWT Helpers
    
    /// Extracts the `organization_id` claim from a session JWT, so `identify`
    /// sends exactly the org the session was authenticated for (avoiding the
    /// backend's 403 on a mismatch). Payload decode only, see `JWTClaims`.
    ///
    /// Returns nil if the token is malformed or has no `organization_id` claim.
    static func organizationId(fromJWT token: String) -> String? {
        return JWTClaims.string("organization_id", in: token)
    }
}
