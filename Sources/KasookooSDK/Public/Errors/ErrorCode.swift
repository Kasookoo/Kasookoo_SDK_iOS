//
//  ErrorCode.swift
//  KasookooSDK
//
//  Defines all error codes that the SDK can produce.
//  These codes MUST match exactly across React, Kotlin, and Swift SDKs
//  for cross-platform consistency (Section 14 of the SDK spec).
//

import Foundation

/// Standard error codes returned by the Kasookoo SDK.
///
/// These codes are stable identifiers that can be used by app developers
/// to programmatically handle specific error conditions.
///
/// **Cross-platform contract:** The raw string values of these codes must be
/// identical across React, Kotlin, and Swift SDKs.
public enum ErrorCode: String, Sendable, Codable {
    
    // MARK: - Configuration Errors
    
    /// The configuration provided to the SDK is invalid.
    /// Check that all required fields (`publishableKey`, `organizationId`, `environment`) are set.
    case configInvalid = "CONFIG_INVALID"
    
    // MARK: - Session Errors
    
    /// The session has expired and could not be automatically refreshed.
    /// The app should typically re-authenticate the user.
    case sessionExpired = "SESSION_EXPIRED"
    
    /// The session is invalid or was revoked by the server.
    case sessionInvalid = "SESSION_INVALID"
    
    // MARK: - Authorization Errors
    
    /// The current session does not have permission to perform this action.
    case permissionDenied = "PERMISSION_DENIED"
    
    case unauthorized = "unauthorized"
    
    case userNotFound = "not_found"
    
    // MARK: - Network Errors
    
    /// The network is unavailable or the request timed out.
    case networkUnavailable = "NETWORK_UNAVAILABLE"
    
    // MARK: - Feature Errors
    
    /// A call could not be started, accepted, or completed.
    case callFailed = "CALL_FAILED"
    
    /// A message could not be sent.
    case messageSendFailed = "MESSAGE_SEND_FAILED"
    
    // MARK: - Fallback
    
    /// An unknown error occurred. Check `details` for additional context.
    case unknownError = "UNKNOWN_ERROR"
}
