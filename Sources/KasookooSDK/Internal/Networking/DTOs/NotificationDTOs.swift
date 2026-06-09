//
//  NotificationDTOs.swift
//  KasookooSDK
//
//

import Foundation

// MARK: - Device Info

/// Device information sent with token registration.
/// Backend uses this for analytics and diagnostics.
internal struct DeviceInfoDTO: Encodable, Sendable {
    let appVersion: String?
    let osVersion: String?
    let deviceModel: String?
    
    enum CodingKeys: String, CodingKey {
        case appVersion = "app_version"
        case osVersion = "os_version"
        case deviceModel = "device_model"
    }
}

// MARK: - Register Device Token

/// Request body for `POST /api/v1/notifications/register-token`.
///
/// Per Postman collection — FCM-based:
/// ```json
/// {
///   "user_id": "user_123",
///   "user_type": "driver",
///   "device_token": "fcm_device_token_here",
///   "device_type": "android",
///   "new_device_token": null,
///   "device_info": {
///     "app_version": "1.0.0",
///     "os_version": "13.0",
///     "device_model": "Samsung Galaxy S21"
///   }
/// }
/// ```
internal struct RegisterDeviceTokenRequest: Encodable, Sendable {
    let userId: String
    let userType: String
    let deviceToken: String
    let deviceType: String
    let newDeviceToken: String?
    let deviceInfo: DeviceInfoDTO?
    
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case userType = "user_type"
        case deviceToken = "device_token"
        case deviceType = "device_type"
        case newDeviceToken = "new_device_token"
        case deviceInfo = "device_info"
    }
}

/// Response for `POST /api/v1/notifications/register-token`.
internal struct RegisterDeviceTokenResponse: Decodable, Sendable {
    let success: Bool?
    let deviceId: String?
    let message: String?
    
    enum CodingKeys: String, CodingKey {
        case success
        case deviceId = "device_id"
        case message
    }
}

// MARK: - Update Device Token

/// Request body for `POST /api/v1/notifications/update-token`.
///
/// Used when FCM rotates the device token.
internal struct UpdateDeviceTokenRequest: Encodable, Sendable {
    let userId: String
    let userType: String
    let deviceToken: String       // old token to find the record
    let deviceType: String
    let newDeviceToken: String    // new token to replace it with
    let deviceInfo: DeviceInfoDTO?
    
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case userType = "user_type"
        case deviceToken = "device_token"
        case deviceType = "device_type"
        case newDeviceToken = "new_device_token"
        case deviceInfo = "device_info"
    }
}

/// Response shape identical to register.
internal typealias UpdateDeviceTokenResponse = RegisterDeviceTokenResponse

// MARK: - Unregister Device Token

/// Request body for `POST /api/v1/notifications/unregister-token`.
internal struct UnregisterDeviceTokenRequest: Encodable, Sendable {
    let userId: String
    let userType: String
    let deviceToken: String
    let deviceType: String
    
    enum CodingKeys: String, CodingKey {
        case userId = "user_id"
        case userType = "user_type"
        case deviceToken = "device_token"
        case deviceType = "device_type"
    }
}

/// Response for unregister endpoint.
internal struct UnregisterDeviceTokenResponse: Decodable, Sendable {
    let success: Bool?
    let message: String?
}
