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
lib/host.sh           hostname validation and setting
lib/net.sh            address, mask and range arithmetic
lib/oui.sh            MAC vendor lookup
lib/git.sh            git identity, GitHub ssh stanza, pinned host key
bin/provision-report  read and verify the change journal
bin/bld               resolve # include: directives into a self-contained script
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
`backup_file` also backs up a file the invoking user cannot see. When the
file is in a root-owned directory that user may not search (0750, 0700), it
asks root, through `sudo`, whether the file and an existing `.orig` are
there, instead of taking "not visible" for "not there" and letting the file
be replaced with no backup. Exactly what that covers:

- A file that is visible, or visibly absent (its nearest existing ancestor
  can be searched), costs no sudo call for the test.
- A symlink is judged by its target: a visible link into a directory only
  root can search is put to root; a dangling link in plain sight is absent.
- Root is asked only about a directory root owns (a symlinked directory is
  judged by what it points to). One that another user owns and has closed is
  left alone: the file is treated as absent, with a warning.
- A relative path is never put to root; it is absent as soon as the invoking
  user cannot tell.
- If root's answer is needed and sudo gives none, `backup_file` dies rather
  than let the caller modify a file that got no backup.

A symlink is backed up as the file it points to: the backup is a copy of the
content with the target's mode, owner and timestamps, not a second link to
the same target. The copy is written at the backup's own path or not at all:
a file or link already there is replaced, never written through, and if that
path is a directory the copy fails and `backup_file` dies rather than place
the backup inside it.

**Persistent changes are journalled** to `/var/lib/provision/changes.jsonl` —
state, not logs, so it survives log rotation. Run transcripts go to
`/var/log/<script-name>/` separately. The journal records paths, hashes and
descriptions; never file contents, because callers handle private keys. The
system journal is world-readable, so a hash is recorded only for content that
already is: other-read on the file and other-execute on every ancestor directory. A
private key, a 0600 config or anything under a 0700 directory is journalled
without a hash, and `provision-report --verify` tracks it by presence alone.
`journal_record_nohash` leaves the hash out of a world-readable file's record
too.
A script that runs per-user can set `JOURNAL_DIR` (before or after sourcing)
to keep its journal under `~/.local/state` instead; the journal uses `sudo`
only when the invoking user cannot write where it lives, so nothing under
`$HOME` ends up root-owned. The same hashing rule applies there: with a 0750
home directory (Ubuntu's default since 24.04), files under `$HOME` fail the
other-execute test and are tracked by presence only.

**APT signing keys are pinned by the caller.** `apt_add_repo` requires either
`--fingerprint <FPR>[,<FPR>...]` or an explicit `--no-fingerprint` (since
v1.5.0); a call with neither is refused. The fingerprints are policy, so they
live in the calling script, next to the repository URL. A downloaded key and
an existing keyring must both hold only pinned primary keys; a keyring that
does not is moved aside and fetched again. `--no-fingerprint` logs a warning
on every call. To choose a fingerprint, take the publisher's, then confirm the
key actually signs the repository: `gpgv --keyring <key.gpg>
dists/<suite>/InRelease`.

`apt_repo_keyring_pinned <name> <FPR>[,<FPR>...]` answers "is the keyring
installed for this repo one of these pinned keys?" without changing anything:
0 when `<name>.gpg` exists and holds only primary keys from the list, 1 when
it is missing, unreadable or holds any other key, 2 for a bad name or list.
It is the check `apt_add_repo` makes of an existing keyring, and reads the
keyring through `sudo`, so one the invoking user cannot read is still checked.

`apt_add_repo` tells its failures apart, so a caller can fall back to the
distribution's packages in the one case where that is sound:

| Status | Meaning | Left behind |
|---|---|---|
| 0 | configured and validated, or already configured | the keyring and sources file |
| 1 | the repository does not serve this suite: apt's scoped update reported `E: The repository '…' does not have a Release file.` (or `no longer has`), the server's answer for that file was 404 (or it is a `file:` repository), and there was no signature or connection problem | the sources file is removed; after a reconfigure the earlier version is its backup; the pinned keyring stays |
| 2 | anything else | see below |

Status 2 covers:

- a call that is wrong as written (arguments, name, fingerprint options).
  Fatal: the shell exits 2;
- a key that could not be fetched, is not the pinned one, or could not be
  installed. No keyring is left;
- an unpinned existing keyring that could not be moved aside. It is still in
  place;
- a sources file that could not be backed up (untouched), written (possibly
  incomplete; the earlier version is the backup) or removed (still in place,
  unvalidated);
- a scoped validation that did not succeed for any reason other than the
  suite not being served. The sources file is removed as for status 1, since
  an unvalidated source is never left configured:
  - the repository's signature could not be verified against the pinned key
    (signed by another key, expired, not signed, or no longer signed). The
    validation forces `Acquire::AllowInsecureRepositories` and
    `Acquire::AllowDowngradeToInsecureRepositories` off, so a host configured
    to accept unsigned repositories cannot make one validate; if apt still
    only warns that there is no Release file, that is status 2 as well;
  - the repository could not be reached: the name does not resolve, the
    connection failed, the server refused access (401, 403), or it answered
    for the Release file with any HTTP status other than 404; the message
    names the status. The validation runs with `APT::Update::Error-Mode=any`,
    so apt reports a transient failure as a failure instead of exiting 0 with
    a warning;
  - the lists lock was held for the whole wait;
  - apt failed in a way the function does not recognise;
- a full update that failed after a successful validation. The repository
  stays configured and recorded.

Only status 1 says the repository itself is unsuitable. A publisher's key
rotation is always status 2, whichever way it shows up: the key URL serving a
key that is not the pinned one, or the repository signed by a new key while
the keyring holds the old one.

```bash
rc=0
apt_add_repo --fingerprint "$FPR" example "$KEY_URL" "$REPO_URL" "$SUITE" || rc=$?
case "$rc" in
    0) ;;
    1) log_warn "no packages for ${SUITE} upstream; using the distribution's" ;;
    *) die "could not set up the example repository" ;;
esac
```

**apt waits for its locks** (since v1.6.0). On a freshly booted host another
apt process (unattended-upgrades, apt-daily) usually holds one of apt's two
locks for minutes, and an `apt-get` that finds a lock taken fails at once.
Everything in `lib/apt.sh` waits instead:

- installs, removes and purges pass `-o DPkg::Lock::Timeout=$APT_LOCK_WAIT`,
  apt's own option: apt waits up to that many seconds for the dpkg lock;
- that option does not cover the package lists lock, so every `apt-get update`
  goes through `apt_update_wait [apt-get option...]`. It runs the update under
  `LC_ALL=C` and, while apt's stderr has a line starting `E: Could not get
  lock`, retries every `APT_LOCK_RETRY` seconds until `APT_LOCK_WAIT` seconds
  have been spent waiting. It says once that it is waiting (a `log_info`). Any
  other failure, or the limit, returns apt's exit status.

`APT_LOCK_WAIT` defaults to 1200 (20 minutes) and `APT_LOCK_RETRY` to 10; set
either before sourcing the library to change it. `APT_LOCK_WAIT` must be a
whole number of seconds from 0 to 999999 and `APT_LOCK_RETRY` one from 1 to
9999, in decimal with no leading zero; anything else is replaced by the
default, with a warning, when the library is sourced and again wherever the
values are used. `apt_lock_wait_message`
prints a sentence describing the wait, for a script to log before its first
apt call: `log_info "$(apt_lock_wait_message)"`. A caller that captures
`apt_update_wait`'s output sets `APT_WAIT_NOTICE_FD` to a descriptor of its
own, so the waiting line still reaches the terminal:

```bash
{ out="$(APT_WAIT_NOTICE_FD=3 apt_update_wait -qq 2>&1)"; } 3>&1
```

A value that is not a descriptor number, or a descriptor that is not open, is
ignored: the line goes to stdout.

All of `lib/apt.sh` escalates through `sudo`, like the rest of the library;
there is no run-as-root branch.

**Package changes are journalled by what dpkg says changed**, not by what was
asked for (since v1.6.0). The functions:

```
apt_pkg_state <package>
apt_change  <install|remove|purge> [--reason <text>] [apt-get option... --] <package>...
apt_install [--reason <text>] [apt-get option... --] <package>...
apt_remove  [--reason <text>] [apt-get option... --] <package>...
apt_purge   [--reason <text>] [apt-get option... --] <package>...
apt_install_list <path>
```

- `apt_pkg_state` prints dpkg's status and version for a package (`ii 1.7.1-3`,
  `rc 1.7.1-3`), or nothing when dpkg does not know it.
- `apt_change` makes one non-interactive `apt-get` run (`sudo env
  DEBIAN_FRONTEND=noninteractive`, with the lock timeout) and **returns**
  apt-get's exit status: the caller decides whether a failure is fatal.
  `apt_install`, `apt_remove` and `apt_purge` are the same call but **die** on
  failure; `apt_install_list` installs a manifest the same way.
- **Options convention:** when the arguments contain a `--`, everything before
  it is passed to apt-get as options and everything after it is a package.
  apt-get is then run as `… <options> -- <packages>`, so a package can never
  be read as an option. With no `--`, every argument is a package, so
  `apt_install foo bar` works as it always has.
- Before the `--`, every word must start with `-`. The separate values of
  `-t`, `-o`, `-c` and `--target-release` are the exceptions (`-t <release>`,
  `-o Key=Val`); any other option that has a value needs it attached
  (`--option=value`). A bare word anywhere else before the `--` is a misplaced
  package: the call returns 2 and runs nothing.
- `--reason <text>` (or `--reason=<text>`) is what the journal records as the
  reason, and is not passed to apt-get. With no `--` it must be the first
  argument; with a `--` it may be anywhere before it. The default is
  `apt-get <action>`.
- `apt_install_list` holds each manifest line to exactly one package:
  `<name>[:<arch>][=<version> | /<release>]`, after the comment (from the
  first `#`) and the whitespace at either end are dropped. `<name>` is a
  Debian package name (a lower-case letter or digit, then lower-case letters,
  digits, `+`, `.` and `-`) that does not end in `-`. No glob, path or option,
  and no whitespace inside the line: two names on one line are an error. A
  line that does not fit kills the run, naming its number and the line as
  written.

```bash
apt_install foo bar
apt_install --no-install-recommends -- foo bar
apt_install --reason "pinned for the old kernel" --allow-downgrades -- foo=1.2-3
apt_install -t some-backports -- foo
apt_change remove --reason "replaced by foo" -- bar || log_warn "bar is still installed"
```

Each package's state is read before and after the run. A package whose status
or version changed gets one journal record of its own (`install` or `remove`)
carrying the reason and both states; a package that did not change gets none,
so a run that changes nothing journals nothing. An install that apt-get
reports as successful but that leaves a package not installed is logged as a
warning and not recorded: that is what happens when another installed package
Provides the name, and it is not an error. `<name>=<version>` and
`<name>/<release>` are tracked as `<name>`. A word that is not a plain package
name (a local `.deb`, a glob, apt's `<pkg>-` and `<pkg>+` suffixes) is passed
to apt-get but not tracked: no record and no warning.

**APT sources are backed up before they are replaced or removed.** A repo
name is letters, digits, `.`, `_` and `-`, starting with a letter or digit;
`apt_add_repo` and `apt_remove_repo` refuse anything else.
`apt_add_repo` backs up a sources file it reconfigures. The `repo` journal
record is written once the scoped validation has succeeded, and carries the
backup path after a reconfigure; if the full update after it then fails, the
call warns and returns 2 with the repo configured and recorded, and a re-run
finds nothing to do.

Whenever the scoped validation does not succeed, the new sources file is
removed, and the status says why (1 for a suite the repository does not
serve, 2 for a signature, connection or lock failure; see the table above).
The file the call wrote is not backed up, so the backup of the version before
the call (or an older backup, when the call created the file) is left intact.
A file created and removed in the same call is not journalled; a reconfigured
one is journalled as a single `delete` record with the backup path and the
reason. A repository that is already configured as requested is left alone:
no update, no write, no record.

`apt_remove_repo [--keep-key] <name>` backs up the sources file and the
keyring before removing them and journals each removal with its backup path.
`--keep-key` removes the sources file only, for a caller that keeps its pinned
key. Without it, a keyring left behind with no sources file is removed too.

`apt_pkg_state` matches a package with or without its architecture qualifier
(`foo` and `foo:amd64`), whichever form was asked for and whichever dpkg
lists.

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

## Building

Consumers wrap their includes and a development bootstrap in a marker block:

```bash
# >>> bash-includes >>>
# include: backup.sh
# embed: packages/*.list
_bootstrap_lib() { ... }      # lets the script run from a checkout
_bootstrap_lib
# <<< bash-includes <<<
```

`bin/bld` replaces that whole block with the library inlined, producing a file
with no runtime dependency on this repository — deployment is one copy rather
than a bootstrap sequence.

```bash
bld -L lib -L /path/to/bash-includes/lib -o dist myscript.sh
```

Includes resolve **transitively**: declaring `backup.sh` pulls in `journal.sh`
and `log.sh`, emitted in dependency order. Double-source guards are stripped
during inlining — `return` outside a function is fatal in a concatenated
script, and de-duplication is the builder's job.

`# embed:` inlines data files as heredocs, extracted to a temp directory at run
time and exposed as `$BLD_EMBED_DIR`, so a script that reads manifests is still
a single file.

Each build stamps `git describe --tags --always --dirty` into `SCRIPT_VERSION`,
which the change journal records — so an entry says not just what changed but
exactly which revision changed it, and `-dirty` flags a build from an
uncommitted tree.

## Checking a system

```bash
provision-report              # what has been done to this box
provision-report --verify     # …and has anything changed since
```

`--verify` re-hashes each world-readable file against its recorded hash (OK /
CHANGED), and reports files journalled without a hash as PRESENT or MISSING.
A journal written before v1.5.1 may hold hashes of files that are not
world-readable (earlier versions hashed anything the user could read, and
root-only files through sudo); `--verify` now reports those NOREAD, not OK.

Only the latest record for each path is checked (since v1.6.0). An earlier
record for a path that a later record changed or deleted shows SUPERSEDED
instead of CHANGED or MISSING, and is counted separately. Which record is the
latest is decided over the whole journal, whatever `--run` or `--script`
select. A record that names a backup also shows whether the backup still
exists (`[present]`, `[missing]`, `[unknown]`): presence only, without
changing the record's own status, with missing backups counted separately in
the summary line.

## Changes in v1.6.0

What a script that used v1.5.x can notice:

- **Journal records per package.** `apt_install` and `apt_install_list` write
  one `install` record for each package whose dpkg state changed, with the
  package as the target, instead of one record for the whole request. A run
  that installs nothing writes nothing. A requested package that is not
  installed afterwards (a provided one, usually) draws a warning.
- **Lock waits.** Every apt call waits for apt's locks, for up to
  `APT_LOCK_WAIT` seconds (20 minutes by default) each, where it used to fail
  at once.
- **`apt_install` arguments.** A `--` separates apt-get options from packages,
  and a leading `--reason <text>` is taken as the journal reason.
  `apt_install_list` refuses a line that is not exactly one package name
  (before, whitespace inside a line was dropped, joining `foo bar` into
  `foobar`), and reads a last line that has no trailing newline.
- **`apt_add_repo`.** A reconfigured sources file's record carries the backup
  path; a failed validation after a reconfigure is recorded as a `delete`.
  The updates run under `LC_ALL=C`, with apt's stderr shown after its stdout.
- **`apt_remove_repo`.** It backs up what it removes (`<name>.sources.bak`,
  `<name>.gpg.bak`), journals each removal, removes a keyring left behind
  without its sources file, and takes `--keep-key` to leave the keyring.
- **Repo names are validated** by `apt_add_repo` and `apt_remove_repo`.
- **`apt_add_repo` statuses.** It returned 1 for every failure; now 1 means
  only that the repository does not serve the suite (apt found no Release
  file for it), and every other failure is 2 (a wrong call exits 2 where it
  exited 1). A repository whose signature does not verify against the pinned
  key, or that cannot be reached, is 2 and is removed; before, an unreachable
  one passed validation. `apt_add_repo … || die` is unaffected; a caller that
  fell back to the distribution's packages on any non-zero status should now
  do so on 1 only.
- **`apt_repo_keyring_pinned <name> <FPR>[,<FPR>...]`** is new: whether the
  keyring installed for a repo holds only pinned keys.
- **`backup_file` sees root-only files.** A file in a root-owned directory the
  invoking user cannot search is now backed up; before, it was taken for
  absent and skipped. An existing `.orig` there is found too, and not
  overwritten. If root has to be asked and sudo gives no answer, it dies.
- **`backup_file` and symlinks.** The backup of a symlink is now a copy of the
  file it points to; before, it was another link to the same target.
- **`apt.sh` no longer includes `os.sh`.** A script that calls `get_os_codename`
  or the like must include `os.sh` itself.
- **Delete your own copies.** A script that defines its own `apt_update_wait`,
  or assigns `APT_LOCK_WAIT`, after including the library overrides the
  library's; remove them when re-pinning.
- **Test stubs.** The library now runs every apt-get through `sudo env …
  apt-get`, so a test that stubs `apt-get` needs an executable on `PATH`; a
  shell function is not seen.
- **`provision-report --verify`** has a new status, SUPERSEDED, two more
  counts in its summary line (superseded records, missing backups), and a
  `[present]`/`[missing]`/`[unknown]` note on each `backup:` line. Output
  without `--verify` is unchanged.

## Status

`include-build` and `include-install` are legacy and slated for removal. Their
contents are policy, not mechanism, and are being migrated into `sys-bld` and
the per-installer repositories. The pre-restructure layout is tagged `v0.1.0`.
