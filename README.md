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
lib/log.sh            timestamped, per-stream colour-aware logging; text made printable for a message
lib/privilege.sh      enforce run-as-user / escalate-per-command
lib/cleanup.sh        stack of teardown handlers sharing one EXIT trap
lib/child.sh          run a privileged command as a tracked background child
lib/journal.sh        append-only record of persistent system changes
lib/backup.sh         the .orig / .bak backup convention
lib/file.sh           write a root-owned file only when its content, mode or owner changes; the staging name a killed install leaves
lib/payload.sh        a built payload checked before use (whole, current, parses, no bootstrap) and rendered under a NAME=%q settings header
lib/teardown.sh       snapshot what a rebuild removes, stop units, remove it
lib/os.sh             OS, arch, kernel, init and session detection
lib/apt.sh            APT repository and package helpers
lib/host.sh           hostname validation and setting
lib/net.sh            address, mask and range arithmetic
lib/oui.sh            MAC vendor lookup
lib/mac.sh            read an interface's MAC address; set it and read it back, in this or another network namespace
lib/netdev.sh         an interface's existence, IFF_UP state and wireless phy; the modes a phy supports
lib/nft.sh            jq programs over nft's JSON listings: chain policy, other forward users, filter family, jump handles
lib/nftchain.sh       a root-run hook's own chains: fresh at start, jumps by handle and deleted at stop, the forward policy; status tokens, no logging
lib/sshd.sh           the SSH ports and endpoints sshd is configured for (sshd -T), ssh.socket listens on, and sshd actually holds (ss); an endpoint's nft address match; whether the session keeps a rule
lib/git.sh            git identity, GitHub ssh stanza, pinned host key
bin/provision-report  read and verify the change journal
bin/bld               resolve # include: directives into a self-contained script
```

## Conventions

**Run as your normal user.** Scripts are invoked without `sudo` and escalate
per command. `require_unprivileged` enforces this and fails immediately with an
explanation if a script is run as root, instead of silently leaving root-owned
artefacts behind.

**A Ctrl-C during a `sudo` command stops the script.** `privilege.sh` defines
a `sudo` function around the real one. With a terminal, sudo-rs (0.2.13, the
`sudo` of Ubuntu 26.04) runs the command on its own pty and takes the
terminal's foreground for the duration, so a Ctrl-C typed meanwhile kills the
command and never reaches the script: sudo returns 130, no trap runs, and the
script carries on one step short. The function takes a 130 from sudo as that
interrupt and sends the script the SIGINT it missed, so its trap (the
`cleanup.sh` handlers, exit 130) runs as it would for any other command.
Limits: a command that catches SIGINT and exits with another status is not
seen, and a command that exits 130 for its own reasons is taken for an
interrupt; and under sudo 1.9, where the script gets the terminal's signal
itself, a trap that does not exit runs twice. Use `command sudo` for such a
command, and for a helper started with `&` (through the function, `$!` would
be a subshell, not sudo). The function is not defined when a `sudo` function
already exists, so a test stub exported before the script runs stays in
charge.

**Library files never set shell options.** `set -euo pipefail` belongs to the
entry-point script; a library that sets it changes the behaviour of code that
did not ask for it. Library files assume strict mode is in effect. The one
piece of process state the library does set is the umask: `log.sh`, which
every consumer includes first, runs `umask 022`, so a consumer creates 0644
files and 0755 directories whatever shell started it (since v1.11.0; see
below). A file that must be private is given its mode explicitly.

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
the same target. The copy is written under a private name beside the backup
(`<file>.bak.XXXXXXXX`) and renamed into place, so it lands at the backup's
own path or not at all: a file or link already there is replaced, never
written through, and if that path is a directory the rename fails and
`backup_file` dies rather than place the backup inside it. The file's
directory, in its canonical form (the backup is written there, not through
a link that someone else could repoint), and every ancestor of it must be
owned by root or the invoking user and closed to group and other; the one
exception is a directory shaped like `/tmp`, sticky and world-writable with
`fs.protected_symlinks` and `fs.protected_regular` on, which is what the
kernel actually protects. Otherwise `backup_file` dies, since an account
that can write the directory could redirect the copy while it is written. A run
interrupted between the copy and the rename leaves the private file behind;
with `cleanup.sh` loaded it is removed at exit.

**Persistent changes are journalled** to `/var/lib/provision/changes.jsonl` —
state, not logs, so it survives log rotation. Run transcripts go to
`/var/lib/provision/log/<script-name>/` (see below). The journal records paths, hashes and
descriptions; never file contents, because callers handle private keys. The
system journal is world-readable, so a hash is recorded only for content that
already is: group- and other-read on the file and group- and other-execute on every
ancestor directory (mode bits only; ACLs are not consulted). Journal a file after its
final `chmod`, since the rule is applied when the record is written. A
private key, a 0600 config or anything under a 0700 directory is journalled
without a hash, and `provision-report --verify` tracks it by presence alone.
`journal_record_nohash` leaves the hash out of a world-readable file's record
too.
A script that runs per-user can set `JOURNAL_DIR` (before or after sourcing)
to keep its journal under `~/.local/state` instead; the journal uses `sudo`
only when the invoking user cannot write where it lives, so nothing under
`$HOME` ends up root-owned. The same hashing rule applies there: with a 0750
home directory (Ubuntu's default since 24.04), files under `$HOME` fail the
ancestor test and are tracked by presence only.

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

# A file whose whole content the script owns: compared, backed up, written
# atomically and journalled in one call, and only when something differs.
# include: file.sh
install_file_if_changed /etc/widget.d/50-site.conf "widget site drop-in" <<CONF
option = value
CONF
(( INSTALL_FILE_CHANGED )) && sudo systemctl restart widget.service
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

## Run transcripts

```bash
log_open_transcript "$(log_transcript_path my-tool)"          # run-<UTC stamp>.log
log_open_transcript "$(log_transcript_path my-tool deploy)"   # deploy-<UTC stamp>.log
```

`log_transcript_path <tool> [label]` prints
`/var/lib/provision/log/<tool>/<label>-<UTC timestamp>.log`
(`LOG_TRANSCRIPT_ROOT` moves the root). `log_open_transcript <path>` then
appends every log line, uncoloured, to that file. It never fails the run: if
it cannot open a transcript it warns and carries on without one.

Transcripts are **not** under `/var/log`. On Ubuntu `/var/log` is `root:syslog
0775` with no sticky bit, so the `syslog` account can create `/var/log/<tool>`
before a tool first runs, or rename a root-owned one away between any two
commands — and the transcript is created by root and handed to the invoking
user. No check on a path under such a parent closes that.
`log_open_transcript` therefore accepts only a directory nobody else can
interfere with:

- a directory whose every component from `/` down is a real directory owned
  by root and closed to group and other. Missing components are created
  `root:root 0755`, one at a time; the file is created by root, owned by the
  invoking user, mode `0640`;
- or a directory the invoking user owns that group and other cannot write,
  reached through ancestors owned by root or that user which others cannot
  write either (or which are sticky, like `/tmp`). It is created without
  `sudo` if missing, and so is the file.

The privileged case runs `sudo -n`: it never prompts, and if `sudo` will not
run without a password the transcript is skipped with a warning that says so.

Anything else — `/var/log/<tool>` on Ubuntu, a new directory directly under `/tmp` — is
refused with a warning that names the component in the way, and nothing is
created. An existing file at the path is reused only if it is a regular file
owned by the invoking user; a link or anything else there is never written
through.

## Changes in v1.16.3

- **`file_dir_trusted` learns root's uid before the walk.** The walk judges
  a link on the chain by its owner against root's uid, which `_file_owner`
  provides; as the first `file.sh` call of a run (a preflight is), v1.16.2's
  function skipped that and a root-owned link read as untrusted. One line;
  found by wireguard-bld's implementer.

## Changes in v1.16.2

- **`file.sh`: `file_dir_trusted <dir>`** — the directory rule the writers
  apply (`install_file_if_changed`, `install_atomic`, `mkdir_root_p`),
  offered on its own for a preflight: 0 when root may safely create or
  replace files in `<dir>`, 1 after a `log_error` naming the directory and
  the reason, nothing created. Debian ships `/usr/local` as `root:staff
  2775`, which the rule refuses (a `staff` member could replace a root-run
  file there); a builder that installs under it learns that from this call
  before it changes the host, not from `install_atomic` at its last step
  (found by the code review of wireguard-bld's v1.16.0 migration).

## Changes in v1.16.1

- **`install_atomic` checks the directory its source waits in.** The
  source is the caller's file until root's `install` reads it, so its
  directory now gets the same rule as the one root writes to (`realpath`
  first, then the directory-trust walk): another account able to rename a
  file into a shared, non-sticky TMPDIR between the caller's write and
  root's read would otherwise have root install its content — and the VPN
  builders' firewall hooks, rendered into TMPDIR by `payload_render` and
  installed by `install_atomic`, run as root. The default `/tmp` (sticky,
  world-writable, protected_* sysctls on) passes; a refusal says "set
  TMPDIR to a private directory", as `install_file_if_changed` has since
  v1.9.0. Found by the security review of wireguard-bld's v1.16.0 migration.

## Changes in v1.16.0

The helpers the two VPN builders each carried for their embedded payloads
and their root-run firewall hooks, lifted into the library (FA-fleet-023,
FA-fleet-024). Each existed twice, and a fix made in one builder stayed
there: wireguard-bld refuses an empty, cut or unbuilt payload and strips
control characters from the hook header, openvpn-bld does neither;
openvpn-bld covers a wildcard server address in the session check and
checks nothing about a rule handle before pasting it into `nft delete
rule`. One copy, one test suite, one fix, and the gaps close on each
builder's next re-pin. Nothing existing changes for a consumer that uses
none of it.

- **`payload.sh`** (new, includes log.sh), for a script that embeds a
  bld-built payload. `payload_check [--last <line>] <artefact> <source>
  [<dependency>...]` refuses, with `log_error` and status 1, an artefact
  that is missing, empty, does not parse, still holds the development
  bootstrap (bld's marker as an exact line, or a `_bootstrap_lib()`
  definition — not the bare name, which a payload that includes payload.sh
  carries itself), or, with `--last`, whose last non-blank line is not that
  line (`main` for a hook: bld leaves a `build/<x>.sh` that failed its own
  `bash -n` in place, and one cut at a line boundary parses and, installed
  as a hook, exits 0 having done nothing); and, in a development checkout
  only (where `_bootstrap_lib` is defined), one older than its source, any
  dependency given, or any `*.sh` in the directory payload.sh was sourced
  from (`_PAYLOAD_LIBDIR`), which is the library checkout that moved under
  an unchanged LIB_VERSION neither builder could see. It returns, never
  exits: `payload_check … || exit 1`. `payload_render [--shebang <line>]
  [--readonly] [--comment <text>]... [--] <payload> [NAME | NAME=value]...`
  prints the payload as installed: line 1 (the given shebang, or the
  payload's own, which must be one), each comment with control characters
  removed (a newline in a checkout's SCRIPT_VERSION would end the comment
  and start a line root runs), each setting as `[readonly ]NAME=%q` under
  the C locale (a bare NAME must be set and may be empty; NAME=value is the
  literal; NAME must be an identifier not starting with `_payload_`, the
  prefix of the function's own locals), then the payload from line 2.
  Everything is checked before anything is printed; every step is
  `|| return 1`. Which settings and what the comments say stay with the
  caller; the result goes through `install_atomic`.

- **`nftchain.sh`** (new, includes nft.sh and nothing else), for the hooks
  themselves: it runs no command at source time, so a hook that pins PATH
  as its first command keeps that property with it inlined, and it logs
  nothing — every function prints a status token and returns, and what a
  token is worth (a WARN, a fatal start, a line in a list) stays in the
  hook. `nft_chain_fresh <family> <table> <chain>` adds and then flushes
  the chain whatever its state (`nft add chain` on an existing chain
  succeeds and would have appended the new rules to the old; a probe that
  fails cannot change that), printing `created` or `flushed` (a chain left
  by a stop that could not delete it), 1 when nft refused. `nft_jump_handles <family> <table> <base> <target>` prints the
  numeric handles of the rules that jump or goto to the target from the
  JSON listing, 1 when the listing or jq failed, 2 after the numeric ones
  when a handle was not a number (judged in jq, so a string holding a
  newline cannot pass as two numbers) — openvpn-bld pasted jq's output
  into `nft delete rule … handle` unchecked; read it as `handles="$(…)";
  rc=$?`, since status 2 comes with the good handles. `nft_delete_chain
  <family> <table> <chain>` prints `deleted`, or `absent` when the delete
  was refused and the chain is not there, 1 when it still is.
  `nft_forward_drop <family> <table>` is the forward-policy decision both
  hooks carried (`_NFT_FWD_OTHERS_JQ`, `_NFT_POLICY_JQ`): one token among
  `unread`, `created-drop`, `created-accept <others>`, `drop-failed
  missing`, `flipped`, `drop-failed accept`, `kept <others>`, `drop` and
  `not-base` (a chain named forward that is not a base chain on the forward
  hook; whether that fails the start is the hook's call), and 1 only when a
  policy-accept create failed. Tested against a stateful nft fake
  (`tests/fake-nft.sh`, a copy of openvpn-bld's).

- **`sshd.sh`: `sshd_session_covered <server address> <port>
  <endpoint>...`** — whether the SSH session that reached that address and
  port keeps an accept rule once per-listener rules are written for the
  endpoints (as the `*_endpoints_*` readers print them): 0 or 1, silent;
  1 as well for an empty server address or a port that is not a number.
  The same address (`_sshd_addr_key`: scope off, mapped form unmapped,
  lower case), the family wildcard of the session's family (`::` never
  covers an IPv4 session), `*`, a scoped listener only for a session with
  the same scope, a name (port-wide rule) always; and a wildcard server
  address, for a caller holding one endpoint set against another, is
  covered by `*` or either family's wildcard. The family asked of
  `sshd_endpoint_match` is fixed at `inet`: only "not an address" is used,
  which no valid family changes, and an empty or wrong family read from a
  variable made every session covered, the lockout direction. The builders'
  `session_covered` and `ssh_addr_key` go.

- **`file.sh`: `install_atomic_glob <dest>`** prints the glob
  (`.<name>.` then eight `[[:alnum:]]` and `~`) that finds a staging file
  `install_atomic` left beside `<dest>` when it was killed between its
  mktemp and its rename, for a caller that lists leftovers in the directory
  it installs into (matched under `LC_ALL=C`; 1 for a name holding a glob
  metacharacter or a control character, which would widen the pattern). The glob and `install_atomic`'s mktemp template come
  from one helper (`_file_stage_name`), so they cannot drift. The builders'
  `install_fw_hook` becomes `payload_render … > "$tmp"` plus
  `install_atomic "$tmp" 0700 "$path"`, which also gives the hooks the
  directory-trust walk.

- **`log.sh`: `log_printable <text>`** — every byte outside printable ASCII
  replaced by `?` under the C locale, for naming an address or a value from
  the environment in a message or a generated comment. The builders'
  identical `printable` goes; the name differs because a payload that
  includes log.sh (openvpn-bld's `ovpnbld-ca.sh`) defines its own
  `printable`, and bld's duplicate check would fail the build.

## Changes in v1.15.0

- **CI lints the test suites.** `shell-ci.yml` gained a `shellcheck tests`
  step after `shellcheck sources`: every tracked `.bats` file, same
  invocation (`-x -e SC1091,SC2034 -S warning`), skipped with a notice
  where a repository has none. shellcheck reads bats syntax natively and
  reports SC2314, the bare `! cmd` that `set -e` ignores inside a test;
  that class returned twice after the fleet-wide fix, which is why.
  Workflow only: no tag, consumers call it at `main`. Every suite in the
  fleet was made clean against that invocation first (2026-10-18).

- **`provision-report` shows what a step ran and who chose it.** A record
  that carries a `command` or `selected_by` key (sys-bld writes both on
  every checklist step since its `--step`/`--arg` command line: the
  function and arguments that ran, and `profile:<path>` or `command-line`
  for where the selection came from) prints them under the record as dim
  `command:` and `selected by:` lines, through the same visible-escape
  rendering as every other journalled string, so a value with a newline or
  a terminal escape stays one line. Records without the keys, `--raw` and
  `--targets` are unchanged; there is no new option.

## Changes in v1.14.0

The open library findings after v1.13.0, each closed where the consumers
can take it up on their next re-pin.

- **`sshd.sh`: a port is not an endpoint, now with the tooling to act on
  it.** `sshd_endpoints_listening [socket-port...]` joins
  `sshd_endpoints_configured` and `sshd_endpoints_socket`, so every source
  reads `<address> <port>` (`ss` prints a scoped address as
  `[fe80::1]%eth0:22` and an IPv6 any-address socket that takes IPv4 as
  `*:22`; both are parsed). `sshd_endpoint_match <family> <address>` turns
  an address into the match a `tcp dport` rule carries in a table of that
  family: nothing for `*` (a dual-stack any-address socket: port-wide),
  `meta nfproto ipv4 ` / `meta nfproto ipv6 ` for `0.0.0.0` / `::` in an
  inet table and nothing in the table of their own family (an any-address
  listener of one family must not open the port for the other, where a
  local user's own listener would sit), `ip daddr <a> ` or `ip6 daddr
  <a> ` for an address, `iifname "<dev>" ` in front of any of those for a
  scoped or device-bound listener; status 2 when the family cannot reach
  the address (IPv6 in an ip table), 1 for anything that is not an address
  by the grammar (checked under the C locale: canonical octets, eight
  groups or one `::`, an interface name), with the fail-safe reading for
  the caller written in the header, so nothing unchecked is ever pasted
  into a rule. The validators the consumers were calling by
  their private names are public: `sshd_valid_ports` and
  `sshd_valid_endpoints` (FA-bash-includes-017; `_sshd_valid_ports` is
  gone, re-pin and rename).

- **`nft.sh`: `_NFT_POLICY_JQ` expects a base chain on the hook it is named
  after** (FA-bash-includes-018). A chain named `input` on the output hook,
  or a regular chain named `input`, reported its own policy as the input
  policy; now it is `none`, as a chain named `forward` on another hook
  already was. `--arg h <hook>` names the hook for a chain not named after
  it (iptables-nft's `FORWARD`). Callers that query `input` and `forward`
  need no change.

- **`oui.sh`: `oui_lookup` matches the prefix as text at the start of the
  line** with awk's `index()`, as its comment claimed `grep -F` did
  (FA-bash-includes-014); the first record wins, as before.

- **`apt.sh`: the existence tests on the sources file and keyring go
  through `backup.sh`'s `_backup_exists`** when backup.sh is loaded
  (`_apt_present`), so a file behind a directory the invoking user cannot
  search is asked of root instead of read as absent, which would have
  rewritten a repository that was already right or removed nothing; a
  question root does not answer is status 2 from `apt_add_repo`, 1 from
  `apt_remove_repo`, with nothing written or removed (FA-bash-includes-012
  item 7).
  Items 4 and 5 of the same finding are closed by a run, not a change: in a
  Debian 12 chroot (apt 2.6.1) the validation's three options behave as on
  apt 3.2.0, and the `NO_PUBKEY`, `BADSIG`, `EXPKEYSIG` and `GPG error`
  lines the classifier matches were produced and classed `signature`; the
  lines are in the header. Item 2 is decided, not changed: a link's target
  is backed up wherever it is, with its own mode and owner (the reason is in
  `backup_file`'s comment).

## Changes in v1.13.0

Three modules lifted out of the consumers that each carried them twice or
three times (FA-fleet-020, FA-fleet-021), and two fixes to what was here.

- **`nft.sh`** — the jq programs the VPN builders and their root-run hooks
  decide on, over `nft -j list ruleset` / `list chains` / `-a list chain`,
  never the text listing (a rule comment can forge a text line):
  `_NFT_POLICY_JQ` (a chain's policy, `missing`, or `none` for a regular
  chain and for a chain named forward on any other hook), `_NFT_FWD_OTHERS_JQ`
  (every other base chain on the forward hook, Docker's `ip filter FORWARD`
  included, ip6 excluded for an ip family), `_NFT_DETECT_FAMILY_JQ` and
  `_NFT_FILTER_FAMILY_JQ` (which filter table a hook should use, and which
  one it did use), `_NFT_JUMP_HANDLES_JQ`, `_NFT_HAS_JUMP_JQ` and
  `_NFT_EXACT_JUMP_JQ` (a conditional jump is a jump but not the
  unconditional one a hook verifies), `_NFT_COUNT_JQ` and
  `_NFT_CHAINS_NAMED_JQ` (exact names, given as a JSON list). Assignments
  only, no single quote in any program, so a hook that includes only
  `log.sh` can include this too. Which chain, which policy and what to do
  about the answer stay with the caller.

- **`sshd.sh`** — the SSH ports, one per line, sorted, numeric, from each
  source separately so the caller sets the policy: `sshd_ports_configured`
  (`sshd -T`; the `listenaddress` ports when there are any, else the `port`
  lines, which is what sshd binds; returns 1 when `sshd -T` fails so the
  caller can tell "no sshd" from "broken config"), `sshd_ports_socket`
  (ssh.socket's `Listen=`, Stream lines only; returns 1 when the socket is
  not active), `sshd_ports_listening [socket-port...]` (`ss -Htlnp`, a
  listener counting only when the sshd master holds it or pid 1 holds it on
  a socket port — never by process name, which any user can forge) and
  `sshd_master_pid`. stderr passes through; a caller that wants silence
  redirects it. The two VPN builders compare the configured and listening
  sets and flag the session's own port; sys-bld takes the configured set
  minus 22. One parse is fixed on the way in: a scoped IPv6 socket address
  (`[fe80::1%eth0]:22`) lost its port to the scope strip. And one thing the
  three originals all got wrong is named in the header and given a
  reader: a port is not an endpoint. `sshd_endpoints_configured` and
  `sshd_endpoints_socket` print `<address> <port>` (`*` for a port line),
  because a `ListenAddress 10.8.0.1:2222` turned into `tcp dport 2222
  accept` opens 2222 on every address, where any local user can bind it
  alongside sshd (only the wildcard bind conflicts) and be reached from
  outside. The consumers still write port-wide rules today; the finding is
  theirs to fix with `ip daddr` / `ip6 daddr` on a non-wildcard address.

- **`netdev.sh`** — `iface_exists`, `iface_is_up` (IFF_UP from sysfs: admin
  up, not carrier), `iface_phy` (the phy behind a wireless interface, via
  `readlink -e`, so a wired one never reports a phy named `phy80211`),
  `phy_modes_parse` (stdin) and `phy_modes <phy>` (the modes under
  "Supported interface modes", one per line, awk not grep because grep does
  not expand `\t`), `phy_supports_mode <phy> <mode>`. `phy_modes` returns 1
  when `iw` fails instead of printing nothing under `|| true`, so a caller
  under `set -e` writes `modes="$(phy_modes "$phy")" || modes=""`, or parses
  an `iw` capture it already holds with `phy_modes_parse`. Not named `iface.sh`:
  `bld` resolves an include with the consumer's own `lib/` first, and
  wifi-cap-test has one. `_NETDEV_SYSFS` points tests at a temp tree, as
  `_MAC_SYSFS` does.

- **`mac.sh` runs `ip` directly when already root** (FA-bash-includes-015).
  `mac_set` and `mac_set_ns` went through `sudo` whatever the EUID; a script
  that runs whole as root (wifi-trainer, by documented exception) logged
  three sudo calls per radio, and on a minimal image with no sudo binary
  the first `sudo ip … down` failed "command not found" and `mac_set`
  reported the link as not coming down. `_mac_root` elevates only when the
  script is not root; `_MAC_EUID` is the test seam (EUID is read-only).
  wifi-trainer can drop its `ensure_command sudo` once re-pinned.

- **`bld` builds the same artefact on every machine** (FA-bash-includes-016).
  An `# embed:` glob matching several files embedded them in the caller's
  locale collation (en_US.UTF-8 puts `firefox-policies.json` before
  `firefox-policies-no-lookups.json`, C after it), so a dist/ built on a
  workstation failed CI's freshness check; each glob's matches are now
  sorted under `LC_ALL=C`, with the embed lines themselves kept in written
  order. And the directives were read with `grep -oP … || true`: PCRE grep
  differs on aarch64, and on a grep without `-P` the `|| true` turned the
  failure into "no includes" — a built script with no library in it, found
  only when it ran. They are read with a bash regex now, which cannot fail
  quietly. sys-bld's `export LC_ALL=C` in its build.sh is no longer needed.

## Changes in v1.12.0

One new module, lifting a sequence four consumers had each written for
themselves (sys-bld, gps-time-sync, log-ship, wireguard-bld), none of them
quite alike.

- **`file.sh`: `install_file_if_changed [--mode M] [--allow-empty]
  [--no-backup] [--quiet] <dest> <reason>`**, content on stdin (a heredoc,
  `<<<` or `< file`; never a pipe, which would run it in a subshell). It
  stages the content, does nothing when `<dest>` already holds those bytes
  with that mode (default 0644) and root as owner — mode and owner count as
  content — and otherwise backs an existing file up with `backup_file` (or,
  with `--no-backup`, records the previous content's sha256 under the
  journal's own world-readable rule), creates missing parents one level at a
  time as root's 0755 directories, installs the content under a random
  root-owned name beside the target and renames it over, and journals
  `create` or `modify` with the reason. Empty content, meaning nothing but
  whitespace (`<<< "$unset"` yields one newline), is refused unless
  `--allow-empty`. `INSTALL_FILE_CHANGED` is 1 after a write, for the callers
  that restart something only then. A file that matches in content and
  differs only in mode or owner is rewritten and journalled but not backed
  up. The comparison is byte for byte: content with a per-run stamp belongs
  with a caller-side comparison, or without the stamp.

- **Where root may write.** Every directory root is about to use passes the
  rule `backup_file` already applies to the directory it writes a backup
  into: each component up to `/` a directory of root's or the invoking
  user's that nobody else can write, or sticky and world-writable with the
  kernel's `protected_symlinks` and `protected_regular` on. The path is
  walked as written, one component at a time, so a link is followed only
  when the directory holding it has already passed — a link planted as a
  middle component in a directory others can write is refused even when it
  points into a closed one — and the file is written at the canonical path
  the walk reached. The same walk covers `TMPDIR`, where the content waits
  as the user's file before root reads it. A refusal is logged and returns
  1. Parents are made with `mkdir` per level, never `install -d`, which
  follows a link at the path and would chmod and chown what it points to.
  Existence is probed through the yes/no helper `backup.sh` uses, so a
  `sudo` that failed to run is never read as "the file is not there", and a
  destination that exists but is not a regular file (a directory, a FIFO) is
  refused before anything opens it.

- **Three smaller helpers under the same rule:** `file_differs <src> <dest>
  <mode>` (a predicate; a failed check reads as "differs", so a broken sudo
  costs a rewrite and a `.bak` per run and never a skipped write),
  `install_atomic <src> <mode> <dest>` and `mkdir_root_p <dir>`.

## Changes in v1.11.0

One addition, for an interface that lives in another network namespace, and
one piece of process state the library now sets for every consumer.

- **`log.sh` pins `umask 022`.** sudo-rs (0.2.13, the `sudo` of Ubuntu 26.04)
  hands the caller's umask on, so from an interactive shell at 077 every
  `sudo tee` and `sudo install` without an explicit mode left a 0600
  root-only file: apt keyrings `_apt` could not read, sources files rewritten
  on every run. v1.7.0 fixed one such site; this covers every write site in
  every consumer at once, from the moment `log.sh` loads, and is what lets
  the fleet's interactive shells move to 077. Consumers that pinned the
  umask themselves (sys-bld, openvpn-bld) can keep the line; it is now
  redundant. Nothing changes for a file whose mode is set explicitly.

- **`mac.sh`: `mac_set_ns <netns> <iface> <mac>`.** `mac_set` through
  `ip -n <netns>`: link down, address set, and the read-back that decides
  the result, taken from `ip -n <netns> -br link show` because
  `/sys/class/net` only shows the caller's own namespace. Same statuses as
  `mac_set`, plus 5 for a namespace name `ip netns` could not have created
  (anything but letters, digits, `.`, `_` and `-`), refused before any
  command runs. Every step goes through `sudo`, the read-back included, since
  entering a namespace needs CAP_SYS_ADMIN. Added for wifi-trainer, whose
  simulated radios are moved into per-network namespaces before their
  addresses are randomised (FA-wifi-trainer-004); until now that was the one
  tool in the fleet setting a MAC without `mac.sh`.

## Changes in v1.10.0

`child.sh` — run a privileged command as a tracked background child and stop
it reliably under sudo and sudo-rs. `start_child <pid-var> <log> <cmd...>`
backgrounds the command under `command sudo` (so `$!` is sudo, not the
wrapper subshell) with stdin from `/dev/null`; `stop_child <pid-var>` sends
SIGTERM, waits, then SIGKILLs the whole process tree under the sudo child;
`_child_alive` requires the pid to still be this script's own child before
signalling, so a reused pid is never hit. `STOP_CHILD_KILLED` is set when
escalation to SIGKILL was needed. Lifted out of open-wifi-scanner (which now
consumes it); wifi-cap-test is the other consumer. Depends on nothing.

## Changes in v1.9.0

One removal from the public API, one change to what the journal hashes, and
hardening a consumer sees only as fewer ways for a run to go wrong.

- **`privilege.sh` defines a `sudo` function.** With a terminal, sudo-rs
  takes the foreground, so a Ctrl-C during a `sudo` command killed the
  command and never reached the script. A 130 from sudo now sends the script
  the SIGINT it missed (see Conventions for the limits). Use `command sudo`
  for a helper started with `&`.
- **`log_warning` is removed.** It was an alias for `log_warn`, kept for
  openvpn-bld's old spelling, and no consumer calls it any more. A script
  that still does fails with `log_warning: command not found`; rename the
  call to `log_warn`.
- **The journal hashes only content every account can read.** The rule was
  other-read on the file and other-execute on every ancestor directory. It is
  now group- and other-read on the file and group- and other-execute on every
  ancestor: the group class is checked before other, so a 0604 file or a 0705
  directory shuts out the owning group. Mode bits only; an access ACL is not
  consulted. Such a file is journalled without `sha256_after` and tracked by
  presence, and a record an earlier release wrote for one reports NOREAD
  under `provision-report --verify`. No fleet caller journals such a path.
  The rule is applied when the record is written, so journal a file after its
  final `chmod` (now said in `journal_record`'s header).
- **`provision-report --verify` cannot hang on a path root must be asked
  about.** The `sudo -n test -e` for a file the invoking user cannot see runs
  under the hash timeout; an unresponsive automount or a stale NFS target
  makes the path NOREAD instead of stopping the report.
- **`backup_file` writes the copy under a private name and renames it into
  place.** Nothing is written through the backup's own name any more. With
  uutils `cp` (rust-coreutils, installed beside GNU coreutils on Ubuntu
  26.04, which links `cp` to GNU today) `--remove-destination` reopens the
  destination without `O_EXCL`, so a link planted at `<file>.bak` between
  its unlink and its open would have been written through as root; GNU cp
  recreates with `O_EXCL` and was not affected. The private name narrows
  that window for uutils cp (one `cp`, under a name that has to be read from
  a directory listing first) and GNU cp closes it; what closes it for both
  is a new rule: **the file's directory, resolved to its canonical path,
  and every ancestor must be owned by root or the invoking user and not
  writable by group or other**; the one exception is a directory like
  `/tmp`, sticky and world-writable with `fs.protected_symlinks` and
  `fs.protected_regular` on (a sticky directory that only its group can
  write gets no kernel protection and is refused). Any other directory is
  refused before anything is written, with the reason, and the backup is
  written by the canonical path, so a link in the literal path cannot be
  repointed after the check. No fleet caller backs up into a refused
  directory (every call site was checked: root-owned 0755/0700 system
  directories, or the invoking user's own home). What a caller sees is
  otherwise unchanged: the backup
  lands at exactly its path or `backup_file` dies, a file or link already
  there is replaced, a directory is refused, and with uutils `mv` so is a
  link to one. A run interrupted between the copy and the rename leaves
  `<file>.bak.XXXXXXXX` beside the backup; with `cleanup.sh` loaded it is
  removed at exit. The private name is nine characters longer than `.bak`,
  so a file whose name is within nine characters of the 255 limit can no
  longer be backed up.
- **`provision-report --verify` asks root for a yes or no.** The root
  existence probe for a file the invoking user cannot see used `test -e`'s
  exit status, where a 1 from `sudo` itself (a lapsed timestamp, a policy
  without `test`) read as MISSING. Root now answers in words, as
  `backup_file` already had it do; anything but yes or no is NOREAD.
- **`apt.sh` leaves no temporary file behind on an interrupt.** The fetched
  key and the readable copy of an installed keyring are registered with
  `cleanup.sh` when it is loaded; `apt_key_fingerprints` removes its
  throwaway GNUPGHOME from inside the subshell that runs gpg, so a Ctrl-C
  during gpg removes it as well.
- **Tests.** The three status-2 paths of `apt_add_repo` that had none (a
  keyring that cannot be moved aside, a keyring directory that cannot be
  created, a sources file that cannot be removed after a failed validation)
  have one. Seven negated assertions that could not fail (`! cmd` on any line
  but a test's last is ignored by `set -e`; shellcheck SC2314) are `run !`
  or `[[ ! … ]]` now.

## Changes in v1.8.0

Two new modules; nothing existing changes, so a consumer that uses neither can
move to this tag with no difference in its dist beyond the stamp.

`teardown.sh` is for a tool that replaces an installation it made earlier.
`snapshot_create <root> <name>` makes a root-owned 0700 directory
`<root>/<name>-<timestamp>`; `snapshot_add <path> [name]` copies a path into it
(`cp -a`) and registers it; `snapshot_remove_all [detail]` then removes each
registered path, journalled with where its copy is. Every failed copy is
fatal while nothing has been removed yet, and at removal a path goes only if
its copy is in the snapshot at that moment. `snapshot_register <path> <copy>`
adds a path the caller copied its own way. When a removal fails half way the
function named in `SNAPSHOT_ON_FAIL` is called with what failed and can read
`SNAPSHOT_REMOVED_SRC` / `SNAPSHOT_REMOVED_COPY`; without one, a generic report
lists what is gone and the `cp` commands that put it back
(`snapshot_failure_report`, which a handler may call before adding its own).
`unit_stop_disable <unit> <reason>` stops a unit that is active or failed,
clears a failed state and disables it, journalling each step; it returns 1
only when the stop itself failed. Which paths, what to check first and any
firewall cleanup stay with the caller. Snapshots hold whatever was copied,
private keys included, and are never pruned.

`mac.sh`: `mac_get <iface>` prints the current address; `mac_set <iface>
<mac>` takes the link down, sets the address and reads it back, returning a
distinct status for a malformed address (1), a link that would not go down
(2), an address the kernel rejected (3) and one it accepted but the interface
does not report (4). The link is left down, and where the original address is
kept is the caller's business.

## Changes in v1.7.1

`cleanup.sh` traps SIGHUP (`exit 129`), so a closed terminal or a dropped SSH
session runs the handlers; before, bash died on the default action and nothing
was torn down (a run under `nohup` still ignores HUP, as before). While the
handlers run, INT, TERM, HUP and PIPE are ignored — by the shell and by the
commands the handlers start — so a second Ctrl-C, a hangup arriving during a
Ctrl-C's teardown, or a log line written to a pipe whose reader has gone, no
longer ends it half way with the rest of the stack unrun. A script that tears
something down on Ctrl-C now does the same on a hangup. **A teardown that hangs can no longer be stopped
with Ctrl-C; SIGQUIT (Ctrl-\\) still stops it.** A script that set its own HUP
trap after sourcing `cleanup.sh` keeps it.

## Changes in v1.7.0

`log_open_transcript` no longer trusts the directory it is given (it used to
create it only when absent, never look at who owned an existing one, and
create the file with a root `touch`, `chown` and `chmod` that followed
symlinks). It now requires a directory only root, or only the invoking user,
can write — see *Run transcripts*. **A consumer still passing
`/var/log/<tool>/…` gets a warning and no transcript on Ubuntu**; switch the
call to `log_open_transcript "$(log_transcript_path <tool>)"`. Transcript
files are `0640`, not `0644`. New: `log_transcript_path`,
`LOG_TRANSCRIPT_ROOT`.

`apt_add_repo` sets the `.sources` file to `0644` itself; under a caller
umask of 077 it was left `0600`, unreadable to `_apt`, and rewritten on every
run.

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
