//
//  APIRequest.swift
//  KasookooSDK
//
//  A self-describing HTTP request — the per-module replacement for the central
//  `Endpoint` enum (see Architecture Map §8 and §14, seam #2).
//
//  ─────────────────────────────────────────────────────────────────────────────
//  WHY THIS EXISTS
//  ─────────────────────────────────────────────────────────────────────────────
//  Today every backend call is a case in the `Endpoint` enum. Adding one endpoint
//  means editing that enum plus its six `switch` sites (path, method, requiresAuth,
//  requiresOrganizationHeader, timeoutClass). A new *module* therefore cannot add
//  its endpoints without editing shared core files.
//
//  An `APIRequest` is built inline by whoever needs it, so a module describes its
//  own request without touching any central enum. `ApiClient` can then send *any*
//  module's request without knowing which endpoints exist.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  TRANSITIONAL
//  ─────────────────────────────────────────────────────────────────────────────
//  This is ADDITIVE. `Endpoint` still exists and every service still uses it — the
//  two paths run side by side. Services migrate to `APIRequest` one at a time, each
//  verified independently; `Endpoint` is removed only once no caller remains. Until
//  then nothing about the existing calling/SIP/messaging behaviour changes.
//

import Foundation

/// Controls how a request body's keys are encoded.
///
/// The backend is inconsistent about casing (see Backend Review §4.2): most bodies
/// are snake_case, but some endpoints historically took camelCase. A *per-request*
/// strategy lets each call pick the right one instead of a single global setting
/// that forces every DTO to fight it with hand-written `CodingKeys`.
internal enum RequestKeyStrategy: Sendable {

    /// Convert camelCase Swift properties to snake_case JSON keys.
    /// This matches the current global `RequestBuilder` behaviour, so it is the
    /// default and preserves today's output for every existing request.
    case convertToSnakeCase

    /// Encode keys exactly as declared. Use when the body DTO defines its own
    /// `CodingKeys` (e.g. a mixed-casing endpoint) and must not be rewritten.
    case useDefaultKeys
}

/// A self-describing HTTP request that carries everything `ApiClient` needs to
/// build and send it, without consulting a central endpoint table.
///
/// ## Example
/// ```swift
/// let request = APIRequest(
///     path: "/api/v1/messaging/send",
///     method: .post,
///     timeout: .messaging
/// )
/// let response = try await apiClient.send(
///     apiRequest: request,
///     body: sendMessageDTO,
///     responseType: SendMessageResponse.self
/// )
/// ```
internal struct APIRequest: Sendable {

    /// Relative path, e.g. `/api/v1/messaging/send`. May already include a query
    /// string, or supply `queryItems` separately (both are supported).
    let path: String

    /// HTTP method.
    let method: HTTPMethod

    /// Whether an `Authorization: Bearer` token is required.
    let requiresAuth: Bool

    /// Whether the `X-Organization-Id` header must be sent. Currently the backend
    /// reads the org from the JWT, so this defaults to `false` — retained per
    /// endpoint in case the contract changes (see Backend Review §4.2 / Endpoint).
    let requiresOrgHeader: Bool

    /// Timeout class (reuses the existing `TimeoutClass`).
    let timeout: TimeoutClass

    /// Body key-encoding strategy for this specific request.
    let keyStrategy: RequestKeyStrategy

    /// Optional query items. Kept as plain `(name, value)` pairs so the whole
    /// struct stays trivially `Sendable`. Folded into the URL by `resolvedPath`.
    let queryItems: [(name: String, value: String)]?

    init(
        path: String,
        method: HTTPMethod,
        requiresAuth: Bool = true,
        requiresOrgHeader: Bool = false,
        timeout: TimeoutClass = .standard,
        keyStrategy: RequestKeyStrategy = .convertToSnakeCase,
        queryItems: [(name: String, value: String)]? = nil
    ) {
        self.path = path
        self.method = method
        self.requiresAuth = requiresAuth
        self.requiresOrgHeader = requiresOrgHeader
        self.timeout = timeout
        self.keyStrategy = keyStrategy
        self.queryItems = queryItems
    }

    /// The relative path with any `queryItems` appended.
    ///
    /// If `queryItems` is nil/empty this returns `path` unchanged, so a request
    /// that already baked its query into `path` (the way `Endpoint` does today)
    /// is passed through untouched.
    var resolvedPath: String {
        guard let queryItems, !queryItems.isEmpty else { return path }

        var components = URLComponents()
        // Split any pre-existing query already present in `path`.
        if let qIndex = path.firstIndex(of: "?") {
            components.path = String(path[path.startIndex..<qIndex])
            components.percentEncodedQuery = String(path[path.index(after: qIndex)...])
        } else {
            components.path = path
        }

        var items = components.queryItems ?? []
        items.append(contentsOf: queryItems.map { URLQueryItem(name: $0.name, value: $0.value) })
        components.queryItems = items

        return components.string ?? path
    }
}
