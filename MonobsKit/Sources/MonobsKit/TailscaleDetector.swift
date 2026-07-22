#if canImport(Darwin)
import Darwin
#endif
import Foundation

/// Story 2.1: the dedicated Tailscale-local detection module. It produces the
/// single entry fact `tailscaleLocalUp` (a `Bool`) and nothing else. Per AD-14
/// this Bool is the ONE stable contract — no other part of the code infers
/// Tailscale state. The reducer is NOT wired to it here; that is Story 2.2.

/// Pure classifier for the RFC 6598 shared-address CGNAT block that Tailscale
/// draws tailnet node addresses from — the 100.64/10 prefix. The single source
/// of truth for "this address looks like a tailnet address".
///
/// PRIVACY (AD-15): the block is expressed NUMERICALLY. No dotted CGNAT literal
/// is committed — that block is outside `scripts/t-priv`'s RFC 5737 allowlist,
/// so a dotted CGNAT address string (or its dotted netmask) would fail T-PRIV.
/// Constants are hex; comments use the single-dot CIDR shorthand only.
public enum TailscaleCGNAT {
    /// Network address of the 100.64/10 block (its lower-bound host address).
    static let networkBase: UInt32 = 0x6440_0000
    /// The /10 prefix mask (10 leading one-bits; low 22 bits clear).
    static let prefixMask: UInt32 = 0xFFC0_0000

    /// Is `address` inside the 100.64/10 CGNAT block? Boundaries: the block
    /// spans `networkBase` through `networkBase | ~prefixMask` inclusive; one
    /// bit outside either end is rejected. A wrong mask fails the boundary rows
    /// in `TailscaleDetectorTests`.
    public static func contains(_ address: UInt32) -> Bool {
        (address & prefixMask) == networkBase
    }
}

/// A read of the local interface IPv4 addresses (host byte order), or `nil` when
/// the interface list could not be read at all. `nil` is the fail-closed signal
/// (see `TailscaleDetector.tailscaleLocalUp`); an empty array is a successful
/// read that simply found no address.
public typealias InterfaceAddressProbe = @Sendable () -> [UInt32]?

/// Produces the `tailscaleLocalUp` entry fact. The system probe is INJECTED
/// (default = real `getifaddrs`), same seam pattern as `HostPollingLoop`'s
/// `pollHost:` / `now:` — tests inject a fake probe so AC3 is exercised without
/// a real Tailscale.
public struct TailscaleDetector: Sendable {
    private let probe: InterfaceAddressProbe

    public init(probe: @escaping InterfaceAddressProbe = TailscaleDetector.systemProbe) {
        self.probe = probe
    }

    /// The ONE stable contract of this module (AD-14): a single `Bool` telling
    /// whether the local Tailscale transport looks available. Every other part
    /// of the app must read Tailscale state through THIS value and never infer
    /// it independently.
    ///
    /// NOT consumed by anything yet — Story 2.1 only produces this input.
    /// Wiring it into the reducer for the FR10.1 override (`tailscaleLocalUp ==
    /// false` ⇒ all hosts forced STALE/grey, including reds) is Story 2.2;
    /// `StateReducer.reduce` is deliberately left unchanged here. Do NOT branch
    /// the reducer or a surface on this Bool in 2.1 — that would merge 2.1/2.2.
    ///
    /// Re-probed on every read so the value TRACKS reality: a state change is
    /// observable at the next read, never frozen at the first probe (AC3).
    public var tailscaleLocalUp: Bool {
        // Fail-closed (leçon 1.4 #1 transposée): on any doubt — the probe could
        // not read the interface list, or read no in-range address — report
        // `false`. Rationale: in 2.2, `false` forces every host STALE/grey with
        // zero red (U-3, an honest "cannot guarantee reachability"), whereas a
        // wrong `true` would let an SSH failure surface as a false red "server
        // dead" when the real fault is the local transport. Tension left OPEN
        // (not resolved here — Q4.3): `false`-on-doubt can equally MASK a real
        // incident by suppressing legitimate reds; the exact cursor belongs to
        // the mechanism (Q4.3) and the 2.2 wiring, not to 2.1.
        guard let addresses = probe() else { return false }
        return addresses.contains(where: TailscaleCGNAT.contains)
    }
}

extension TailscaleDetector {
    /// PROVISIONAL detection mechanism (Q4.3, DEFERRED — substitutable). A
    /// read-only enumeration of local interfaces via `getifaddrs`, collecting
    /// the IPv4 address of every up, running, non-loopback interface. A CGNAT
    /// (100.64/10) address on any of them is taken as "Tailscale local looks
    /// up". This is a PROXY, not proof:
    ///   - a stale `utun` interface can outlive a disconnected/unauthenticated
    ///     daemon (address present ≠ healthy tailscaled);
    ///   - 100.64/10 is RFC 6598 shared space — another CGNAT could, in theory,
    ///     expose such an address.
    /// It is kept ONLY because it is read-only, zero-dependency, zero-network
    /// and simple to swap. The stable contract is the `tailscaleLocalUp` Bool;
    /// this mechanism is disposable — future substitutes (Tailscale LocalAPI,
    /// `tailscale status --json`, a pinned utun check; none promised) plug in
    /// behind the same Bool without touching the reducer or any surface.
    ///
    /// Strictly read-only (T-RO / NFR1): it reads the local kernel interface
    /// list and emits NO network byte — no subprocess, no LocalAPI call, no
    /// ping. It logs NO address or interface name (a real tailnet address is an
    /// infra identifier — AD-15). On any failure it returns `nil` (fail-closed).
    public static let systemProbe: InterfaceAddressProbe = {
        #if canImport(Darwin)
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return nil }  // fail-closed
        defer { freeifaddrs(head) }

        var addresses: [UInt32] = []
        var cursor = head
        while let ifa = cursor {
            cursor = ifa.pointee.ifa_next
            guard let sa = ifa.pointee.ifa_addr,
                  sa.pointee.sa_family == UInt8(AF_INET) else { continue }
            let flags = ifa.pointee.ifa_flags
            guard flags & UInt32(IFF_UP) != 0,
                  flags & UInt32(IFF_RUNNING) != 0,
                  flags & UInt32(IFF_LOOPBACK) == 0 else { continue }
            let hostOrder = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                UInt32(bigEndian: $0.pointee.sin_addr.s_addr)
            }
            addresses.append(hostOrder)
        }
        return addresses
        #else
        // Non-Darwin: this getifaddrs mechanism is unavailable — fail-closed.
        // The module still compiles and its pure predicate + injected-probe
        // tests run everywhere Swift does.
        return nil
        #endif
    }
}

/// Holds the latest global `tailscaleLocalUp` fact BESIDE the per-host
/// snapshots. It is NOT a `HostSnapshot` field and NOT an input to
/// `StateReducer.reduce` (AD-14: one global Bool for the whole machine). The
/// runtime refreshes it once per poll cycle; Story 2.2 will READ `current`
/// to apply the FR10.1 override. Starts `false` (fail-closed) until the first
/// probe.
public final class TailscaleFactStore: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool

    public init(initial: Bool = false) {
        self.value = initial
    }

    public var current: Bool {
        lock.lock(); defer { lock.unlock() }
        return value
    }

    public func update(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }
}
