//
//  SDKModule.swift
//  KasookooSDK
//
//  The contract every SDK feature implements so the core never changes when a
//  module is added (Architecture Map §14, seams #1 and #6).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS
//  ─────────────────────────────────────────────────────────────────────────────
//  A module is the unit of extensibility: calling, SIP, messaging today, and
//  WhatsApp / recording / CDR / AI tomorrow. Each conforms to `SDKModule`, is
//  added to one list, and wires itself up via `configure`. Adding a feature is
//  then a conformance + one line — no edits to the builder, facade, or any enum.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  LIFECYCLE ONLY (interface segregation)
//  ─────────────────────────────────────────────────────────────────────────────
//  This protocol is intentionally about lifecycle only. Push handling is a
//  SEPARATE, opt-in protocol added in the next step (the push router), so a module
//  that never receives a push carries no push code. Likewise, capability gating is
//  expressed by one property, not baked into behaviour.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  ADDITIVE
//  ─────────────────────────────────────────────────────────────────────────────
//  Nothing conforms to this yet. The SDK still assembles services directly via
//  `SDKBuilder`. Modules adopt it one at a time in later steps; existing
//  behaviour is unchanged.
//

import Foundation

/// A self-contained SDK feature module.
internal protocol SDKModule: Sendable {

    /// Stable identifier, e.g. "calling", "sip", "messaging". Used in logs and to
    /// deduplicate registrations.
    var id: String { get }

    /// The `configuration_availability` key that gates this module for an
    /// organization (e.g. "sip_outbound", "whatsapp"). `nil` means always
    /// available. At connect time the SDK enables a module only when the org has
    /// actually provisioned its capability (Map §11.2 / §13.2), so a bank that
    /// never bought SIP simply never gets the SIP module — no per-app flags.
    var capabilityKey: String? { get }

    /// Build and register the module's service(s) using shared infrastructure.
    /// Called once during SDK initialization. The module creates its service and
    /// registers it via `context.registry`.
    func configure(_ context: ModuleContext) async

    /// Called after the session connects. Optional (default: no-op).
    func start() async

    /// Called on disconnect / teardown. Optional (default: no-op).
    func stop() async
}

// MARK: - Defaults — a module implements only what it needs

internal extension SDKModule {
    var capabilityKey: String? { nil }
    func start() async {}
    func stop() async {}
}
