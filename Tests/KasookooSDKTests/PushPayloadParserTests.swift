//
//  PushPayloadParserTests.swift
//  KasookooSDKTests
//

import Testing
@testable import KasookooSDK

@Suite struct PushPayloadParserTests {
    
    private let parser = PushPayloadParser(logger: testLogger)
    
    @Test("FCM-wrapped incoming call carries the media credentials")
    func incomingCall() {
        let payload = PushPayload(values: [
            "aps": .dictionary([:]),
            "data": .dictionary([
                "action": .string("incoming_call"),
                "room_name": .string("call_room_1"),
                "participant_identity_name": .string("John"),
                "participant_identity_type": .string("driver"),
                "accessToken": .string("lk_token"),
                "wsUrl": .string("https://livekit.test")
            ])
        ])
        
        guard case .incomingCall(let info) = parser.parse(payload) else {
            Issue.record("Expected an incoming call")
            return
        }
        #expect(info.callId == "call_room_1")
        #expect(info.caller.name == "John")
        #expect(info.caller.type == .driver)
        #expect(info.accessToken == "lk_token")
        // https is normalised to wss for LiveKit.
        #expect(info.wsUrl == "wss://livekit.test")
    }
    
    @Test("Every call-over action maps to a cancellation")
    func callOver() {
        for action in ["call_cancelled", "cancel_call", "end_call", "reject_call", "caller_end_call"] {
            let payload = PushPayload(values: ["action": .string(action), "room_name": .string("r1")])
            guard case .callCancelled(let callId) = parser.parse(payload) else {
                Issue.record("\(action) should parse as a cancellation")
                continue
            }
            #expect(callId == "r1")
        }
    }
    
    @Test("A foreign push is generic, not a call")
    func foreignPush() {
        let payload = PushPayload(values: ["aps": .dictionary([:]), "promo": .string("sale")])
        guard case .generic = parser.parse(payload) else {
            Issue.record("Expected a generic push")
            return
        }
    }
}
