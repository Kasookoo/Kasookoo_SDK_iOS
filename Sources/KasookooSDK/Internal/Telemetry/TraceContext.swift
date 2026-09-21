//
//  TraceContext.swift
//  KasookooSDK
//

import Foundation

// MARK: - Feature Type

/// Feature categories recognised by the Kasookoo backend.
///
/// Sent as the `X-Feature-Type` header and used as the `feature_type`
/// attribute on telemetry, so backend logs and client telemetry can be
/// grouped by feature. Raw values must match the backend exactly.
internal enum FeatureType: String, Sendable {
    case inAppCall = "in_app_call"
    case sipCall = "sip_call"
    case whatsappCall = "whatsapp_call"
    case whatsappMessaging = "whatsapp_messaging"
    case inAppMessaging = "in_app_messaging"
    case authenticationCalling = "authentication_calling"
    case recording = "recording"
}

// MARK: - Trace Context

/// Correlation context for one feature lifecycle (one user action such as
/// sending a message or placing a call).
///
/// A single `callTraceId` is shared by every API request made during that
/// lifecycle, so the backend can join all of them in Loki via
/// `call_trace_id`.
///
/// The context travels through async code as a `@TaskLocal`, which means it
/// is scoped per task. Two concurrent features (for example messaging while
/// an incoming call arrives) each keep their own id and never overwrite each
/// other, unlike a global static.
///
/// Note: task locals propagate to child tasks and `Task { }`, but NOT to
/// `Task.detached { }`. Lifecycles that span delegate callbacks (CallKit,
/// LiveKit) will need a per call registry; that is added with the Calling
/// module migration.
internal struct TraceContext: Sendable {

    let callTraceId: String
    let featureType: FeatureType

    init(featureType: FeatureType, callTraceId: String = TraceContext.newId()) {
        self.featureType = featureType
        self.callTraceId = callTraceId
    }

    /// The context active for the current task, if any.
    @TaskLocal static var current: TraceContext?

    /// Generates an opaque id (32 lowercase hex characters, no dashes).
    /// Used for both `call_trace_id` and `request_id`.
    static func newId() -> String {
        UUID().uuidString.replacingOccurrences(of: "-", with: "").lowercased()
    }

    /// Runs `operation` inside a feature lifecycle.
    ///
    /// If a context is already active (a nested SDK call inside a larger
    /// feature), it is reused so the whole flow stays on one trace id.
    static func run<T>(
        _ featureType: FeatureType,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        if Self.current != nil {
            return try await operation()
        }
        return try await Self.$current.withValue(TraceContext(featureType: featureType)) {
            try await operation()
        }
    }
}

// MARK: - Correlation Headers

/// Header names expected by the Kasookoo backend for log correlation.
internal enum CorrelationHeader {
    static let requestId = "X-Request-ID"
    static let callTraceId = "X-Call-Trace-ID"
    static let userId = "X-User-ID"
    static let featureType = "X-Feature-Type"
}

extension URLRequest {

    /// Adds lifecycle correlation headers.
    ///
    /// `X-Request-ID` is already set by `RequestBuilder` (HTTP header names
    /// are case insensitive, so `X-Request-Id` there is equivalent).
    mutating func applyCorrelation(trace: TraceContext?, userId: String?) {
        if let trace {
            setValue(trace.callTraceId, forHTTPHeaderField: CorrelationHeader.callTraceId)
            setValue(trace.featureType.rawValue, forHTTPHeaderField: CorrelationHeader.featureType)
        }
        if let userId, !userId.isEmpty {
            setValue(userId, forHTTPHeaderField: CorrelationHeader.userId)
        }
    }
}
