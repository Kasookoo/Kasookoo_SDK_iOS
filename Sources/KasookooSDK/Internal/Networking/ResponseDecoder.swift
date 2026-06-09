//
//  ResponseDecoder.swift
//  KasookooSDK
//
//

import Foundation

/// Decodes raw HTTP responses into typed Swift values and SDK errors.
internal struct ResponseDecoder: Sendable {
    
    private let decoder: JSONDecoder
    
    init() {
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }
    
    // MARK: - Decode Successful Response
    
    /// Decodes a successful HTTP response body into `T`.
    ///
    /// - Throws: `KasookooError` if decoding fails or the response is unsuccessful.
    func decode<T: Decodable>(
        _ type: T.Type,
        from data: Data,
        response: URLResponse,
        requestId: String?
    ) throws -> T {
        // Verify HTTP response
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KasookooError.unknown(message: "Response is not an HTTP response.")
        }
        
        let statusCode = httpResponse.statusCode
        
        // Success range
        if (200...299).contains(statusCode) {
            // Handle empty bodies (e.g., 204 No Content)
            if data.isEmpty, let empty = EmptyResponse() as? T {
                return empty
            }
            
            do {
                return try decoder.decode(T.self, from: data)
            } catch {
                throw KasookooError.unknown(
                    message: "Failed to decode response: \(error.localizedDescription)",
                    underlyingError: error
                )
            }
        }
        
        // Error range — try to parse server error
        throw mapServerError(
            data: data,
            statusCode: statusCode,
            requestId: requestId,
            httpResponse: httpResponse
        )
    }
    
    /// Decodes only the HTTP status, ignoring the body.
    /// Used for endpoints like `DELETE /sessions/{id}` where the body may be empty.
    func decodeStatus(
        from data: Data,
        response: URLResponse,
        requestId: String?
    ) throws {
        guard let httpResponse = response as? HTTPURLResponse else {
            throw KasookooError.unknown(message: "Response is not an HTTP response.")
        }
        
        let statusCode = httpResponse.statusCode
        if (200...299).contains(statusCode) {
            return
        }
        
        throw mapServerError(
            data: data,
            statusCode: statusCode,
            requestId: requestId,
            httpResponse: httpResponse
        )
    }
    
    // MARK: - Error Mapping
    
    /// Maps a non-2xx HTTP response into a `KasookooError`.
    private func mapServerError(
        data: Data,
        statusCode: Int,
        requestId: String?,
        httpResponse: HTTPURLResponse
    ) -> KasookooError {
        
        // Try to decode the structured error body
        let serverError = try? decoder.decode(ServerErrorDTO.self, from: data)
        let serverRequestId = serverError?.requestId ?? requestId
        let serverMessage = serverError?.message
        let serverDetails = serverError?.details
        
        // Map status codes to error codes (Section 8)
        switch statusCode {
        case 401:
            return KasookooError(
                code: .sessionExpired,
                message: serverMessage ?? "Session expired or invalid.",
                retryable: true,
                httpStatus: 401,
                requestId: serverRequestId,
                details: serverDetails
            )
        case 403:
            return KasookooError(
                code: .permissionDenied,
                message: serverMessage ?? "You do not have permission to perform this action.",
                retryable: false,
                httpStatus: 403,
                requestId: serverRequestId,
                details: serverDetails
            )
        case 408, 504:
            return KasookooError(
                code: .networkUnavailable,
                message: serverMessage ?? "Request timed out.",
                retryable: true,
                httpStatus: statusCode,
                requestId: serverRequestId,
                details: serverDetails
            )
        case 429:
            return KasookooError(
                code: .networkUnavailable,
                message: serverMessage ?? "Too many requests. Please retry later.",
                retryable: true,
                httpStatus: 429,
                requestId: serverRequestId,
                details: serverDetails
            )
        case 500...599:
            return KasookooError(
                code: .networkUnavailable,
                message: serverMessage ?? "Server error. Please retry later.",
                retryable: true,
                httpStatus: statusCode,
                requestId: serverRequestId,
                details: serverDetails
            )
        default:
            // Use server-provided code if available and recognized
            let code = serverError?.code.flatMap { ErrorCode(rawValue: $0) } ?? .unknownError
            return KasookooError(
                code: code,
                message: serverMessage ?? "Request failed with status \(statusCode).",
                retryable: false,
                httpStatus: statusCode,
                requestId: serverRequestId,
                details: serverDetails
            )
        }
    }
}

// MARK: - Empty Response Sentinel

/// A sentinel type for endpoints that return empty bodies.
internal struct EmptyResponse: Decodable, Sendable {}
