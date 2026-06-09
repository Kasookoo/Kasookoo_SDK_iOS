//
//  RetryPolicy.swift
//  KasookooSDK
//
//

import Foundation

/// Configuration for retry behavior on retryable failures.
internal struct RetryPolicy: Sendable {
    
    /// The maximum number of retry attempts (excluding the initial attempt).
    let maxRetries: Int
    
    /// The initial delay before the first retry, in seconds.
    let initialDelay: TimeInterval
    
    /// The exponential backoff multiplier.
    let backoffMultiplier: Double
    
    /// The maximum delay cap between retries, in seconds.
    let maxDelay: TimeInterval
    
    /// Whether to add random jitter to delays to avoid thundering herd.
    let useJitter: Bool
    
    /// Default retry policy for most network operations.
    static let `default` = RetryPolicy(
        maxRetries: 3,
        initialDelay: 0.5,
        backoffMultiplier: 2.0,
        maxDelay: 8.0,
        useJitter: true
    )
    
    /// Aggressive retry for critical operations (e.g., session refresh).
    static let aggressive = RetryPolicy(
        maxRetries: 5,
        initialDelay: 0.3,
        backoffMultiplier: 2.0,
        maxDelay: 10.0,
        useJitter: true
    )
    
    /// No retries.
    static let none = RetryPolicy(
        maxRetries: 0,
        initialDelay: 0,
        backoffMultiplier: 1.0,
        maxDelay: 0,
        useJitter: false
    )
    
    /// Calculates the delay for a specific retry attempt.
    ///
    /// - Parameter attempt: The retry attempt number (0-indexed: 0 = first retry).
    /// - Returns: The delay in seconds.
    func delay(forAttempt attempt: Int) -> TimeInterval {
        let exponentialDelay = initialDelay * pow(backoffMultiplier, Double(attempt))
        let cappedDelay = min(exponentialDelay, maxDelay)
        
        guard useJitter else { return cappedDelay }
        
        // Add up to 30% random jitter
        let jitter = Double.random(in: 0...(cappedDelay * 0.3))
        return cappedDelay + jitter
    }
}

// MARK: - Retry Helper

internal enum Retrier {
    
    /// Executes an operation with retry logic.
    ///
    /// - Parameters:
    ///   - policy: The retry policy to apply.
    ///   - isRetryable: A closure that determines whether a thrown error is retryable.
    ///   - operation: The async operation to execute.
    /// - Returns: The successful result.
    /// - Throws: The last error if all retries are exhausted.
    static func execute<T: Sendable>(
        policy: RetryPolicy,
        isRetryable: @Sendable (Error) -> Bool = { _ in true },
        operation: @Sendable () async throws -> T
    ) async throws -> T {
        var lastError: Error?
        
        for attempt in 0...policy.maxRetries {
            do {
                return try await operation()
            } catch {
                lastError = error
                
                // Don't retry if not retryable
                if !isRetryable(error) {
                    throw error
                }
                
                // Don't sleep after the final attempt
                if attempt < policy.maxRetries {
                    let delay = policy.delay(forAttempt: attempt)
                    try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                }
            }
        }
        
        throw lastError ?? KasookooError.unknown(message: "Retry exhausted with no error captured.")
    }
}

// MARK: - KasookooError Retryable Detection

internal extension KasookooError {
    /// Whether this error should be retried based on its `retryable` flag and code.
    var shouldRetry: Bool {
        return retryable
    }
}
