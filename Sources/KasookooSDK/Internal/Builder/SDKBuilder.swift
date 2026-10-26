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
    let sipService: SipService
    let notificationService: NotificationService

    // Module registry infrastructure. Messaging runs on this today; the other
    // services migrate onto it in later steps. Added once so the struct is not
    // re-touched each migration.
    let container: ServiceContainer
    let moduleRegistry: SDKModuleRegistry
    let pushRouter: PushRouter

    // Cross-cutting infrastructure, like the logger. Held here so the facade
    // can set the user id, flush on disconnect, and shut the pipeline down.
    let telemetry: TelemetryReporting
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
        
        // Telemetry is built early so every layer below can be instrumented.
        // `TelemetryFactory` returns a no-op reporter when the tenant has
        // telemetry disabled, so nothing downstream has to branch on it.
        let telemetry = TelemetryFactory.make(
            configuration: config.effectiveTelemetry,
            organizationId: config.organizationId,
            logger: logger
        )
        LogExportWiring.connect(logger: logger, telemetry: telemetry, configuration: config.effectiveTelemetry)
        
        // ─────────────────────────────────────────────────────────────
        // Layer 2: Networking
        // ─────────────────────────────────────────────────────────────
        
        let apiClient = ApiClient(
            baseURL: config.baseURL,
            publishableKey: config.publishableKey,
            organizationId: config.organizationId,
            logger: logger,
            telemetry: telemetry
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
        
        // ─────────────────────────────────────────────────────────────
        // Module registry (messaging runs here today; other services later)
        // ─────────────────────────────────────────────────────────────
        
        let container = ServiceContainer()
        let pushRouter = PushRouter()
        let moduleContext = ModuleContext(
            config: config,
            logger: logger,
            eventBus: eventBus,
            stateStore: stateStore,
            apiClient: apiClient,
            sessionManager: sessionManager,
            registry: container,
            telemetry: telemetry
        )
        let moduleRegistry = SDKModuleRegistry(modules: [
            MessagingModule()
        ])
        await moduleRegistry.configureAll(context: moduleContext, pushRouter: pushRouter)
        
        logger.info("SDK build complete")
        
        return AssembledSDK(
            config: config,
            logger: logger,
            eventBus: eventBus,
            stateStore: stateStore,
            apiClient: apiClient,
            sessionManager: sessionManager,
            callService: callService,
            sipService: sipService,
            notificationService: notificationService,
            container: container,
            moduleRegistry: moduleRegistry,
            pushRouter: pushRouter,
            telemetry: telemetry
        )
    }
}
