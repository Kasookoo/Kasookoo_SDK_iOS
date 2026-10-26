//
//  JWTClaims.swift
//  KasookooSDK
//
//  Reads individual claims out of a session JWT.
//

import Foundation

/// Reads claims from a JWT payload.
///
/// This decodes the payload only. It is not verification: the tokens read here
/// were just issued to us by the backend over TLS, and are read solely to
/// recover values the response body omits (`sid`) or that must match what the
/// backend authenticated (`organization_id`).
internal enum JWTClaims {
    
    /// Returns a non-empty string claim, or nil if the token is malformed or
    /// the claim is absent.
    static func string(_ claim: String, in token: String) -> String? {
        guard let payload = payload(of: token),
              let value = payload[claim] as? String,
              !value.isEmpty else {
            return nil
        }
        return value
    }
    
    /// The decoded payload segment of a `header.payload.signature` token.
    static func payload(of token: String) -> [String: Any]? {
        let segments = token.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return nil }
        
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        // Pad to a multiple of 4 for base64 decoding.
        while base64.count % 4 != 0 { base64 += "=" }
        
        guard let data = Data(base64Encoded: base64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }
}
