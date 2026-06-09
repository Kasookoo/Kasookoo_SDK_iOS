//
//  TokenStorage.swift
//  KasookooSDK
//
//

import Foundation
import Security

/// A token bundle representing a session.
internal struct StoredToken: Sendable, Equatable {
    let token: String
    let sessionId: String
    let expiresAt: Date
    
    /// Whether this token is currently valid (not expired).
    var isValid: Bool {
        return Date() < expiresAt
    }
    
    /// Whether this token will expire within the given threshold.
    func willExpireSoon(threshold: TimeInterval) -> Bool {
        return Date().addingTimeInterval(threshold) >= expiresAt
    }
    
    /// Time remaining until expiry in seconds.
    var secondsUntilExpiry: TimeInterval {
        return expiresAt.timeIntervalSinceNow
    }
}

// MARK: - TokenStorage Protocol

/// Abstraction over token storage. Allows mocking in tests.
internal protocol TokenStorage: Sendable {
    func load() -> StoredToken?
    func save(_ token: StoredToken)
    func clear()
}

// MARK: - In-Memory Storage (Default)

/// In-memory token storage. Token is lost when the app is killed.
///
/// This is the **recommended default** per Section 6: tokens should live in
/// memory and be re-acquired on app launch via `connect()`.
internal final class InMemoryTokenStorage: TokenStorage, @unchecked Sendable {
    
    private let lock = NSLock()
    private var token: StoredToken?
    
    init() {}
    
    func load() -> StoredToken? {
        lock.lock()
        defer { lock.unlock() }
        return token
    }
    
    func save(_ token: StoredToken) {
        lock.lock()
        defer { lock.unlock() }
        self.token = token
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        self.token = nil
    }
}

// MARK: - Keychain Storage (Optional)

/// Keychain-backed token storage for cases where persistence across app launches is required.
///
/// **Use sparingly.** Section 12: "Use Keychain for sensitive token persistence when needed."
/// Most consumers should use `InMemoryTokenStorage` instead.
internal final class KeychainTokenStorage: TokenStorage, @unchecked Sendable {
    
    // MARK: - Constants
    
    private let service: String
    private let account = "kasookoo.session.token"
    private let lock = NSLock()
    
    // In-memory cache to avoid hitting Keychain on every read
    private var cache: StoredToken?
    
    // MARK: - Init
    
    init(service: String = "com.kasookoo.sdk") {
        self.service = service
    }
    
    // MARK: - TokenStorage
    
    func load() -> StoredToken? {
        lock.lock()
        defer { lock.unlock() }
        
        if let cached = cache {
            return cached
        }
        
        guard let data = readFromKeychain() else { return nil }
        guard let decoded = try? JSONDecoder().decode(KeychainEntry.self, from: data) else {
            return nil
        }
        
        let token = StoredToken(
            token: decoded.token,
            sessionId: decoded.sessionId,
            expiresAt: decoded.expiresAt
        )
        cache = token
        return token
    }
    
    func save(_ token: StoredToken) {
        lock.lock()
        defer { lock.unlock() }
        
        let entry = KeychainEntry(
            token: token.token,
            sessionId: token.sessionId,
            expiresAt: token.expiresAt
        )
        guard let data = try? JSONEncoder().encode(entry) else { return }
        writeToKeychain(data: data)
        cache = token
    }
    
    func clear() {
        lock.lock()
        defer { lock.unlock() }
        deleteFromKeychain()
        cache = nil
    }
    
    // MARK: - Keychain Operations
    
    private func keychainQuery() -> [String: Any] {
        return [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        ]
    }
    
    private func readFromKeychain() -> Data? {
        var query = keychainQuery()
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        
        var result: AnyObject?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        
        guard status == errSecSuccess else { return nil }
        return result as? Data
    }
    
    private func writeToKeychain(data: Data) {
        // Delete any existing item first
        SecItemDelete(keychainQuery() as CFDictionary)
        
        // Add new item
        var query = keychainQuery()
        query[kSecValueData as String] = data
        SecItemAdd(query as CFDictionary, nil)
    }
    
    private func deleteFromKeychain() {
        SecItemDelete(keychainQuery() as CFDictionary)
    }
    
    // MARK: - Encoding Helper
    
    private struct KeychainEntry: Codable {
        let token: String
        let sessionId: String
        let expiresAt: Date
    }
}
