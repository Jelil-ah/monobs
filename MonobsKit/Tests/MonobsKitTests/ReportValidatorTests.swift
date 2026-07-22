import XCTest
@testable import MonobsKit

// Story 1.3, Task 3 (AC2) — T-CONTRACT core: every fixture gets one exact
// expected verdict (fail-closed — a wrong or merely "some invalid" verdict
// fails the test, never a vacuous pass). Fixtures are files with fictional
// values only (AD-15).
final class ReportValidatorTests: XCTestCase {

    private func fixture(_ name: String) throws -> Data {
        let url = try XCTUnwrap(
            Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"),
            "missing fixture \(name).json"
        )
        return try Data(contentsOf: url)
    }

    // MARK: valid

    func testValidV1FixtureYieldsExactFacts() throws {
        // Mirror of the docs/report-contract.md example. Exact facts asserted:
        // proves extraction really happened (non-vacuous for every later
        // "facts unchanged" assertion).
        let verdict = ReportValidator.validate(try fixture("valid-v1"))
        XCTAssertEqual(verdict, .valid(ReportFacts(
            metrics: [
                "loadavg_1m": .number(0.42),
                "uptime_s": .number(123456),
                "mem_available_kib": .number(1048576),
            ],
            serverTimestamp: "2026-01-01T12:00:00Z"
        )))
    }

    func testValidDocumentToleratesSurroundingWhitespaceOnly() {
        // monobs-report ends the document with a newline; whitespace is not
        // "noise around the document".
        let data = Data("  \n{\"v\":1,\"ts\":\"2026-01-01T12:00:00Z\",\"metrics\":{}}\n\n".utf8)
        guard case .valid(let facts) = ReportValidator.validate(data) else {
            return XCTFail("whitespace-padded single document must stay valid")
        }
        XCTAssertEqual(facts.metrics, [:])
    }

    // MARK: invalid fixtures — exact verdict each

    func testUnknownMajorVersionFixture() throws {
        XCTAssertEqual(ReportValidator.validate(try fixture("v-unknown")), .invalid(.versionUnknown(2)))
    }

    func testQuotedVersionFixture() throws {
        XCTAssertEqual(ReportValidator.validate(try fixture("v-quoted")), .invalid(.versionNotAnInteger))
    }

    func testFloatVersionFixture() throws {
        XCTAssertEqual(ReportValidator.validate(try fixture("v-float")), .invalid(.versionNotAnInteger))
    }

    func testMalformedJSONFixture() throws {
        XCTAssertEqual(ReportValidator.validate(try fixture("malformed")), .invalid(.notJSON))
    }

    func testEmptyDocumentFixture() throws {
        XCTAssertEqual(ReportValidator.validate(try fixture("empty")), .invalid(.emptyDocument))
    }

    func testTruncatedDocumentFixture() throws {
        XCTAssertEqual(ReportValidator.validate(try fixture("truncated")), .invalid(.notJSON))
    }

    func testNoiseAroundDocumentFixture() throws {
        // "exactly one JSON document on stdout, and nothing else" — noise
        // before/after the document breaks the contract even if a valid
        // document is embedded in the middle.
        XCTAssertEqual(ReportValidator.validate(try fixture("noise-around")), .invalid(.notJSON))
    }

    func testMetricsMissingFixture() throws {
        XCTAssertEqual(ReportValidator.validate(try fixture("metrics-missing")), .invalid(.metricsMissing))
    }

    func testMetricsNotAnObjectFixture() throws {
        XCTAssertEqual(ReportValidator.validate(try fixture("metrics-not-object")), .invalid(.metricsNotAnObject))
    }

    func testTimestampMissingFixture() throws {
        // `ts` is required by the v1 envelope (docs/report-contract.md) even
        // though its value is informative only — absence is a contract breach.
        XCTAssertEqual(ReportValidator.validate(try fixture("ts-missing")), .invalid(.timestampMissing))
    }

    // MARK: invalid — inline edge cases

    func testWhitespaceOnlyDocumentIsEmpty() {
        XCTAssertEqual(ReportValidator.validate(Data(" \n\t\n".utf8)), .invalid(.emptyDocument))
    }

    func testTopLevelArrayIsNotAnObject() {
        XCTAssertEqual(ReportValidator.validate(Data("[1,2]".utf8)), .invalid(.notAnObject))
    }

    func testVersionMissing() {
        XCTAssertEqual(
            ReportValidator.validate(Data("{\"ts\":\"2026-01-01T12:00:00Z\",\"metrics\":{}}".utf8)),
            .invalid(.versionMissing)
        )
    }

    func testBooleanVersionIsNotAnInteger() {
        XCTAssertEqual(
            ReportValidator.validate(Data("{\"v\":true,\"ts\":\"2026-01-01T12:00:00Z\",\"metrics\":{}}".utf8)),
            .invalid(.versionNotAnInteger)
        )
    }

    func testTimestampNotAString() {
        XCTAssertEqual(
            ReportValidator.validate(Data("{\"v\":1,\"ts\":12,\"metrics\":{}}".utf8)),
            .invalid(.timestampNotAString)
        )
    }

    func testTwoConcatenatedDocumentsAreNotASingleDocument() {
        let one = "{\"v\":1,\"ts\":\"2026-01-01T12:00:00Z\",\"metrics\":{}}"
        XCTAssertEqual(ReportValidator.validate(Data((one + one).utf8)), .invalid(.notJSON))
    }

    func testMetricsValuesAreKeptOpaque() {
        // Q1/Q2 gated: arbitrary keys and shapes pass through untouched — the
        // validator must not expect any particular metric key.
        let data = Data("{\"v\":1,\"ts\":\"2026-01-01T12:00:00Z\",\"metrics\":{\"anything\":[1,\"x\",null,{\"nested\":true}]}}".utf8)
        guard case .valid(let facts) = ReportValidator.validate(data) else {
            return XCTFail("arbitrary metric shapes must be valid")
        }
        XCTAssertEqual(facts.metrics, [
            "anything": .array([.number(1), .string("x"), .null, .object(["nested": .bool(true)])]),
        ])
    }
}
