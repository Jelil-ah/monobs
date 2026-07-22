import Foundation

/// Owns the application process' polling cadence. One cycle visits every
/// configured host sequentially with an ephemeral SSH connection. The cadence
/// and sequencing remain provisional (Q4.2).
public final class HostPollingLoop: @unchecked Sendable {
    public static let defaultCadence: TimeInterval = 60

    private let hosts: [ObservedHost]
    private let snapshotStore: SnapshotStore
    private let cadence: TimeInterval
    private let pollHost: @Sendable (ObservedHost) -> PollOutcome
    private let now: @Sendable () -> Date
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var running = false
    private var generation: UInt64 = 0

    public init(hosts: [ObservedHost],
                snapshotStore: SnapshotStore,
                cadence: TimeInterval = defaultCadence,
                queue: DispatchQueue = DispatchQueue(label: "monobs.host-polling"),
                now: @escaping @Sendable () -> Date = { Date() },
                pollHost: @escaping @Sendable (ObservedHost) -> PollOutcome = {
                    SSHPollRunner.poll(host: $0)
                }) {
        precondition(cadence > 0, "poll cadence must be positive")
        self.hosts = hosts
        self.snapshotStore = snapshotStore
        self.cadence = cadence
        self.queue = queue
        self.now = now
        self.pollHost = pollHost
    }

    /// Starts with an immediate cycle. Zero configured hosts remain cleanly
    /// idle. Repeated starts are ignored.
    @discardableResult
    public func start() -> Bool {
        lock.lock()
        guard !running, !hosts.isEmpty else {
            lock.unlock()
            return false
        }
        running = true
        generation &+= 1
        let activeGeneration = generation
        lock.unlock()
        scheduleCycle(at: .now(), generation: activeGeneration)
        return true
    }

    public func stop() {
        lock.lock()
        running = false
        generation &+= 1
        lock.unlock()
    }

    /// Synchronous cycle seam used by focused tests and future manual refresh.
    public func runOneCycle() {
        for host in hosts {
            let outcome = pollHost(host)
            snapshotStore.record(outcome, forHost: host.host, receivedAt: now())
        }
    }

    /// Provisional Q4.2 overrun policy: cycle starts are anchored to monotonic
    /// cadence deadlines. The next tick is enqueued before work begins; when a
    /// cycle overruns one or more deadlines, missed ticks coalesce into one
    /// immediate cycle and the following deadline remains on the original grid.
    private func scheduleCycle(at deadline: DispatchTime, generation: UInt64) {
        queue.asyncAfter(deadline: deadline) { [weak self] in
            guard let self, self.isRunning(generation: generation) else { return }
            let now = DispatchTime.now().uptimeNanoseconds
            let cadenceNanoseconds = max(1, UInt64(self.cadence * 1_000_000_000))
            let elapsed = now > deadline.uptimeNanoseconds
                ? now - deadline.uptimeNanoseconds
                : 0
            let intervalsToNext = elapsed / cadenceNanoseconds + 1
            let nextUptime = deadline.uptimeNanoseconds
                &+ intervalsToNext &* cadenceNanoseconds
            self.scheduleCycle(at: DispatchTime(uptimeNanoseconds: nextUptime),
                               generation: generation)
            self.runOneCycle()
        }
    }

    private func isRunning(generation expected: UInt64) -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return running && generation == expected
    }
}
