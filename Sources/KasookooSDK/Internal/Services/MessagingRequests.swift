//
//  MessagingRequests.swift
//  KasookooSDK
//
//  The messaging module's own HTTP request definitions, expressed as `APIRequest`
//  values instead of cases on the central `Endpoint` enum (Architecture Map §14,
//  seam #2). This is the messaging module owning its own endpoints.
//
//  ─────────────────────────────────────────────────────────────────────────────
//  FAITHFUL MIGRATION
//  ─────────────────────────────────────────────────────────────────────────────
//  Each request reproduces EXACTLY what the corresponding `Endpoint` case produced
//  — same path (including query construction), method, auth, org-header rule, and
//  timeout. The query-carrying paths are built with the identical `URLComponents`
//  code the enum used, so the final URL is byte-for-byte the same. Defaults on
//  `APIRequest` already match the messaging endpoints (requiresAuth = true,
//  requiresOrgHeader = false, keyStrategy = .convertToSnakeCase), so behaviour is
//  unchanged — only the mechanism moved off the shared enum.
//

import Foundation

/// Namespace of `APIRequest` factories for the messaging backend endpoints.
internal enum MessagingRequests {

    /// `POST /api/v1/messaging/get-token`
    static var getToken: APIRequest {
        APIRequest(path: "/api/v1/messaging/get-token", method: .post, timeout: .messaging, isRepeatable: true)
    }

    /// `POST /api/v1/messaging/send`
    ///
    /// Not repeatable: a timeout may mean the message was stored, so a retry
    /// would deliver it twice. Only pre-transmission failures are retried.
    static var send: APIRequest {
        APIRequest(path: "/api/v1/messaging/send", method: .post, timeout: .messaging)
    }

    /// `GET /api/v1/messaging/conversations?skip=&limit=`
    static func listConversations(userId: String, skip: Int, limit: Int) -> APIRequest {
        var components = URLComponents()
        components.path = "/api/v1/messaging/conversations"
        components.queryItems = [
            URLQueryItem(name: "skip", value: "\(skip)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "user_id", value: "\(userId)")
        ]
        let path = components.string ?? "/api/v1/messaging/conversations"
        return APIRequest(path: path, method: .get, timeout: .messaging)
    }

    /// `GET /api/v1/messaging/conversations/{conversation_id}/messages?skip=&limit=`
    static func getMessages(userId: String, conversationId: String, skip: Int, limit: Int) -> APIRequest {
        let encoded = conversationId.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? conversationId
        var components = URLComponents()
        components.path = "/api/v1/messaging/conversations/\(encoded)/messages"
        components.queryItems = [
            URLQueryItem(name: "skip", value: "\(skip)"),
            URLQueryItem(name: "limit", value: "\(limit)"),
            URLQueryItem(name: "user_id", value: "\(userId)")
        ]
        let path = components.string ?? "/api/v1/messaging/conversations/\(encoded)/messages"
        return APIRequest(path: path, method: .get, timeout: .messaging)
    }

    /// `POST /api/v1/messaging/mark-read`
    static var markRead: APIRequest {
        APIRequest(path: "/api/v1/messaging/mark-read", method: .post, timeout: .messaging, isRepeatable: true)
    }

    /// `GET /api/v1/messaging/unread-count`
    static var unreadCount: APIRequest {
        APIRequest(path: "/api/v1/messaging/unread-count", method: .get, timeout: .messaging)
    }
}
