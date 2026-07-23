import XCTest
@testable import MonobsKit

// Story 3.2 (AC5/AC6): the shared app↔widget container contract — versioned
// (`v` major, AD-10 mirror), round-trips as identity, and tolerates an unknown
// major version with a readable degradation (NEVER a crash). Non-vacuous: a
// KNOWN version decodes normally, proving the degradation branch is triggered by
// the version and not systematically.
final class SharedSnapshotContractTests: XCTestCase {

    private let t0 = Date(timeIntervalSince1970: 1_750_000_000)

    // AC6 round-trip: encode → decode = identity, derived states included, `v`
    // present. `freshnessTimestamp` is an ABSOLUTE instant and survives exactly.
    func testRoundTripIsIdentityAcrossAllStates() throws {
        let snapshot = SharedSnapshot(hosts: [
            SharedHostEntry(hostID: "vps-a.example", state: .rougeInjoignable, freshnessTimestamp: t0),
            SharedHostEntry(hostID: "vps-b.example", state: .rougeSeuil, freshnessTimestamp: t0.addingTimeInterval(-42)),
            SharedHostEntry(hostID: "vps-c.example", state: .stale, freshnessTimestamp: t0.addingTimeInterval(-600)),
            SharedHostEntry(hostID: "vps-d.example", state: .vert, freshnessTimestamp: t0.addingTimeInterval(-5)),
            SharedHostEntry(hostID: "vps-e.example", state: .stale, freshnessTimestamp: nil),
        ])
        let data = try SharedSnapshotCodec.encode(snapshot)
        guard case .ok(let decoded) = SharedSnapshotCodec.decode(data) else {
            return XCTFail("known-version payload must decode to .ok")
        }
        XCTAssertEqual(decoded, snapshot)
        XCTAssertEqual(decoded.v, SharedSnapshotCodec.currentVersion)
        // The absolute instant survived exactly (not a frozen duration).
        XCTAssertEqual(decoded.hosts[0].freshnessTimestamp, t0)
        // A never-received host keeps a nil timestamp (rendered "jamais").
        XCTAssertNil(decoded.hosts[4].freshnessTimestamp)
    }

    // AC5/AC6: an UNKNOWN major version ⇒ .unsupportedVersion, never a crash and
    // never a payload decode. The payload here is deliberately shaped so a naive
    // full decode would ALSO fail — proving stage 1 (envelope) short-circuits.
    func testUnknownMajorVersionDegradesWithoutCrash() throws {
        let futurePayload = """
        { "v": 999, "hosts": "an incompatible shape from a future major version" }
        """.data(using: .utf8)!
        XCTAssertEqual(SharedSnapshotCodec.decode(futurePayload), .unsupportedVersion(999))
    }

    // Non-vacuous control: the SAME shape at the KNOWN version decodes cleanly.
    // Proves the degradation is version-driven, not systematic.
    func testKnownVersionDecodesNormallyNonVacuous() throws {
        let known = SharedSnapshot(hosts: [
            SharedHostEntry(hostID: "vps-a.example", state: .vert, freshnessTimestamp: t0),
        ])
        let data = try SharedSnapshotCodec.encode(known)
        guard case .ok = SharedSnapshotCodec.decode(data) else {
            return XCTFail("current version must decode to .ok (non-vacuous control)")
        }
    }

    // Corrupt / non-JSON bytes ⇒ .unreadable, never a crash.
    func testGarbageBytesAreUnreadable() {
        XCTAssertEqual(SharedSnapshotCodec.decode(Data([0x00, 0x01, 0x02])), .unreadable)
        XCTAssertEqual(SharedSnapshotCodec.decode(Data()), .unreadable)
    }

    // A known-version payload carrying an unknown STATE identifier is corruption
    // ⇒ .unreadable (fail-closed), not a guessed state.
    func testUnknownStateIdentifierIsUnreadable() {
        let payload = """
        { "v": 1, "hosts": [ { "hostID": "vps-a.example", "state": "mauve" } ] }
        """.data(using: .utf8)!
        XCTAssertEqual(SharedSnapshotCodec.decode(payload), .unreadable)
    }

    // The file location resolves under Application Support/Monobs — via
    // FileManager, never a literal path (AD-15).
    func testStateFileLocationResolvesUnderApplicationSupport() throws {
        let url = try SharedSnapshotLocation.stateFileURL()
        XCTAssertEqual(url.lastPathComponent, "state.json")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "Monobs")
        XCTAssertTrue(url.path.contains("Application Support"))
    }
}
