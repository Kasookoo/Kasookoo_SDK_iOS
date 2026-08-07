//
//  PushHandling.swift
//  KasookooSDK
//
//  Opt-in capability: a module that receives push notifications
//  (Map §14.2, seam #5).
//
//  Separate from `SDKModule` (interface segregation) — a module that never gets a
//  push carries none of this. A push handler owns BOTH the recognition ("is this
//  push mine?") and the handling of its own push shapes, so push-shape knowledge
//  lives inside the owning module — never in a central parser or switch.
//

import Foundation

internal protocol PushHandling: Sendable {

    /// Stable id for logging / dedup, e.g. "calling.push".
    var pushHandlerId: String { get }

    /// Higher runs first. Lets a specific handler (e.g. incoming call) claim a
    /// push before a broad/generic one. Default: 0.
    var pushPriority: Int { get }

    /// Attempt to handle the push.
    /// - Returns: `true` if this handler recognized and consumed it (routing
    ///   stops); `false` to let the next handler try.
    func handlePush(_ push: PushContext) async -> Bool
}

internal extension PushHandling {
    var pushPriority: Int { 0 }
}
