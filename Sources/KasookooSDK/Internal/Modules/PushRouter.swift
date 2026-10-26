//
//  PushRouter.swift
//  KasookooSDK
//
//  Registry + dispatcher for inbound pushes (Map §14.2, seam #5) — the mechanism
//  that turns Notification from a hardcoded hub into an open one.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHAT IT DOES
//  ─────────────────────────────────────────────────────────────────────────────
//  The Notification hub owns device registration, CallKit timing, and this router.
//  Feature modules register a `PushHandling`; the router offers each inbound push
//  to handlers in priority order until one claims it (chain of responsibility).
//  Adding a push-receiving module (WhatsApp, recording-ready, …) is then a
//  registration — the hub's dispatch code never changes.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  TRANSITIONAL / ADDITIVE
//  ─────────────────────────────────────────────────────────────────────────────
//  Built and populated by `SDKBuilder`, but no module handles pushes yet, so
//  nothing routes through it. `NotificationService` still uses its
//  `PushPayloadParser` + switch exactly as before. The router is wired in only
//  when modules migrate and the hub is converted LAST (Map §14.7), with the
//  incoming-call path tested at every step. Building it now changes no behaviour.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  CONCURRENCY
//  ─────────────────────────────────────────────────────────────────────────────
//  The handler list is guarded by a lock, and the lock is released BEFORE any
//  handler is awaited — never held across `await`. So a handler can do async work
//  without blocking registration or risking reentrancy.
//

import Foundation

internal final class PushRouter: @unchecked Sendable {

    private var handlers: [PushHandling] = []
    private let lock = NSLock()

    init() {}

    /// Registers a push handler. Handlers are kept sorted by descending priority.
    func register(_ handler: PushHandling) {
        lock.lock()
        defer { lock.unlock() }
        handlers.append(handler)
        handlers.sort { $0.pushPriority > $1.pushPriority }
    }

    /// Offers a push to registered handlers in priority order.
    /// - Returns: `true` if some handler consumed it, else `false`.
    @discardableResult
    func route(_ push: PushContext) async -> Bool {
        // Snapshot under lock in a SYNCHRONOUS helper, then await outside it.
        // (`NSLock.lock()`/`unlock()` are unavailable directly in an async
        // context; taking the snapshot in a non-async function keeps the lock
        // off the async path entirely while still never holding it across await.)
        let snapshot = snapshotHandlers()

        for handler in snapshot {
            if await handler.handlePush(push) {
                return true
            }
        }
        return false
    }

    /// Synchronous snapshot of the current handlers (lock scope stays sync).
    private func snapshotHandlers() -> [PushHandling] {
        lock.lock()
        defer { lock.unlock() }
        return handlers
    }

    /// Whether no handler is registered — lets the hub fall back to its legacy
    /// path during the migration window.
    var isEmpty: Bool {
        lock.lock()
        defer { lock.unlock() }
        return handlers.isEmpty
    }

    /// Removes all handlers. Called during teardown.
    func removeAll() {
        lock.lock()
        defer { lock.unlock() }
        handlers.removeAll()
    }
}
