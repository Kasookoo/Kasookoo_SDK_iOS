//
//  SessionManagerTests.swift
//  KasookooSDKTests
//
//  Regression tests for the session refresh deadlock: rotation used to ask
//  the auth provider for a token from inside the refresh, which then waited
//  on itself forever.
//

import Foundation
import Testing
@testable import KasookooSDK

@Suite(.serialized)
struct SessionManagerTests {
    
    private func makeManager() -> (SessionManager, InMemoryTokenStorage) {
        let apiClient = ApiClient(
            baseURL: testConfig.baseURL,
            publishableKey: testConfig.publishableKey,
            organizationId: testConfig.organizationId,
            logger: testLogger,
            session: makeStubSession()
        )
        let storage = InMemoryTokenStorage()
        let manager = SessionManager(
            apiClient: apiClient,
            storage: storage,
            scheduler: RefreshScheduler(logger: testLogger),
            eventBus: EventBus(logger: testLogger),
            logger: testLogger,
            config: testConfig
        )
        apiClient.setAuthProvider(manager)
        return (manager, storage)
    }
    
    @Test("A 401 on rotation falls back to a new session instead of hanging")
    func rotationRejectedBootstrapsNewSession() async throws {
        let oldToken = makeJWT(["sid": "sess_old"])
        let newToken = makeJWT(["sid": "sess_new"])
        StubServer.shared.reset { request in
            let path = request.url?.path ?? ""
            if path.hasSuffix("/tokens") {
                return (401, Data(#"{"error":{"code":"unauthorized","message":"Invalid SDK token"}}"#.utf8))
            }
            if path.hasSuffix("/client-sessions") {
                return (200, sessionResponse(token: newToken))
            }
            return (404, Data())
        }
        
        let (manager, storage) = makeManager()
        storage.save(StoredToken(token: oldToken, sessionId: "sess_old", expiresAt: Date().addingTimeInterval(300)))
        
        let token = try await withTimeout { try await manager.forceRefresh() }
        
        #expect(token == newToken)
        #expect(storage.load()?.sessionId == "sess_new")
        
        // Rotation was authenticated with the current token directly, not
        // through the provider.
        let rotate = StubServer.shared.recorded.first { ($0.url?.path ?? "").hasSuffix("/tokens") }
        #expect(rotate?.value(forHTTPHeaderField: "Authorization") == "Bearer \(oldToken)")
    }
    
    @Test("An expired token is replaced without a rotation round trip")
    func expiredTokenBootstrapsDirectly() async throws {
        let newToken = makeJWT(["sid": "sess_fresh"])
        StubServer.shared.reset { request in
            if (request.url?.path ?? "").hasSuffix("/client-sessions") {
                return (200, sessionResponse(token: newToken))
            }
            return (500, Data())
        }
        
        let (manager, storage) = makeManager()
        storage.save(StoredToken(token: makeJWT(["sid": "sess_stale"]), sessionId: "sess_stale", expiresAt: Date().addingTimeInterval(-60)))
        
        let token = try await withTimeout { try await manager.ensureValidToken() }
        
        #expect(token == newToken)
        #expect(!StubServer.shared.recorded.contains { ($0.url?.path ?? "").hasSuffix("/tokens") })
    }
    
    @Test("Successful rotation keeps the session id and uses the new token")
    func rotationSucceeds() async throws {
        let oldToken = makeJWT(["sid": "sess_keep"])
        let rotated = makeJWT(["sid": "sess_keep", "n": "2"])
        StubServer.shared.reset { request in
            if (request.url?.path ?? "").hasSuffix("/sessions/sess_keep/tokens") {
                return (200, sessionResponse(token: rotated))
            }
            return (500, Data())
        }
        
        let (manager, storage) = makeManager()
        storage.save(StoredToken(token: oldToken, sessionId: "sess_keep", expiresAt: Date().addingTimeInterval(300)))
        
        let token = try await withTimeout { try await manager.forceRefresh() }
        
        #expect(token == rotated)
        #expect(storage.load()?.sessionId == "sess_keep")
    }
    
    @Test("After disconnect no request can silently create a new session")
    func disconnectBlocksLazyBootstrap() async throws {
        StubServer.shared.reset { request in
            if request.httpMethod == "DELETE" { return (204, Data()) }
            return (200, sessionResponse(token: makeJWT(["sid": "sess_x"])))
        }
        
        let (manager, _) = makeManager()
        try await withTimeout { try await manager.connect() }
        await manager.disconnect()
        
        do {
            _ = try await withTimeout { try await manager.ensureValidToken() }
            Issue.record("ensureValidToken() should throw after disconnect")
        } catch let error as KasookooError {
            #expect(error.code == .sessionInvalid)
        }
    }
    
    @Test("Revoke on disconnect uses the session token directly")
    func revokeUsesExplicitBearer() async throws {
        let token = makeJWT(["sid": "sess_revoke"])
        StubServer.shared.reset { request in
            if request.httpMethod == "DELETE" { return (204, Data()) }
            return (200, sessionResponse(token: token))
        }
        
        let (manager, _) = makeManager()
        try await withTimeout { try await manager.connect() }
        await manager.disconnect()
        
        let revoke = StubServer.shared.recorded.first { $0.httpMethod == "DELETE" }
        #expect(revoke?.url?.path == "/api/v1/sdk/auth/sessions/sess_revoke")
        #expect(revoke?.value(forHTTPHeaderField: "Authorization") == "Bearer \(token)")
    }
}
