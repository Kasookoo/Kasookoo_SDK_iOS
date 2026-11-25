//
//  CallControlTests.swift
//  KasookooSDKTests
//
//  KSA-327 (status events), KSA-328 (control validation), KSA-278 (profile
//  validation). The LiveKit and AVAudioSession parts (hold, audio routes)
//  need a device and are covered by manual testing.
//

import Foundation
import Testing
@testable import KasookooSDK

@Suite struct CallStatusEventTests {

    @Test("Connecting now emits call.connecting")
    func connectingEmitsEvent() {
        #expect(CallStateMachine.eventName(for: .connecting) == EventName.callConnecting)
        #expect(CallStateMachine.eventName(for: .initiating) == nil)
        #expect(CallStateMachine.eventName(for: .ending) == nil)
    }

    @Test("New event names are listed in allEventNames")
    func newEventsRegistered() {
        for name in [
            EventName.callConnecting, EventName.callMuted, EventName.callUnmuted,
            EventName.callHeld, EventName.callResumed, EventName.audioRouteChanged
        ] {
            #expect(EventName.allEventNames.contains(name))
        }
    }

    @Test("Route event data carries id, name and kind when known")
    func routeEventData() {
        let route = AudioRoute(id: "AA:BB-tsco", name: "AirPods", kind: .bluetooth, isActive: true)
        let data = CallControlValidation.routeEventData(route, isSip: false)
        #expect(data["routeId"] != nil)
        #expect(data["routeName"] != nil)
        #expect(data["routeKind"] != nil)

        let unknown = CallControlValidation.routeEventData(nil, isSip: true)
        #expect(unknown["routeId"] == nil)
        #expect(unknown["isSip"] != nil)
    }
}

@Suite struct CallControlValidationTests {

    @Test("Hold and DTMF are only allowed when connected")
    func connectedOnly() {
        #expect(CallControlValidation.connectedOnly == [.connected])
        #expect(!CallControlValidation.connectedOnly.contains(.ringing))
    }

    @Test("Audio controls work before the call connects")
    func audioStates() {
        for state in [CallState.initiating, .ringing, .connecting, .connected] {
            #expect(CallControlValidation.audioStates.contains(state))
        }
        for state in [CallState.ending, .ended, .failed, .rejected, .missed] {
            #expect(!CallControlValidation.audioStates.contains(state))
        }
    }

    @Test("Errors say which action, which call and why")
    func errorDetails() {
        let unknown = CallControlValidation.unknownCall(callId: "c1", action: "hold")
        #expect(unknown.code == .callFailed)
        #expect(unknown.details?["reason"] == "unknown_call")
        #expect(unknown.details?["action"] == "hold")
        #expect(unknown.details?["callId"] == "c1")

        let invalid = CallControlValidation.invalidState(callId: "c1", action: "dtmf", state: .ringing)
        #expect(invalid.details?["reason"] == "invalid_state")
        #expect(invalid.details?["state"] == "ringing")
        #expect(invalid.retryable == false)
    }
}

@Suite struct CallerProfileValidationTests {

    private func profile(name: String = "Alex Rivera",
                         email: String = "alex@example.com",
                         phone: String = "") -> CallerProfile {
        CallerProfile(name: name, email: email, phoneNumber: phone, type: .customer)
    }

    @Test("A normal profile passes, with or without a phone number")
    func validProfiles() throws {
        try profile().validate()
        try profile(phone: "+44 1234 567890").validate()
        try profile(phone: "0300-1234567").validate()
        try profile(phone: "(555) 123.4567").validate()
    }

    @Test("A phone number that is not one is rejected")
    func badPhone() {
        for phone in ["abc", "12345", "+1234567890123456", "N/A"] {
            #expect(throws: KasookooError.self) { try profile(phone: phone).validate() }
        }
    }

    @Test("Spaces around the email are rejected")
    func emailWithSpaces() {
        #expect(throws: KasookooError.self) { try profile(email: " alex@example.com").validate() }
        #expect(throws: KasookooError.self) { try profile(email: "alex@example.com ").validate() }
    }

    @Test("All bad fields are reported together")
    func reportsEveryField() {
        do {
            try profile(name: "", email: "nope", phone: "x").validate()
            Issue.record("Expected validation to fail")
        } catch let error as KasookooError {
            #expect(error.code == .configInvalid)
            #expect(error.details?["name"] != nil)
            #expect(error.details?["email"] != nil)
            #expect(error.details?["phoneNumber"] != nil)
        } catch {
            Issue.record("Unexpected error \(error)")
        }
    }

    @Test("Overlong names are rejected")
    func longName() {
        let long = String(repeating: "a", count: CallerProfile.maxNameLength + 1)
        #expect(throws: KasookooError.self) { try profile(name: long).validate() }
    }
}
