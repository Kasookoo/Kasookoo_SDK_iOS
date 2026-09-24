//
//  Logger.swift
//  KasookooSDK
//
//

import Foundation
import OSLog

/// Internal logger used throughout the SDK.
///
/// Wraps Apple's `os.Logger` for system-level logging and optionally prints
/// to the console for development.
///
/// **Privacy:** in release builds messages are written to the unified log as
/// `.private`, so they are redacted in sysdiagnoses and Console unless a
/// debugger is attached. This SDK runs inside other companies' apps, and ids,
/// room names and error text should not be readable from a device log.
/// Debug builds stay `.public` for development.
///
/// **Security:** Never log tokens, passwords, OTPs, or PII via this logger.
internal final class Logger: @unchecked Sendable {
    
    // MARK: - Properties
    
    private let config: LoggingConfig
    private let osLogger: os.Logger
    private let subsystem: String
    private let category: String
    
    // MARK: - Initialization
    
    /// Creates a new logger.
    ///
    /// - Parameters:
    ///   - config: The logging configuration.
    ///   - category: A category string (e.g., "Networking", "Session").
    init(config: LoggingConfig, category: String = "SDK") {
        self.config = config
        self.subsystem = "com.kasookoo.sdk"
        self.category = category
        self.osLogger = os.Logger(subsystem: subsystem, category: category)
    }
    
    // MARK: - Logging Methods
    
    /// Logs a verbose message (most detailed level).
    func verbose(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        guard shouldLog(.verbose) else { return }
        emit(level: .verbose, message: message(), file: file, line: line)
    }
    
    /// Logs a debug message.
    func debug(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        guard shouldLog(.debug) else { return }
        emit(level: .debug, message: message(), file: file, line: line)
    }
    
    /// Logs an informational message.
    func info(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        guard shouldLog(.info) else { return }
        emit(level: .info, message: message(), file: file, line: line)
    }
    
    /// Logs a warning message.
    func warning(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        guard shouldLog(.warning) else { return }
        emit(level: .warning, message: message(), file: file, line: line)
    }
    
    /// Logs an error message.
    func error(_ message: @autoclosure () -> String, file: String = #fileID, line: Int = #line) {
        guard shouldLog(.error) else { return }
        emit(level: .error, message: message(), file: file, line: line)
    }
    
    // MARK: - Private Helpers
    
    private func shouldLog(_ level: LoggingConfig.Level) -> Bool {
        return level.priority <= config.level.priority
    }
    
    private func emit(
        level: LoggingConfig.Level,
        message: String,
        file: String,
        line: Int
    ) {
        let prefix = "[\(category)] \(level.symbol)"
        let location = "(\(file):\(line))"
        let fullMessage = "\(prefix) \(message) \(location)"
        
        // Always send to os.Logger (visible in Console.app, Instruments).
        // The privacy level must be a compile-time constant, hence the two
        // switch copies.
#if DEBUG
        switch level {
        case .verbose, .debug:
            osLogger.debug("\(fullMessage, privacy: .public)")
        case .info:
            osLogger.info("\(fullMessage, privacy: .public)")
        case .warning:
            osLogger.warning("\(fullMessage, privacy: .public)")
        case .error:
            osLogger.error("\(fullMessage, privacy: .public)")
        case .none:
            break
        }
#else
        switch level {
        case .verbose, .debug:
            osLogger.debug("\(fullMessage, privacy: .private)")
        case .info:
            osLogger.info("\(fullMessage, privacy: .private)")
        case .warning:
            osLogger.warning("\(fullMessage, privacy: .private)")
        case .error:
            osLogger.error("\(fullMessage, privacy: .private)")
        case .none:
            break
        }
#endif
        
        // Print to console if enabled
        if config.enableConsole {
            print(fullMessage)
        }
    }
}

// MARK: - Level Priority

private extension LoggingConfig.Level {
    
    /// Numeric priority for level comparison. Lower = more critical.
    var priority: Int {
        switch self {
        case .none: return 0
        case .error: return 1
        case .warning: return 2
        case .info: return 3
        case .debug: return 4
        case .verbose: return 5
        }
    }
    
    /// A short symbol representing this level for log prefixes.
    var symbol: String {
        switch self {
        case .none: return ""
        case .error: return "❌ ERROR"
        case .warning: return "⚠️ WARN"
        case .info: return "ℹ️ INFO"
        case .debug: return "🔍 DEBUG"
        case .verbose: return "🔬 VERBOSE"
        }
    }
}
