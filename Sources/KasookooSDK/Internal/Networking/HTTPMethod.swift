//
//  HTTPMethod.swift
//  KasookooSDK
//
//

import Foundation

/// HTTP methods supported by the API client.
///
/// Internal type — not exposed to SDK consumers.
internal enum HTTPMethod: String, Sendable {
    case get = "GET"
    case post = "POST"
    case put = "PUT"
    case patch = "PATCH"
    case delete = "DELETE"
    
    /// Whether this HTTP method is considered idempotent.
    /// Idempotent methods can be safely retried without side effects.
    var isIdempotent: Bool {
        switch self {
        case .get, .put, .delete:
            return true
        case .post, .patch:
            return false
        }
    }
}
