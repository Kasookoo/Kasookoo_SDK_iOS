//
//  ModuleContext.swift
//  KasookooSDK
//
//  The shared infrastructure handed to every module at configuration time
//  (Architecture Map §14, seam #6).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS
//  ─────────────────────────────────────────────────────────────────────────────
//  Every service today is constructed with the SAME five dependencies
//  (apiClient, stateStore, eventBus, logger, config). `SDKBuilder` passes them by
//  hand to each service. A single `ModuleContext` bundles that shared infra so a
//  module receives one value — the builder no longer needs to know each service's
//  constructor, which is what lets new modules slot in without editing it.
//
//  A module also gets `registry` (the REGISTERING face only) so it can register
//  its own service. It deliberately cannot RESOLVE — no peer-module lookups; see
//  ServiceContainer.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  TRANSITIONAL
//  ─────────────────────────────────────────────────────────────────────────────
//  Additive. Not yet constructed or passed anywhere. `SDKBuilder` still wires
//  services with individual arguments. All members are `Sendable`, so the context
//  is `Sendable` and safe to hand to modules across concurrency domains.
//

import Foundation

internal struct ModuleContext: Sendable {

    /// The immutable SDK configuration for this instance.
    let config: KasookooConfig

    /// Shared logger.
    let logger: Logger

    /// Shared event bus — modules emit their own events here.
    let eventBus: EventBus

    /// Shared runtime state (identity/session-level). Module-specific state
    /// should live in the module itself (Map §14.3), not here.
    let stateStore: StateStore

    /// Shared HTTP client. Modules send their own `APIRequest`s through it.
    let apiClient: ApiClient

    /// Session/token lifecycle. Needed by modules that must read the session
    /// (e.g. resolve the authenticated org id from the JWT).
    let sessionManager: SessionManager

    /// Registration face of the service graph — a module registers its own
    /// service(s) here during `configure`. Cannot resolve peers (by design).
    let registry: any ServiceRegistering

    /// Traces and structured logs exported to the observability stack.
    ///
    /// Cross-cutting infrastructure like the logger, not a feature module, so it
    /// is handed to every module rather than resolved from the container. Every
    /// call is fire and forget and never throws, so instrumentation cannot
    /// change what a module does.
    ///
    /// Defaults to `NoopTelemetry()` so a caller that has not been wired up yet
    /// still compiles and simply reports nothing.
    let telemetry: TelemetryReporting

    init(
        config: KasookooConfig,
        logger: Logger,
        eventBus: EventBus,
        stateStore: StateStore,
        apiClient: ApiClient,
        sessionManager: SessionManager,
        registry: any ServiceRegistering,
        telemetry: TelemetryReporting = NoopTelemetry()
    ) {
        self.config = config
        self.logger = logger
        self.eventBus = eventBus
        self.stateStore = stateStore
        self.apiClient = apiClient
        self.sessionManager = sessionManager
        self.registry = registry
        self.telemetry = telemetry
    }
}
