//
//  ServiceContainer.swift
//  KasookooSDK
//
//  Type-keyed service registry — the extensible replacement for the hardcoded
//  `AssembledSDK` struct (Architecture Map §8 and §14, seam #1).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS
//  ─────────────────────────────────────────────────────────────────────────────
//  Today every service is a named field on `AssembledSDK`, so adding a service
//  means editing that struct AND the builder that fills it AND the facade that
//  exposes it. A container keyed by service type lets a module register its own
//  service, and the facade resolve it by type — no central struct to edit when a
//  module is added.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  DECOUPLING — modules register, they do NOT resolve
//  ─────────────────────────────────────────────────────────────────────────────
//  Modules receive only the `ServiceRegistering` face (via `ModuleContext`), so a
//  module can register its OWN service but cannot resolve a PEER module's service.
//  Cross-module interaction goes through events / the push router, never a direct
//  lookup — which is exactly the coupling we are removing. The facade uses the
//  concrete container to resolve.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  TRANSITIONAL
//  ─────────────────────────────────────────────────────────────────────────────
//  Messaging is registered here and resolved by the facade. The other services
//  are still fields on `AssembledSDK` and move onto the container one at a
//  time; the struct is removed only once empty.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  CONCURRENCY
//  ─────────────────────────────────────────────────────────────────────────────
//  Guarded by an `NSLock`, exactly like the `KasookooSDK` facade's own state.
//  Resolution is synchronous so it can back the facade's synchronous throwing
//  accessors (`var call: CallServicing { get throws }`) without forcing async.
//  `@unchecked Sendable` because the lock — not the compiler — enforces safety;
//  the stored services are themselves actors or `Sendable` classes.
//

import Foundation

/// The registration face of the service graph. Handed to modules so they can
/// register their own service without being able to resolve peers.
internal protocol ServiceRegistering: Sendable {
    func register<Service>(_ type: Service.Type, _ instance: Service)
}

internal final class ServiceContainer: ServiceRegistering, @unchecked Sendable {

    /// Services keyed by their registered type's identity.
    private var services: [ObjectIdentifier: Any] = [:]
    private let lock = NSLock()

    init() {}

    // MARK: - Register (also satisfies ServiceRegistering)

    /// Registers a service instance under a type key (usually its public protocol).
    ///
    /// ```swift
    /// container.register(CallServicing.self, callService)
    /// ```
    func register<Service>(_ type: Service.Type, _ instance: Service) {
        lock.lock()
        defer { lock.unlock() }
        services[ObjectIdentifier(type)] = instance
    }

    // MARK: - Resolve (facade only — not exposed to modules)

    /// Resolves a previously-registered service.
    ///
    /// - Throws: `KasookooError.configInvalid` if no service is registered for the
    ///   type — which, once modules are wired, means the owning module is either
    ///   not registered or disabled for this organization.
    func resolve<Service>(_ type: Service.Type = Service.self) throws -> Service {
        lock.lock()
        defer { lock.unlock() }
        guard let service = services[ObjectIdentifier(type)] as? Service else {
            throw KasookooError.configInvalid(
                "No registered service for \(String(reflecting: type)). "
                + "Ensure the owning module is registered and enabled for this organization."
            )
        }
        return service
    }

    /// Non-throwing lookup — nil if not registered.
    func optional<Service>(_ type: Service.Type = Service.self) -> Service? {
        lock.lock()
        defer { lock.unlock() }
        return services[ObjectIdentifier(type)] as? Service
    }

    /// Whether a service is registered for the given type.
    func contains<Service>(_ type: Service.Type) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return services[ObjectIdentifier(type)] != nil
    }

    /// Removes all registrations. Called during teardown.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        services.removeAll()
    }
}
