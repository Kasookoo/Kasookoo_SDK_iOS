//
//  AudioRoute.swift
//  KasookooSDK
//
//  Public model for an audio route (earpiece, loudspeaker, headset, Bluetooth).
//  KSA-292 / KSA-326.
//

import Foundation

/// Where call audio is played and captured.
///
/// Get the routes that can be used right now with
/// `sdk.call.availableAudioRoutes(callId:)` (or `sdk.sip`), and switch with
/// `setAudioRoute(_:callId:)`. Routes change as devices connect and disconnect;
/// observe `EventName.audioRouteChanged` to refresh your picker.
public struct AudioRoute: Sendable, Hashable, Identifiable, Codable {

    /// Stable identifier for this route while the device stays connected.
    ///
    /// Built-in routes use fixed ids (`"builtin.receiver"`,
    /// `"builtin.speaker"`). External devices use the system port id.
    public let id: String

    /// Human-readable name, e.g. "iPhone", "Speaker", "AirPods Pro".
    public let name: String

    /// The kind of device.
    public let kind: AudioRouteKind

    /// Whether call audio is using this route right now.
    public let isActive: Bool

    public init(id: String, name: String, kind: AudioRouteKind, isActive: Bool) {
        self.id = id
        self.name = name
        self.kind = kind
        self.isActive = isActive
    }
}

/// The kind of audio device behind an `AudioRoute`.
public enum AudioRouteKind: String, Sendable, Hashable, Codable {
    /// The phone's earpiece (receiver).
    case earpiece
    /// The phone's loudspeaker.
    case speaker
    /// A Bluetooth headset or car kit (hands-free profile, has a microphone).
    case bluetooth
    /// A wired headset or headphones (including Lightning / USB-C).
    case wiredHeadset
    /// CarPlay or other car audio.
    case carAudio
    /// A USB audio interface.
    case usb
    /// Anything else the system reports.
    case other
}
