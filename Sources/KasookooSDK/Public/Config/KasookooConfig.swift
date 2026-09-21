//
//  KasookooConfig.swift
//  KasookooSDK
//
//  The main configuration struct for initializing the SDK (Section 5).
//

import Foundation

/// Configuration for the Kasookoo SDK.
///
/// Pass this to `KasookooSDK.initialize(config:)` to configure the SDK.
/// All required fields must be provided; optional fields have sensible defaults.
///
/// ## Example
/// ```swift
/// let config = KasookooConfig(
///     publishableKey: "pk_live_xxx",
///     organizationId: "org_123",
///     environment: .production,
///     userMode: .guest,
///     features: .default
/// )
///
/// try await sdk.initialize(config: config)
/// ```
public struct KasookooConfig: Sendable {
    
    // MARK: - Required Fields
    
    /// The publishable API key issued by Kasookoo.
    ///
    /// Format: `pk_live_xxx` for production, `pk_test_xxx` for testing.
    public let publishableKey: String
    
    /// The organization ID this SDK instance belongs to.
    public let organizationId: String
    
    /// The deployment environment (production, staging, development).
    public let environment: KasookooEnvironment
    
    // MARK: - Optional Fields
    
    /// The geographic region for backend routing (e.g., "eu-west-1", "us-east-1").
    /// Defaults to `nil` (backend chooses).
    public let region: String?
    
    /// The user authentication mode. Defaults to `.guest`.
    public let userMode: UserMode
    
    /// Feature flags controlling which SDK modules are active.
    public let features: FeatureFlags
    
    /// Logging configuration.
    public let logging: LoggingConfig
    
    /// An optional custom base URL that overrides the environment default.
    /// Useful for testing against non-standard backends.
    public let customBaseURL: URL?
    
    /// Telemetry reporting configuration.
    ///
    /// Leave as `nil` to follow `environment`: production reports to the
    /// production collector, staging and development report to the test
    /// collector. Pass `.disabled` to switch client side reporting off.
    public let telemetry: TelemetryConfiguration?
    
    // MARK: - Computed Properties
    
    /// The effective base URL for backend requests.
    /// Returns `customBaseURL` if set, otherwise the environment's default URL.
    public var baseURL: URL {
        return customBaseURL ?? environment.baseURL
    }
    
    /// The telemetry configuration actually used, after applying the
    /// environment default when none was supplied.
    ///
    /// An explicitly supplied configuration is used as given. A derived one
    /// also reports `deployment.environment` as the SDK environment, so
    /// staging traffic is distinguishable from development in Grafana.
    public var effectiveTelemetry: TelemetryConfiguration {
        if let telemetry {
            return telemetry
        }
        var derived: TelemetryConfiguration
        switch environment {
        case .production:
            derived = .production
        case .staging, .development:
            derived = .test
        }
        derived.environment = environment.rawValue
        return derived
    }
    
    // MARK: - Initialization
    
    /// Creates a new SDK configuration.
    ///
    /// - Parameters:
    ///   - publishableKey: The publishable API key.
    ///   - organizationId: The organization ID.
    ///   - environment: The deployment environment.
    ///   - region: Optional region for backend routing.
    ///   - userMode: User authentication mode. Defaults to `.guest`.
    ///   - features: Feature flags. Defaults to `.default`.
    ///   - logging: Logging configuration. Defaults to `.default`.
    ///   - customBaseURL: Optional URL override.
    ///   - telemetry: Telemetry reporting. Defaults to the environment's setting.
    public init(
        publishableKey: String,
        organizationId: String,
        environment: KasookooEnvironment,
        region: String? = nil,
        userMode: UserMode = .guest,
        features: FeatureFlags = .default,
        logging: LoggingConfig = .default,
        customBaseURL: URL? = nil,
        telemetry: TelemetryConfiguration? = nil
    ) {
        self.publishableKey = publishableKey
        self.organizationId = organizationId
        self.environment = environment
        self.region = region
        self.userMode = userMode
        self.features = features
        self.logging = logging
        self.customBaseURL = customBaseURL
        self.telemetry = telemetry
    }
    
    // MARK: - Validation
    
    /// Validates the configuration.
    ///
    /// - Throws: `KasookooError` with code `.configInvalid` if validation fails.
    public func validate() throws {
        var errors: [String: String] = [:]
        
        // Publishable key validation
        let trimmedKey = publishableKey.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedKey.isEmpty {
            errors["publishableKey"] = "publishableKey is required and cannot be empty"
        } else if !trimmedKey.hasPrefix("pk_") {
            errors["publishableKey"] = "publishableKey must start with 'pk_' (e.g., pk_live_xxx or pk_test_xxx)"
        }
        
        // Organization ID validation
        let trimmedOrgId = organizationId.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedOrgId.isEmpty {
            errors["organizationId"] = "organizationId is required and cannot be empty"
        }
        
        // Environment vs key consistency check (warning-level via details)
        if environment == .production && publishableKey.hasPrefix("pk_test_") {
            errors["publishableKey"] = "Test key (pk_test_) cannot be used with production environment"
        }
        
        if !errors.isEmpty {
            throw KasookooError.configInvalid(
                "Invalid SDK configuration. See details for specific issues.",
                details: errors
            )
        }
    }
}
