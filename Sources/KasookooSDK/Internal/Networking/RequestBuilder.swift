//
//  RequestBuilder.swift
//  KasookooSDK
//
//

import Foundation

/// Builds `URLRequest` objects for a given endpoint.
///
/// Internal type — handles URL construction, headers, body encoding, and timeouts.
internal struct RequestBuilder: Sendable {
    
    private let baseURL: URL
    private let publishableKey: String
    private let organizationId: String
    private let sdkVersion: String
    private let encoder: JSONEncoder
    
    init(
        baseURL: URL,
        publishableKey: String,
        organizationId: String,
        sdkVersion: String = SDKVersion.current
    ) {
        self.baseURL = baseURL
        self.publishableKey = publishableKey
        self.organizationId = organizationId
        self.sdkVersion = sdkVersion
        
        // Key strategy is symmetric with ResponseDecoder's
        // `.convertFromSnakeCase`: every request body the backend accepts uses
        // snake_case (`phone_number`, `room_name`, `publishable_key`, …), so the
        // encoder converts automatically and DTOs don't declare CodingKeys.
        //
        // This previously had to be off because `/users/identify` took camelCase
        // (`phoneNumber`); that endpoint now takes `{organization_id, email,
        // role}` like everything else, so the exception is gone.
        //
        // Declaring explicit snake_case CodingKeys *and* enabling this strategy
        // is the bug that silently broke decoding elsewhere (the strategy
        // rewrites the key first, then the snake_case CodingKey no longer
        // matches) — so DTOs should rely on the strategy, not fight it.
        let encoder = JSONEncoder()
        encoder.keyEncodingStrategy = .convertToSnakeCase
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder
    }
    
    // MARK: - Build Request
    
    /// Builds a `URLRequest` for the given endpoint.
    ///
    /// - Parameters:
    ///   - endpoint: The endpoint to call.
    ///   - body: An optional `Encodable` body.
    ///   - authToken: Optional bearer token (for authenticated endpoints).
    ///   - requestId: Optional correlation ID; generated if not provided.
    /// - Returns: A configured `URLRequest`.
    /// - Throws: `KasookooError` if URL construction or body encoding fails.
    func build<Body: Encodable & Sendable>(
        endpoint: Endpoint,
        body: Body?,
        authToken: String? = nil,
        requestId: String = UUID().uuidString
    ) throws -> URLRequest {
        
        // Construct URL
        guard let url = URL(string: endpoint.path, relativeTo: baseURL) else {
            throw KasookooError.unknown(
                message: "Failed to construct URL for endpoint: \(endpoint.path)"
            )
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = endpoint.method.rawValue
        request.timeoutInterval = endpoint.timeoutClass.seconds
        
        // Standard headers
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        
        // SDK identification (custom; backend may or may not use it)
        request.setValue("ios-swift/\(sdkVersion)", forHTTPHeaderField: "X-Kasookoo-SDK")
        request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        
        // Authorization header (Bearer token)
        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        
        // Organization context header — only sent on endpoints that need it.
        // After JWT bootstrap, the JWT itself usually carries the org context.
        // But some endpoints still require the explicit header.
        if endpoint.requiresOrganizationHeader {
            request.setValue(organizationId, forHTTPHeaderField: "X-Organization-Id")
        }
        
        // Encode body
        if let body = body {
            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw KasookooError.unknown(
                    message: "Failed to encode request body: \(error.localizedDescription)",
                    underlyingError: error
                )
            }
        }
        
        return request
    }
    
    /// Convenience overload for endpoints without a body.
    func build(
        endpoint: Endpoint,
        authToken: String? = nil,
        requestId: String = UUID().uuidString
    ) throws -> URLRequest {
        return try build(
            endpoint: endpoint,
            body: Optional<EmptyBody>.none,
            authToken: authToken,
            requestId: requestId
        )
    }
}

// MARK: - Helpers

/// Empty body sentinel for requests without a payload.
private struct EmptyBody: Encodable, Sendable {}

/// SDK version constant.
internal enum SDKVersion {
    /// Keep in step with the git tag. Reported as `X-Kasookoo-SDK` on every
    /// request and as `service.version` on every span, so a wrong value here
    /// misattributes production telemetry.
    static let current = "1.0.6"
}

// MARK: - APIRequest support (ADDITIVE — Map §14, seam #2)
//
// Builds a URLRequest from an `APIRequest` descriptor instead of an `Endpoint`.
// This runs alongside the `Endpoint`-based `build(...)` above; existing callers
// are untouched. The only new capability is a per-request key strategy, which the
// `Endpoint` path does not need (it always uses convertToSnakeCase).
//
// Same-file extension: intentional, so it can read RequestBuilder's private
// stored properties (baseURL, publishableKey, organizationId, sdkVersion).

extension RequestBuilder {

    /// Builds a `URLRequest` for the given `APIRequest`.
    ///
    /// Behaviour matches the `Endpoint` overload (same headers, auth, timeout,
    /// org-header rule) except the body encoder honours `apiRequest.keyStrategy`.
    func build<Body: Encodable & Sendable>(
        apiRequest: APIRequest,
        body: Body?,
        authToken: String? = nil,
        requestId: String = UUID().uuidString
    ) throws -> URLRequest {

        // Construct URL from the resolved (query-inclusive) path.
        guard let url = URL(string: apiRequest.resolvedPath, relativeTo: baseURL) else {
            throw KasookooError.unknown(
                message: "Failed to construct URL for request: \(apiRequest.resolvedPath)"
            )
        }

        var request = URLRequest(url: url)
        request.httpMethod = apiRequest.method.rawValue
        request.timeoutInterval = apiRequest.timeout.seconds

        // Standard headers — identical to the Endpoint path.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ios-swift/\(sdkVersion)", forHTTPHeaderField: "X-Kasookoo-SDK")
        request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")

        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if apiRequest.requiresOrgHeader {
            request.setValue(organizationId, forHTTPHeaderField: "X-Organization-Id")
        }

        // Per-request body encoder — this is the one behaviour the Endpoint path
        // can't express (it's locked to a single global strategy).
        if let body = body {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            switch apiRequest.keyStrategy {
            case .convertToSnakeCase:
                encoder.keyEncodingStrategy = .convertToSnakeCase
            case .useDefaultKeys:
                encoder.keyEncodingStrategy = .useDefaultKeys
            }

            do {
                request.httpBody = try encoder.encode(body)
            } catch {
                throw KasookooError.unknown(
                    message: "Failed to encode request body: \(error.localizedDescription)",
                    underlyingError: error
                )
            }
        }

        return request
    }

    /// Convenience overload for an `APIRequest` with no body.
    func build(
        apiRequest: APIRequest,
        authToken: String? = nil,
        requestId: String = UUID().uuidString
    ) throws -> URLRequest {
        return try build(
            apiRequest: apiRequest,
            body: Optional<APIRequestEmptyBody>.none,
            authToken: authToken,
            requestId: requestId
        )
    }
}

/// Empty body sentinel for `APIRequest` calls without a payload.
/// (Separate name from the Endpoint path's private `EmptyBody` to avoid any clash.)
private struct APIRequestEmptyBody: Encodable, Sendable {}
