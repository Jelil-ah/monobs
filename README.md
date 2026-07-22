# Monobs

A read-only macOS menu bar surface showing the state of VPS hosts, reached over SSH through a Tailscale tailnet.

Current status: **early scaffold** — the app shows a static menu bar placeholder. No network code, no widget, no popover yet.

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
