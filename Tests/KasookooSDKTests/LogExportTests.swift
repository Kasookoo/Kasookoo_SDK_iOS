//
//  LogExportTests.swift
//  KasookooSDKTests
//
//  Guards the rule that the SDK's own log lines reach the telemetry
//  pipeline (Loki), so they cannot silently stop being exported again.
//

import Foundation
import Testing
@testable import KasookooSDK

/// Collects what the logger exported.
private final class ExportedLines: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [(level: LoggingConfig.Level, category: String, message: String)] = []

    func append(_ level: LoggingConfig.Level, _ category: String, _ message: String) {
        lock.lock(); defer { lock.unlock() }
        items.append((level, category, message))
    }

    var messages: [String] {
        lock.lock(); defer { lock.unlock() }
        return items.map { $0.message }
    }

    var categories: [String] {
        lock.lock(); defer { lock.unlock() }
        return items.map { $0.category }
    }
}

/// Records `logMessage` calls instead of exporting them.
private final class RecordingTelemetry: TelemetryReporting, @unchecked Sendable {
    private let lock = NSLock()
    private(set) var lines: [(message: String, severity: TelemetrySeverity, attributes: [String: TelemetryAttribute])] = []

    func startSpan(_ name: String, attributes: [String: TelemetryAttribute]) -> TelemetrySpanHandle { NoopSpanHandle() }
    func log(event: String, message: String, severity: TelemetrySeverity, attributes: [String: TelemetryAttribute]) {}
    func logMessage(_ message: String, severity: TelemetrySeverity, attributes: [String: TelemetryAttribute]) {
        lock.lock(); defer { lock.unlock() }
        lines.append((message, severity, attributes))
    }
    func setUserId(_ userId: String?) {}
    func flush() {}
    func shutdown() {}
}

@Suite struct LogExportTests {

    @Test("Lines at or above the export level are exported, below are not")
    func exportThreshold() {
        let logger = Logger(config: .silent, category: "Calling")
        let exported = ExportedLines()
        logger.setExport(level: .info) { level, category, message, _, _ in
            exported.append(level, category, message)
        }

        logger.verbose("v")
        logger.debug("d")
        logger.info("i")
        logger.warning("w")
        logger.error("e")

        #expect(exported.messages == ["i", "w", "e"])
        #expect(exported.categories == ["Calling", "Calling", "Calling"])
    }

    @Test("Export does not depend on the console level (release apps log nothing to the console)")
    func exportIndependentOfConsole() {
        let logger = Logger(config: LoggingConfig(level: .none, enableConsole: false))
        let exported = ExportedLines()
        logger.setExport(level: .warning) { level, category, message, _, _ in
            exported.append(level, category, message)
        }

        logger.info("not exported")
        logger.error("exported")

        #expect(exported.messages == ["exported"])
    }

    @Test("Removing the sink stops export")
    func stopExport() {
        let logger = Logger(config: .silent)
        let exported = ExportedLines()
        logger.setExport(level: .info) { level, category, message, _, _ in
            exported.append(level, category, message)
        }
        logger.setExport(level: .none, sink: nil)

        logger.error("after stop")

        #expect(exported.messages.isEmpty)
    }

    @Test("The telemetry pipeline's own logger never exports (no export loop while offline)")
    func pipelineLoggerDoesNotExport() {
        let logger = Logger(config: .silent)
        let exported = ExportedLines()
        logger.setExport(level: .info) { level, category, message, _, _ in
            exported.append(level, category, message)
        }

        let pipelineLogger = logger.makeNonExportingChild(category: "Telemetry")
        pipelineLogger.warning("Telemetry export failed")

        #expect(exported.messages.isEmpty)
    }

    @Test("Wiring sends logger lines to telemetry with category, source and severity")
    func wiringForwardsToTelemetry() {
        let logger = Logger(config: .silent, category: "SDK")
        let telemetry = RecordingTelemetry()
        let wired = LogExportWiring.connect(
            logger: logger,
            telemetry: telemetry,
            configuration: .test
        )

        logger.warning("Token rotation rejected")

        #expect(wired)
        #expect(telemetry.lines.count == 1)
        #expect(telemetry.lines.first?.message == "Token rotation rejected")
        #expect(telemetry.lines.first?.severity == .warn)
        #expect(telemetry.lines.first?.attributes[TelemetryKey.logger] == .string("SDK"))
        if case .string(let source)? = telemetry.lines.first?.attributes[TelemetryKey.source] {
            #expect(source.contains("LogExportTests.swift:"))
        } else {
            Issue.record("source attribute missing")
        }
    }

    @Test("No export when telemetry is disabled, logs are off, or the level is .none")
    func wiringRespectsConfiguration() {
        var noLogs = TelemetryConfiguration.test
        noLogs.capturesLogs = false
        var levelNone = TelemetryConfiguration.test
        levelNone.exportedLogLevel = .none

        for configuration in [TelemetryConfiguration.disabled, noLogs, levelNone] {
            let logger = Logger(config: .silent)
            let telemetry = RecordingTelemetry()
            let wired = LogExportWiring.connect(logger: logger, telemetry: telemetry, configuration: configuration)
            logger.error("should stay on device")
            #expect(!wired)
            #expect(telemetry.lines.isEmpty)
        }
    }

    @Test("Default configuration exports info and above")
    func defaultExportLevel() {
        #expect(TelemetryConfiguration().exportedLogLevel == .info)
        #expect(TelemetryConfiguration.test.exportedLogLevel == .info)
        #expect(TelemetryConfiguration.production.exportedLogLevel == .info)
    }
}
