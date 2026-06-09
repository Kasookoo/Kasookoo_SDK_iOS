//
//  KasookooError.swift
//  KasookooSDK
//
//  The unified error type used throughout the SDK.
//  All errors (network, decoding, business logic) are normalized into this type
//  before being exposed to the app developer (Section 8 of the SDK spec).
//

import Foundation

/// The unified error type produced by the Kasookoo SDK.
///
/// All internal errors — network failures, JSON decoding errors, server errors,
/// validation errors — are normalized into `KasookooError` before being thrown
/// to the app developer.
///
/// ## Example
/// ```swift
/// do {
///     try await sdk.connect()
/// } catch let error as KasookooError {
///     if error.code == .sessionExpired {
///         // Re-authenticate the user
///     } else if error.retryable {
///         // Retry the operation
///     }
/// }
/// ```
public struct KasookooError: Error, Sendable {
    
    // MARK: - Public Properties
    
    /// A stable error code identifying the type of error.
    public let code: ErrorCode
    
    /// A human-readable message describing the error.
    /// This message is intended for developers; do not show it directly to end users.
    public let message: String
    
    /// Whether this error is potentially retryable.
    /// Network and transient errors are retryable; validation errors are not.
    public let retryable: Bool
    
    /// The HTTP status code associated with this error, if any.
    public let httpStatus: Int?
    
    /// A unique request identifier from the backend, used for support and debugging.
    public let requestId: String?
    
    /// Additional context-specific details about the error.
    public let details: [String: String]?
    
    /// The underlying error, if this error wraps another error.
    /// Not exposed to consumers but useful for internal debugging.
    internal let underlyingError: Error?
    
    // MARK: - Initialization
    
    /// Creates a new SDK error.
    ///
    /// - Parameters:
    ///   - code: The stable error code.
    ///   - message: A human-readable message.
    ///   - retryable: Whether the error is retryable. Defaults to `false`.
    ///   - httpStatus: The HTTP status code, if applicable.
    ///   - requestId: The backend request ID, if available.
    ///   - details: Additional context.
    ///   - underlyingError: The original error being wrapped, if any.
    public init(
        code: ErrorCode,
        message: String,
        retryable: Bool = false,
        httpStatus: Int? = nil,
        requestId: String? = nil,
        details: [String: String]? = nil,
        underlyingError: Error? = nil
    ) {
        self.code = code
        self.message = message
        self.retryable = retryable
        self.httpStatus = httpStatus
        self.requestId = requestId
        self.details = details
        self.underlyingError = underlyingError
    }
}

// MARK: - LocalizedError Conformance

extension KasookooError: LocalizedError {
    
    public var errorDescription: String? {
        return message
    }
    
    public var failureReason: String? {
        return "Error code: \(code.rawValue)"
    }
}

// MARK: - CustomStringConvertible

extension KasookooError: CustomStringConvertible {
    
    public var description: String {
        var parts = ["KasookooError(code: \(code.rawValue)"]
        parts.append("message: \"\(message)\"")
        if let httpStatus = httpStatus {
            parts.append("httpStatus: \(httpStatus)")
        }
        if let requestId = requestId {
            parts.append("requestId: \(requestId)")
        }
        parts.append("retryable: \(retryable))")
        return parts.joined(separator: ", ")
    }
}

// MARK: - Convenience Factory Methods

extension KasookooError {
    
    // MARK: Configuration
    
    /// Creates a `CONFIG_INVALID` error for missing or invalid configuration.
    public static func configInvalid(_ message: String, details: [String: String]? = nil) -> KasookooError {
        return KasookooError(
            code: .configInvalid,
            message: message,
            retryable: false,
            details: details
        )
    }
    
    // MARK: Session
    
    /// Creates a `SESSION_EXPIRED` error.
    public static func sessionExpired(message: String = "Session expired. Please reconnect.") -> KasookooError {
        return KasookooError(
            code: .sessionExpired,
            message: message,
            retryable: true,
            httpStatus: 401
        )
    }
    
    /// Creates a `SESSION_INVALID` error.
    public static func sessionInvalid(message: String = "Session is invalid or has been revoked.") -> KasookooError {
        return KasookooError(
            code: .sessionInvalid,
            message: message,
            retryable: false,
            httpStatus: 401
        )
    }
    
    // MARK: Permissions
    
    /// Creates a `PERMISSION_DENIED` error.
    public static func permissionDenied(message: String = "You do not have permission to perform this action.") -> KasookooError {
        return KasookooError(
            code: .permissionDenied,
            message: message,
            retryable: false,
            httpStatus: 403
        )
    }
    
    // MARK: Network
    
    /// Creates a `NETWORK_UNAVAILABLE` error wrapping an underlying error.
    public static func networkUnavailable(
        message: String = "Network is unavailable.",
        underlyingError: Error? = nil
    ) -> KasookooError {
        return KasookooError(
            code: .networkUnavailable,
            message: message,
            retryable: true,
            underlyingError: underlyingError
        )
    }
    
    // MARK: Calling
    
    /// Creates a `CALL_FAILED` error.
    public static func callFailed(
        message: String,
        retryable: Bool = false,
        details: [String: String]? = nil,
        underlyingError: Error? = nil
    ) -> KasookooError {
        return KasookooError(
            code: .callFailed,
            message: message,
            retryable: retryable,
            details: details,
            underlyingError: underlyingError
        )
    }
    
    // MARK: Messaging
    
    /// Creates a `MESSAGE_SEND_FAILED` error.
    public static func messageSendFailed(
        message: String = "Failed to send message.",
        retryable: Bool = true,
        underlyingError: Error? = nil,
        details: [String: String]? = nil
    ) -> KasookooError {
        return KasookooError(
            code: .messageSendFailed,
            message: message,
            retryable: retryable,
            details: details,
            underlyingError: underlyingError
        )
    }
    
    // MARK: Unknown
    
    /// Creates an `UNKNOWN_ERROR` for unexpected failures.
    public static func unknown(
        message: String = "An unexpected error occurred.",
        underlyingError: Error? = nil
    ) -> KasookooError {
        return KasookooError(
            code: .unknownError,
            message: message,
            retryable: false,
            underlyingError: underlyingError
        )
    }
}
