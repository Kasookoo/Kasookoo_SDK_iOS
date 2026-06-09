//
//  CallerProfile.swift
//  KasookooSDK
//
//  The profile used with sdk.identify(callerProfile:).
//  Section 18: SDK identify(...) calls POST /api/v1/users/identify to upsert user by email.
//

import Foundation

/// The user profile passed to `sdk.identify(callerProfile:)`.
///
/// This profile is used to identify the current user with the backend.
/// Identification creates or updates (upserts) the user record by email.
///
/// ## Example
/// ```swift
/// try await sdk.identify(
///     callerProfile: CallerProfile(
///         name: "John Caller",
///         email: "john.caller@example.com",
///         phoneNumber: "+447700900111",
///         type: .customer
///     )
/// )
/// ```
public struct CallerProfile: Sendable, Hashable, Codable {
    
    // MARK: - Properties
    
    /// The user's display name.
    public let name: String
    
    /// The user's email address — the central identity field.
    public let email: String
    
    /// The user's phone number in E.164 format.
    public let phoneNumber: String
    
    /// The type of user.
    public let type: ParticipantType
    
    /// Optional metadata to attach to the user record.
    public let metadata: [String: String]?
    
    // MARK: - Init
    
    /// Creates a new caller profile.
    ///
    /// - Parameters:
    ///   - name: The display name.
    ///   - email: The email address.
    ///   - phoneNumber: The phone number in E.164 format.
    ///   - type: The user type. Defaults to `.customer`.
    ///   - metadata: Optional custom metadata.
    public init(
        name: String,
        email: String,
        phoneNumber: String,
        type: ParticipantType = .customer,
        metadata: [String: String]? = nil
    ) {
        self.name = name
        self.email = email
        self.phoneNumber = phoneNumber
        self.type = type
        self.metadata = metadata
    }
    
    // MARK: - Conversion
    
    /// Converts this profile into a `Participant` for use in calls/messages.
    public func asParticipant() -> Participant {
        return Participant(
            name: name,
            email: email,
            phoneNumber: phoneNumber,
            type: type
        )
    }
    
    // MARK: - Validation
    
    /// Validates the profile fields.
    ///
    /// - Throws: `KasookooError.configInvalid` if validation fails.
    public func validate() throws {
        try asParticipant().validate()
    }
}
