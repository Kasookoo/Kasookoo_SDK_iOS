//
//  TelemetryRedactionTests.swift
//  KasookooSDKTests
//

import Testing
@testable import KasookooSDK

@Suite struct TelemetryRedactionTests {
    
    @Test("Identifiers inside a sentence are redacted")
    func embeddedIdentifiers() {
        let email = TelemetryRedaction.sanitize(text: "Identify failed for jane.doe@example.com today")
        #expect(!email.contains("@"))
        
        let phone = TelemetryRedaction.sanitize(text: "Dialing +44 7700 900111 failed")
        #expect(!phone.contains("7700"))
        
        let jwt = TelemetryRedaction.sanitize(text: "token eyJhbGciOi.eyJzdWIiOiIx.c2lnbmF0dXJl rejected")
        #expect(!jwt.contains("eyJ"))
    }
    
    @Test("Ordinary numbers and dates are kept")
    func ordinaryTextKept() {
        let text = "HTTP 504 after 10000 ms on 2026-09-25"
        #expect(TelemetryRedaction.sanitize(text: text) == text)
    }
    
    @Test("Sensitive keys are dropped, safe ones kept")
    func keyFilter() {
        let result = TelemetryRedaction.sanitize([
            "callee_email": .string("a@b.co"),
            "access_token": .string("x"),
            "error_code": .string("CALL_FAILED"),
            "room_name": .string("room_1")
        ])
        #expect(result["callee_email"] == nil)
        #expect(result["access_token"] == nil)
        #expect(result["error_code"] == .string("CALL_FAILED"))
        #expect(result["room_name"] == .string("room_1"))
    }
}
