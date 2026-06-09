//
//  RefreshScheduler.swift
//  KasookooSDK
//
//

import Foundation

/// Schedules pre-emptive session refresh.
///
/// Runs a single timer that fires at the configured threshold of token TTL.
/// Cancellable and re-schedulable as tokens are renewed.
internal actor RefreshScheduler {
    
    // MARK: - Properties
    
    private var refreshTask: Task<Void, Never>?
    private let refreshThresholdRatio: Double
    private let logger: Logger
    
    // MARK: - Init
    
    /// Creates a new scheduler.
    ///
    /// - Parameters:
    ///   - refreshThresholdRatio: When to trigger refresh, as a ratio of TTL.
    ///                            Default `0.85` means refresh at 85% of token lifetime.
    ///   - logger: The logger to use.
    init(refreshThresholdRatio: Double = 0.85, logger: Logger) {
        self.refreshThresholdRatio = refreshThresholdRatio
        self.logger = logger
    }
    
    // MARK: - Public API
    
    /// Schedules a refresh based on the token's expiry.
    ///
    /// - Parameters:
    ///   - expiresAt: When the token expires.
    ///   - refreshAction: The async action to perform when it's time to refresh.
    func schedule(
        expiresAt: Date,
        refreshAction: @Sendable @escaping () async -> Void
    ) {
        // Cancel any existing scheduled refresh
        cancel()
        
        let secondsUntilExpiry = expiresAt.timeIntervalSinceNow
        guard secondsUntilExpiry > 0 else {
            logger.warning("Token already expired; skipping refresh schedule")
            return
        }
        
        // Refresh at threshold% of remaining time
        let secondsUntilRefresh = secondsUntilExpiry * refreshThresholdRatio
        let nanoseconds = UInt64(max(secondsUntilRefresh, 1) * 1_000_000_000)
        
        logger.debug("Scheduling refresh in \(Int(secondsUntilRefresh))s (TTL: \(Int(secondsUntilExpiry))s)")
        
        refreshTask = Task { [weak self] in
            do {
                try await Task.sleep(nanoseconds: nanoseconds)
            } catch {
                // Task was cancelled — exit silently
                return
            }
            
            guard !Task.isCancelled else { return }
            await self?.logTriggered()
            await refreshAction()
        }
    }
    
    /// Cancels any pending refresh.
    func cancel() {
        refreshTask?.cancel()
        refreshTask = nil
    }
    
    // MARK: - Private
    
    private func logTriggered() {
        logger.info("Pre-emptive refresh triggered")
    }
}
