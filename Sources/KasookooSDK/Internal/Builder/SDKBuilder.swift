//
//  SDKBuilder.swift
//  KasookooSDK
//
//

import Foundation

/// Result of building the SDK — a bundle of all assembled components.
internal struct AssembledSDK {
    let config: KasookooConfig
    let logger: Logger
    let eventBus: EventBus
    let stateStore: StateStore
    let apiClient: ApiClient
    let sessionManager: SessionManager
    let callService: CallService
    let messagingService: MessagingService
    let sipService: SipService
    let notificationService: NotificationService
}

/// Constructs the full SDK component graph.
///
/// This is the only place that knows the internal wiring. The `KasookooSDK`
/// facade simply asks for an `AssembledSDK` and exposes the resulting services.
internal enum SDKBuilder {
    
    /// Builds the complete SDK component graph from a configuration.
    ///
    /// Construction order matters:
    /// 1. Stateless helpers first (Logger, EventBus, StateStore)
    /// 2. Networking layer (ApiClient with placeholder auth provider)
    /// 3. Session layer (SessionManager — depends on ApiClient)
    /// 4. Wire ApiClient ↔ SessionManager (circular dependency resolution)
    /// 5. Service layer (services depend on everything above)
    /// 6. Wire NotificationService → CallService + SipService
    static func build(config: KasookooConfig) async -> AssembledSDK {
        
        // ─────────────────────────────────────────────────────────────
        // Layer 1: Stateless helpers
        // ─────────────────────────────────────────────────────────────
        
        let logger = Logger(config: config.logging, category: "SDK")
        logger.info("Building SDK for org: \(config.organizationId)")
        
        let eventBus = EventBus(logger: logger)
        let stateStore = StateStore(logger: logger)
        
        // ─────────────────────────────────────────────────────────────
        // Layer 2: Networking
        // ─────────────────────────────────────────────────────────────
        
        let apiClient = ApiClient(
            baseURL: config.baseURL,
            publishableKey: config.publishableKey,
            organizationId: config.organizationId,
            logger: logger
        )
        
        // ─────────────────────────────────────────────────────────────
        // Layer 3: Session management
        // ─────────────────────────────────────────────────────────────
        
        let tokenStorage: TokenStorage = InMemoryTokenStorage()
        let refreshScheduler = RefreshScheduler(
            refreshThresholdRatio: 0.85,
            logger: logger
        )
        
        let sessionManager = SessionManager(
            apiClient: apiClient,
            storage: tokenStorage,
            scheduler: refreshScheduler,
            eventBus: eventBus,
            logger: logger,
            config: config
        )
        
        // Wire circular dependency: ApiClient → SessionManager
        apiClient.setAuthProvider(sessionManager)
        
        // ─────────────────────────────────────────────────────────────
        // Layer 4: Services
        // ─────────────────────────────────────────────────────────────
        
        let callService = CallService(
            apiClient: apiClient,
            stateStore: stateStore,
            eventBus: eventBus,
            logger: logger,
            config: config
        )
        
        let messagingService = MessagingService(
            apiClient: apiClient,
            stateStore: stateStore,
            eventBus: eventBus,
            logger: logger,
            config: config
        )
        
        let sipService = SipService(
            apiClient: apiClient,
            stateStore: stateStore,
            eventBus: eventBus,
            logger: logger,
            config: config
        )
        
        let notificationService = NotificationService(
            apiClient: apiClient,
            stateStore: stateStore,
            eventBus: eventBus,
            logger: logger,
            config: config
        )
        
        // Wire NotificationService → CallService + SipService
        // This lets push-driven actions reach the right service.
        await notificationService.setServices(
            callService: callService,
            sipService: sipService
        )
        
        logger.info("SDK build complete")
        
        return AssembledSDK(
            config: config,
            logger: logger,
            eventBus: eventBus,
            stateStore: stateStore,
            apiClient: apiClient,
            sessionManager: sessionManager,
            callService: callService,
            messagingService: messagingService,
            sipService: sipService,
            notificationService: notificationService
        )
    }
}
