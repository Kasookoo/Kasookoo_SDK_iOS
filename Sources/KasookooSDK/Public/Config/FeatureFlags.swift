//
//  FeatureFlags.swift
//  KasookooSDK
//
//  Toggles for enabling/disabling SDK features (Section 5 of the spec).
//

import Foundation

/// Feature flags that control which SDK modules are active.
///
/// Each flag corresponds to a feature module. Disabling a feature prevents
/// its service from initializing, saving resources for apps that don't need it.
///
/// ## Example
/// ```swift
/// let features = FeatureFlags(
///     calling: true,
///     messaging: true,
///     sipCalling: false,         // Disable SIP for this app
///     pushNotifications: true,
///     recording: false           // Disable recording (default)
/// )
/// ```
public struct FeatureFlags: Sendable, Codable {
    
    /// Enables app-to-app WebRTC calling.
    public let calling: Bool
    
    /// Enables in-app messaging.
    public let messaging: Bool
    
    /// Enables SIP calling (PSTN).
    public let sipCalling: Bool
    
    /// Enables push notifications via APNs.
    public let pushNotifications: Bool
    
    /// Enables call recording. Defaults to `false` for privacy.
    public let recording: Bool
    
    /// Creates a new feature flag configuration.
    ///
    /// - Parameters:
    ///   - calling: Enable WebRTC calling. Defaults to `true`.
    ///   - messaging: Enable messaging. Defaults to `true`.
    ///   - sipCalling: Enable SIP calling. Defaults to `true`.
    ///   - pushNotifications: Enable push notifications. Defaults to `true`.
    ///   - recording: Enable call recording. Defaults to `false`.
    public init(
        calling: Bool = true,
        messaging: Bool = true,
        sipCalling: Bool = false,
        pushNotifications: Bool = true,
        recording: Bool = false
    ) {
        self.calling = calling
        self.messaging = messaging
        self.sipCalling = sipCalling
        self.pushNotifications = pushNotifications
        self.recording = recording
    }
    
    /// A default configuration with the most common features enabled.
    public static let `default` = FeatureFlags()
    
    /// A configuration with all features enabled. Useful for full-featured apps.
    public static let all = FeatureFlags(
        calling: true,
        messaging: true,
        sipCalling: true,
        pushNotifications: true,
        recording: true
    )
}
