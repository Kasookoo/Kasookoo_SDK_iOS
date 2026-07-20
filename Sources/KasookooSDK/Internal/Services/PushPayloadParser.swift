//
//  PushPayloadParser.swift
//  KasookooSDK
//
//  Parses incoming push notification payloads (APNs and FCM-wrapped) into typed
//  PushNotificationType values that the SDK can act on.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  REAL BACKEND PAYLOAD CONTRACT (verified against production pushes)
//  ─────────────────────────────────────────────────────────────────────────────
//
//  The discriminator is **`action`** (NOT `type`). `type` is a secondary hint
//  such as "driver_incoming_call" / "customer_incoming_call".
//
//  Incoming call:
//    {
//      "action": "incoming_call",          // or "receive_call"
//      "type": "driver_incoming_call",     // hint only
//      "room_name": "call_room_xxx",       // ← also serves as the call identity
//      "caller_user_id": "...",
//      "called_user_id": "...",
//      "participant_identity_name": "John",
//      "participant_identity_type": "customer" | "driver",
//      "accessToken": "eyJhbGc...",        // ← LiveKit token (CRITICAL)
//      "wsUrl": "wss://..."                // ← LiveKit URL  (CRITICAL)
//    }
//
//  Call teardown (three distinct actions, all mean "the call is over"):
//    "call_cancelled" | "end_call" | "cancel_call"   → caller cancelled before answer
//    "reject_call" | "reject_incoming_call"          → callee rejected
//    "caller_end_call"                               → caller hung up
//
//  Message:
//    {
//      "action": "receive_message",
//      "room_name": "chat_xxx",
//      "sender_user_id": "...",
//      "receiver_user_id": "...",
//      "sender_name": "Jane",
//      "conversation_id": "...",
//      "body": "message text"
//    }
//
//  IMPORTANT: The incoming-call push carries the LiveKit `accessToken` and
//  `wsUrl` because the callee has no chance to request a token before answering.
//  Without capturing these, an accepted call can never join the room and there
//  will be NO AUDIO. They are surfaced on `IncomingCallInfo`.
//

import Foundation

// MARK: - Parsed Notification Types

/// The result of parsing a push payload.
internal enum PushNotificationType: Sendable {
    
    /// An incoming WebRTC call (use CallKit).
    case incomingCall(IncomingCallInfo)
    
    /// An incoming SIP call (use CallKit).
    case incomingSipCall(IncomingCallInfo)
    
    /// The call is over before/without being answered — cancelled by the caller,
    /// rejected by the callee, or ended by the caller. CallKit must dismiss any
    /// incoming-call UI and the SDK must clear the call from state.
    ///
    /// The associated `callId` is the room name (the backend's call identity).
    case callCancelled(callId: String)
    
    /// A new chat message arrived.
    case messageReceived(Message)
    
    /// A generic notification (no special handling).
    case generic(data: [String: String])
    
    /// Payload was not recognized as a Kasookoo notification.
    case unknown
}

// MARK: - Normalized Action

/// The backend's `action` values, normalized into the actions the SDK cares about.
private enum PushAction {
    case incomingCall
    case callOver        // cancelled | rejected | caller ended — all mean "tear down"
    case messageReceived
    case unrecognized
}

// MARK: - Parser

/// Parses push payloads into typed `PushNotificationType` values.
///
/// Handles both delivery shapes:
/// - FCM-wrapped: `{ "data": { "action": "incoming_call", ... }, "aps": {...} }`
/// - Flat APNs:   `{ "action": "incoming_call", ..., "aps": {...} }`
internal struct PushPayloadParser: Sendable {
    
    private let logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    // MARK: - Public Entry Point
    
    /// Parses a push payload into a typed notification.
    func parse(_ payload: PushPayload) -> PushNotificationType {
        let data = extractDataDictionary(from: payload.values)
        
        let action = normalizedAction(from: data)
        let typeHint = (firstString(in: data, keys: "type") ?? "").lowercased()
        
        logger.debug("Parsing push — action: \(action), typeHint: \(typeHint)")
        
        switch action {
        case .incomingCall:
            let isSip = typeHint.contains("sip")
            return parseIncomingCall(data: data, isSip: isSip)
            
        case .callOver:
            return parseCallOver(data: data)
            
        case .messageReceived:
            return parseMessageReceived(data: data)
            
        case .unrecognized:
            logger.debug("Push payload not recognized as a Kasookoo call/message notification")
            return .generic(data: stringifyDictionary(data))
        }
    }
    
    // MARK: - Action Normalization
    
    /// Maps the backend's `action` (with `type` as a fallback hint) onto a
    /// normalized `PushAction`. Mirrors the action vocabulary the backend emits.
    private func normalizedAction(from data: [String: AnyCodableValue]) -> PushAction {
        let rawAction = (firstString(in: data, keys: "action") ?? "").lowercased()
        
        switch rawAction {
        case "incoming_call", "receive_call":
            return .incomingCall
            
        case "call_cancelled", "call_canceled", "end_call", "cancel_call",
             "reject_call", "reject_incoming_call", "caller_end_call":
            return .callOver
            
        case "receive_message":
            return .messageReceived
            
        default:
            break
        }
        
        // No usable action — fall back to the `type` hint.
        let typeHint = (firstString(in: data, keys: "type") ?? "").lowercased()
        
        if typeHint.contains("incoming_call") || typeHint.contains("receive_call") {
            return .incomingCall
        }
        if typeHint.contains("receive_message") || typeHint.contains("message") {
            return .messageReceived
        }
        if typeHint.contains("cancel") || typeHint.contains("reject") || typeHint.contains("end_call") {
            return .callOver
        }
        
        return .unrecognized
    }
    
    // MARK: - Payload Normalization
    
    /// FCM nests custom fields under "data"; APNs delivers them at the root
    /// alongside "aps". This returns the right dictionary either way.
    ///
    /// When the payload is FCM-nested, root-level keys are merged in as a
    /// fallback so that fields the backend places at the top level (e.g. an
    /// `accessToken` injected by an adapter) are not lost.
    private func extractDataDictionary(from payload: [String: AnyCodableValue]) -> [String: AnyCodableValue] {
        var result: [String: AnyCodableValue] = [:]
        
        // Start with root-level fields (minus iOS system metadata).
        for (key, value) in payload where key != "aps" && key != "data" {
            result[key] = value
        }
        
        // Nested "data" wins on conflict — it is the backend's custom payload.
        if case .dictionary(let nested) = payload["data"] {
            for (key, value) in nested {
                result[key] = value
            }
        }
        
        return result
    }
    
    private func stringifyDictionary(_ dict: [String: AnyCodableValue]) -> [String: String] {
        var result: [String: String] = [:]
        for (key, value) in dict {
            result[key] = stringValue(value) ?? describe(value)
        }
        return result
    }
    
    // MARK: - Incoming Call Parsing
    
    private func parseIncomingCall(data: [String: AnyCodableValue], isSip: Bool) -> PushNotificationType {
        // The backend does not send a distinct call id — the room name IS the
        // call identity (this is what the rest of the call APIs key on too).
        guard let roomName = firstString(in: data, keys: "room_name", "roomName") else {
            logger.warning("Incoming call push missing room_name — cannot handle")
            return .unknown
        }
        
        let callId = firstString(in: data, keys: "callId", "call_id") ?? roomName
        
        // ─── LiveKit credentials (CRITICAL — no audio without these) ─────────
        let accessToken = firstString(in: data, keys: "accessToken", "access_token")
        let wsUrl = firstString(in: data, keys: "wsUrl", "ws_url")
            .map { normalizeWebSocketURL($0) }
        
        if accessToken == nil || wsUrl == nil {
            logger.warning("Incoming call push is missing accessToken/wsUrl — the call cannot join the media room and will have no audio")
        }
        
        // ─── Caller ──────────────────────────────────────────────────────────
        let callerName = firstString(
            in: data,
            keys: "participant_identity_name", "callerName", "caller_name", "sender_name"
        ) ?? "Unknown Caller"
        
        let callerEmail = firstString(in: data, keys: "callerEmail", "caller_email") ?? ""
        let callerPhone = firstString(in: data, keys: "callerPhoneNumber", "caller_phone_number") ?? ""
        
        // `participant_identity_type` describes the *caller's* role (customer/driver).
        let callerTypeStr = firstString(
            in: data,
            keys: "participant_identity_type", "callerType", "caller_type"
        ) ?? ParticipantType.customer.rawValue
        
        let caller = Participant(
            name: callerName,
            email: callerEmail,
            phoneNumber: callerPhone,
            type: ParticipantType(rawValue: callerTypeStr.lowercased()) ?? .customer
        )
        
        // ─── Callee (the local user) ─────────────────────────────────────────
        let calleeName = firstString(in: data, keys: "calleeName", "callee_name") ?? "Me"
        let calleeEmail = firstString(in: data, keys: "calleeEmail", "callee_email") ?? ""
        let calleePhone = firstString(in: data, keys: "calleePhoneNumber", "callee_phone_number") ?? ""
        
        let callee = Participant(
            name: calleeName,
            email: calleeEmail,
            phoneNumber: calleePhone,
            type: .customer
        )
        
        let info = IncomingCallInfo(
            callId: callId,
            roomName: roomName,
            caller: caller,
            callee: callee,
            isSipCall: isSip,
            accessToken: accessToken,
            wsUrl: wsUrl
        )
        
        logger.info("Parsed incoming \(isSip ? "SIP " : "")call push — room: \(roomName), hasCredentials: \(info.hasMediaCredentials)")
        
        return isSip ? .incomingSipCall(info) : .incomingCall(info)
    }
    
    // MARK: - Call Over Parsing (cancelled / rejected / caller ended)
    
    private func parseCallOver(data: [String: AnyCodableValue]) -> PushNotificationType {
        // Same identity rule as incoming: the room name is the call id.
        guard let callId = firstString(in: data, keys: "callId", "call_id", "room_name", "roomName") else {
            logger.warning("Call-over push missing room_name/callId")
            return .unknown
        }
        return .callCancelled(callId: callId)
    }
    
    // MARK: - Message Received Parsing
    
    /// Parses a message push.
    ///
    /// NOTE: The backend's message push is a *notification*, not the message
    /// itself — it carries routing fields (room, sender, conversation) and the
    /// notification `body`, but not the full persisted message record. The app
    /// is expected to fetch the message list over REST after being notified.
    /// We therefore build a best-effort `Message` from what is present.
    private func parseMessageReceived(data: [String: AnyCodableValue]) -> PushNotificationType {
        guard let roomName = firstString(in: data, keys: "room_name", "roomName") else {
            logger.warning("Message push missing room_name")
            return .unknown
        }
        
        let messageId = firstString(
            in: data,
            keys: "message_id", "messageId", "gcm.message_id"
        ) ?? UUID().uuidString
        
        // The backend identifies participants by user id in pushes (not email).
        let senderIdentity = firstString(
            in: data,
            keys: "sender_email", "senderEmail", "sender_user_id", "senderUserId"
        ) ?? ""
        
        let receiverIdentity = firstString(
            in: data,
            keys: "receiver_email", "receiverEmail", "receiver_user_id", "receiverUserId"
        ) ?? ""
        
        // Message text arrives as the notification body in most cases.
        let content = firstString(in: data, keys: "content", "message", "body") ?? ""
        
        let messageTypeStr = firstString(in: data, keys: "message_type", "messageType")
            ?? MessageType.text.rawValue
        let mediaURL = firstString(in: data, keys: "media_url", "mediaUrl").flatMap { URL(string: $0) }
        
        let message = Message(
            id: messageId,
            roomName: roomName,
            senderEmail: senderIdentity,
            receiverEmail: receiverIdentity,
            content: content,
            messageType: MessageType(rawValue: messageTypeStr) ?? .text,
            mediaURL: mediaURL,
            sentAt: Date(),
            status: .delivered,
            isOutgoing: false
        )
        
        return .messageReceived(message)
    }
    
    // MARK: - Helper: AnyCodableValue Extraction
    
    /// Coerces a media-server URL into a scheme LiveKit can actually use.
    ///
    /// The backend has been observed sending `https://` where a WebSocket URL is
    /// expected (confirmed on the SIP make-call response, where the nested
    /// `data.wsUrl` is `https://` while the top-level one is `wss://`). LiveKit
    /// requires `ws://` or `wss://`, so we normalize defensively rather than
    /// failing to connect.
    private func normalizeWebSocketURL(_ url: String) -> String {
        if url.hasPrefix("wss://") || url.hasPrefix("ws://") {
            return url
        }
        if url.hasPrefix("https://") {
            return "wss://" + url.dropFirst("https://".count)
        }
        if url.hasPrefix("http://") {
            return "ws://" + url.dropFirst("http://".count)
        }
        return url
    }
    
    /// Extracts a string from an `AnyCodableValue?`.
    ///
    /// FCM delivers *all* data-payload values as strings, but APNs adapters may
    /// pass numbers/bools through natively — so non-string scalars are coerced
    /// rather than dropped.
    private func stringValue(_ value: AnyCodableValue?) -> String? {
        guard let value = value else { return nil }
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .array, .dictionary, .null: return nil
        }
    }
    
    /// Returns the first non-empty string found by checking multiple keys in order.
    /// Supports snake_case and camelCase variants from the backend.
    private func firstString(in dict: [String: AnyCodableValue], keys: String...) -> String? {
        for key in keys {
            if let s = stringValue(dict[key]), !s.isEmpty { return s }
        }
        return nil
    }
    
    /// Best-effort string representation for fallback logging.
    private func describe(_ value: AnyCodableValue) -> String {
        switch value {
        case .string(let s): return s
        case .int(let i): return String(i)
        case .double(let d): return String(d)
        case .bool(let b): return String(b)
        case .array: return "[array]"
        case .dictionary: return "[dictionary]"
        case .null: return "null"
        }
    }
}
