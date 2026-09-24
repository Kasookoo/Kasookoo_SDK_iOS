//
//  RequestBuilder.swift
//  KasookooSDK
//
//

import Foundation

/// Builds `URLRequest` objects from `APIRequest` descriptors.
///
/// Internal type — handles URL construction, headers, body encoding, and timeouts.
/// `Endpoint` values are converted with `Endpoint.apiRequest`, so there is one
/// builder for every request the SDK sends.
internal struct RequestBuilder: Sendable {
    
    private let baseURL: URL
    private let publishableKey: String
    private let organizationId: String
    private let sdkVersion: String
    
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
    }
}

// MARK: - Helpers

/// SDK version constant.
internal enum SDKVersion {
    /// Keep in step with the git tag. Reported as `X-Kasookoo-SDK` on every
    /// request and as `service.version` on every span, so a wrong value here
    /// misattributes production telemetry.
    static let current = "1.1.0"
}

// MARK: - Build
//
// Same-file extension: intentional, so it can read RequestBuilder's private
// stored properties (baseURL, publishableKey, organizationId, sdkVersion).
//
// Body keys follow `apiRequest.keyStrategy`. Every request the backend accepts
// is snake_case, so DTOs rely on `.convertToSnakeCase` rather than declaring
// snake_case CodingKeys. (Declaring both is the bug that once silently broke
// decoding: the strategy rewrites the key first, then the CodingKey no longer
// matches.)

extension RequestBuilder {

    /// Builds a `URLRequest` for the given `APIRequest`.
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

        // Standard headers.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.setValue("ios-swift/\(sdkVersion)", forHTTPHeaderField: "X-Kasookoo-SDK")
        request.setValue(requestId, forHTTPHeaderField: "X-Request-Id")
        
        // The request id is stable across retries of one logical request, so
        // it doubles as an idempotency key for methods that are not naturally
        // idempotent. A backend that honours it can drop duplicates; one that
        // does not simply ignores the header.
        if !apiRequest.method.isIdempotent {
            request.setValue(requestId, forHTTPHeaderField: "Idempotency-Key")
        }

        if let token = authToken {
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }

        if apiRequest.requiresOrgHeader {
            request.setValue(organizationId, forHTTPHeaderField: "X-Organization-Id")
        }

        // Per-request body encoder, honouring the request's key strategy.
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

/// Empty body sentinel for requests without a payload.
private struct APIRequestEmptyBody: Encodable, Sendable {}
