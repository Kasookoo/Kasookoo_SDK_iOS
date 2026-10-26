import Foundation

// This file must NOT import OpenTelemetryApi.
//
// It defines the SDK-facing telemetry seam in plain Swift types, so module code
// (Messaging, Calling, SIP) never touches OpenTelemetry directly. That keeps the
// vendor swappable: only `OTelTelemetry.swift` knows OpenTelemetry exists.
//
// It is also where `SDKLogger` is declared. `OpenTelemetryApi` exports a type
// called `Logger` too, so in any file that imports it the bare name `Logger` is
// ambiguous, and `KasookooSDK.Logger` does not help (the facade class shadows the
// module name). Resolving the alias here, where only the SDK's `Logger` is
// visible, gives those files an unambiguous name to use.

internal typealias SDKLogger = Logger

// MARK: - Attribute Value

/// A telemetry attribute value.
///
/// Mirrors the subset of OpenTelemetry's `AttributeValue` the SDK actually uses.
/// Literal conformances let call sites stay readable:
/// `["result": "ok", "attempt": 2, "cached": false]`.
internal enum TelemetryAttribute: Sendable, Equatable {
    case string(String)
    case int(Int)
    case double(Double)
    case bool(Bool)
}

extension TelemetryAttribute: ExpressibleByStringLiteral {
    init(stringLiteral value: String) { self = .string(value) }
}

extension TelemetryAttribute: ExpressibleByIntegerLiteral {
    init(integerLiteral value: Int) { self = .int(value) }
}

extension TelemetryAttribute: ExpressibleByFloatLiteral {
    init(floatLiteral value: Double) { self = .double(value) }
}

extension TelemetryAttribute: ExpressibleByBooleanLiteral {
    init(booleanLiteral value: Bool) { self = .bool(value) }
}

// MARK: - Severity

internal enum TelemetrySeverity: Sendable {
    case debug
    case info
    case warn
    case error
}

// MARK: - Span Handle

/// A started span. Always call `end()`, normally from a `defer`.
///
/// Implementations are safe to call from any thread and must never throw.
internal protocol TelemetrySpanHandle: AnyObject, Sendable {

    /// Adds or replaces an attribute. Redaction is applied by the implementation.
    func setAttribute(_ key: String, _ value: TelemetryAttribute)

    /// Marks the span as failed. Does not end it.
    func setError(_ message: String)

    /// Ends the span. Calling it more than once is a no-op.
    func end()
}

// MARK: - Reporter

/// The SDK's telemetry sink.
///
/// Every method is fire and forget: no throwing, no blocking on the network, no
/// effect on the caller's control flow. A telemetry failure must never change
/// what the SDK does, which matters most on the incoming call path.
internal protocol TelemetryReporting: Sendable {

    /// Starts a span. Correlation attributes from the active `TraceContext` are
    /// attached automatically.
    func startSpan(_ name: String, attributes: [String: TelemetryAttribute]) -> TelemetrySpanHandle

    /// Emits a structured log record. `event` is the machine readable name that
    /// Loki queries filter on (for example `CALL_FAILED`).
    func log(
        event: String,
        message: String,
        severity: TelemetrySeverity,
        attributes: [String: TelemetryAttribute]
    )

    /// Emits a plain log line (the SDK's own `Logger` output), so it appears
    /// in Loki next to the backend's logs. Unlike `log(event:)` it carries no
    /// `event` attribute: it is context, not a queryable incident.
    func logMessage(
        _ message: String,
        severity: TelemetrySeverity,
        attributes: [String: TelemetryAttribute]
    )

    /// Sets the end user id attached to spans and logs as `user_id`.
    /// Pass `nil` on disconnect or sign out.
    func setUserId(_ userId: String?)

    /// Asks the batch processors to export what they are holding.
    func flush()

    /// Flushes and stops the pipelines. The instance is unusable afterwards.
    func shutdown()
}

extension TelemetryReporting {

    func startSpan(_ name: String) -> TelemetrySpanHandle {
        startSpan(name, attributes: [:])
    }

    func logError(_ event: String, _ message: String, attributes: [String: TelemetryAttribute] = [:]) {
        log(event: event, message: message, severity: .error, attributes: attributes)
    }

    func logInfo(_ event: String, _ message: String, attributes: [String: TelemetryAttribute] = [:]) {
        log(event: event, message: message, severity: .info, attributes: attributes)
    }

    func logWarning(_ event: String, _ message: String, attributes: [String: TelemetryAttribute] = [:]) {
        log(event: event, message: message, severity: .warn, attributes: attributes)
    }
}

// MARK: - No-op Implementation

/// Used when telemetry is disabled for a tenant, and as the default in
/// `ModuleContext` so nothing breaks before the pipeline is wired.
internal struct NoopTelemetry: TelemetryReporting {

    init() {}

    func startSpan(_ name: String, attributes: [String: TelemetryAttribute]) -> TelemetrySpanHandle {
        NoopSpanHandle()
    }

    func log(
        event: String,
        message: String,
        severity: TelemetrySeverity,
        attributes: [String: TelemetryAttribute]
    ) {}

    func logMessage(
        _ message: String,
        severity: TelemetrySeverity,
        attributes: [String: TelemetryAttribute]
    ) {}

    func setUserId(_ userId: String?) {}
    func flush() {}
    func shutdown() {}
}

internal final class NoopSpanHandle: TelemetrySpanHandle {
    init() {}
    func setAttribute(_ key: String, _ value: TelemetryAttribute) {}
    func setError(_ message: String) {}
    func end() {}
}

// MARK: - Names

/// Span names, kept in one place so Tempo queries stay stable.
///
/// Calling and SIP names are declared now but are only emitted when those
/// modules migrate, so the vocabulary does not drift later.
internal enum TelemetrySpan {
    // Session and identity
    static let sessionMint = "session.mint"
    static let identify = "identify"

    // Messaging
    static let messagingSend = "messaging.send"
    static let messagingSync = "messaging.sync"

    // In-app calling
    static let webrtcCreateSession = "webrtc.create_session"
    static let webrtcJoin = "webrtc.join"
    static let webrtcEnd = "webrtc.end"

    // SIP
    static let sipOutbound = "sip.outbound"
    static let sipTokenMint = "sip.token_mint"
}

/// Log event names. These are the values Loki filters on via `event="..."`,
/// so they are uppercase and must not be renamed casually.
internal enum TelemetryEvent {
    static let sessionExpired = "SESSION_EXPIRED"
    static let userNotFound = "USER_NOT_FOUND"
    static let identifyFailed = "IDENTIFY_FAILED"
    static let callFailed = "CALL_FAILED"
    static let sipCallFailed = "SIP_CALL_FAILED"
    static let micPermissionDenied = "MIC_PERMISSION_DENIED"
    static let messageSendFailed = "MESSAGE_SEND_FAILED"
    static let pushRoutingFailed = "PUSH_ROUTING_FAILED"
}

/// Attribute keys shared by spans and log records, matching the backend's
/// Loki fields so mobile and server records join on the same names.
internal enum TelemetryKey {
    static let callTraceId = "call_trace_id"
    static let requestId = "request_id"
    static let userId = "user_id"
    static let featureType = "feature_type"
    static let event = "event"
    static let level = "level"
    static let result = "result"
    static let errorCode = "error_code"
    /// Category of the SDK logger that wrote the line (e.g. "SDK").
    static let logger = "logger"
    /// "File.swift:123" of the log call. ("code.*" keys are redacted.)
    static let source = "source"
}

extension LoggingConfig.Level {
    /// Severity used when a logger line is exported.
    var telemetrySeverity: TelemetrySeverity {
        switch self {
        case .verbose, .debug: return .debug
        case .info, .none: return .info
        case .warning: return .warn
        case .error: return .error
        }
    }
}
