//
//  Participant.swift
//  KasookooSDK
//
//  Represents an identity (caller, callee, sender, receiver) in calls and messages.
//

import Foundation

/// Represents a participant (caller, callee, sender, or receiver) in a call or message.
///
/// Used as the input identity for calls and messages. The backend identifies users
/// by email primarily, with an internal user_id assigned after identification.
///
/// ## Example
/// ```swift
/// let caller = Participant(
///     name: "John Caller",
///     email: "john.caller@example.com",
///     phoneNumber: "+447700900111",
///     type: .customer
/// )
/// ```
public struct Participant: Sendable, Hashable, Codable {
    
    // MARK: - Properties
    
    /// The display name of the participant.
    public let name: String
    
    /// The email address of the participant. Used as the primary identity.
    public let email: String
    
    /// The phone number in E.164 format (e.g., "+447700900111").
    public let phoneNumber: String
    
    /// The type of participant (customer, agent, etc.).
    public let type: ParticipantType
    
    /// The backend-assigned user ID, if known.
    /// Populated after the participant is identified via the backend.
    /// Optional because the SDK may know about a participant before resolution.
    public let userId: String?
    
    // MARK: - Init
    
    /// Creates a new participant.
    ///
    /// - Parameters:
    ///   - name: The display name.
    ///   - email: The email address.
    ///   - phoneNumber: The phone number in E.164 format.
    ///   - type: The participant type. Defaults to `.customer`.
    ///   - userId: Optional backend user ID, if known.
    public init(
        name: String,
        email: String,
        phoneNumber: String,
        type: ParticipantType = .customer,
        userId: String? = nil
    ) {
        self.name = name
        self.email = email
        self.phoneNumber = phoneNumber
        self.type = type
        self.userId = userId
    }
    
    // MARK: - Computed
    
    /// Returns a `UserReference` for this participant, preferring user ID if known.
    public var userReference: UserReference {
        if let userId = userId {
            return .userId(userId)
        }
        return .email(email)
    }
    
    // MARK: - Validation
    
    /// Validates that the participant fields are non-empty and well-formed.
    ///
    /// - Throws: `KasookooError.configInvalid` if validation fails.
    public func validate() throws {
        var errors: [String: String] = [:]
        
        if name.trimmingCharacters(in: .whitespaces).isEmpty {
            errors["name"] = "name cannot be empty"
        }
        
        if email.trimmingCharacters(in: .whitespaces).isEmpty {
            errors["email"] = "email cannot be empty"
        } else if !Self.isValidEmail(email) {
            errors["email"] = "email is not in a valid format"
        }
        
        // NOTE: phoneNumber is intentionally NOT required.
        //
        // The backend identifies participants by email; the phone number is
        // informational for app-to-app (WebRTC) calls. Requiring it would also
        // make the SDK reject its own data: an incoming-call push carries no
        // phone numbers, so participants parsed from a push always have an empty
        // one. For SIP the destination number is supplied separately via
        // `SipDialParams.destinationNumber`, so nothing is lost here either.
        
        if !errors.isEmpty {
            throw KasookooError.configInvalid(
                "Invalid participant data.",
                details: errors
            )
        }
    }
    
    /// Lightweight email format check.
    /// Not RFC 5322 compliant; just catches obvious issues.
    private static func isValidEmail(_ email: String) -> Bool {
        let pattern = #"^[^\s@]+@[^\s@]+\.[^\s@]+$"#
        return email.range(of: pattern, options: .regularExpression) != nil
    }
}

// MARK: - Participant Type

/// The role/type of a participant in a call or message.
///
/// **Backend note:** Values must match what the backend expects.
/// Common values are `customer` and `agent`; backend has been observed accepting
/// `driver` in some contexts. Confirm exhaustive list with backend team.
public enum ParticipantType: String, Sendable, Hashable, Codable {
    
    /// An end customer/user.
    case customer = "customer"
    
    /// A support agent or staff member.
    case agent = "agent"
    
    /// A driver (used in ride-share style deployments).
    case driver = "driver"
    
    /// A bot or automated participant.
    case bot = "bot"
    
    /// An anonymous/unidentified participant.
    case anonymous = "anonymous"
    
    /// A system participant (e.g., for system messages).
    case system = "system"
}
