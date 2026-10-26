//
//  EventBus.swift
//  KasookooSDK
//
//

import Foundation
import Combine

/// A type-erased handler for SDK events.
internal typealias EventHandler = @Sendable (SDKEvent) -> Void

/// Thread-safe event distribution hub.
///
/// Services publish events here; the public `KasookooSDK` facade subscribes
/// and delivers them to consumer handlers on the main thread.
///
/// Emission is actor-isolated, so events from all services are delivered one
/// at a time and in order. Subscription is synchronous (`nonisolated`, guarded
/// by a lock): a handler registered by `sdk.on(...)` is live before `on(...)`
/// returns, so an event emitted right afterwards cannot be missed, and an
/// `off(...)` can never race the registration it cancels.
internal actor EventBus {
    
    // MARK: - Subscription Storage
    
    private struct Subscription {
        let token: EventToken
        let handler: EventHandler
    }
    
    /// Lock-protected subscription table, keyed by event name for O(1)
    /// lookup during emit. The lock is only ever held for synchronous
    /// dictionary work, never across an `await` or a handler call.
    private final class Registry: @unchecked Sendable {
        private let lock = NSLock()
        private var subscriptions: [String: [Subscription]] = [:]
        
        func add(_ subscription: Subscription) {
            lock.lock()
            defer { lock.unlock() }
            subscriptions[subscription.token.eventName, default: []].append(subscription)
        }
        
        func remove(_ token: EventToken) {
            lock.lock()
            defer { lock.unlock() }
            guard var list = subscriptions[token.eventName] else { return }
            list.removeAll { $0.token == token }
            if list.isEmpty {
                subscriptions.removeValue(forKey: token.eventName)
            } else {
                subscriptions[token.eventName] = list
            }
        }
        
        func removeAll() {
            lock.lock()
            defer { lock.unlock() }
            subscriptions.removeAll()
        }
        
        func handlers(for eventName: String) -> [EventHandler] {
            lock.lock()
            defer { lock.unlock() }
            return subscriptions[eventName]?.map { $0.handler } ?? []
        }
    }
    
    private let registry = Registry()
    
    /// Combine subject for consumers who prefer reactive streams.
    ///
    /// Marked `nonisolated(unsafe)` because:
    /// 1. `PassthroughSubject` is internally thread-safe per Combine's contract
    /// 2. It's a `let` constant — the reference itself never changes
    /// 3. `send()` and `eraseToAnyPublisher()` are safe to call from any context
    /// This is the standard pattern for bridging Combine with Swift actors.
    nonisolated(unsafe) private let subject = PassthroughSubject<SDKEvent, Never>()
    
    // MARK: - Logger
    
    private let logger: Logger
    
    // MARK: - Init
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    // MARK: - Public Subject Access
    
    /// A Combine publisher for all events.
    /// Subscribe via `eventBus.publisher.sink { event in ... }`.
    nonisolated var publisher: AnyPublisher<SDKEvent, Never> {
        return subject.eraseToAnyPublisher()
    }
    
    // MARK: - Subscribe
    
    /// Subscribes to a specific event by name. Synchronous: the handler is
    /// registered when this returns.
    ///
    /// - Parameters:
    ///   - eventName: The event name to subscribe to. Use constants from `EventName`.
    ///   - handler: The closure to invoke when the event fires.
    /// - Returns: A token used to unsubscribe.
    @discardableResult
    nonisolated func subscribe(to eventName: String, handler: @escaping EventHandler) -> EventToken {
        let token = EventToken(eventName: eventName)
        registry.add(Subscription(token: token, handler: handler))
        logger.debug("Subscribed to '\(eventName)' (token: \(token.id))")
        return token
    }
    
    /// Subscribes to ALL events. Useful for logging or debugging.
    @discardableResult
    nonisolated func subscribeToAll(handler: @escaping EventHandler) -> EventToken {
        return subscribe(to: EventBus.wildcardEventName, handler: handler)
    }
    
    // MARK: - Unsubscribe
    
    /// Removes a subscription identified by its token.
    nonisolated func unsubscribe(_ token: EventToken) {
        registry.remove(token)
        logger.debug("Unsubscribed token: \(token.id)")
    }
    
    /// Removes all subscriptions. Called during SDK shutdown.
    nonisolated func unsubscribeAll() {
        registry.removeAll()
        logger.debug("All event subscriptions cleared")
    }
    
    // MARK: - Emit
    
    /// Emits an event to all matching subscribers.
    /// Handlers run sequentially on this actor's executor; the public facade
    /// is responsible for hopping to MainActor before invoking consumer code.
    func emit(_ event: SDKEvent) {
        logger.debug("Emitting '\(event.name)' (eventId: \(event.eventId))")
        
        // Notify Combine subscribers
        subject.send(event)
        
        // Name-specific subscribers, then wildcard subscribers. Handlers are
        // snapshotted first so none runs while the registry lock is held.
        for handler in registry.handlers(for: event.name) {
            handler(event)
        }
        for handler in registry.handlers(for: EventBus.wildcardEventName) {
            handler(event)
        }
    }
    
    // MARK: - Wildcard Constant
    
    /// Internal sentinel value for wildcard subscriptions.
    static let wildcardEventName = "__kasookoo.wildcard__"
}
