//
//  KasookooSDKTests.swift
//  KasookooSDKTests
//

import Foundation
import Testing
@testable import KasookooSDK

@Suite struct ConfigurationTests {
    
    @Test func validConfigurationPasses() throws {
        try testConfig.validate()
    }
    
    @Test func rejectsMissingOrMalformedKey() {
        #expect(throws: KasookooError.self) {
            try KasookooConfig(publishableKey: "", organizationId: "org", environment: .staging).validate()
        }
        #expect(throws: KasookooError.self) {
            try KasookooConfig(publishableKey: "sk_live_x", organizationId: "org", environment: .staging).validate()
        }
        #expect(throws: KasookooError.self) {
            try KasookooConfig(publishableKey: "pk_test_x", organizationId: "org", environment: .production).validate()
        }
    }
    
    @Test func readsOrganizationIdFromJWT() {
        let token = makeJWT(["organization_id": "org_from_token"])
        #expect(KasookooSDK.organizationId(fromJWT: token) == "org_from_token")
        #expect(KasookooSDK.organizationId(fromJWT: "not-a-jwt") == nil)
    }
}
