//
//  ServerErrorDTO.swift
//  KasookooSDK
//
//  The backend error response, normalized into a single set of fields that
//  `ResponseDecoder` maps into a `KasookooError`.
//
//  The current backend returns errors in one primary shape:
//
//      { "success": false, "error": { "code": "...", "message": "..." } }
//
//  A custom decoder lets this one type also absorb the other shapes the backend
//  can still produce, so the caller never has to know which arrived:
//
//      • nested error object   { "error": { "code", "message" } }   (primary)
//      • top level fields       { "code", "message" }               (legacy)
//      • validation detail      { "detail": "..." }                 (string)
//      • validation detail      { "detail": [ { "msg": "..." } ] }  (array)
//
//  Decoding runs under the shared decoder's `.convertFromSnakeCase` strategy, so
//  the container keys arrive already in camelCase (for example `request_id`
//  becomes `requestId`). The dynamic key lookups below use those camelCase names.
//

import Foundation

/// The error response shape returned by the backend.
internal struct ServerErrorDTO: Decodable, Sendable {

    /// The machine readable error code, taken from the nested `error` object when
    /// present, otherwise from a top level `code`.
    let code: String?

    /// The human readable message, taken from the nested `error` object, a top
    /// level `message`, or a validation `detail`, in that order of preference.
    let message: String?

    /// A request identifier for tracing, when the backend supplies one.
    let requestId: String?

    /// Additional structured context, when present.
    let details: [String: String]?

    // MARK: - Nested shapes

    private struct NestedError: Decodable, Sendable {
        let code: String?
        let message: String?
    }

    private struct DetailItem: Decodable, Sendable {
        let msg: String?
        let type: String?
    }

    private struct DynamicKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init(_ value: String) { self.stringValue = value }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { return nil }
    }

    // MARK: - Custom decoding

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: DynamicKey.self)

        // Primary: nested error object.
        let nested = try? container.decodeIfPresent(NestedError.self, forKey: DynamicKey("error"))

        // Legacy: top level code / message.
        let topCode = try? container.decodeIfPresent(String.self, forKey: DynamicKey("code"))
        let topMessage = try? container.decodeIfPresent(String.self, forKey: DynamicKey("message"))

        // Validation: `detail` may be a plain string or an array of items.
        var detailMessage: String?
        if let string = try? container.decodeIfPresent(String.self, forKey: DynamicKey("detail")) {
            detailMessage = string
        } else if let items = try? container.decodeIfPresent([DetailItem].self, forKey: DynamicKey("detail")) {
            let joined = items.compactMap { $0.msg }.joined(separator: "; ")
            detailMessage = joined.isEmpty ? nil : joined
        }

        self.code = nested?.code ?? topCode
        self.message = nested?.message ?? topMessage ?? detailMessage
        self.requestId = try? container.decodeIfPresent(String.self, forKey: DynamicKey("requestId"))
        self.details = try? container.decodeIfPresent([String: String].self, forKey: DynamicKey("details"))
    }
}
