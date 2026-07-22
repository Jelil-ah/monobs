import Foundation

/// Opaque JSON value. `metrics` entries are stored as raw facts and never
/// interpreted: no key is expected and no value is compared to anything.
public enum JSONValue: Equatable, Sendable {
    case null
    case bool(Bool)
    case number(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    init(fromJSONObject any: Any) {
        switch any {
        case is NSNull:
            self = .null
        case let number as NSNumber:
            // CFBoolean bridges to NSNumber; distinguish it from numeric values.
            self = CFGetTypeID(number) == CFBooleanGetTypeID()
                ? .bool(number.boolValue)
                : .number(number.doubleValue)
        case let string as String:
            self = .string(string)
        case let array as [Any]:
            self = .array(array.map(JSONValue.init(fromJSONObject:)))
        case let object as [String: Any]:
            self = .object(object.mapValues(JSONValue.init(fromJSONObject:)))
        default:
            // JSONSerialization only produces the cases above.
            self = .null
        }
    }
}

/// Facts extracted from one valid v1 report — and nothing more.
public struct ReportFacts: Equatable, Sendable {
    /// Raw metric facts, opaque (see `JSONValue`).
    public let metrics: [String: JSONValue]
    /// Server-side `ts`, kept **informative only** (AD-10): no code path uses
    /// it for freshness — freshness is anchored on the client's reception
    /// instant of the last valid report (`HostSnapshot.lastValidReceivedAt`).
    public let serverTimestamp: String

    public init(metrics: [String: JSONValue], serverTimestamp: String) {
        self.metrics = metrics
        self.serverTimestamp = serverTimestamp
    }
}

public enum ReportInvalidReason: Equatable, Sendable {
    case emptyDocument
    /// The SSH process exited successfully, but stdout exceeded the poller's
    /// provisional bounded-capture limit before validation (Q4.2).
    case documentTooLarge
    case notJSON
    case notAnObject
    case versionMissing
    case versionNotAnInteger
    case versionUnknown(Int)
    case timestampMissing
    case timestampNotAString
    case metricsMissing
    case metricsNotAnObject
}

public enum ReportVerdict: Equatable, Sendable {
    case valid(ReportFacts)
    case invalid(ReportInvalidReason)
}

/// AD-10 client-side validator. A report is usable iff stdout is exactly one
/// parseable JSON object whose envelope matches the known major version
/// (v1: `v` strict JSON integer == 1, `ts` string, `metrics` object —
/// docs/report-contract.md). Everything else — unknown version, quoted `v`,
/// malformed/truncated/empty document, noise around it — is invalid: no fresh
/// data, no SSH-failure signal, no crash.
public enum ReportValidator {
    private static let knownMajorVersion = 1

    public static func validate(_ stdout: Data) -> ReportVerdict {
        guard !stdout.isEmpty,
              !(String(data: stdout, encoding: .utf8)?
                  .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? false) else {
            return .invalid(.emptyDocument)
        }
        // JSONSerialization enforces "exactly one document": concatenated
        // documents or surrounding noise fail the parse (whitespace tolerated).
        guard let parsed = try? JSONSerialization.jsonObject(with: stdout) else {
            return .invalid(.notJSON)
        }
        guard let object = parsed as? [String: Any] else {
            return .invalid(.notAnObject)
        }
        guard let versionAny = object["v"] else {
            return .invalid(.versionMissing)
        }
        // Strict JSON integer: rejects "1" (string), true (CFBoolean) and 1.0
        // (parsed as a floating NSNumber).
        guard let versionNumber = versionAny as? NSNumber,
              CFGetTypeID(versionNumber) != CFBooleanGetTypeID(),
              !CFNumberIsFloatType(versionNumber) else {
            return .invalid(.versionNotAnInteger)
        }
        let version = versionNumber.intValue
        guard version == knownMajorVersion else {
            return .invalid(.versionUnknown(version))
        }
        guard let timestampAny = object["ts"] else {
            return .invalid(.timestampMissing)
        }
        guard let timestamp = timestampAny as? String else {
            return .invalid(.timestampNotAString)
        }
        guard let metricsAny = object["metrics"] else {
            return .invalid(.metricsMissing)
        }
        guard let metrics = metricsAny as? [String: Any] else {
            return .invalid(.metricsNotAnObject)
        }
        return .valid(ReportFacts(
            metrics: metrics.mapValues(JSONValue.init(fromJSONObject:)),
            serverTimestamp: timestamp
        ))
    }
}
