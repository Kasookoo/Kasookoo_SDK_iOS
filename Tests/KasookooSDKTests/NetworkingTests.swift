//
//  NetworkingTests.swift
//  KasookooSDKTests
//

import Foundation
import Testing
@testable import KasookooSDK

@Suite struct RetryClassificationTests {
    
    private func transportError(_ code: URLError.Code) -> KasookooError {
        KasookooError.networkUnavailable(message: "transport", underlyingError: URLError(code))
    }
    
    private func httpError(_ status: Int) -> KasookooError {
        KasookooError(code: .networkUnavailable, message: "http", retryable: true, httpStatus: status)
    }
    
    @Test("A timed-out dial is never repeated")
    func timeoutNotRetriedForSideEffects() {
        #expect(!ApiClient.isRetryable(transportError(.timedOut), isRepeatable: false))
        #expect(!ApiClient.isRetryable(transportError(.networkConnectionLost), isRepeatable: false))
        #expect(!ApiClient.isRetryable(httpError(503), isRepeatable: false))
        #expect(!ApiClient.isRetryable(httpError(504), isRepeatable: false))
    }
    
    @Test("Failures before transmission are retried even for side effects")
    func preTransmissionRetried() {
        #expect(ApiClient.isRetryable(transportError(.cannotConnectToHost), isRepeatable: false))
        #expect(ApiClient.isRetryable(transportError(.notConnectedToInternet), isRepeatable: false))
        #expect(ApiClient.isRetryable(transportError(.dnsLookupFailed), isRepeatable: false))
        #expect(ApiClient.isRetryable(httpError(429), isRepeatable: false))
    }
    
    @Test("Repeatable requests retry transient failures")
    func repeatableRetried() {
        #expect(ApiClient.isRetryable(transportError(.timedOut), isRepeatable: true))
        #expect(ApiClient.isRetryable(httpError(503), isRepeatable: true))
    }
    
    @Test("401 and 403 are never retried")
    func authErrorsNotRetried() {
        let unauthorized = KasookooError(code: .sessionExpired, message: "401", retryable: true, httpStatus: 401)
        let forbidden = KasookooError(code: .permissionDenied, message: "403", retryable: false, httpStatus: 403)
        #expect(!ApiClient.isRetryable(unauthorized, isRepeatable: true))
        #expect(!ApiClient.isRetryable(forbidden, isRepeatable: true))
    }
    
    @Test("Only calls with user-visible side effects are non-repeatable")
    func endpointRepeatability() {
        #expect(!Endpoint.sipMakeCall.apiRequest.isRepeatable)
        #expect(!Endpoint.getCallTokens.apiRequest.isRepeatable)
        #expect(!MessagingRequests.send.isRepeatable)
        
        #expect(Endpoint.createClientSession.apiRequest.isRepeatable)
        #expect(Endpoint.rotateSessionToken(sessionId: "s").apiRequest.isRepeatable)
        #expect(Endpoint.sipEndCall.apiRequest.isRepeatable)
        #expect(Endpoint.identifyUser.apiRequest.isRepeatable)
        #expect(MessagingRequests.markRead.isRepeatable)
        #expect(MessagingRequests.unreadCount.isRepeatable)
    }
}

@Suite struct RequestBuilderTests {
    
    private let builder = RequestBuilder(
        baseURL: URL(string: "https://stub.test")!,
        publishableKey: "pk_test_unit",
        organizationId: "org_test"
    )
    
    @Test("POST carries an Idempotency-Key equal to the request id")
    func idempotencyKeyOnPost() throws {
        let request = try builder.build(
            apiRequest: Endpoint.sipMakeCall.apiRequest,
            authToken: "tok",
            requestId: "req123"
        )
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == "req123")
        #expect(request.value(forHTTPHeaderField: "X-Request-Id") == "req123")
        #expect(request.value(forHTTPHeaderField: "Authorization") == "Bearer tok")
        #expect(request.url?.absoluteString == "https://stub.test/api/v1/sip/calls/make")
    }
    
    @Test("GET carries no Idempotency-Key")
    func noIdempotencyKeyOnGet() throws {
        let request = try builder.build(apiRequest: MessagingRequests.unreadCount, requestId: "req456")
        #expect(request.value(forHTTPHeaderField: "Idempotency-Key") == nil)
        #expect(request.httpMethod == "GET")
    }
    
    @Test("Endpoint bodies are encoded as snake_case")
    func snakeCaseBody() throws {
        let body = SipEndCallRequest(participantIdentity: "p1", roomName: "r1")
        let request = try builder.build(apiRequest: Endpoint.sipEndCall.apiRequest, body: body, requestId: "r")
        let json = try JSONSerialization.jsonObject(with: request.httpBody ?? Data()) as? [String: String]
        #expect(json?["participant_identity"] == "p1")
        #expect(json?["room_name"] == "r1")
    }
}

@Suite struct ResponseDecoderTests {
    
    private let decoder = ResponseDecoder()
    
    private func response(_ status: Int) -> HTTPURLResponse {
        HTTPURLResponse(url: URL(string: "https://stub.test")!, statusCode: status, httpVersion: nil, headerFields: nil)!
    }
    
    private func decodeError(_ status: Int, _ body: String) -> KasookooError? {
        do {
            _ = try decoder.decode(EmptyResponse.self, from: Data(body.utf8), response: response(status), requestId: "r")
            return nil
        } catch {
            return error as? KasookooError
        }
    }
    
    @Test func mapsStatusCodes() {
        #expect(decodeError(401, "{}")?.code == .sessionExpired)
        #expect(decodeError(403, "{}")?.code == .permissionDenied)
        #expect(decodeError(429, "{}")?.retryable == true)
        #expect(decodeError(502, "{}")?.code == .networkUnavailable)
    }
    
    @Test func readsNestedServerError() {
        let error = decodeError(404, #"{"success":false,"error":{"code":"not_found","message":"User not found"}}"#)
        #expect(error?.code == .userNotFound)
        #expect(error?.message == "User not found")
    }
    
    @Test func emptySuccessBody() throws {
        _ = try decoder.decode(EmptyResponse.self, from: Data(), response: response(204), requestId: nil)
    }
    
    @Test("snake_case response keys decode into the device-token response")
    func registerResponseDecodesDeviceId() throws {
        let body = Data(#"{"success":true,"device_id":"dev_1"}"#.utf8)
        let decoded = try decoder.decode(RegisterDeviceTokenResponse.self, from: body, response: response(200), requestId: nil)
        #expect(decoded.deviceId == "dev_1")
    }
}
