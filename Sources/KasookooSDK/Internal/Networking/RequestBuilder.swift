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
        
        // IMPORTANT: We don't use convertToSnakeCase globally because the backend
        // has inconsistent casing — most endpoints use snake_case, but
        // /users/identify uses camelCase. Each DTO declares its own CodingKeys.
        let encoder = JSONEncoder()
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
    static let current = "0.1.0"
}
