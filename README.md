# bash-includes

Shared bash primitives for system provisioning and maintenance scripts.

This library holds **mechanism only** — how to log, how to back up a file safely,
how to add an APT repository correctly, how to record what changed. It contains
no policy: no hardening choices, no package lists, no repository URLs, nothing
that describes how any particular machine is configured. Policy lives in the
scripts that call this library.

That separation is deliberate. It keeps this repository publishable, generic,
and testable, while the decisions about what a machine should look like stay in
their own repositories.

## Layout

```
lib/log.sh            timestamped, per-stream colour-aware logging
lib/privilege.sh      enforce run-as-user / escalate-per-command
lib/cleanup.sh        stack of teardown handlers sharing one EXIT trap
lib/journal.sh        append-only record of persistent system changes
lib/backup.sh         the .orig / .bak backup convention
lib/os.sh             OS, arch, kernel, init and session detection
lib/apt.sh            APT repository and package helpers
bin/provision-report  read and verify the change journal
```

## Conventions

**Run as your normal user.** Scripts are invoked without `sudo` and escalate
per command. `require_unprivileged` enforces this and fails immediately with an
explanation if a script is run as root, instead of silently leaving root-owned
artefacts behind.

**Library files never set shell options.** `set -euo pipefail` belongs to the
entry-point script; a library that sets it changes the behaviour of code that
did not ask for it. Library files assume strict mode is in effect.

**Every file is guarded against double-sourcing** and declares its dependencies
in the header comment.

**Backups follow `.orig` / `.bak`.** `.orig` captures the pristine
package-shipped version, written at most once. `.bak` captures the previous
state for everything else and is overwritten each run. See `lib/backup.sh`.

**Persistent changes are journalled** to `/var/lib/provision/changes.jsonl` —
state, not logs, so it survives log rotation. Run transcripts go to
`/var/log/<script-name>/` separately. The journal records paths, hashes and
descriptions; never file contents, because callers handle private keys.

## Use

```bash
#!/usr/bin/env bash
set -euo pipefail

# include: log.sh
# include: privilege.sh
# include: journal.sh
# include: backup.sh

require_unprivileged
journal_init "my-script" "$SCRIPT_VERSION"

backup_file /etc/some/config.conf "enabling widget support"
# … modify it …
journal_record modify /etc/some/config.conf "enabled widget support"
```

Consumers resolve `# include:` directives at build time and ship a
self-contained script, so deployed scripts have no runtime dependency on this
repository. Includes are resolved transitively — declaring `backup.sh` pulls in
`journal.sh` and `log.sh` automatically.

## Checking a system

```bash
provision-report              # what has been done to this box
provision-report --verify     # …and has anything changed since
```

## Status

`include-build` and `include-install` are legacy and slated for removal. Their
contents are policy, not mechanism, and are being migrated into `sys-bld` and
the per-installer repositories. The pre-restructure layout is tagged `v0.1.0`.
