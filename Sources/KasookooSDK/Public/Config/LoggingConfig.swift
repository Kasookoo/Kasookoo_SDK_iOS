//
//  LoggingConfig.swift
//  KasookooSDK
//
//  Controls SDK internal logging behavior (Section 5 of the spec).
//

import Foundation

/// Controls SDK internal logging behavior.
public struct LoggingConfig: Sendable, Codable {
    
    /// The verbosity level for SDK logs.
    public enum Level: String, Sendable, Codable {
        /// Suppresses all logs.
        case none = "none"
        
        /// Logs only errors.
        case error = "error"
        
        /// Logs errors and warnings.
        case warning = "warning"
        
        /// Logs errors, warnings, and informational messages. (Default)
        case info = "info"
        
        /// Logs all messages including debug-level details.
        case debug = "debug"
        
        /// Logs everything including verbose internal state. Use sparingly.
        case verbose = "verbose"
    }
    
    /// The log level threshold. Only messages at or above this level are logged.
    public let level: Level
    
    /// Whether to print logs to the console (Xcode debugger).
    /// Disabled by default in production to avoid leaking information.
    public let enableConsole: Bool
    
    /// Creates a new logging configuration.
    ///
    /// - Parameters:
    ///   - level: The minimum log level. Defaults to `.info`.
    ///   - enableConsole: Whether to print to the console. Defaults to `false`.
    public init(level: Level = .info, enableConsole: Bool = false) {
        self.level = level
        self.enableConsole = enableConsole
    }
    
    /// A silent configuration that disables all logging.
    public static let silent = LoggingConfig(level: .none, enableConsole: false)
    
    /// A debug configuration with verbose console logging. For development only.
    public static let debug = LoggingConfig(level: .debug, enableConsole: true)
    
    /// The default configuration: info-level logging, no console output.
    public static let `default` = LoggingConfig()
}
