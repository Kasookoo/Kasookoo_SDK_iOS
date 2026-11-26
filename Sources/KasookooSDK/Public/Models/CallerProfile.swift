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
    
    /// Validates the profile fields before they are sent to the backend.
    ///
    /// On top of the participant checks (name and email present, email
    /// format), the user's own profile must have:
    /// - no spaces around the email, so the same person is not registered
    ///   twice as "a@b.com" and " a@b.com";
    /// - a phone number that looks like one, if given (7–15 digits, optional
    ///   leading `+`; spaces, dashes, dots and brackets are ignored);
    /// - a name of at most 100 characters.
    ///
    /// - Throws: `KasookooError.configInvalid` with one entry per bad field in
    ///   `details`.
    public func validate() throws {
        var errors: [String: String] = [:]
        do {
            try asParticipant().validate()
        } catch let error as KasookooError {
            errors.merge(error.details ?? [:]) { first, _ in first }
        }

        if errors["email"] == nil, email != email.trimmingCharacters(in: .whitespacesAndNewlines) {
            errors["email"] = "email must not start or end with spaces"
        }

        let phone = phoneNumber.trimmingCharacters(in: .whitespaces)
        if !phone.isEmpty && !Self.isPlausiblePhoneNumber(phone) {
            errors["phoneNumber"] = "phoneNumber must be 7 to 15 digits, optionally starting with +"
        }

        if errors["name"] == nil, name.count > Self.maxNameLength {
            errors["name"] = "name must be at most \(Self.maxNameLength) characters"
        }

        if !errors.isEmpty {
            throw KasookooError.configInvalid("Invalid caller profile.", details: errors)
        }
    }

    /// Longest display name accepted by `validate()`.
    static let maxNameLength = 100

    static func isPlausiblePhoneNumber(_ number: String) -> Bool {
        let stripped = number.filter { !" -.()".contains($0) }
        return stripped.range(of: #"^\+?[0-9]{7,15}$"#, options: .regularExpression) != nil
    }
}
