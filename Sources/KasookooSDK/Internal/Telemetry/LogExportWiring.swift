//
//  LogExportWiring.swift
//  KasookooSDK
//
//  Connects the SDK's Logger to the telemetry pipeline.
//

import Foundation

/// Sends the SDK's own log lines to Loki (service_name `kasookoo-ios`).
///
/// Before this, `Logger` wrote only to the device (os_log / console) and
/// Loki received just a handful of named failure events, so a call or a
/// message could only be followed through Tempo spans. Every `logger.info`,
/// `.warning` and `.error` now also becomes an OTLP log record — redacted by
/// `TelemetryRedaction`, correlated with `call_trace_id` / `user_id`, and
/// linked to the open span of its lifecycle.
///
/// Kept separate from `SDKBuilder` so the rule ("which lines are exported")
/// lives in one place and can be unit tested.
internal enum LogExportWiring {

    /// Wires `logger` to `telemetry` when the configuration allows it.
    /// - Returns: whether export was enabled.
    @discardableResult
    static func connect(
        logger: Logger,
        telemetry: TelemetryReporting,
        configuration: TelemetryConfiguration
    ) -> Bool {
        guard configuration.isEnabled,
              configuration.capturesLogs,
              configuration.exportedLogLevel != .none else {
            logger.setExport(level: .none, sink: nil)
            return false
        }

        logger.setExport(level: configuration.exportedLogLevel) { level, category, message, file, line in
            telemetry.logMessage(
                message,
                severity: level.telemetrySeverity,
                attributes: [
                    TelemetryKey.logger: .string(category),
                    TelemetryKey.source: .string("\(file):\(line)")
                ]
            )
        }
        return true
    }
}
