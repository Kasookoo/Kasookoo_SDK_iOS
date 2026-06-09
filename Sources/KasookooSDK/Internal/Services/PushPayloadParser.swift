//
//  PushPayloadParser.swift
//  KasookooSDK
//
//

import Foundation

// MARK: - Parsed Notification Types

/// The result of parsing a push payload.
internal enum PushNotificationType: Sendable {
    
    /// An incoming WebRTC call (use CallKit).
    case incomingCall(IncomingCallInfo)
    
    /// An incoming SIP call (use CallKit).
    case incomingSipCall(IncomingCallInfo)
    
    /// A call that was cancelled before being answered.
    /// CallKit must be notified to dismiss the incoming-call UI.
    case callCancelled(callId: String)
    
    /// A new chat message arrived.
    case messageReceived(Message)
    
    /// A generic notification (no special handling).
    case generic(data: [String: String])
    
    /// Payload was not recognized as a Kasookoo notification.
    case unknown
}

// MARK: - Parser

/// Parses push payloads into typed `PushNotificationType` values.
///
/// Handles both shapes:
/// - Direct APNs payload: `{ "type": "call.incoming", "callId": "...", ... }`
/// - FCM-wrapped payload: `{ "data": { "type": "call.incoming", ... } }`
///
/// The `"type"` field is the discriminator. All other fields depend on the type.
internal struct PushPayloadParser: Sendable {
    
    private let logger: Logger
    
    init(logger: Logger) {
        self.logger = logger
    }
    
    // MARK: - Public Entry Point
    
    /// Parses a push payload into a typed notification.
    func parse(_ payload: PushPayload) -> PushNotificationType {
        // Normalize: extract the data dictionary, unwrapping FCM nesting if present
        let data = extractDataDictionary(from: payload.values)
        
        // Identify by 'type' field — match event names for cross-platform parity
        guard let type = stringValue(data["type"]) else {
            logger.warning("Push payload missing 'type' field; treating as unknown")
            return .unknown
        }
        
        logger.debug("Parsing push with type: \(type)")
        
        switch type {
        case EventName.callIncoming, "call.incoming":
            return parseIncomingCall(data: data, isSip: false)
            
        case "sip.incoming":
            return parseIncomingCall(data: data, isSip: true)
            
        case "call.cancelled", "call.canceled":
            return parseCallCancelled(data: data)
            
        case EventName.messageReceived, "message.received":
            return parseMessageReceived(data: data)
            
        default:
            // Unknown type → treat as generic notification
            return .generic(data: stringifyDictionary(data))
        }
    }
    
    // MARK: - Payload Normalization
    
    /// FCM wraps custom payload under a "data" key. APNs delivers it at the top level
    /// (or nested under "aps" for system fields). This method returns the right
    /// dictionary regardless of which delivery system the backend used.
    private func extractDataDictionary(from payload: [String: AnyCodableValue]) -> [String: AnyCodableValue] {
        // FCM-style: { "data": { ...custom fields... }, "aps": { ... } }
        if case .dictionary(let nested) = payload["data"] {
            return nested
        }
        
        // APNs-style: custom fields at root, alongside "aps"
        // Strip "aps" since it's iOS system metadata, not app data.
        var result: [String: AnyCodableValue] = [:]
        for (key, value) in payload where key != "aps" {
            result[key] = value
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
        guard let callId = firstString(in: data, keys: "callId", "call_id"),
              let roomName = firstString(in: data, keys: "roomName", "room_name") else {
            logger.warning("Incoming call push missing callId or roomName")
            return .unknown
        }
        
        // Caller info — fall back to phone-number-only if backend sends sparse data
        let callerName = firstString(in: data, keys: "callerName", "caller_name")
            ?? "Unknown Caller"
        let callerEmail = firstString(in: data, keys: "callerEmail", "caller_email")
            ?? "unknown@kasookoo.local"
        let callerPhone = firstString(in: data, keys: "callerPhoneNumber", "caller_phone_number")
            ?? ""
        let callerTypeStr = firstString(in: data, keys: "callerType", "caller_type")
            ?? ParticipantType.customer.rawValue
        
        let caller = Participant(
            name: callerName,
            email: callerEmail,
            phoneNumber: callerPhone,
            type: ParticipantType(rawValue: callerTypeStr) ?? .customer
        )
        
        // Callee info (local user)
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
            isSipCall: isSip
        )
        
        return isSip ? .incomingSipCall(info) : .incomingCall(info)
    }
    
    // MARK: - Call Cancelled Parsing
    
    private func parseCallCancelled(data: [String: AnyCodableValue]) -> PushNotificationType {
        guard let callId = firstString(in: data, keys: "callId", "call_id") else {
            logger.warning("Call cancelled push missing callId")
            return .unknown
        }
        return .callCancelled(callId: callId)
    }
    
    // MARK: - Message Received Parsing
    
    private func parseMessageReceived(data: [String: AnyCodableValue]) -> PushNotificationType {
        guard let messageId = firstString(in: data, keys: "messageId", "message_id"),
              let roomName = firstString(in: data, keys: "roomName", "room_name"),
              let senderEmail = firstString(in: data, keys: "senderEmail", "sender_email"),
              let receiverEmail = firstString(in: data, keys: "receiverEmail", "receiver_email"),
              let content = firstString(in: data, keys: "content", "message") else {
            logger.warning("Message push missing required fields")
            return .unknown
        }
        
        let messageTypeStr = firstString(in: data, keys: "messageType", "message_type")
            ?? MessageType.text.rawValue
        let mediaUrlStr = firstString(in: data, keys: "mediaUrl", "media_url")
        let mediaURL = mediaUrlStr.flatMap { URL(string: $0) }
        
        let message = Message(
            id: messageId,
            roomName: roomName,
            senderEmail: senderEmail,
            receiverEmail: receiverEmail,
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
    
    /// Extracts a string from an `AnyCodableValue?`, if it is `.string`.
    private func stringValue(_ value: AnyCodableValue?) -> String? {
        guard let value = value else { return nil }
        if case .string(let s) = value { return s }
        return nil
    }
    
    /// Returns the first non-nil string found by checking multiple keys in order.
    /// Used to support both camelCase and snake_case field names from the backend.
    private func firstString(in dict: [String: AnyCodableValue], keys: String...) -> String? {
        for key in keys {
            if let s = stringValue(dict[key]) { return s }
        }
        return nil
    }
    
    /// Best-effort string representation of an `AnyCodableValue` for fallback logging.
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
