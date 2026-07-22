# Host configuration (out-of-repo)

Monobs reads the list of hosts to observe from a configuration file that lives
**outside the repo tree**, on the operator's machine only. The repo never
contains real host data — only this format description with fictional examples
(RFC 2606 hostnames, RFC 5737 documentation IPs).

> Status: the scaffold (story 1.1) does not read this file yet. Nothing in the
> current code consumes it; this document only fixes the expected format and
> location for upcoming stories.

## Location

```
~/.config/monobs/hosts.toml
```

The directory and file are created by the operator, never by the repo. Do not
copy real host data into the repo tree, even temporarily — `.gitignore` blocks
`hosts.toml` as defense in depth, and the T-PRIV lint will flag identifiers.

## Format

TOML, one `[[hosts]]` entry per observed VPS. All values below are fictional:

```toml
# ~/.config/monobs/hosts.toml — fictional example
[[hosts]]
name = "web frontend"            # display label in the menu bar UI
host = "vps-web.example"         # SSH target: tailnet MagicDNS name or IP
user = "deploy"                  # SSH user (key-based auth only)
port = 22                        # optional, default 22

[[hosts]]
name = "database"
host = "vps-db.example"
user = "deploy"

[[hosts]]
name = "lab"
host = "192.0.2.10"              # RFC 5737 documentation address
user = "ops"
```

- `host` may be a Tailscale MagicDNS name or a tailnet IP; in real use these
  are exactly the identifiers that must never appear in this repo.
- Authentication is key-based SSH only; no secrets ever go in this file's
  documented examples, and no passwords are supported.

## Optional T-PRIV denylist (also out-of-repo)

You can additionally list your real identifiers (hostnames, tailnet names) as
literal strings so the lint catches them even where generic patterns might not:

```
~/.config/monobs/t-priv-denylist      # or $T_PRIV_DENYLIST
```

One literal string per line, `#` for comments. Fictional example:

```
# ~/.config/monobs/t-priv-denylist
vps-web.example
vps-db.example
```

This file must never be committed — a committed denylist would itself leak the
identifiers it protects. `.gitignore` blocks `t-priv-denylist*` as defense in
depth.
