//
//  NotificationServicing.swift
//  KasookooSDK
//
//  Public protocol for push notification management.
//  Backend uses FCM exclusively — iOS apps must use Firebase iOS SDK to get FCM tokens.
//

import Foundation

/// The public contract for push notification management.
///
/// Accessed via `sdk.notifications`. Handles:
/// - FCM device token registration with the backend
/// - Incoming call detection from push payloads
/// - CallKit integration for native incoming-call UI
///
/// ## Integration Overview
///
/// Backend uses **Firebase Cloud Messaging (FCM)** for all push notifications.
/// iOS apps must integrate the Firebase iOS SDK to obtain FCM tokens.
///
/// ```swift
/// import FirebaseMessaging
///
/// // In AppDelegate.didFinishLaunching:
/// Messaging.messaging().token { token, error in
///     guard let token = token else { return }
///     Task {
///         try await sdk.notifications.registerDevice(
///             fcmToken: token,
///             userId: currentUserId,
///             userType: .customer
///         )
///     }
/// }
/// ```
public protocol NotificationServicing: Sendable {
    
    // MARK: - Incoming Call Handler
    
    /// Sets the handler that receives CallKit user actions (answer, decline, end).
    /// Set this once during app launch.
    func setIncomingCallHandler(_ handler: IncomingCallHandler?) async
    
    // MARK: - Device Registration
    
    /// Registers an FCM device token with the backend.
    ///
    /// The user must already be identified (via `sdk.identify()`) so that the
    /// backend can associate the device with the correct user account.
    ///
    /// - Parameters:
    ///   - fcmToken: The FCM token obtained from Firebase iOS SDK.
    ///   - userId: The backend-assigned user_id (from identify response).
    ///   - userType: The user type (customer, agent, driver, etc.).
    ///   - deviceInfo: Optional device metadata for analytics.
    /// - Throws: `KasookooError` if registration fails.
    func registerDevice(
        fcmToken: String,
        userId: String,
        userType: ParticipantType,
        deviceInfo: DeviceInfo?
    ) async throws
    
    /// Registers this device for push notifications, resolving the user
    /// automatically from the identity established by `identify()`.
    ///
    /// Prefer this over the explicit-`userId` variant: the backend keys device
    /// tokens by *its own* user id, which the host app has no way of knowing —
    /// the SDK resolves it internally from the identified user's email.
    ///
    /// - Parameters:
    ///   - fcmToken: The FCM registration token from Firebase.
    ///   - deviceInfo: Optional device metadata. Defaults to the current device.
    /// - Throws: `KasookooError.notIdentified` if `identify()` has not been called,
    ///   or a network error if registration fails.
    func registerDevice(
        fcmToken: String,
        deviceInfo: DeviceInfo?
    ) async throws
    
    /// Updates an FCM device token when Firebase rotates it.
    ///
    /// FCM may rotate tokens periodically. When your `MessagingDelegate` receives
    /// a new token, call this method with both the old and new tokens.
    ///
    /// - Parameters:
    ///   - oldFcmToken: The previously-registered token.
    ///   - newFcmToken: The new FCM token from Firebase.
    ///   - userId: The backend user_id.
    ///   - userType: The user type.
    ///   - deviceInfo: Optional updated device metadata.
    /// - Throws: `KasookooError` if update fails.
    func updateDevice(
        oldFcmToken: String,
        newFcmToken: String,
        userId: String,
        userType: ParticipantType,
        deviceInfo: DeviceInfo?
    ) async throws
    
    /// Unregisters an FCM device token.
    ///
    /// Typically called on logout. Stops push notifications to this device.
    ///
    /// - Parameters:
    ///   - fcmToken: The FCM token to unregister.
    ///   - userId: The user this token belongs to.
    ///   - userType: The user type.
    /// - Throws: `KasookooError` if unregistration fails.
    func unregisterDevice(
        fcmToken: String,
        userId: String,
        userType: ParticipantType
    ) async throws
    
    // MARK: - Push Handling
    
    /// Processes a regular (non-VoIP) push notification payload.
    ///
    /// Call this from `UNUserNotificationCenter` delegate or from
    /// `application(_:didReceiveRemoteNotification:fetchCompletionHandler:)`.
    @discardableResult
    func handlePushNotification(payload: PushPayload) async -> Bool
    
    /// Processes a VoIP push notification payload (PushKit).
    ///
    /// Call this from your `PKPushRegistryDelegate`'s
    /// `pushRegistry(_:didReceiveIncomingPushWith:for:completion:)` method.
    ///
    /// **Critical:** The SDK will report the incoming call to CallKit within
    /// the 5-second window required by Apple.
    @discardableResult
    func handleVoIPPush(payload: PushPayload) async -> Bool
}

// MARK: - Device Info

/// Optional device metadata sent during token registration.
public struct DeviceInfo: Sendable, Codable {
    public let appVersion: String?
    public let osVersion: String?
    public let deviceModel: String?
    
    public init(
        appVersion: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil
    ) {
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.deviceModel = deviceModel
    }
    
    /// Auto-populates device info from the current iOS device.
    public static func current() -> DeviceInfo {
        let appVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        
        #if canImport(UIKit)
        // Available on iOS
        return DeviceInfo(
            appVersion: appVersion,
            osVersion: nil,  // Filled in by NotificationService when calling
            deviceModel: nil // Filled in by NotificationService when calling
        )
        #else
        return DeviceInfo(appVersion: appVersion)
        #endif
    }
}

// MARK: - Device Type for FCM

/// Device type values accepted by the backend for FCM registration.
public enum DeviceTypeFCM: String, Sendable, Codable {
    case ios = "ios"
    case android = "android"
    case web = "web"
}

// MARK: - PushPayload

/// A Sendable wrapper around an iOS push notification payload.
///
/// iOS native callbacks (`didReceiveRemoteNotification`, `PKPushPayload`) deliver
/// payloads as `[AnyHashable: Any]`, which is not `Sendable` and cannot
/// cross actor boundaries in Swift 6 strict concurrency mode.
///
/// `PushPayload` solves this by extracting all JSON-compatible values from the
/// raw dictionary into a `Sendable` representation at construction time.
///
/// ## Usage
/// ```swift
/// // From regular push:
/// let payload = PushPayload(rawDictionary: userInfo)
///
/// // From PushKit:
/// let payload = PushPayload(rawDictionary: pkPayload.dictionaryPayload)
///
/// // Pass to SDK:
/// await sdk.notifications.handlePushNotification(payload: payload)
/// ```
public struct PushPayload: Sendable {
    
    /// The extracted Sendable representation of the payload.
    public let values: [String: AnyCodableValue]
    
    /// Creates a `PushPayload` from a raw iOS dictionary payload.
    public init(rawDictionary: [AnyHashable: Any]) {
        var result: [String: AnyCodableValue] = [:]
        for (key, value) in rawDictionary {
            guard let stringKey = key as? String else { continue }
            result[stringKey] = Self.toCodableValue(value)
        }
        self.values = result
    }
    
    /// Creates a `PushPayload` directly from a string-keyed dictionary.
    public init(values: [String: AnyCodableValue]) {
        self.values = values
    }
    
    // MARK: - Conversion Helper
    
    private static func toCodableValue(_ value: Any) -> AnyCodableValue {
        if let string = value as? String {
            return .string(string)
        }
        if let bool = value as? Bool, type(of: value) == Bool.self {
            return .bool(bool)
        }
        if let int = value as? Int {
            return .int(int)
        }
        if let double = value as? Double {
            return .double(double)
        }
        if let number = value as? NSNumber {
            let typeId = CFGetTypeID(number)
            if typeId == CFBooleanGetTypeID() {
                return .bool(number.boolValue)
            }
            if CFNumberIsFloatType(number) {
                return .double(number.doubleValue)
            }
            return .int(number.intValue)
        }
        if let array = value as? [Any] {
            return .array(array.map { toCodableValue($0) })
        }
        if let dict = value as? [String: Any] {
            var nested: [String: AnyCodableValue] = [:]
            for (k, v) in dict {
                nested[k] = toCodableValue(v)
            }
            return .dictionary(nested)
        }
        if let dict = value as? [AnyHashable: Any] {
            var nested: [String: AnyCodableValue] = [:]
            for (k, v) in dict {
                if let sk = k as? String {
                    nested[sk] = toCodableValue(v)
                }
            }
            return .dictionary(nested)
        }
        if value is NSNull {
            return .null
        }
        return .string(String(describing: value))
    }
}
