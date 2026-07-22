# Deploying `monobs-report` behind an SSH forced command (AD-9)

The only server-side channel Monobs uses is a **non-interactive SSH exec
over the Tailscale tailnet**, with a dedicated key that sshd constrains to
the forced command `monobs-report` — no pty, no forwarding, no other
command. Read-only is guaranteed at both ends: the key can run nothing
else (this document), and the code has no write path (T-RO, see
[report-contract.md](report-contract.md)).

> This document describes operator steps. Nothing in this repository
> executes them. Every hostname below is an RFC 2606 fictional name, and
> every path is generic. No real infrastructure identifier appears here.

## 1. Generate a dedicated key (operator machine)

The key is used for `monobs-report` **only** — never reuse an existing key,
never reuse this one for anything else. Revoking observation then costs
exactly one `authorized_keys` line.

```sh
ssh-keygen -t ed25519 -f ~/.ssh/monobs_report_ed25519 -C monobs-report
```

## 2. Install the executable (VPS)

Copy `server/monobs-report` from this repository to the VPS, owned by
root, world-executable, not world-writable:

```sh
install -o root -g root -m 0755 monobs-report /usr/local/bin/monobs-report
```

The deployed file name must remain `monobs-report`: it is the forced
command name the `authorized_keys` entry points at.

## 3. Constrain the key in `authorized_keys` (VPS)

In the observed account's `~/.ssh/authorized_keys` on the VPS (example
account: `deploy`), add the public key on **one line**, prefixed with the
forced-command options:

```
command="/usr/local/bin/monobs-report",restrict ssh-ed25519 AAAA...public-key-material... monobs-report
```

`restrict` (OpenSSH 7.2+) disables pty allocation and all forwardings in
one word. If the VPS runs an older sshd without `restrict`, spell it out
explicitly:

```
command="/usr/local/bin/monobs-report",no-pty,no-port-forwarding,no-agent-forwarding,no-X11-forwarding ssh-ed25519 AAAA...public-key-material... monobs-report
```

Semantics: for every connection authenticated by this key, sshd runs
`/usr/local/bin/monobs-report` and nothing else. Whatever command the
client asks for is only exposed as `SSH_ORIGINAL_COMMAND` — and
`monobs-report` never reads it, so a requested command is **ignored**, not
interpreted.

## 4. Verify the constraint (operator machine, over the tailnet)

The following non-tty exec requests must behave identically: the forced
command emits one JSON document and ignores any requested command
(`vps-web.example` is a fictional tailnet name; see
[host-config.md](host-config.md)):

```sh
# Plain exec: emits the report.
ssh -i ~/.ssh/monobs_report_ed25519 deploy@vps-web.example

# Any requested command is ignored — still just the report.
ssh -i ~/.ssh/monobs_report_ed25519 deploy@vps-web.example uname -a
ssh -i ~/.ssh/monobs_report_ed25519 deploy@vps-web.example 'rm -f somefile'

```

If the second and third commands print anything other than the report
document, the forced command is not in effect — stop and fix the
`authorized_keys` line before using the key.

For these non-tty exec requests, the client sees `monobs-report`'s exit
code: `0` with the document on success, or non-zero with a stderr diagnostic
on collection failure (see the error section of the contract doc).

A pty request is intentionally different. From an interactive terminal,
this command is refused:

```sh
ssh -t -i ~/.ssh/monobs_report_ed25519 deploy@vps-web.example
```

The expected result is `PTY allocation request failed`, ssh exit `255`, and
**no report**. This is the correct outcome for a pty request; use the plain
non-tty exec above to obtain the report. Here, `255` is ssh's own exit code,
not `monobs-report`'s.
