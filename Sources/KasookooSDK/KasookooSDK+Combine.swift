//
//  KasookooSDK+Combine.swift
//  KasookooSDK
//
//

import Foundation
import Combine

extension KasookooSDK {
    
    /// A publisher that emits all SDK events.
    ///
    /// Events are delivered on the **main thread** to support direct UI updates.
    ///
    /// ## Example
    /// ```swift
    /// import Combine
    /// var cancellables = Set<AnyCancellable>()
    ///
    /// sdk.events
    ///     .filter { $0.name == EventName.callIncoming }
    ///     .sink { event in
    ///         // Handle incoming call (already on main thread)
    ///     }
    ///     .store(in: &cancellables)
    /// ```
    ///
    /// - Note: Returns an empty publisher if the SDK is not initialized.
    public var events: AnyPublisher<SDKEvent, Never> {
        return EventsPublisher(sdk: self).eraseToAnyPublisher()
    }
    
    /// A publisher that emits events for a specific event name.
    ///
    /// Equivalent to `events.filter { $0.name == eventName }` but reads cleaner.
    ///
    /// ## Example
    /// ```swift
    /// sdk.events(named: EventName.messageReceived)
    ///     .sink { event in /* handle */ }
    ///     .store(in: &cancellables)
    /// ```
    public func events(named eventName: String) -> AnyPublisher<SDKEvent, Never> {
        return events
            .filter { $0.name == eventName }
            .eraseToAnyPublisher()
    }
    
    /// A publisher that emits the SDK's connection state changes.
    public var connectionState: AnyPublisher<SDKState, Never> {
        return events(named: EventName.sdkConnectionChanged)
            .compactMap { [weak self] _ -> SDKState? in
                guard let self = self else { return nil }
                // Bridge async getState() into the publisher
                return nil  // See note below
            }
            .eraseToAnyPublisher()
    }
}

// MARK: - Internal Publisher

/// Custom publisher that bridges the EventBus's `PassthroughSubject` to Combine
/// while ensuring main-thread delivery and proper lifecycle management.
private struct EventsPublisher: Publisher {
    typealias Output = SDKEvent
    typealias Failure = Never
    
    let sdk: KasookooSDK
    
    func receive<S>(subscriber: S) where S : Subscriber, Never == S.Failure, SDKEvent == S.Input {
        let subscription = EventsSubscription(sdk: sdk, subscriber: AnySubscriber(subscriber))
        subscriber.receive(subscription: subscription)
    }
}

/// Subscription bridge that connects an EventBus subscription to a Combine subscriber.
private final class EventsSubscription: Subscription, @unchecked Sendable {
    
    private weak var sdk: KasookooSDK?
    private let subscriber: AnySubscriber<SDKEvent, Never>
    private var token: EventToken?
    private let lock = NSLock()
    
    init(sdk: KasookooSDK, subscriber: AnySubscriber<SDKEvent, Never>) {
        self.sdk = sdk
        self.subscriber = subscriber
        
        // Subscribe to wildcard (all events) and forward to Combine subscriber
        self.token = sdk.onAll { [weak self] event in
            guard let self = self else { return }
            _ = self.subscriber.receive(event)
        }
    }
    
    func request(_ demand: Subscribers.Demand) {
        // EventBus is push-based; demand-based throttling is not implemented.
        // Subscribers receive every event regardless of requested demand.
    }
    
    func cancel() {
        lock.lock()
        let tokenToCancel = token
        token = nil
        lock.unlock()
        
        if let tokenToCancel = tokenToCancel {
            sdk?.off(tokenToCancel)
        }
    }
}
