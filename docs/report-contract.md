# Report contract — v1

`monobs-report` (in `server/`) emits **exactly one JSON document on stdout,
and nothing else**. This document is the only thing the server side ever
says; everything the client derives (states, thresholds, colors, freshness)
is computed on the client from these raw facts (AD-8).

Machine check: `./server/monobs-report-selftest` (also run in CI on pushes
to `main` and on pull requests).

## Envelope (ratified — AD-10)

| Field     | Type              | Meaning |
| --------- | ----------------- | ------- |
| `v`       | integer, required | Major contract version. A version the client does not know makes the whole report unusable on the client side (AD-10). Initial value: **1**. |
| `ts`      | UTC timestamp, required | Server-side emission instant, **informative only**. Freshness/age is anchored on the client's reception of the last valid report, never on `ts` — this keeps the pipeline immune to server clock skew. |
| `metrics` | object, required  | Raw facts, one entry per metric. Never a state, threshold, or color — those are client-side concepts and must not appear anywhere in the output, keys or values (AD-8). |

### `ts` serialization (implementation convention, v1)

The spine ratifies only that `ts` is UTC. v1 serializes it as ISO 8601
`YYYY-MM-DDTHH:MM:SSZ` (e.g. `2026-01-01T12:00:00Z`).

### `metrics` keys — provisional, pending Q1 ratification

The metric set is an **open question (Q1)**. The keys currently emitted are
placeholders that only demonstrate the shape of the object; they are not
ratified and may change without a `v` bump until Q1 is settled:

| Placeholder key     | Fact (read-only source)                  |
| ------------------- | ---------------------------------------- |
| `loadavg_1m`        | 1-minute load average (`/proc/loadavg`)  |
| `uptime_s`          | Uptime in whole seconds (`/proc/uptime`) |
| `mem_available_kib` | `MemAvailable` (`/proc/meminfo`)         |

## Example document (fictional values)

```json
{"v":1,"ts":"2026-01-01T12:00:00Z","metrics":{"loadavg_1m":0.42,"uptime_s":123456,"mem_available_kib":1048576}}
```

## Error behavior (implementation convention, v1 — not part of the ratified AD-10 contract)

The ratified contract only defines what a valid document looks like. How
v1 behaves when it cannot produce one is an implementation convention, on
the same footing as the `ts` format:

- Success: exit `0`, the single document on stdout, stderr empty.
- Any collection failure: **non-zero exit**, one diagnostic line on stderr
  (`monobs-report: <reason>`), and **nothing on stdout** — a partial
  document is never presented as valid. All facts are collected and
  validated before the single final write.

Client side (story 1.3, referenced here, not implemented): any invalid,
partial, or absent document is handled through the staleness path (AD-10)
— the client keeps the last valid report and lets its age grow. No error
payload is ever parsed out of a broken report.

## Read-only, guaranteed at both ends

- **Transport (AD-9):** the dedicated SSH key is bound by sshd to the
  forced command `monobs-report` — no pty, no forwarding, no other command.
  See [deploy-forced-command.md](deploy-forced-command.md).
- **Code (T-RO):** `monobs-report` reads `/proc` and the system clock,
  writes nothing, opens no network connection, runs no side-effecting
  command.
