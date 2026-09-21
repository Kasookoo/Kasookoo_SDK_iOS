import Foundation

// OpenTelemetry is imported implementation-only on purpose.
//
// `OpenTelemetryApi` declares `extension NSError: SpanException`, which adds
// `type`, `message` and `stackTrace` to EVERY NSError subclass. Without this
// attribute those members leak through KasookooSDK into the tenant's app: any
// error type of theirs that already has a `message` (LiveKitError does) becomes
// ambiguous at the call site, in their code, for a dependency they never asked
// for. An SDK must not reshape Foundation types in the apps that embed it.
//
// Nothing here appears in the SDK's public API, so implementation-only is safe:
// every telemetry type crossing a file boundary is the SDK's own.
@_implementationOnly import OpenTelemetryApi
@_implementationOnly import OpenTelemetrySdk

#if canImport(UIKit)
import UIKit
#endif

// This and `OTLPJSONExporter.swift` are the only files in the SDK that know
// OpenTelemetry exists. Everything else talks to `TelemetryReporting`. If the
// vendor ever changes, these are replaced and nothing else moves.
//
// Only `opentelemetry-swift-core` is used, which has no external dependencies on
// iOS. The transport is the SDK's own OTLP/JSON exporter.
//
// `OpenTelemetryApi` also exports a `Logger`, so the SDK's own logger is
// referenced here as `SDKLogger` (see Telemetry.swift).

// MARK: - Factory

internal enum TelemetryFactory {

    /// Builds the reporter for a configuration. Returns `NoopTelemetry` when
    /// telemetry is off, so nothing downstream needs to branch.
    static func make(
        configuration: TelemetryConfiguration,
        organizationId: String,
        logger: SDKLogger
    ) -> TelemetryReporting {
        guard configuration.isEnabled else {
            return NoopTelemetry()
        }
        return OTelTelemetry(
            configuration: configuration,
            organizationId: organizationId,
            logger: logger
        )
    }
}

// MARK: - OpenTelemetry Reporter

internal final class OTelTelemetry: TelemetryReporting, @unchecked Sendable {

    /// Instrumentation scope reported to the collector.
    private static let scopeName = "KasookooSDK"

    /// Required by the backend so Tempo and Loki can tell platforms apart.
    private static let serviceName = "kasookoo-ios"

    private let tracer: Tracer
    private let otelLogger: OpenTelemetryApi.Logger
    private let logger: SDKLogger
    private let configuration: TelemetryConfiguration

    /// Held so the pipelines can be flushed and shut down. `LoggerProviderSdk`
    /// exposes no flush of its own, so the log processor is kept directly.
    private let tracerProvider: TracerProviderSdk
    private let spanProcessor: BatchSpanProcessor?
    private let logProcessor: BatchLogRecordProcessor?

    private var userId: String?
    private let userIdLock = NSLock()

    private var lifecycleObserver: NSObjectProtocol?

    // MARK: Init

    init(
        configuration: TelemetryConfiguration,
        organizationId: String,
        logger: SDKLogger
    ) {
        self.configuration = configuration
        self.logger = logger

        // Start from the default resource so `telemetry.sdk.*` is kept, then
        // override with ours. Later values win in `merging`.
        let resource = Resource().merging(
            other: Resource(attributes: OTelTelemetry.resourceAttributes(
                configuration: configuration,
                organizationId: organizationId
            ))
        )

        // One uploader shared by both signals, so traces and logs use a single
        // URLSession and one set of headers.
        //
        // Nothing here reads OTEL_EXPORTER_* environment variables, which the
        // upstream exporters do by default. In a commercial SDK that would let a
        // host application silently redirect a tenant's telemetry elsewhere.
        let uploader = OTLPJSONUploader(
            headers: configuration.additionalHeaders,
            timeout: 10,
            logger: logger
        )

        // Traces
        var spanProcessor: BatchSpanProcessor?
        if configuration.capturesTraces {
            let traceExporter = OTLPJSONSpanExporter(
                endpoint: configuration.tracesEndpoint,
                uploader: uploader
            )
            spanProcessor = BatchSpanProcessor(
                spanExporter: traceExporter,
                scheduleDelay: configuration.scheduleDelay,
                maxQueueSize: configuration.maxQueueSize,
                maxExportBatchSize: configuration.maxExportBatchSize,
                willExportCallback: OTelTelemetry.spanExportLogger(logger)
            )
        }
        self.spanProcessor = spanProcessor

        let tracerBuilder = TracerProviderBuilder().with(resource: resource)
        if let spanProcessor {
            _ = tracerBuilder.add(spanProcessor: spanProcessor)
        }
        if !configuration.capturesTraces {
            // No exporter, so make spans non-recording rather than paying to
            // build them and throwing them away.
            _ = tracerBuilder.with(sampler: Samplers.alwaysOff)
        } else if configuration.sampleRate < 1.0 {
            _ = tracerBuilder.with(
                sampler: Samplers.parentBased(
                    root: Samplers.traceIdRatio(ratio: configuration.sampleRate)
                )
            )
        }
        let tracerProvider = tracerBuilder.build()
        self.tracerProvider = tracerProvider

        // Logs
        var logProcessor: BatchLogRecordProcessor?
        if configuration.capturesLogs {
            let logExporter = OTLPJSONLogExporter(
                endpoint: configuration.logsEndpoint,
                uploader: uploader
            )
            logProcessor = BatchLogRecordProcessor(
                logRecordExporter: logExporter,
                scheduleDelay: configuration.scheduleDelay,
                maxQueueSize: configuration.maxQueueSize,
                maxExportBatchSize: configuration.maxExportBatchSize,
                willExportCallback: OTelTelemetry.logExportLogger(logger)
            )
        }
        self.logProcessor = logProcessor

        let loggerBuilder = LoggerProviderBuilder().with(resource: resource)
        if let logProcessor {
            _ = loggerBuilder.with(processors: [logProcessor])
        }
        let loggerProvider = loggerBuilder.build()

        // The providers are deliberately NOT registered with
        // `OpenTelemetry.registerTracerProvider`. That global is the host app's
        // to own; a tenant with its own OpenTelemetry setup must not have it
        // replaced by ours. We hold our own instances instead.
        self.tracer = tracerProvider.get(
            instrumentationName: OTelTelemetry.scopeName,
            instrumentationVersion: SDKVersion.current
        )
        self.otelLogger = loggerProvider.get(
            instrumentationScopeName: OTelTelemetry.scopeName
        )

        observeAppLifecycle()

        logger.debug(
            "Telemetry enabled: endpoint=\(configuration.endpoint.absoluteString) "
            + "environment=\(configuration.environment) sampleRate=\(configuration.sampleRate)"
        )
    }

    deinit {
        if let lifecycleObserver {
            NotificationCenter.default.removeObserver(lifecycleObserver)
        }
    }

    // MARK: TelemetryReporting

    func startSpan(
        _ name: String,
        attributes: [String: TelemetryAttribute]
    ) -> TelemetrySpanHandle {
        let builder = tracer.spanBuilder(spanName: name)
        for (key, value) in correlated(attributes) {
            builder.setAttribute(key: key, value: value.otelValue)
        }
        return OTelSpanHandle(span: builder.startSpan())
    }

    func log(
        event: String,
        message: String,
        severity: TelemetrySeverity,
        attributes: [String: TelemetryAttribute]
    ) {
        guard configuration.capturesLogs else { return }

        var merged = correlated(attributes)
        merged[TelemetryKey.event] = .string(event)
        merged[TelemetryKey.level] = .string(severity.levelName)

        let body = TelemetryRedaction.sanitize(text: "\(event): \(message)")

        otelLogger.logRecordBuilder()
            .setTimestamp(Date())
            .setSeverity(severity.otelSeverity)
            .setBody(.string(body))
            .setAttributes(merged.mapValues { $0.otelValue })
            .setEventName(event)
            .emit()
    }

    func setUserId(_ userId: String?) {
        userIdLock.lock()
        defer { userIdLock.unlock() }
        self.userId = userId
    }

    func flush() {
        spanProcessor?.forceFlush()
        _ = logProcessor?.forceFlush(explicitTimeout: nil)
    }

    func shutdown() {
        if let lifecycleObserver {
            NotificationCenter.default.removeObserver(lifecycleObserver)
            self.lifecycleObserver = nil
        }
        tracerProvider.shutdown()
        _ = logProcessor?.shutdown(explicitTimeout: nil)
    }

    // MARK: Correlation

    /// Merges the caller's attributes with the active trace context and the
    /// current user id, then redacts the result.
    ///
    /// `TraceContext.current` is a task local, so reading it here picks up the
    /// feature lifecycle the caller is running inside without it having to pass
    /// anything down.
    private func correlated(
        _ attributes: [String: TelemetryAttribute]
    ) -> [String: TelemetryAttribute] {
        var merged = TelemetryRedaction.sanitize(attributes)

        if let trace = TraceContext.current {
            merged[TelemetryKey.callTraceId] = .string(trace.callTraceId)
            merged[TelemetryKey.featureType] = .string(trace.featureType.rawValue)
        }

        userIdLock.lock()
        let currentUserId = userId
        userIdLock.unlock()

        if let currentUserId, !currentUserId.isEmpty {
            merged[TelemetryKey.userId] = .string(currentUserId)
        }
        return merged
    }

    // MARK: Export tracing (DEBUG only)
    
    /// Logs each batch as it leaves the processor.
    ///
    /// OTLP exporters swallow their result by design, so without this there is
    /// no way to tell "nothing was ever recorded" apart from "records were
    /// recorded but the export failed". Compiled out of release builds.
    private static func spanExportLogger(_ logger: SDKLogger) -> ((inout [SpanData]) -> Void)? {
        #if DEBUG
        return { spans in
            let names = spans.map { $0.name }.joined(separator: ", ")
            logger.debug("Telemetry: exporting \(spans.count) span(s) [\(names)]")
        }
        #else
        return nil
        #endif
    }
    
    /// DEBUG counterpart of `spanExportLogger` for log records.
    private static func logExportLogger(_ logger: SDKLogger) -> ((inout [ReadableLogRecord]) -> Void)? {
        #if DEBUG
        return { records in
            logger.debug("Telemetry: exporting \(records.count) log record(s)")
        }
        #else
        return nil
        #endif
    }
    
    // MARK: Resource

    private static func resourceAttributes(
        configuration: TelemetryConfiguration,
        organizationId: String
    ) -> [String: AttributeValue] {
        [
            "service.name": .string(serviceName),
            "service.version": .string(SDKVersion.current),
            "deployment.environment": .string(configuration.environment),
            "organization_id": .string(organizationId),
            "os.type": .string("darwin"),
            "os.name": .string("iOS"),
            "os.version": .string(ProcessInfo.processInfo.operatingSystemVersionString),
            "device.model.identifier": .string(deviceModelIdentifier())
        ]
    }

    /// Hardware identifier such as `iPhone15,3`. Not personally identifying.
    private static func deviceModelIdentifier() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { raw in
            let bytes = raw.prefix { $0 != 0 }
            return String(decoding: bytes, as: UTF8.self)
        }
    }

    // MARK: App lifecycle

    /// Flushes when the app is backgrounded.
    ///
    /// Batch processors hold records for `scheduleDelay`, so without this a
    /// backgrounded or terminated app loses whatever was still queued, which is
    /// exactly the failed call that needed reporting. The background task
    /// assertion buys the export a few seconds before suspension.
    ///
    /// This observer runs in the app process only. It is inert in an app
    /// extension, where there is no `UIApplication` lifecycle to observe.
    private func observeAppLifecycle() {
        #if canImport(UIKit) && !os(watchOS)
        lifecycleObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.flushInBackground()
        }
        #endif
    }

    #if canImport(UIKit) && !os(watchOS)
    private func flushInBackground() {
        let application = UIApplication.shared
        var taskId: UIBackgroundTaskIdentifier = .invalid

        taskId = application.beginBackgroundTask(withName: "KasookooTelemetryFlush") {
            if taskId != .invalid {
                application.endBackgroundTask(taskId)
                taskId = .invalid
            }
        }
        guard taskId != .invalid else { return }

        DispatchQueue.global(qos: .utility).async { [weak self] in
            self?.flush()
            DispatchQueue.main.async {
                if taskId != .invalid {
                    application.endBackgroundTask(taskId)
                    taskId = .invalid
                }
            }
        }
    }
    #endif
}

// MARK: - Span Handle

private final class OTelSpanHandle: TelemetrySpanHandle, @unchecked Sendable {

    private let span: Span
    private let lock = NSLock()
    private var hasEnded = false

    init(span: Span) {
        self.span = span
    }

    func setAttribute(_ key: String, _ value: TelemetryAttribute) {
        guard TelemetryRedaction.isAllowed(key: key) else { return }
        let sanitized: TelemetryAttribute
        if case .string(let text) = value {
            sanitized = .string(TelemetryRedaction.sanitize(text: text))
        } else {
            sanitized = value
        }

        lock.lock()
        defer { lock.unlock() }
        guard !hasEnded else { return }
        span.setAttribute(key: key, value: sanitized.otelValue)
    }

    func setError(_ message: String) {
        let description = TelemetryRedaction.sanitize(text: message)

        lock.lock()
        defer { lock.unlock() }
        guard !hasEnded else { return }
        span.status = .error(description: description)
        span.setAttribute(
            key: TelemetryKey.result,
            value: AttributeValue.string("error")
        )
    }

    func end() {
        lock.lock()
        defer { lock.unlock() }
        guard !hasEnded else { return }
        hasEnded = true
        span.end()
    }
}

// MARK: - Bridging

private extension TelemetryAttribute {
    var otelValue: AttributeValue {
        switch self {
        case .string(let value): return .string(value)
        case .int(let value): return .int(value)
        case .double(let value): return .double(value)
        case .bool(let value): return .bool(value)
        }
    }
}

private extension TelemetrySeverity {
    var otelSeverity: Severity {
        switch self {
        case .debug: return .debug
        case .info: return .info
        case .warn: return .warn
        case .error: return .error
        }
    }

    /// Matches the `level` values the backend writes to Loki.
    var levelName: String {
        switch self {
        case .debug: return "debug"
        case .info: return "info"
        case .warn: return "warning"
        case .error: return "error"
        }
    }
}
