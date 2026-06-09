//
//  ServerErrorDTO.swift
//  KasookooSDK
//
//

import Foundation

/// The error response shape returned by the backend.
///
/// Most backends return errors in a consistent format. This DTO models that.
/// Adjust the structure here when the actual backend error format is confirmed.
internal struct ServerErrorDTO: Decodable, Sendable {
    
    /// Server-provided error code (e.g., "SESSION_EXPIRED").
    let code: String?
    
    /// Human-readable error message.
    let message: String?
    
    /// A unique request ID for support and tracing.
    let requestId: String?
    
    /// Additional error context.
    let details: [String: String]?
    
    enum CodingKeys: String, CodingKey {
        case code
        case message
        case requestId = "request_id"
        case details
    }
}
