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
/// Implemented as an `actor` for safe concurrent access from any service.
internal actor EventBus {
    
    // MARK: - Subscription Storage
    
    private struct Subscription {
        let token: EventToken
        let handler: EventHandler
    }
    
    /// Subscriptions keyed by event name for O(1) lookup during emit.
    private var subscriptions: [String: [Subscription]] = [:]
    
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
    
    /// Subscribes to a specific event by name.
    ///
    /// - Parameters:
    ///   - eventName: The event name to subscribe to. Use constants from `EventName`.
    ///   - handler: The closure to invoke when the event fires.
    /// - Returns: A token used to unsubscribe.
    func subscribe(to eventName: String, handler: @escaping EventHandler) -> EventToken {
        let token = EventToken(eventName: eventName)
        let subscription = Subscription(token: token, handler: handler)
        subscriptions[eventName, default: []].append(subscription)
        logger.debug("Subscribed to '\(eventName)' (token: \(token.id))")
        return token
    }
    
    /// Subscribes to ALL events. Useful for logging or debugging.
    func subscribeToAll(handler: @escaping EventHandler) -> EventToken {
        return subscribe(to: WildcardEventName, handler: handler)
    }
    
    // MARK: - Unsubscribe
    
    /// Removes a subscription identified by its token.
    func unsubscribe(_ token: EventToken) {
        guard var list = subscriptions[token.eventName] else { return }
        list.removeAll { $0.token == token }
        if list.isEmpty {
            subscriptions.removeValue(forKey: token.eventName)
        } else {
            subscriptions[token.eventName] = list
        }
        logger.debug("Unsubscribed token: \(token.id)")
    }
    
    /// Removes all subscriptions. Called during SDK shutdown.
    func unsubscribeAll() {
        subscriptions.removeAll()
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
        
        // Notify name-specific subscribers
        if let handlers = subscriptions[event.name] {
            for sub in handlers {
                sub.handler(event)
            }
        }
        
        // Notify wildcard subscribers
        if let wildcardHandlers = subscriptions[WildcardEventName] {
            for sub in wildcardHandlers {
                sub.handler(event)
            }
        }
    }
}

// MARK: - Wildcard Constant

/// Internal sentinel value for wildcard subscriptions.
private let WildcardEventName = "__kasookoo.wildcard__"
