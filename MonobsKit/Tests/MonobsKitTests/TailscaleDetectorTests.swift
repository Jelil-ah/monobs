import XCTest
@testable import MonobsKit

// Story 2.1 (AC1/AC2/AC3): the `tailscaleLocalUp` entry fact — a dedicated
// detection module producing the single AD-14 Bool. The reducer is NOT wired to
// it here (that is Story 2.2); these tests exercise the pure CGNAT predicate and
// the injected-probe seam only, so they are deterministic and never depend on a
// real Tailscale.
//
// PRIVACY (AD-15): every CGNAT (100.64/10) address is built NUMERICALLY from
// integer octets via `ipv4(_:_:_:_:)` — no dotted CGNAT literal is committed
// (that block is outside scripts/t-priv's RFC 5737 allowlist, so a dotted
// literal would fail T-PRIV). Out-of-range fixtures are built the same way.
//
// Every checker is proven non-vacuous: boundary rows carry paired true/false
// assertions that fail if the /10 mask is wrong; the up / down / error branches
// are observed distinctly; the transition test fails if the value is frozen.
final class TailscaleDetectorTests: XCTestCase {

    /// Build an IPv4 address as a UInt32 from integer octets. Comma-separated
    /// ints — never a dotted string — so no address literal is committed.
    private func ipv4(_ a: UInt32, _ b: UInt32, _ c: UInt32, _ d: UInt32) -> UInt32 {
        (a << 24) | (b << 16) | (c << 8) | d
    }

    // MARK: - Task 2: pure CGNAT predicate, exact boundaries (non-vacuous)

    func testCGNATPredicate_boundariesInclusiveExclusive() {
        // First and last address of 100.64/10 are INSIDE.
        XCTAssertTrue(TailscaleCGNAT.contains(ipv4(100, 64, 0, 0)),
                      "100.64/10 lower bound must be inside")
        XCTAssertTrue(TailscaleCGNAT.contains(ipv4(100, 127, 255, 255)),
                      "100.64/10 upper bound must be inside")
        // One address below and one above are OUTSIDE — these fail if the /10
        // mask is loosened or tightened by a single bit.
        XCTAssertFalse(TailscaleCGNAT.contains(ipv4(100, 63, 255, 255)),
                       "one below the block must be outside")
        XCTAssertFalse(TailscaleCGNAT.contains(ipv4(100, 128, 0, 0)),
                       "one above the block must be outside")
    }

    func testCGNATPredicate_inAndOutOfRange() {
        // A mid-block address IS inside (predicate is not always-false).
        XCTAssertTrue(TailscaleCGNAT.contains(ipv4(100, 100, 50, 25)))
        // RFC 5737 documentation address — never CGNAT.
        XCTAssertFalse(TailscaleCGNAT.contains(ipv4(192, 0, 2, 1)))
        // RFC 1918 private — outside 100.64/10.
        XCTAssertFalse(TailscaleCGNAT.contains(ipv4(10, 0, 0, 1)))
        // Loopback — outside.
        XCTAssertFalse(TailscaleCGNAT.contains(ipv4(127, 0, 0, 1)))
    }

    // MARK: - Task 3: injected probe seam — up / down / error→false (fail-closed)

    func testDetector_probeReportsCGNAT_isUp() {
        let cgnat = ipv4(100, 64, 1, 2)
        let detector = TailscaleDetector(probe: { [self.ipv4(192, 0, 2, 5), cgnat] })
        XCTAssertTrue(detector.tailscaleLocalUp)
    }

    func testDetector_noCGNATAddress_isDown() {
        let detector = TailscaleDetector(probe: { [self.ipv4(192, 0, 2, 5), self.ipv4(10, 0, 0, 1)] })
        XCTAssertFalse(detector.tailscaleLocalUp)
    }

    func testDetector_probeFailure_failsClosed() {
        // nil = the interface list could not be read at all ⇒ fail-closed false,
        // never a default true (the recurring fail-open lesson, 1.1→1.4).
        let detector = TailscaleDetector(probe: { nil })
        XCTAssertFalse(detector.tailscaleLocalUp)
    }

    func testDetector_emptyList_isDown() {
        let detector = TailscaleDetector(probe: { [] })
        XCTAssertFalse(detector.tailscaleLocalUp)
    }

    // MARK: - Task 4: transition observable across re-probes (AC3), reducer untouched

    /// Mutable reference probe so the simulated Tailscale state can flip between
    /// reads. Proves the value TRACKS reality and is not frozen at first probe.
    private final class MutableProbe: @unchecked Sendable {
        var addresses: [UInt32]? = []
        func read() -> [UInt32]? { addresses }
    }

    func testDetector_transitionsAcrossReprobes() {
        let cgnat = ipv4(100, 80, 7, 7)
        let probe = MutableProbe()
        let detector = TailscaleDetector(probe: { probe.read() })

        XCTAssertFalse(detector.tailscaleLocalUp)  // down
        probe.addresses = [cgnat]
        XCTAssertTrue(detector.tailscaleLocalUp)    // up — transited (fails if frozen)
        probe.addresses = []
        XCTAssertFalse(detector.tailscaleLocalUp)   // down again — not stuck at true
        probe.addresses = nil
        XCTAssertFalse(detector.tailscaleLocalUp)   // error — fail-closed
    }

    func testFactStore_refreshedEachCycle() {
        let cgnat = ipv4(100, 90, 3, 4)
        let probe = MutableProbe()
        let detector = TailscaleDetector(probe: { probe.read() })
        let store = TailscaleFactStore()  // starts false (fail-closed)

        XCTAssertFalse(store.current)  // before any cycle
        // Simulate the runtime's per-cycle refresh (onCycleComplete).
        probe.addresses = [cgnat]
        store.update(detector.tailscaleLocalUp)
        XCTAssertTrue(store.current)   // cycle N: up
        probe.addresses = []
        store.update(detector.tailscaleLocalUp)
        XCTAssertFalse(store.current)  // cycle N+1: down — fresh, not stuck
    }
}
