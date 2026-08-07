//
//  KasookooEnvironment.swift
//  KasookooSDK
//
//  Defines the deployment environment for the SDK.
//

import Foundation

/// The deployment environment for the SDK.
///
/// Determines which backend URL the SDK will connect to.
///
/// - Note: Named `KasookooEnvironment` rather than `Environment` on purpose.
///   SwiftUI ships an `Environment` property wrapper that virtually every iOS
///   app uses (`@Environment(\.dismiss)`, `@Environment(\.colorScheme)`, …). A
///   public type called `Environment` here would collide with it in any file
///   that imports both, forcing consumers to write `@SwiftUI.Environment`
///   everywhere. Prefixing keeps the SDK a good citizen in host apps.
public enum KasookooEnvironment: String, Sendable, Codable {
    
    /// Production environment. Live user traffic.
    case production = "production"
    
    /// Staging environment. Pre-release testing.
    case staging = "staging"
    
    /// Development environment. Local or dev backends.
    case development = "development"
    
    // MARK: - Backend URLs
    
    /// The base URL for this environment.
    public var baseURL: URL {
        switch self {
        case .production:
            return URL(string: "https://sdk.kasookoo.ai")!
        case .staging:
            return URL(string: "https://sdk-test.kasookoo.ai")!
        case .development:
            // TODO: Replace with the actual development URL when the backend
            // team confirms one. Falls back to staging so dev builds still work.
            return URL(string: "https://sdk-test.kasookoo.ai")!
        }
    }
}
