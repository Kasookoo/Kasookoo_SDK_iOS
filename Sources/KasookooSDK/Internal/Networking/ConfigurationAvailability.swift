//
//  ConfigurationAvailability.swift
//  KasookooSDK
//
//  The per organization capability map returned by the session endpoints in the
//  `configuration_availability` block (Architecture Map §11.2 and §13.2).
//
//  Schema verified against the live backend response of
//  `POST /api/v1/sdk/auth/client-sessions` and the refresh endpoint.
//
//  This describes what the organization has actually provisioned, so the SDK can
//  enable features from the backend rather than from hard coded flags. Decoding
//  relies on the shared decoder's `.convertFromSnakeCase` strategy, so the JSON
//  keys (for example `sip_outbound`, `dispatch_rule_set`) map to the camelCase
//  properties below automatically. Every field is optional so that a missing or
//  newly added section never breaks decoding.
//

import Foundation

internal struct ConfigurationAvailability: Decodable, Sendable {

    // MARK: Sections

    internal struct SipOutbound: Decodable, Sendable {
        let configured: Bool?
        let provisioned: Bool?
    }

    internal struct SipInbound: Decodable, Sendable {
        let configured: Bool?
        let provisioned: Bool?
        let dispatchRuleSet: Bool?
    }

    internal struct ContactCenterNumber: Decodable, Sendable {
        let configured: Bool?
    }

    internal struct WhatsApp: Decodable, Sendable {
        let configured: Bool?
        let apiKeySet: Bool?
        let appSecretConfigured: Bool?
        let associatedNumbersConfigured: Bool?
    }

    internal struct SilentAuthCall: Decodable, Sendable {
        let configured: Bool?
        let confirmAllowedIpsSet: Bool?
    }

    internal struct SdkAuth: Decodable, Sendable {
        let publishableKeySet: Bool?
        let subSet: Bool?
    }

    internal struct AI: Decodable, Sendable {
        let available: Bool?
        let reason: String?
    }

    // MARK: Fields

    let sipOutbound: SipOutbound?
    let sipInbound: SipInbound?
    let contactCenterNumber: ContactCenterNumber?
    let whatsapp: WhatsApp?
    let silentAuthCall: SilentAuthCall?
    let sdkAuth: SdkAuth?
    let ai: AI?
}

// MARK: - Capability helpers

internal extension ConfigurationAvailability {

    /// SIP outbound is safe to call only when the organization has it both
    /// configured and provisioned, per the backend contract.
    var isSipOutboundAvailable: Bool {
        (sipOutbound?.configured ?? false) && (sipOutbound?.provisioned ?? false)
    }

    /// SIP inbound is available only when configured and provisioned.
    var isSipInboundAvailable: Bool {
        (sipInbound?.configured ?? false) && (sipInbound?.provisioned ?? false)
    }

    /// WhatsApp messaging is available when the organization has it configured.
    var isWhatsAppAvailable: Bool {
        whatsapp?.configured ?? false
    }

    /// Silent authentication calling is available when configured.
    var isSilentAuthCallAvailable: Bool {
        silentAuthCall?.configured ?? false
    }

    /// AI features are available when the backend reports them available.
    var isAIAvailable: Bool {
        ai?.available ?? false
    }

    /// The set of capability keys that are currently available for this
    /// organization. These match the `capabilityKey` values that feature modules
    /// declare, so a module can be gated by membership in this set.
    var availableCapabilityKeys: Set<String> {
        var keys = Set<String>()
        if isSipOutboundAvailable { keys.insert("sip_outbound") }
        if isSipInboundAvailable { keys.insert("sip_inbound") }
        if isWhatsAppAvailable { keys.insert("whatsapp") }
        if isSilentAuthCallAvailable { keys.insert("silent_auth_call") }
        if isAIAvailable { keys.insert("ai") }
        return keys
    }
}
