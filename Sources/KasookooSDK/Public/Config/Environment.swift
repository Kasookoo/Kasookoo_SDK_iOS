//
//  Environment.swift
//  KasookooSDK
//
//  Defines the deployment environment for the SDK.
//

import Foundation

/// The deployment environment for the SDK.
///
/// Determines which backend URL the SDK will connect to.
public enum Environment: String, Sendable, Codable {
    
    /// Production environment. Live user traffic.
    case production = "production"
    
    /// Staging environment. Pre-release testing.
    case staging = "staging"
    
    /// Development environment. Local or dev backends.
    case development = "development"
    
    // MARK: - Backend URLs
    
    /// The base URL for this environment.
    ///
    /// **Current state:** All three point to the same backend until separate
    /// staging/dev environments are confirmed with the backend team.
    public var baseURL: URL {
        switch self {
        case .production:
            return URL(string: "https://sdk.kasookoo.ai")!
        case .staging:
            // TODO: Replace with actual staging URL when available from backend team
            return URL(string: "https://sdk.kasookoo.ai")!
        case .development:
            // TODO: Replace with actual development URL when available from backend team
            return URL(string: "https://sdk.kasookoo.ai")!
        }
    }
}
