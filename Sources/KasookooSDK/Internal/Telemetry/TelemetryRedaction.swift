import Foundation

/// Strips anything sensitive before it can leave the device.
///
/// Telemetry leaves the app and lands in a shared observability stack, so this
/// is a security boundary, not a formatting helper. It works two ways:
///
/// 1. A key denylist. Any attribute whose name looks like a credential or a
///    personal identifier is dropped outright, whatever its value.
/// 2. A value scrubber. Anything that still looks like a token, a phone number,
///    or a URL carrying query parameters is replaced or truncated, which catches
///    cases where such a value reached an innocently named key (an error
///    message quoting a signed URL, for example).
///
/// The rule for new call sites: pass opaque ids (`user_id`, `session_id`,
/// `room_name`, `call_id`) and result codes. Never pass a body, a token, or a
/// number a person could be reached on.
internal enum TelemetryRedaction {

    /// Replacement for a value that matched a sensitive pattern.
    static let placeholder = "[redacted]"

    /// Attribute values longer than this are truncated. Keeps a runaway error
    /// message from carrying a payload into the export.
    static let maxValueLength = 256

    // MARK: - Key denylist

    /// Normalised key fragments that cause an attribute to be dropped.
    ///
    /// Matching is on a normalised key (lowercased, separators removed), so
    /// `dialedNumber`, `dialed_number`, and `Dialed-Number` all match
    /// `dialednumber`.
    private static let deniedKeyFragments: [String] = [
        // Credentials
        "token",
        "authorization",
        "apikey",
        "secret",
        "password",
        "credential",
        "publishablekey",
        "signature",
        "otp",
        "pin",
        "code",

        // Personal identifiers
        "phone",
        "msisdn",
        "e164",
        "dialednumber",
        "callerid",
        "calleenumber",
        "email",
        "address",
        "latitude",
        "longitude",

        // Payloads and connection strings
        "body",
        "payload",
        "message",
        "content",
        "text",
        "wsurl",
        "httpurl",
        "url"
    ]

    /// Keys that contain a denied fragment but are safe and must be kept.
    ///
    /// `error_code`, `status_code`, and `country_code` all contain "code"; the
    /// denylist exists for OTP-style codes, not these.
    private static let allowedKeys: Set<String> = [
        "errorcode",
        "statuscode",
        "httpstatuscode",
        "countrycode",
        "reasoncode",
        "responsecode",
        "messagetype",
        "messagecount",
        "messageid"
    ]

    // MARK: - Public API

    /// Drops denied attributes and scrubs the values that remain.
    static func sanitize(_ attributes: [String: TelemetryAttribute]) -> [String: TelemetryAttribute] {
        var result: [String: TelemetryAttribute] = [:]
        result.reserveCapacity(attributes.count)

        for (key, value) in attributes {
            guard isAllowed(key: key) else { continue }
            switch value {
            case .string(let text):
                result[key] = .string(sanitize(text: text))
            case .int, .double, .bool:
                result[key] = value
            }
        }
        return result
    }

    /// Scrubs a free-form string such as a log body or an error description.
    static func sanitize(text: String) -> String {
        var value = text

        if looksLikeToken(value) || looksLikePhoneNumber(value) {
            return placeholder
        }

        // Identifiers embedded inside a sentence ("… for jane@example.com",
        // "dialing +447700900111 failed", a bearer token quoted in an error).
        // The whole-value checks above only catch a value that IS one.
        value = replacingMatches(of: embeddedEmail, in: value)
        value = replacingMatches(of: embeddedPhoneNumber, in: value)
        value = replacingMatches(of: embeddedJWT, in: value)

        value = strippingQueryStrings(in: value)

        if value.count > maxValueLength {
            value = String(value.prefix(maxValueLength)) + "…"
        }
        return value
    }

    /// Whether an attribute with this key may be exported.
    static func isAllowed(key: String) -> Bool {
        let normalised = normalise(key)
        if allowedKeys.contains(normalised) { return true }
        return !deniedKeyFragments.contains { normalised.contains($0) }
    }

    // MARK: - Embedded identifier patterns

    /// An email address anywhere in the text.
    private static let embeddedEmail = try? NSRegularExpression(
        pattern: "[A-Z0-9._%+-]+@[A-Z0-9.-]+\\.[A-Z]{2,}",
        options: [.caseInsensitive]
    )

    /// An E.164-style number anywhere in the text: a `+` followed by 7 to 15
    /// digits, optionally separated by spaces or dashes. Requiring the `+`
    /// keeps dates, durations and ids from being mistaken for phone numbers.
    private static let embeddedPhoneNumber = try? NSRegularExpression(
        pattern: "\\+[0-9](?:[ -]?[0-9]){6,14}"
    )

    /// A JWT (three base64url segments, the first starting with `eyJ`).
    private static let embeddedJWT = try? NSRegularExpression(
        pattern: "eyJ[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]+\\.[A-Za-z0-9_-]*"
    )

    private static func replacingMatches(of regex: NSRegularExpression?, in value: String) -> String {
        guard let regex else { return value }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return regex.stringByReplacingMatches(
            in: value,
            options: [],
            range: range,
            withTemplate: placeholder
        )
    }

    // MARK: - Helpers

    /// Lowercases and removes separators so naming style cannot bypass the list.
    private static func normalise(_ key: String) -> String {
        key.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    /// Matches JWTs and other dot separated base64 credentials.
    private static func looksLikeToken(_ value: String) -> Bool {
        guard value.count >= 20 else { return false }
        if value.hasPrefix("eyJ") { return true }
        if value.lowercased().hasPrefix("bearer ") { return true }

        // Three dot separated segments of base64url characters.
        let parts = value.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 3 else { return false }
        let allowed = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_")
        return parts.allSatisfy { part in
            !part.isEmpty && CharacterSet(charactersIn: String(part)).isSubset(of: allowed)
        }
    }

    /// Matches a bare number that could reach a person, with or without
    /// formatting characters.
    private static func looksLikePhoneNumber(_ value: String) -> Bool {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }

        let formatting: Set<Character> = ["+", "-", " ", "(", ")", "."]
        var digits = 0
        for character in trimmed {
            if character.isNumber {
                digits += 1
            } else if !formatting.contains(character) {
                return false
            }
        }
        return (7...15).contains(digits)
    }

    /// Removes query strings from any URL appearing in the value, since signed
    /// LiveKit and media URLs carry the token there.
    private static func strippingQueryStrings(in value: String) -> String {
        guard value.contains("://"), value.contains("?") else { return value }

        return value
            .split(separator: " ", omittingEmptySubsequences: false)
            .map { component -> Substring in
                guard component.contains("://"),
                      let queryStart = component.firstIndex(of: "?") else {
                    return component
                }
                return component[component.startIndex..<queryStart]
            }
            .joined(separator: " ")
    }
}
