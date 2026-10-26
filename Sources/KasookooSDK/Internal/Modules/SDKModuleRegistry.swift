//
//  SDKModuleRegistry.swift
//  KasookooSDK
//
//  Holds the SDK's modules and drives their lifecycle generically
//  (Architecture Map §14, seams #1 and #6).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS
//  ─────────────────────────────────────────────────────────────────────────────
//  Today `SDKBuilder` and `KasookooSDK.destroy()` name each service by hand, so
//  adding a module means editing both. The registry replaces that with a single
//  loop over `[SDKModule]`: configure, start, stop all fan out generically, and a
//  `PushHandling` module is auto-registered with the push router. Adding a module
//  becomes one entry in the module list — no lifecycle code changes.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  CAPABILITY GATING (multi-tenant — Map §13.2)
//  ─────────────────────────────────────────────────────────────────────────────
//  Every module is configured (so its service is registered), but only modules
//  whose `capabilityKey` is provisioned for the organization are started. A bank
//  that never bought SIP simply never starts the SIP module. Capabilities come
//  from the backend's `configuration_availability` at connect time; pass `nil` to
//  start everything (e.g. before capability discovery, or when not gating).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  TRANSITIONAL / ADDITIVE
//  ─────────────────────────────────────────────────────────────────────────────
//  `SDKBuilder` constructs the registry and calls `configureAll` (messaging runs
//  on it). `startAll`/`stopAll` are not called yet: no module declares a
//  `capabilityKey` or start/stop work. Wire them into connect/disconnect, fed by
//  `configuration_availability`, when the first gated module (SIP) migrates.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  USAGE (once wired, illustrative)
//  ─────────────────────────────────────────────────────────────────────────────
//  ```swift
//  let registry = SDKModuleRegistry(modules: [
//      MessagingModule(),
//      CallingModule(),
//      SipModule(),
//      // WhatsAppModule()   ← future: just one more line
//  ])
//  await registry.configureAll(context: context, pushRouter: pushRouter)
//  // …after connect(), capabilities known:
//  await registry.startAll(enabledCapabilities: caps)
//  ```
//
//  CONCURRENCY: the module list is immutable after init, so no locking is needed;
//  lifecycle methods are called sequentially by the SDK's own lifecycle.
//

import Foundation

internal final class SDKModuleRegistry: Sendable {

    private let modules: [SDKModule]

    /// - Parameter modules: the SDK's modules, in configure/start order.
    ///   Duplicate ids are dropped (first one wins) to avoid double registration.
    init(modules: [SDKModule]) {
        var seen = Set<String>()
        self.modules = modules.filter { seen.insert($0.id).inserted }
    }

    /// The ids of the registered modules, in order. Useful for logging/tests.
    var moduleIds: [String] {
        modules.map { $0.id }
    }

    // MARK: - Lifecycle fan-out

    /// Configures every module and auto-registers any `PushHandling` module with
    /// the push router. Called once during SDK initialization.
    ///
    /// All modules are configured regardless of capability, so their services are
    /// resolvable; capability only gates `startAll(...)`.
    func configureAll(context: ModuleContext, pushRouter: PushRouter) async {
        for module in modules {
            await module.configure(context)

            // Opt-in push capability (interface segregation): only modules that
            // also conform to PushHandling participate in push routing.
            if let pushModule = module as? PushHandling {
                pushRouter.register(pushModule)
            }
        }
    }

    /// Starts the modules enabled for this organization.
    ///
    /// - Parameter enabledCapabilities: capability keys the org has provisioned
    ///   (from `configuration_availability`). Pass `nil` to start every module
    ///   (no gating). A module with `capabilityKey == nil` is always started.
    func startAll(enabledCapabilities: Set<String>?) async {
        for module in modules where Self.isEnabled(module, in: enabledCapabilities) {
            await module.start()
        }
    }

    /// Stops all modules in reverse order (teardown symmetry).
    func stopAll() async {
        for module in modules.reversed() {
            await module.stop()
        }
    }

    // MARK: - Helpers

    private static func isEnabled(_ module: SDKModule, in caps: Set<String>?) -> Bool {
        guard let key = module.capabilityKey else { return true }  // always-on
        guard let caps else { return true }                        // no gating info
        return caps.contains(key)
    }
}
