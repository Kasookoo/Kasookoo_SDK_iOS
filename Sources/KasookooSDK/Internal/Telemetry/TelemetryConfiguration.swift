import Foundation

/// Controls whether the SDK reports traces and logs to the Kasookoo
/// observability stack, and where it sends them.
///
/// Telemetry carries operational signals only: span names, durations, result
/// codes, and correlation ids. Message contents, phone numbers, tokens, and
/// request bodies are never exported (see `TelemetryRedaction`).
///
/// A tenant that cannot allow any client side reporting sets
/// `KasookooConfig.telemetry = .disabled`, which removes the pipeline entirely
/// rather than muting it.
public struct TelemetryConfiguration: Sendable {

    // MARK: Mode

    public enum Mode: Sendable, Equatable {
        /// No provider is created and nothing is collected or sent.
        case disabled
        /// Traces and logs are collected and exported.
        case enabled
    }

    // MARK: Stored

    public var mode: Mode

    /// Base URL of the OTLP collector. Signal paths are appended to it.
    public var endpoint: URL

    /// Reported as `deployment.environment`, for example `production` or `staging`.
    public var environment: String

    /// Fraction of traces to keep, from 0.0 to 1.0. Logs are not sampled.
    public var sampleRate: Double

    public var capturesTraces: Bool
    public var capturesLogs: Bool

    /// Extra headers sent with every export, for example an ingest key.
    public var additionalHeaders: [String: String]

    /// How long a batch waits before being exported.
    public var scheduleDelay: TimeInterval

    /// Maximum records held in memory. Oldest are dropped when full, so a long
    /// offline period cannot grow without bound.
    public var maxQueueSize: Int

    /// Maximum records per export request.
    public var maxExportBatchSize: Int

    // MARK: Init

    public init(
        mode: Mode = .enabled,
        endpoint: URL = TelemetryConfiguration.productionEndpoint,
        environment: String = "production",
        sampleRate: Double = 1.0,
        capturesTraces: Bool = true,
        capturesLogs: Bool = true,
        additionalHeaders: [String: String] = [:],
        scheduleDelay: TimeInterval = 5,
        maxQueueSize: Int = 2048,
        maxExportBatchSize: Int = 512
    ) {
        self.mode = mode
        self.endpoint = endpoint
        self.environment = environment
        self.sampleRate = min(max(sampleRate, 0.0), 1.0)
        self.capturesTraces = capturesTraces
        self.capturesLogs = capturesLogs
        self.additionalHeaders = additionalHeaders
        self.scheduleDelay = scheduleDelay
        self.maxQueueSize = maxQueueSize
        self.maxExportBatchSize = maxExportBatchSize
    }

    // MARK: Presets

    // Literal URLs that are known to parse, declared once so the force unwrap
    // exists in exactly one place.
    public static let productionEndpoint = URL(string: "https://monitoring.kasookoo.ai")!
    public static let testEndpoint = URL(string: "https://monitoring-test.kasookoo.ai")!

    /// Nothing is collected or sent.
    public static let disabled = TelemetryConfiguration(mode: .disabled)

    /// Production collector, full sampling.
    public static let production = TelemetryConfiguration(
        mode: .enabled,
        endpoint: productionEndpoint,
        environment: "production"
    )

    /// Test collector, full sampling. Intended for development builds.
    public static let test = TelemetryConfiguration(
        mode: .enabled,
        endpoint: testEndpoint,
        environment: "test"
    )

    /// Test collector in `DEBUG` builds, production collector otherwise.
    public static var automatic: TelemetryConfiguration {
        #if DEBUG
        return .test
        #else
        return .production
        #endif
    }

    // MARK: Derived

    var tracesEndpoint: URL { endpoint.appendingPathComponent("v1/traces") }
    var logsEndpoint: URL { endpoint.appendingPathComponent("v1/logs") }

    var isEnabled: Bool {
        mode == .enabled && (capturesTraces || capturesLogs)
    }
}
