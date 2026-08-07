//
//  MessagingModule.swift
//  KasookooSDK
//
//  The messaging feature as an `SDKModule` (Architecture Map §14) — the FIRST
//  module to run on the full registry path (ServiceContainer + ModuleContext +
//  SDKModule), proving the pattern before the other services follow.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHAT IT DOES
//  ─────────────────────────────────────────────────────────────────────────────
//  Builds `MessagingService` from shared infrastructure and registers it under
//  `MessagingServicing`. The facade then resolves messaging from the service
//  container — there is no `AssembledSDK.messagingService` field and no builder
//  edit when messaging changes. Adding messaging behaviour becomes a change inside
//  this module, not the core.
//
//  Push handling (message-received) moves here when the Notification hub is
//  converted to the push router (later step). For now messaging is lifecycle-only,
//  so this does NOT conform to `PushHandling` yet — behaviour is unchanged.
//
//  `capabilityKey` is nil (always available): messaging is not gated by
//  `configuration_availability` today.
//

import Foundation

internal struct MessagingModule: SDKModule {

    let id = "messaging"

    func configure(_ context: ModuleContext) async {
        let service = MessagingService(
            apiClient: context.apiClient,
            stateStore: context.stateStore,
            eventBus: context.eventBus,
            logger: context.logger,
            config: context.config
        )
        context.registry.register(MessagingServicing.self, service)
        context.logger.debug("MessagingModule configured and registered")
    }
}
