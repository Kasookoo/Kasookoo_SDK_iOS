//
//  PushContext.swift
//  KasookooSDK
//
//  A single inbound push, handed to registered push handlers (Map §14.2, seam #5).
//
//  Carries the RAW `PushPayload` (not a pre-parsed enum) plus whether it arrived
//  via the VoIP/PushKit channel. Each handler parses the payload the way its own
//  module understands it — the router never interprets the payload, so there is no
//  central push-type enum to edit when a new kind of push is added.
//

import Foundation

internal struct PushContext: Sendable {

    /// The raw, JSON-safe push payload as delivered by iOS.
    let payload: PushPayload

    /// True if delivered on the VoIP/PushKit channel (must reach CallKit fast).
    let isVoIP: Bool

    init(payload: PushPayload, isVoIP: Bool) {
        self.payload = payload
        self.isVoIP = isVoIP
    }
}
