# Monobs

A read-only macOS menu bar surface showing the state of VPS hosts, reached over SSH through a Tailscale tailnet.

Current status: **read-only polling core** — the visible menu bar surface remains
a static placeholder while the app polls configured hosts and keeps per-host
facts in memory. No server action, notification, widget, or popover exists.

## Requirements

- macOS 13 or later (runtime)
- Xcode 16 or later (build — the project uses the Xcode 16+ project format)

## Build

```sh
git clone https://github.com/Jelil-ah/monobs.git
cd monobs
xcodebuild -project Monobs.xcodeproj -scheme Monobs -configuration Debug -derivedDataPath build build
open build/Build/Products/Debug/Monobs.app
```

The app is a menu bar agent (no Dock icon): look for the dashed-circle icon in the menu bar.

## Read-only SSH client

At launch, the app reads the out-of-repo host configuration and runs one global
poll cycle every 60 seconds. Each host is queried by a non-interactive exec of
the system `ssh` binary with no remote command argument. Cycle starts stay on a
monotonic 60-second grid; overruns coalesce instead of shifting the next start by
the work duration (provisional Q4.2 policy). The in-process snapshot contains
only the last valid report facts, their client reception time, and the latest
SSH transport-failure boolean.

Read-only is enforced at both ends: the client has no SCP/SFTP/rsync or remote
command path. It ignores OpenSSH config (`-F /dev/null`) and explicitly disables
remote/local commands, proxies, jumps, and forwarding. Captured output is bounded
(1 MiB stdout, 64 KiB stderr); excess is drained and discarded, and an oversized
successful report is invalid rather than fresh. The server key is restricted to
`monobs-report` by the forced command documented in
[docs/deploy-forced-command.md](docs/deploy-forced-command.md).

Core and live local-sshd integration tests:

```sh
swift test --package-path MonobsKit
```

## Server report (`monobs-report`)

`server/monobs-report` is the server-side executable: it emits one versioned JSON document of raw facts on stdout (`{"v":1,"ts":…,"metrics":…}`) and is meant to run on a VPS behind an SSH forced command — POSIX sh plus standard utilities, nothing to install.

Contract self-test (one command, non-zero exit on any contract violation):

```sh
./server/monobs-report-selftest
```

CI runs it on every push and pull request (`.github/workflows/report-contract.yml`). The output contract is documented in [docs/report-contract.md](docs/report-contract.md), and the forced-command deployment in [docs/deploy-forced-command.md](docs/deploy-forced-command.md).

## Privacy lint (T-PRIV)

The repo is linted for real infrastructure identifiers. One command, non-zero exit code on violation:

```sh
./scripts/t-priv
```

Self-test (seeded violation must fail, delivered repo must pass):

```sh
./scripts/t-priv-selftest
```

CI runs both on every push and pull request (`.github/workflows/t-priv.yml`).

## Privacy policy

This repository must never contain real infrastructure identifiers — no real IPs, hostnames, tailnet/MagicDNS names, server paths, usernames, keys, or tokens — anywhere: code, fixtures, docs, screenshots, file names, or commit messages.

Conventions enforced by the lint:

- Example hostnames use RFC 2606 reserved names only (`.example`, `.invalid`, `.test`).
- Example IPv4 addresses use RFC 5737 documentation ranges (`192.0.2.0/24`, `198.51.100.0/24`, `203.0.113.0/24`) or localhost.
- Example IPv6 addresses use the RFC 3849 documentation prefix (`2001:db8::/32`).

The lint has no rule for personal names or account aliases. Pre-push checklist: scrub the `Created by <account>` header Xcode puts in every new file, and re-read diffs for names before pushing.

## Host configuration

The configuration describing real hosts lives **outside the repo tree**, on the operator's machine only. Expected format and location (with fictional examples) are documented in [docs/host-config.md](docs/host-config.md).

## License

[MIT](LICENSE)
