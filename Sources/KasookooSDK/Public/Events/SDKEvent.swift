//
//  SDKEvent.swift
//  KasookooSDK
//
//  The standard event payload structure used by all SDK events (Section 7).
//

import Foundation

/// The standard event payload emitted by the Kasookoo SDK.
///
/// All events emitted via `sdk.on(...)` arrive as `SDKEvent` instances with
/// a consistent structure (Section 7 of the spec).
///
/// ## Example
/// ```swift
/// sdk.on(EventName.callIncoming) { event in
///     print("Event: \(event.name) at \(event.timestamp)")
///     if let callerEmail = event.data["callerEmail"] as? String {
///         print("From: \(callerEmail)")
///     }
/// }
/// ```
public struct SDKEvent: Sendable {
    
    // MARK: - Public Properties
    
    /// A unique identifier for this event instance.
    public let eventId: String
    
    /// The name of the event (e.g., "call.incoming"). See `EventName` for constants.
    public let name: String
    
    /// The time this event was emitted.
    public let timestamp: Date
    
    /// The organization ID this event belongs to.
    public let organizationId: String
    
    /// The email of the central identity associated with this event.
    /// May be `nil` for events that occur before identification (e.g., `sdk.ready`).
    public let userEmail: String?
    
    /// Module-specific event data.
    /// The contents depend on the event type. See documentation for each event.
    public let data: [String: AnyCodableValue]
    
    // MARK: - Initialization
    
    /// Creates a new SDK event.
    ///
    /// - Parameters:
    ///   - name: The event name. Should match a constant from `EventName`.
    ///   - organizationId: The organization ID.
    ///   - userEmail: The user's email, if known.
    ///   - data: Event-specific payload data.
    ///   - eventId: A unique ID. Auto-generated if not provided.
    ///   - timestamp: The event timestamp. Defaults to the current time.
    public init(
        name: String,
        organizationId: String,
        userEmail: String? = nil,
        data: [String: AnyCodableValue] = [:],
        eventId: String = UUID().uuidString,
        timestamp: Date = Date()
    ) {
        self.eventId = eventId
        self.name = name
        self.timestamp = timestamp
        self.organizationId = organizationId
        self.userEmail = userEmail
        self.data = data
    }
}

// MARK: - Convenience Accessors

extension SDKEvent {
    
    /// Retrieves a string value from the event data.
    public func string(_ key: String) -> String? {
        guard case .string(let value) = data[key] else { return nil }
        return value
    }
    
    /// Retrieves an integer value from the event data.
    public func int(_ key: String) -> Int? {
        guard case .int(let value) = data[key] else { return nil }
        return value
    }
    
    /// Retrieves a boolean value from the event data.
    public func bool(_ key: String) -> Bool? {
        guard case .bool(let value) = data[key] else { return nil }
        return value
    }
    
    /// Retrieves a double value from the event data.
    public func double(_ key: String) -> Double? {
        guard case .double(let value) = data[key] else { return nil }
        return value
    }
}

// MARK: - AnyCodableValue (Sendable JSON value)

/// A type-safe wrapper for arbitrary JSON values that can be safely passed
/// across Swift concurrency boundaries.
///
/// We use this instead of `[String: Any]` because `Any` is not `Sendable`,
/// which would cause issues when emitting events from actors or background tasks.
public enum AnyCodableValue: Sendable, Codable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
    case array([AnyCodableValue])
    case dictionary([String: AnyCodableValue])
    case null
    
    // MARK: - Codable
    
    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode([AnyCodableValue].self) {
            self = .array(value)
        } else if let value = try? container.decode([String: AnyCodableValue].self) {
            self = .dictionary(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "Unable to decode AnyCodableValue"
            )
        }
    }
    
    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .string(let value): try container.encode(value)
        case .int(let value): try container.encode(value)
        case .double(let value): try container.encode(value)
        case .bool(let value): try container.encode(value)
        case .array(let value): try container.encode(value)
        case .dictionary(let value): try container.encode(value)
        case .null: try container.encodeNil()
        }
    }
}

// MARK: - ExpressibleBy Literals (developer convenience)

extension AnyCodableValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) {
        self = .string(value)
    }
}

extension AnyCodableValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) {
        self = .int(value)
    }
}

extension AnyCodableValue: ExpressibleByFloatLiteral {
    public init(floatLiteral value: Double) {
        self = .double(value)
    }
}

extension AnyCodableValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) {
        self = .bool(value)
    }
}

extension AnyCodableValue: ExpressibleByNilLiteral {
    public init(nilLiteral: ()) {
        self = .null
    }
}
