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
    
    /// The local participant identity (typically the user's email).
    private(set) var localIdentity: String?
    
    /// Delegate for events.
    weak var delegate: LiveKitRoomManagerDelegate?
    
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
        guard room.connectionState != .disconnected else {
            logger.debug("LiveKit: disconnect called but already disconnected")
            return
        }
        logger.info("LiveKit: disconnecting from '\(roomName ?? "unknown")'")
        await room.disconnect()
    }
    
    // MARK: - Microphone Control
    
    /// Mutes or unmutes the local microphone.
    func setMicrophoneEnabled(_ enabled: Bool) async throws {
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
    
    /// Whether the local microphone is currently enabled.
    var isMicrophoneEnabled: Bool {
        return room.localParticipant.isMicrophoneEnabled()
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
    
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? "unknown"
        Task { @MainActor in
            self.logger.info("LiveKit: remote participant left")
            await self.delegate?.roomManager(self, didReceiveEvent: .remoteParticipantLeft(identity: identity))
        }
    }
}
