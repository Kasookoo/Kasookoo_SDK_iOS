//
//  CallStateMachineTests.swift
//  KasookooSDKTests
//

import Foundation
import Testing
@testable import KasookooSDK

@Suite struct CallStateMachineTests {
    
    @Test func normalLifecycle() {
        #expect(CallStateMachine.canTransition(from: .initiating, to: .ringing))
        #expect(CallStateMachine.canTransition(from: .ringing, to: .connecting))
        #expect(CallStateMachine.canTransition(from: .connecting, to: .connected))
        #expect(CallStateMachine.canTransition(from: .connected, to: .ending))
        #expect(CallStateMachine.canTransition(from: .ending, to: .ended))
    }
    
    @Test func terminalStatesAreFinal() {
        for terminal in [CallState.ended, .failed, .rejected, .missed] {
            #expect(!CallStateMachine.canTransition(from: terminal, to: .connected))
            #expect(!CallStateMachine.canTransition(from: terminal, to: .ringing))
        }
    }
    
    @Test func invalidTransitionThrows() {
        #expect(throws: KasookooError.self) {
            try CallStateMachine.validateTransition(from: .connected, to: .ringing)
        }
    }
}

@Suite struct EventBusTests {
    
    /// Collects events from a `@Sendable` handler.
    private final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String] = []
        func add(_ name: String) { lock.lock(); names.append(name); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return names }
    }
    
    @Test("A subscription is live as soon as subscribe returns")
    func subscribeIsSynchronous() async {
        let bus = EventBus(logger: testLogger)
        let collector = Collector()
        let token = bus.subscribe(to: EventName.callRinging) { collector.add($0.name) }
        
        await bus.emit(SDKEvent(name: EventName.callRinging, organizationId: "org"))
        bus.unsubscribe(token)
        await bus.emit(SDKEvent(name: EventName.callRinging, organizationId: "org"))
        
        #expect(collector.all == [EventName.callRinging])
    }
    
    @Test("Wildcard subscribers receive every event in order")
    func wildcardOrder() async {
        let bus = EventBus(logger: testLogger)
        let collector = Collector()
        bus.subscribeToAll { collector.add($0.name) }
        
        await bus.emit(SDKEvent(name: EventName.callRinging, organizationId: "org"))
        await bus.emit(SDKEvent(name: EventName.callConnected, organizationId: "org"))
        await bus.emit(SDKEvent(name: EventName.callEnded, organizationId: "org"))
        
        #expect(collector.all == [EventName.callRinging, EventName.callConnected, EventName.callEnded])
    }
}
