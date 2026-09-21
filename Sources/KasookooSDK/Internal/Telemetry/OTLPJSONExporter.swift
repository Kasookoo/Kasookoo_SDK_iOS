//
//  OTLPJSONExporter.swift
//  KasookooSDK
//

import Foundation

// Implementation-only for the reason documented in OTelTelemetry.swift.
@_implementationOnly import OpenTelemetryApi
@_implementationOnly import OpenTelemetrySdk

// The SDK's own OTLP exporter, speaking OTLP over HTTP with a JSON body.
//
// WHY THIS EXISTS
//
// OpenTelemetry ships an exporter package (`opentelemetry-swift`), but taking it
// means taking grpc-swift, SwiftNIO and its five siblings, swift-crypto,
// swift-certificates, Thrift and swift-protobuf into every tenant application.
// For a commercial SDK that is a large surface to impose, and in practice it
// collided with LiveKit's vendored nanopb over a shared `pb.h`.
//
// `opentelemetry-swift-core` is different: on iOS it has no external
// dependencies at all. So the API, the SDK, sampling, batching and the span and
// log models all stay official, and only the transport is ours. Roughly two
// hundred lines of URLSession replace roughly twenty packages.
//
// The payload is the OTLP/JSON encoding, which every OpenTelemetry Collector
// accepts on `/v1/traces` and `/v1/logs`. Protobuf field names map to
// lowerCamelCase, and 64 bit integers are encoded as strings, which is why
// timestamps and `intValue` are quoted below.

// MARK: - Uploader

/// Posts an encoded OTLP payload to a collector.
///
/// Shared by the span and log exporters so both use one `URLSession` and one set
/// of headers.
internal final class OTLPJSONUploader: @unchecked Sendable {

    private let session: URLSession
    private let headers: [String: String]
    private let timeout: TimeInterval
    private let logger: SDKLogger

    init(
        headers: [String: String],
        timeout: TimeInterval,
        logger: SDKLogger,
        session: URLSession? = nil
    ) {
        self.headers = headers
        self.timeout = timeout
        self.logger = logger

        if let session {
            self.session = session
        } else {
            // A dedicated session. Telemetry must never contend with, or be
            // shaped by, the caches and cookies of the SDK's API traffic.
            let sessionConfiguration = URLSessionConfiguration.ephemeral
            sessionConfiguration.timeoutIntervalForRequest = timeout
            sessionConfiguration.waitsForConnectivity = false
            self.session = URLSession(configuration: sessionConfiguration)
        }
    }

    /// Sends one payload and reports whether the collector accepted it.
    ///
    /// Synchronous on purpose: OpenTelemetry's exporter protocol is
    /// synchronous, and the batch processors already call it from their own
    /// background worker thread, never from the caller's.
    func send(_ payload: [String: Any], to endpoint: URL) -> Bool {
        guard JSONSerialization.isValidJSONObject(payload) else {
            logger.warning("Telemetry: OTLP payload was not valid JSON, dropping batch")
            return false
        }

        let body: Data
        do {
            body = try JSONSerialization.data(withJSONObject: payload, options: [])
        } catch {
            logger.warning("Telemetry: could not encode OTLP payload: \(error.localizedDescription)")
            return false
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.timeoutInterval = timeout
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        for (name, value) in headers {
            request.setValue(value, forHTTPHeaderField: name)
        }
        request.httpBody = body

        let semaphore = DispatchSemaphore(value: 0)
        var accepted = false

        let task = session.dataTask(with: request) { [logger] _, response, error in
            defer { semaphore.signal() }

            if let error {
                logger.warning("Telemetry export failed: \(error.localizedDescription)")
                return
            }
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            accepted = (200..<300).contains(status)
            if !accepted {
                logger.warning("Telemetry export rejected with HTTP \(status)")
            }
        }
        task.resume()

        // A little longer than the request timeout, so the wait is a backstop
        // for a task that never calls back rather than the primary deadline.
        if semaphore.wait(timeout: .now() + timeout + 5) == .timedOut {
            task.cancel()
            logger.warning("Telemetry export timed out")
            return false
        }
        return accepted
    }
}

// MARK: - Encoding

/// Encodes OpenTelemetry values into the OTLP/JSON shape.
internal enum OTLPJSON {

    // MARK: Payloads

    static func tracesPayload(_ spans: [SpanData]) -> [String: Any] {
        var resourceSpans: [[String: Any]] = []

        for (resource, spansForResource) in Dictionary(grouping: spans, by: { $0.resource }) {
            var scopeSpans: [[String: Any]] = []
            let byScope = Dictionary(grouping: spansForResource, by: { $0.instrumentationScope })

            for (scope, spansForScope) in byScope {
                scopeSpans.append([
                    "scope": scopeJSON(scope),
                    "spans": spansForScope.map(spanJSON)
                ])
            }

            resourceSpans.append([
                "resource": ["attributes": attributesJSON(resource.attributes)],
                "scopeSpans": scopeSpans
            ])
        }

        return ["resourceSpans": resourceSpans]
    }

    static func logsPayload(_ records: [ReadableLogRecord]) -> [String: Any] {
        var resourceLogs: [[String: Any]] = []

        for (resource, recordsForResource) in Dictionary(grouping: records, by: { $0.resource }) {
            var scopeLogs: [[String: Any]] = []
            let byScope = Dictionary(grouping: recordsForResource, by: { $0.instrumentationScopeInfo })

            for (scope, recordsForScope) in byScope {
                scopeLogs.append([
                    "scope": scopeJSON(scope),
                    "logRecords": recordsForScope.map(logRecordJSON)
                ])
            }

            resourceLogs.append([
                "resource": ["attributes": attributesJSON(resource.attributes)],
                "scopeLogs": scopeLogs
            ])
        }

        return ["resourceLogs": resourceLogs]
    }

    // MARK: Records

    private static func spanJSON(_ span: SpanData) -> [String: Any] {
        var json: [String: Any] = [
            "traceId": span.traceId.hexString,
            "spanId": span.spanId.hexString,
            "name": span.name,
            "kind": spanKindJSON(span.kind),
            "startTimeUnixNano": unixNano(span.startTime),
            "endTimeUnixNano": unixNano(span.endTime),
            "status": statusJSON(span.status)
        ]

        // Absent for a root span, which is how the collector tells them apart.
        if let parentSpanId = span.parentSpanId {
            json["parentSpanId"] = parentSpanId.hexString
        }
        if !span.attributes.isEmpty {
            json["attributes"] = attributesJSON(span.attributes)
        }
        return json
    }

    private static func logRecordJSON(_ record: ReadableLogRecord) -> [String: Any] {
        var json: [String: Any] = [
            "timeUnixNano": unixNano(record.timestamp),
            "observedTimeUnixNano": unixNano(record.observedTimestamp ?? record.timestamp)
        ]

        if let severity = record.severity {
            json["severityNumber"] = severity.rawValue
            json["severityText"] = severity.description
        }
        if let body = record.body {
            json["body"] = anyValueJSON(body)
        }
        if !record.attributes.isEmpty {
            json["attributes"] = attributesJSON(record.attributes)
        }
        // Present when the record was emitted inside an active span, which is
        // what lets Grafana jump from a log line to its trace.
        if let spanContext = record.spanContext {
            json["traceId"] = spanContext.traceId.hexString
            json["spanId"] = spanContext.spanId.hexString
        }
        return json
    }

    // MARK: Values

    private static func scopeJSON(_ scope: InstrumentationScopeInfo) -> [String: Any] {
        var json: [String: Any] = ["name": scope.name]
        if let version = scope.version {
            json["version"] = version
        }
        return json
    }

    private static func attributesJSON(_ attributes: [String: AttributeValue]) -> [[String: Any]] {
        attributes.map { ["key": $0.key, "value": anyValueJSON($0.value)] }
    }

    private static func anyValueJSON(_ value: AttributeValue) -> [String: Any] {
        switch value {
        case .string(let string):
            return ["stringValue": string]
        case .bool(let bool):
            return ["boolValue": bool]
        case .int(let int):
            // Protobuf JSON encodes 64 bit integers as strings.
            return ["intValue": String(int)]
        case .double(let double):
            return ["doubleValue": double]
        default:
            // Arrays and key-value lists are not emitted by this SDK. Rendering
            // them as text keeps the payload valid if one ever appears.
            return ["stringValue": value.description]
        }
    }

    private static func spanKindJSON(_ kind: SpanKind) -> Int {
        switch kind {
        case .internal: return 1
        case .server: return 2
        case .client: return 3
        case .producer: return 4
        case .consumer: return 5
        default: return 0
        }
    }

    private static func statusJSON(_ status: Status) -> [String: Any] {
        switch status {
        case .unset:
            return ["code": 0]
        case .ok:
            return ["code": 1]
        case .error(let description):
            return ["code": 2, "message": description]
        }
    }

    /// Nanoseconds since the Unix epoch, as a decimal string.
    ///
    /// Split into whole seconds and fraction first. Multiplying the interval
    /// directly would exceed the range a `Double` represents exactly and lose
    /// the low digits.
    private static func unixNano(_ date: Date) -> String {
        let interval = date.timeIntervalSince1970
        guard interval > 0 else { return "0" }

        let seconds = interval.rounded(.down)
        let fraction = interval - seconds
        let nanos = UInt64(seconds) * 1_000_000_000 + UInt64(fraction * 1_000_000_000)
        return String(nanos)
    }
}

// MARK: - Span Exporter

internal final class OTLPJSONSpanExporter: SpanExporter, @unchecked Sendable {

    private let endpoint: URL
    private let uploader: OTLPJSONUploader

    init(endpoint: URL, uploader: OTLPJSONUploader) {
        self.endpoint = endpoint
        self.uploader = uploader
    }

    private func performExport(_ spans: [SpanData]) -> SpanExporterResultCode {
        guard !spans.isEmpty else { return .success }
        return uploader.send(OTLPJSON.tracesPayload(spans), to: endpoint) ? .success : .failure
    }

    // Synchronous requirements: these are the ones `BatchSpanProcessor` calls.

    func export(spans: [SpanData], explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        performExport(spans)
    }

    func flush(explicitTimeout: TimeInterval?) -> SpanExporterResultCode {
        // Nothing is buffered here; the processor owns the queue.
        .success
    }

    func shutdown(explicitTimeout: TimeInterval?) {}

    // Async requirements. The protocol's defaults trip an assertion, so they are
    // implemented even though the batch processor uses the synchronous path.

    func export(spans: [SpanData], explicitTimeout: TimeInterval?) async -> SpanExporterResultCode {
        performExport(spans)
    }

    func flush(explicitTimeout: TimeInterval?) async -> SpanExporterResultCode {
        .success
    }

    func shutdown(explicitTimeout: TimeInterval?) async {}
}

// MARK: - Log Exporter

internal final class OTLPJSONLogExporter: LogRecordExporter, @unchecked Sendable {

    private let endpoint: URL
    private let uploader: OTLPJSONUploader

    init(endpoint: URL, uploader: OTLPJSONUploader) {
        self.endpoint = endpoint
        self.uploader = uploader
    }

    private func performExport(_ records: [ReadableLogRecord]) -> ExportResult {
        guard !records.isEmpty else { return .success }
        return uploader.send(OTLPJSON.logsPayload(records), to: endpoint) ? .success : .failure
    }

    func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) -> ExportResult {
        performExport(logRecords)
    }

    func forceFlush(explicitTimeout: TimeInterval?) -> ExportResult {
        .success
    }

    func shutdown(explicitTimeout: TimeInterval?) {}

    func export(logRecords: [ReadableLogRecord], explicitTimeout: TimeInterval?) async -> ExportResult {
        performExport(logRecords)
    }

    func forceFlush(explicitTimeout: TimeInterval?) async -> ExportResult {
        .success
    }

    func shutdown(explicitTimeout: TimeInterval?) async {}
}
