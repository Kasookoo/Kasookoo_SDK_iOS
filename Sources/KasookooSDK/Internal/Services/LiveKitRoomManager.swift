//
//  LiveKitRoomManager.swift
//  KasookooSDK
//
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
        
        logger.info("LiveKit: connecting to room '\(roomName)' as '\(localIdentity)'")
        
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
    func disconnect() async {
        guard isConnected else {
            logger.debug("LiveKit: disconnect called but not connected")
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
    func setSpeakerEnabled(_ enabled: Bool) throws {
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
            self.logger.info("LiveKit: remote participant joined: \(identity)")
            logger.error("""
            PARTICIPANT CONNECT

            identity = \(participant.identity?.stringValue ?? "")
            participants = \(room.remoteParticipants.count)
            """)
            
            await self.delegate?.roomManager(self, didReceiveEvent: .remoteParticipantJoined(identity: identity))
        }
    }
    
    nonisolated func room(_ room: Room, participantDidDisconnect participant: RemoteParticipant) {
        let identity = participant.identity?.stringValue ?? "unknown"
        Task { @MainActor in
            self.logger.info("LiveKit: remote participant left: \(identity)")
            logger.error("""
            PARTICIPANT DISCONNECT

            identity = \(participant.identity?.stringValue ?? "")
            participants = \(room.remoteParticipants.count)
            """)
            await self.delegate?.roomManager(self, didReceiveEvent: .remoteParticipantLeft(identity: identity))
        }
    }
}
