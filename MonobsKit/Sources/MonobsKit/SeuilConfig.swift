import Foundation

/// Named threshold defaults for the client-side `.rougeSeuil` decision (Q2,
/// ratified 2026-07-23). These fractions are the ONLY place the threshold values
/// live — never a literal scattered across the reducer.
///
/// AD-8: the SERVER emits raw facts only; the reducer applies these fractions to
/// those facts, computing every ratio client-side. Q2 deliberately does NOT build
/// an override system — this struct is only the named, injectable seam
/// (`reduce(..., thresholds:)`, same pattern as `stalenessThreshold`) that makes a
/// future override trivial. No caller passes anything but `.defaults` today.
///
/// The ratified intra-`rougeSeuil` severity (disk ≈ RAM outrank load, the noisiest
/// signal) is documented for a FUTURE sub-cause label; it is NOT materialized here
/// — `HostState` stays four bare cases, so the reducer's OR of the three criteria
/// simply yields `.rougeSeuil`.
public struct SeuilConfig: Equatable, Sendable {
    /// Root-`/` disk breach when `1 − disk_avail_kib/disk_total_kib ≥ diskUsedFraction`.
    public let diskUsedFraction: Double
    /// RAM breach when `mem_available_kib/mem_total_kib ≤ 1 − ramUsedFraction`
    /// (equivalently, used ≥ `ramUsedFraction`).
    public let ramUsedFraction: Double
    /// Load breach when `loadavg_1m/nproc ≥ loadPerCPU`.
    public let loadPerCPU: Double

    public init(diskUsedFraction: Double, ramUsedFraction: Double, loadPerCPU: Double) {
        self.diskUsedFraction = diskUsedFraction
        self.ramUsedFraction = ramUsedFraction
        self.loadPerCPU = loadPerCPU
    }

    /// The ratified Q2 defaults (2026-07-23): disk 90 %, RAM 90 %, load 2.0 per CPU.
    public static let defaults = SeuilConfig(diskUsedFraction: 0.90,
                                             ramUsedFraction: 0.90,
                                             loadPerCPU: 2.0)
}
