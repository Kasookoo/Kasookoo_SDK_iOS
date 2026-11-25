//
//  LiveKitRoomManager.swift
//  KasookooSDK
//
//  Wraps the LiveKit SDK for room/call management.
//  All LiveKit-specific logic lives here so the rest of the SDK doesn't depend on it.
//

import Foundation
import LiveKit
import AVFoundation
#if canImport(UIKit)
import UIKit
#endif

// MARK: - Delegate Events

/// Events emitted by `LiveKitRoomManager` to its delegate.
///
/// These are LiveKit-level events translated into SDK-friendly events.
internal enum LiveKitRoomEvent: Sendable {
    
    /// A remote participant joined the room (call connected).
    case remoteParticipantJoined(identity: String)
    
    /// A remote participant left the room (call ended on their side).
    case remoteParticipantLeft(identity: String)
    
    /// The local connection to the room was established.
    case roomConnected
    
    /// The local connection was lost or disconnected.
    case roomDisconnected(error: Error?)
    
    /// The connection is being re-established after a network drop.
    case roomReconnecting
    
    /// The connection was successfully re-established.
    case roomReconnected

    /// The audio route changed (headset plugged in or out, Bluetooth
    /// connected, speaker toggled). Carries the route now in use.
    case audioRouteChanged(current: AudioRoute?)
}

/// Delegate protocol for receiving room events.
internal protocol LiveKitRoomManagerDelegate: AnyObject, Sendable {
    func roomManager(_ manager: LiveKitRoomManager, didReceiveEvent event: LiveKitRoomEvent) async
}

// MARK: - Room Manager

/// Manages a LiveKit room (one call = one room).
///
/// Responsibilities:
/// - Connect/disconnect from LiveKit rooms
/// - Publish local audio (microphone)
/// - Track remote participant presence
/// - Translate LiveKit delegate callbacks into SDK events
///
/// **Threading:** All public methods are async. Internal state is protected
/// by the `@MainActor` isolation that LiveKit's Room class requires.
@MainActor
internal final class LiveKitRoomManager: NSObject {
    
    // MARK: - Properties
    
    private let room: Room
    private let logger: Logger
    
    /// The room name we connected to.
    private(set) var roomName: String?

    /// Whether anyone else is in the room right now. Participants who were
    /// already there when we joined are only listed here — LiveKit does not
    /// call `participantDidConnect` for them.
    var hasRemoteParticipants: Bool {
        !room.remoteParticipants.isEmpty
    }
    
    /// The local participant identity (typically the user's email).
    private(set) var localIdentity: String?
    
    /// Delegate for events.
    weak var delegate: LiveKitRoomManagerDelegate?

    // MARK: - Hold State (KSA-321)

    /// Whether the call is on hold on this device.
    private(set) var isOnHold = false

    /// The microphone state the user wants once the call is resumed. While
    /// on hold the microphone is always off; a mute or unmute during hold
    /// only updates this value.
    private var micEnabledAfterHold = true

    /// Observer token for `AVAudioSession.routeChangeNotification`.
    private var routeChangeObserver: NSObjectProtocol?
    
    /// Whether the room is currently connected.
    var isConnected: Bool {
        return room.connectionState == .connected
    }
    
    // MARK: - Init
    
    init(logger: Logger) {
        self.room = Room()
        self.logger = logger
        super.init()
        self.room.add(delegate: self)
    }
    
    deinit {
        // Note: We can't await disconnect in deinit, but Room's own deinit
        // will close the underlying connection.
    }
    
    // MARK: - Public API
    
    /// Connects to a LiveKit room.
    ///
    /// - Parameters:
    ///   - wsUrl: The LiveKit WebSocket URL.
    ///   - token: The LiveKit access token.
    ///   - roomName: The room name (for logging).
    ///   - localIdentity: The local participant's identity.
    /// - Throws: `KasookooError.callFailed` on connection failure.
    func connect(
        wsUrl: String,
        token: String,
        roomName: String,
        localIdentity: String
    ) async throws {
        self.roomName = roomName
        self.localIdentity = localIdentity
        
        logger.info("LiveKit: connecting to room '\(roomName)'")
        
        // Configure audio session for VoIP
        try configureAudioSession()
        
        // Connect to the room
        do {
            try await room.connect(url: wsUrl, token: token)
        } catch {
            logger.error("LiveKit connect failed: \(error.localizedDescription)")
            throw KasookooError.callFailed(
                message: "Failed to connect to call: \(error.localizedDescription)",
                retryable: true,
                underlyingError: error
            )
        }

        startObservingAudioRoute()

        // Publish local microphone
        do {
            try await room.localParticipant.setMicrophone(enabled: true)
            logger.debug("LiveKit: microphone enabled")
        } catch {
            logger.warning("LiveKit: failed to enable microphone: \(error.localizedDescription)")
            // Don't fail the call — user might enable mic later.
        }
    }
    
    /// Disconnects from the current room.
    ///
    /// Also acts while a connect or reconnect is still in progress. Checking
    /// only for `.connected` let a hang-up during setup leave the room to
    /// finish connecting and publish the microphone afterwards.
    func disconnect() async {
        stopObservingAudioRoute()
        isOnHold = false
        micEnabledAfterHold = true
        guard room.connectionState != .disconnected else {
            logger.debug("LiveKit: disconnect called but already disconnected")
            return
        }
        logger.info("LiveKit: disconnecting from '\(roomName ?? "unknown")'")
        await room.disconnect()
    }
    
    // MARK: - Microphone Control
    
    /// Mutes or unmutes the local microphone.
    ///
    /// While the call is on hold the microphone stays off; the requested state
    /// is remembered and applied on resume.
    func setMicrophoneEnabled(_ enabled: Bool) async throws {
        if isOnHold {
            micEnabledAfterHold = enabled
            logger.debug("LiveKit: on hold, microphone will be \(enabled ? "enabled" : "disabled") on resume")
            return
        }
        do {
            try await room.localParticipant.setMicrophone(enabled: enabled)
            logger.debug("LiveKit: microphone \(enabled ? "enabled" : "disabled")")
        } catch {
            throw KasookooError.callFailed(
                message: "Failed to toggle microphone: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }
    
    /// Whether the local microphone is enabled, as the user set it.
    ///
    /// On hold this reports the state the microphone returns to on resume, so
    /// a mute button does not flip to "muted" just because the call is held.
    var isMicrophoneEnabled: Bool {
        if isOnHold { return micEnabledAfterHold }
        return room.localParticipant.isMicrophoneEnabled()
    }

    // MARK: - Hold / Resume (KSA-321)

    /// Puts the call on hold, or resumes it.
    ///
    /// Hold is done on this device: the microphone is turned off and the
    /// server stops sending the remote audio, so neither side hears the other.
    /// The other participant is not told the call is held; they hear silence.
    ///
    /// - Throws: `KasookooError.callFailed` if a track cannot be changed. On
    ///   failure the hold state is left unchanged.
    func setOnHold(_ held: Bool) async throws {
        guard held != isOnHold else { return }

        if held {
            let micWasEnabled = room.localParticipant.isMicrophoneEnabled()
            do {
                try await room.localParticipant.setMicrophone(enabled: false)
                try await setRemoteAudioEnabled(false)
            } catch {
                // Undo whatever already changed, so we are not half held.
                try? await setRemoteAudioEnabled(true)
                try? await room.localParticipant.setMicrophone(enabled: micWasEnabled)
                throw KasookooError.callFailed(
                    message: "Failed to put the call on hold: \(error.localizedDescription)",
                    retryable: true,
                    details: ["action": "hold"],
                    underlyingError: error
                )
            }
            micEnabledAfterHold = micWasEnabled
            isOnHold = true
            logger.info("LiveKit: call on hold")
        } else {
            do {
                try await setRemoteAudioEnabled(true)
                try await room.localParticipant.setMicrophone(enabled: micEnabledAfterHold)
            } catch {
                throw KasookooError.callFailed(
                    message: "Failed to resume the call: \(error.localizedDescription)",
                    retryable: true,
                    details: ["action": "resume"],
                    underlyingError: error
                )
            }
            isOnHold = false
            logger.info("LiveKit: call resumed")
        }
    }

    /// Asks the server to start or stop sending every remote audio track.
    private func setRemoteAudioEnabled(_ enabled: Bool) async throws {
        for participant in room.remoteParticipants.values {
            for publication in participant.audioTracks {
                guard let remote = publication as? RemoteTrackPublication else { continue }
                try await remote.set(enabled: enabled)
            }
        }
    }

    // MARK: - Audio Routes (KSA-292 / KSA-326)

    /// Stable ids for the built-in routes.
    private enum BuiltInRouteId {
        static let receiver = "builtin.receiver"
        static let speaker = "builtin.speaker"
    }

    /// The routes call audio can use right now.
    ///
    /// Always lists the loudspeaker, and the earpiece on devices that have one.
    /// Adds every connected headset, Bluetooth hands-free device, car kit or
    /// USB interface the system offers as a call input, plus the current
    /// output if it is a device that is not otherwise listed (for example
    /// Bluetooth headphones without a microphone).
    func availableAudioRoutes() -> [AudioRoute] {
        let session = AVAudioSession.sharedInstance()
        let currentOutputs = session.currentRoute.outputs
        let speakerActive = currentOutputs.contains { $0.portType == .builtInSpeaker }
        let receiverActive = currentOutputs.contains { $0.portType == .builtInReceiver }

        var routes: [AudioRoute] = []
        if Self.deviceHasEarpiece {
            routes.append(AudioRoute(
                id: BuiltInRouteId.receiver,
                name: "Phone",
                kind: .earpiece,
                isActive: receiverActive
            ))
        }
        routes.append(AudioRoute(
            id: BuiltInRouteId.speaker,
            name: "Speaker",
            kind: .speaker,
            isActive: speakerActive
        ))

        var seen = Set<String>()
        for port in session.availableInputs ?? [] where port.portType != .builtInMic {
            guard seen.insert(port.uid).inserted else { continue }
            let active = currentOutputs.contains { Self.isSameDevice($0, port) }
            routes.append(AudioRoute(
                id: port.uid,
                name: port.portName,
                kind: Self.kind(for: port.portType),
                isActive: active
            ))
        }
        for output in currentOutputs
        where output.portType != .builtInSpeaker && output.portType != .builtInReceiver {
            let alreadyListed = routes.contains { $0.id == output.uid }
                || (session.availableInputs ?? []).contains { Self.isSameDevice(output, $0) }
            guard !alreadyListed else { continue }
            routes.append(AudioRoute(
                id: output.uid,
                name: output.portName,
                kind: Self.kind(for: output.portType),
                isActive: true
            ))
        }
        return routes
    }

    /// The route call audio is using right now, if it can be determined.
    func currentAudioRoute() -> AudioRoute? {
        availableAudioRoutes().first { $0.isActive }
    }

    /// Switches call audio to `route`.
    ///
    /// - Throws: `KasookooError.callFailed` if the route is no longer
    ///   available (device disconnected) or the system refuses the change.
    func setAudioRoute(_ route: AudioRoute) throws {
        let session = AVAudioSession.sharedInstance()
        do {
            switch route.id {
            case BuiltInRouteId.speaker:
                AudioManager.shared.isSpeakerOutputPreferred = true
                try session.setPreferredInput(nil)
                try session.overrideOutputAudioPort(.speaker)

            case BuiltInRouteId.receiver:
                guard Self.deviceHasEarpiece else {
                    throw Self.routeUnavailable(route)
                }
                AudioManager.shared.isSpeakerOutputPreferred = false
                try session.overrideOutputAudioPort(.none)
                // Pin the built-in mic, which also makes iOS leave a connected
                // headset and play through the earpiece.
                let builtInMic = session.availableInputs?.first { $0.portType == .builtInMic }
                try session.setPreferredInput(builtInMic)

            default:
                AudioManager.shared.isSpeakerOutputPreferred = false
                try session.overrideOutputAudioPort(.none)
                if let input = session.availableInputs?.first(where: { $0.uid == route.id }) {
                    try session.setPreferredInput(input)
                } else if session.currentRoute.outputs.contains(where: { $0.uid == route.id }) {
                    // Output-only device that is already in use: nothing to do.
                    break
                } else {
                    throw Self.routeUnavailable(route)
                }
            }
            logger.debug("Audio: route set to \(route.kind.rawValue)")
        } catch let error as KasookooError {
            throw error
        } catch {
            throw KasookooError.callFailed(
                message: "Failed to switch audio to \(route.name): \(error.localizedDescription)",
                retryable: true,
                details: ["action": "setAudioRoute", "route": route.id],
                underlyingError: error
            )
        }
    }

    private static func routeUnavailable(_ route: AudioRoute) -> KasookooError {
        KasookooError.callFailed(
            message: "Audio route '\(route.name)' is not available.",
            retryable: false,
            details: ["action": "setAudioRoute", "route": route.id, "reason": "route_unavailable"]
        )
    }

    /// iPhones have an earpiece; iPads and Macs do not.
    private static var deviceHasEarpiece: Bool {
        #if canImport(UIKit)
        return UIDevice.current.userInterfaceIdiom == .phone
        #else
        return false
        #endif
    }

    /// A Bluetooth hands-free device shows up as one input and one output
    /// with different port types; match them on the device part of the uid.
    private static func isSameDevice(_ a: AVAudioSessionPortDescription, _ b: AVAudioSessionPortDescription) -> Bool {
        if a.uid == b.uid { return true }
        let deviceA = a.uid.split(separator: "-").first
        let deviceB = b.uid.split(separator: "-").first
        return deviceA != nil && deviceA == deviceB && a.portName == b.portName
    }

    private static func kind(for port: AVAudioSession.Port) -> AudioRouteKind {
        switch port {
        case .builtInReceiver: return .earpiece
        case .builtInSpeaker: return .speaker
        case .bluetoothHFP, .bluetoothA2DP, .bluetoothLE: return .bluetooth
        case .headsetMic, .headphones, .lineIn, .lineOut: return .wiredHeadset
        case .carAudio: return .carAudio
        case .usbAudio: return .usb
        default: return .other
        }
    }

    private func startObservingAudioRoute() {
        guard routeChangeObserver == nil else { return }
        routeChangeObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.routeChangeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                let current = self.currentAudioRoute()
                await self.delegate?.roomManager(self, didReceiveEvent: .audioRouteChanged(current: current))
            }
        }
    }

    private func stopObservingAudioRoute() {
        if let observer = routeChangeObserver {
            NotificationCenter.default.removeObserver(observer)
            routeChangeObserver = nil
        }
    }
    
    // MARK: - Speaker Control
    
    /// Routes audio to the loudspeaker (true) or earpiece (false).
    ///
    /// LiveKit manages the `AVAudioSession` itself and re-applies its category
    /// whenever the audio engine starts. With its default speaker preference
    /// that category includes `.defaultToSpeaker`, so a plain
    /// `overrideOutputAudioPort(.none)` fell straight back to the speaker and
    /// the earpiece could never be selected. The preference is therefore set on
    /// LiveKit (which reconfigures the session), and the port override is
    /// applied as well so the change is immediate.
    func setSpeakerEnabled(_ enabled: Bool) throws {
        AudioManager.shared.isSpeakerOutputPreferred = enabled
        let session = AVAudioSession.sharedInstance()
        do {
            try session.overrideOutputAudioPort(enabled ? .speaker : .none)
            logger.debug("Audio: speaker \(enabled ? "on" : "off")")
        } catch {
            throw KasookooError.callFailed(
                message: "Failed to toggle speaker: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }
    
    // MARK: - DTMF
    
    /// Sends a DTMF tone to the remote (PSTN) side of a SIP call.
    ///
    /// Tones are published on the LiveKit data channel under the `dtmf` topic,
    /// which is what the backend's SIP bridge listens on. Required for IVR
    /// navigation ("press 1 for sales") on PSTN calls.
    ///
    /// - Parameter digit: A single character: `0`–`9`, `*`, or `#`.
    /// - Throws: `KasookooError.callFailed` if the digit is invalid or publishing fails.
    func sendDTMF(_ digit: String) async throws {
        guard let code = Self.dtmfCode(for: digit) else {
            throw KasookooError.callFailed(
                message: "Invalid DTMF digit '\(digit)'. Expected 0-9, * or #.",
                retryable: false
            )
        }
        
        let message: [String: String] = ["code": code, "digit": digit]
        guard let data = try? JSONSerialization.data(withJSONObject: message) else {
            throw KasookooError.callFailed(
                message: "Failed to encode DTMF payload.",
                retryable: false
            )
        }
        
        do {
            let options = DataPublishOptions(topic: "dtmf", reliable: true)
            try await room.localParticipant.publish(data: data, options: options)
            logger.debug("DTMF sent: \(digit) (code \(code))")
        } catch {
            throw KasookooError.callFailed(
                message: "Failed to send DTMF: \(error.localizedDescription)",
                retryable: true,
                underlyingError: error
            )
        }
    }
    
    /// Maps a DTMF character to the numeric code the SIP bridge expects.
    private static func dtmfCode(for digit: String) -> String? {
        switch digit {
        case "0", "1", "2", "3", "4", "5", "6", "7", "8", "9":
            return digit
        case "*": return "10"
        case "#": return "11"
        default:  return nil
        }
    }
    
    // MARK: - Audio Session Setup
    
    private func configureAudioSession() throws {
        let session = AVAudioSession.sharedInstance()
        do {
            try session.setCategory(
                .playAndRecord,
                mode: .voiceChat,
                options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
            )
            try session.setActive(true)
            logger.debug("Audio session configured for VoIP")
        } catch {
            logger.error("Audio session setup failed: \(error.localizedDescription)")
            throw KasookooError.callFailed(
                message: "Failed to configure audio session: \(error.localizedDescription)",
                underlyingError: error
            )
        }
    }
}

// MARK: - RoomDelegate

extension LiveKitRoomManager: RoomDelegate {
    
    nonisolated func room(_ room: Room, didUpdateConnectionState connectionState: ConnectionState, from oldConnectionState: ConnectionState) {
        Task { @MainActor in
            self.logger.debug("LiveKit connection: \(oldConnectionState) → \(connectionState)")
            
            switch connectionState {
            case .connected:
                if oldConnectionState == .reconnecting {
                    await self.delegate?.roomManager(self, didReceiveEvent: .roomReconnected)
                } else {
                    await self.delegate?.roomManager(self, didReceiveEvent: .roomConnected)
                }
                
            case .reconnecting:
                await self.delegate?.roomManager(self, didReceiveEvent: .roomReconnecting)
                
            case .disconnected:
                let error = self.room.disconnectError
                await self.delegate?.roomManager(self, didReceiveEvent: .roomDisconnected(error: error))
                
            default:
                break
            }
        }
    }
    
    nonisolated func room(_ room: Room, participantDidConnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? "unknown"
        Task { @MainActor in
            self.logger.info("LiveKit: remote participant joined")
            await self.delegate?.roomManager(self, didReceiveEvent: .remoteParticipantJoined(identity: identity))
        }
    }
    
    /// Keeps a held call silent when the other side (re)publishes its audio,
    /// for example after a reconnect.
    nonisolated func room(_ room: Room, participant: RemoteParticipant, didSubscribeTrack publication: RemoteTrackPublication) {
        guard publication.kind == .audio else { return }
        Task { @MainActor in
            guard self.isOnHold else { return }
            do {
                try await publication.set(enabled: false)
            } catch {
                self.logger.warning("LiveKit: could not keep new remote audio silent while on hold: \(error.localizedDescription)")
            }
        }
    }

    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? "unknown"
        Task { @MainActor in
            self.logger.info("LiveKit: remote participant left")
            await self.delegate?.roomManager(self, didReceiveEvent: .remoteParticipantLeft(identity: identity))
        }
    }
}
