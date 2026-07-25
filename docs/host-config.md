# Host configuration (out-of-repo)

Monobs reads the list of hosts to observe from a configuration file that lives
**outside the repo tree**, on the operator's machine only. The repo never
contains real host data — only this format description with fictional examples
(RFC 2606 hostnames, RFC 5737 documentation IPs).

> Status: consumed since story 1.3 — the app's poller reads this file at
> launch and polls every listed host over SSH. The parser accepts exactly the
> subset documented here (`[[hosts]]` entries, quoted-string and integer
> values, `#` comments), nothing more. An absent or invalid file means zero
> hosts and a local diagnostic, never a crash.
>
> Since v1 (CAP-10) this file can also be **written by the app**, from
> *Réglages* in the menu bar popover. Hand-editing it stays supported and is
> still the reference format — see [Editing from the app](#editing-from-the-app)
> for what an in-app save preserves and what it does not.

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
identity = "~/.ssh/monobs_report_ed25519"   # optional, see below

[[hosts]]
name = "lab"
host = "192.0.2.10"              # RFC 5737 documentation address
user = "ops"
```

- `host` may be a Tailscale MagicDNS name or a tailnet IP; in real use these
  are exactly the identifiers that must never appear in this repo. It also
  serves as the stable per-host identifier inside the app (must be unique;
  duplicate entries are ignored with a diagnostic).
- `identity` (optional, **provisional**): path to the dedicated read-only key
  (see docs/deploy-forced-command.md). `IdentitiesOnly=yes` is always applied;
  when this field is set, ssh also receives `-i`. When absent, ssh resolves its
  configured/default identity files without offering unrelated agent keys.
- `name` is optional and defaults to `host`.
- Authentication is key-based SSH only; no secrets ever go in this file's
  documented examples, and no passwords are supported.

## Editing from the app

Since v1, Monobs can create and edit this file itself: menu bar icon →
**Réglages** (or *Ajouter un hôte…* on the very first launch, when no
configuration exists yet). Adding, changing or removing a host and saving
writes this same file, and monitoring is reconfigured immediately — the app
does not need to be relaunched.

The file remains the source of truth on disk. Hand-editing it is still fully
supported: the app re-reads it every time the settings window is opened.

### What an in-app save preserves — and what it does not

An in-app save **regenerates the whole file** from the documented subset above.
It is not a surgical edit of the lines you wrote. Concretely:

- **Preserved:** every host and every documented value — `name`, `host`,
  `user`, `port`, `identity`. What you had is what you get back, which is what
  makes an existing hand-written configuration keep working unchanged: it is
  read as before and shows up pre-filled in the editor.
- **Not preserved: your `#` comments.** They are not part of the data model, so
  a save replaces them with the app's own two-line header. Reading a commented
  file is unaffected — comments only disappear the moment you save from the app.
- **Not preserved: layout.** Key order, blank lines and spacing are normalized,
  and `port` is always written explicitly even when it equals the default `22`.

If your file carries comments you care about, either keep editing it by hand or
copy them elsewhere before saving from the app.

### Fail-closed: a file the app cannot read is never overwritten

If the configuration currently on disk produces **any** parser diagnostic — a
construct outside the documented subset, an unknown key, a dropped entry, or
content that is not readable UTF-8 — the settings window refuses to edit it. It
shows the diagnostics and the file's location, and offers nothing but *Afficher
dans le Finder* and *Relire le fichier*.

There is deliberately no "overwrite it anyway" button in v1: a file Monobs
cannot reproduce is hand-written work, and regenerating it from an empty editor
would destroy it silently. Repair the file (or move it aside), then use *Relire
le fichier*. The refusal happens before a single byte of the destination is
touched, and a save that fails for any other reason leaves the previous
configuration exactly as it was — writes are atomic.

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
