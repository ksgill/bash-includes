#!/usr/bin/env bats
# Unit tests for the pure parts of the library.
#
# Scope: functions with real logic and no side effects on the host — JSON
# escaping, manifest parsing, the .orig/.bak branch, the journal round trip.
# The provisioning functions are not usefully unit-testable; a container smoke
# test would tell you more than mocking apt.
#
# sudo is stubbed so everything runs unprivileged inside a temp tree.

# For `run !`. A bare `! cmd` does not fail a bats test unless it is the last
# line: set -e ignores a negated command (shellcheck SC2314).
bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    BIN="${BATS_TEST_DIRNAME}/../bin"
    TMP="$(mktemp -d)"
    # The journal hashes only world-readable content (other-read on the file,
    # other-execute on every ancestor). mktemp -d is 0700, and the caller's
    # umask may be 002 or 077, so pin both or every hashing test would see a
    # private file. This assumes TMPDIR's own ancestors are world-searchable,
    # as /tmp is.
    chmod 0755 "$TMP"
    umask 022

    # shellcheck disable=SC2317
    sudo() { case "${1:-}" in -v|-n) shift ;; esac; [[ $# -eq 0 ]] && return 0; "$@"; }
    export -f sudo

    export JOURNAL_DIR="${TMP}/var/lib/provision"
    export JOURNAL_FILE="${JOURNAL_DIR}/changes.jsonl"

    # shellcheck source=/dev/null
    . "${LIB}/log.sh"
    # cleanup.sh is deliberately NOT sourced here. It installs `trap _cleanup_run
    # EXIT` (plus INT/TERM handlers), and in the bats test process that replaces
    # the EXIT trap bats uses to emit the TAP result line — so a FAILING test
    # printed nothing at all, leaving only "Executed N instead of expected M".
    # The suite exited non-zero, but never said which test broke.
    #
    # Nothing here needs it: the two cleanup tests source it inside their own
    # `bash -c` subshells, and the only library callers (privilege.sh, oui.sh)
    # guard with `declare -f cleanup_push`.
    # shellcheck source=/dev/null
    . "${LIB}/journal.sh"
    # shellcheck source=/dev/null
    . "${LIB}/backup.sh"
    # shellcheck source=/dev/null
    . "${LIB}/apt.sh"
    # shellcheck source=/dev/null
    . "${LIB}/git.sh"
    # shellcheck source=/dev/null
    . "${LIB}/privilege.sh"
}

# git.sh writes into ~/.ssh and ~/.gitconfig, so every test below redirects HOME
# into the temp tree first. Without it the suite would rewrite the running
# user's real git identity and ssh config.
_git_home() {
    export HOME="${TMP}/home"
    mkdir -p "${HOME}"
    journal_init "test" "v1"
}

teardown() {
    # The FIFO race tests start a background writer; never leave it running.
    if [[ -f "${TMP}/yes.pid" ]]; then
        kill "$(cat "${TMP}/yes.pid")" 2>/dev/null || true
    fi
    rm -rf "${TMP}"
}

# ── _json_escape ──────────────────────────────────────────────────────────────

@test "_json_escape passes plain text through unchanged" {
    run _json_escape "plain text"
    [ "$output" = "plain text" ]
}

@test "_json_escape escapes double quotes" {
    run _json_escape 'say "hi"'
    [ "$output" = 'say \"hi\"' ]
}

@test "_json_escape escapes backslashes before quotes" {
    # Order matters: escaping quotes first would double-escape the backslash.
    run _json_escape 'a\b"c'
    [ "$output" = 'a\\b\"c' ]
}

@test "_json_escape escapes tabs" {
    run _json_escape "$(printf 'a\tb')"
    [ "$output" = 'a\tb' ]
}

# ── journal ───────────────────────────────────────────────────────────────────

@test "journal_record emits one valid JSON object per call" {
    journal_init "test" "v1.2.3"
    journal_record modify /etc/example "did a thing"
    journal_record install some-package "installed it"

    [ "$(wc -l < "$JOURNAL_FILE")" -eq 2 ]
    python3 -c "
import json,sys
for line in open('${JOURNAL_FILE}'):
    json.loads(line)
"
}

@test "journal_record records the version it was given" {
    journal_init "test" "v1.2.3"
    journal_record modify /etc/example "x"
    grep -q '"version":"v1.2.3"' "$JOURNAL_FILE"
}

@test "journal_record survives a detail containing quotes and backslashes" {
    journal_init "test" "v1"
    journal_record modify /etc/example 'quote " slash \ end'
    run python3 -c "
import json
d = json.loads(open('${JOURNAL_FILE}').readline())
print(d['detail'])
"
    [ "$output" = 'quote " slash \ end' ]
}

@test "journal_record hashes an existing target and omits the hash otherwise" {
    journal_init "test" "v1"
    printf 'content\n' > "${TMP}/f"
    journal_record modify "${TMP}/f" "real file"
    journal_record install not-a-file "package"

    grep -q '"sha256_after"' <(sed -n 1p "$JOURNAL_FILE")
    ! grep -q '"sha256_after"' <(sed -n 2p "$JOURNAL_FILE")
}

@test "journal_record never records file contents" {
    journal_init "test" "v1"
    printf 'SUPERSECRETVALUE\n' > "${TMP}/secret"
    journal_record modify "${TMP}/secret" "wrote credentials"
    ! grep -q SUPERSECRETVALUE "$JOURNAL_FILE"
}

# Every line of the journal must parse as a JSON object.
_journal_valid_json() {
    python3 -c 'import json,sys; [json.loads(l) for l in sys.stdin]' < "$JOURNAL_FILE"
}

@test "_json_escape escapes every control character JSON forbids raw" {
    run _json_escape $'a\001b\bc\fd\037e\x7ff'
    [ "$output" = 'a\u0001b\bc\fd\u001fe'$'\x7f''f' ]
}

@test "_json_escape escapes control characters under the C locale" {
    run env LC_ALL=C bash -c '. "$1/log.sh"; . "$1/journal.sh"; _json_escape $'"'"'x\001\033y'"'"'' _ "$LIB"
    [ "$output" = 'x\u0001\u001by' ]
}

@test "journal_record writes valid JSON for fields holding control characters" {
    journal_init "test" "v1"
    local s=$'ctl \001 bs \b ff \f esc \033 us \037 del \x7f tab \t nl \n cr \r end'
    journal_record modify "/etc/x${s}" "$s" "key${s}=val${s}"
    _journal_valid_json
    run python3 -c "
import json
d = json.loads(open('${JOURNAL_FILE}').readline())
print(d['detail'] == d['target'][len('/etc/x'):], end='')
"
    [ "$output" = "True" ]
    run python3 -c "
import json
print(json.loads(open('${JOURNAL_FILE}').readline())['detail'], end='')
"
    [ "$output" = "$s" ]
}

@test "journal_record hashes a file whose name holds a backslash and a newline" {
    # GNU sha256sum prefixes its line with a backslash for such a name when
    # given it as an argument; that prefix must not reach the journal.
    journal_init "test" "v1"
    local f="${TMP}/"$'back\\slash\nnewline'
    printf 'content\n' > "$f"
    journal_record modify "$f" "odd name"
    _journal_valid_json
    local want
    want="$(sha256sum < "$f")"
    want="${want%% *}"
    run python3 -c "
import json
print(json.loads(open('${JOURNAL_FILE}').readline())['sha256_after'], end='')
"
    [ "$output" = "$want" ]
}

@test "journal_record hashes only world-readable content, and never uses sudo" {
    # Any sudo call at all is a failure: hashing must not escalate.
    # shellcheck disable=SC2317
    sudo() { printf '%s\n' "$*" >> "${TMP}/sudo.calls"; return 1; }
    mkdir -m 0755 "${TMP}/pub"
    mkdir -m 0700 "${TMP}/priv"
    mkdir -m 0711 "${TMP}/xonly"
    printf 'a\n' > "${TMP}/pub/a.conf";   chmod 0644 "${TMP}/pub/a.conf"
    printf 'k\n' > "${TMP}/pub/key";      chmod 0600 "${TMP}/pub/key"
    printf 'g\n' > "${TMP}/pub/grp";      chmod 0640 "${TMP}/pub/grp"
    printf 'b\n' > "${TMP}/priv/b.conf";  chmod 0644 "${TMP}/priv/b.conf"
    printf 'c\n' > "${TMP}/xonly/c.conf"; chmod 0644 "${TMP}/xonly/c.conf"
    ln -s "${TMP}/priv/b.conf" "${TMP}/pub/link-to-priv"
    ln -s "${TMP}/pub/a.conf" "${TMP}/priv/link-to-pub"
    journal_init "test" "v1"
    local t
    for t in pub/a.conf pub/key pub/grp priv/b.conf xonly/c.conf \
             pub/link-to-priv priv/link-to-pub; do
        journal_record modify "${TMP}/${t}" "$t"
    done
    _journal_valid_json
    [ ! -e "${TMP}/sudo.calls" ]
    # target -> recorded hash, or "-" for none
    run python3 -c "
import json, os, sys
for l in open(os.environ['JOURNAL_FILE']):
    d = json.loads(l)
    print(d['detail'], d.get('sha256_after', '-'))
"
    local want_a want_c
    want_a="$(sha256sum < "${TMP}/pub/a.conf")"; want_a="${want_a%% *}"
    want_c="$(sha256sum < "${TMP}/xonly/c.conf")"; want_c="${want_c%% *}"
    [ "${lines[0]}" = "pub/a.conf ${want_a}" ]         # 0644 in 0755 dirs
    [ "${lines[1]}" = "pub/key -" ]                    # 0600
    [ "${lines[2]}" = "pub/grp -" ]                    # 0640, no other-read
    [ "${lines[3]}" = "priv/b.conf -" ]                # 0644 inside 0700
    [ "${lines[4]}" = "xonly/c.conf ${want_c}" ]       # 0711 dir: search is enough
    [ "${lines[5]}" = "pub/link-to-priv -" ]           # rule applies to the target
    [ "${lines[6]}" = "priv/link-to-pub ${want_a}" ]   # ...whichever way round
}

@test "journal_record_nohash records the change without a hash" {
    journal_init "test" "v1"
    printf 'private\n' > "${TMP}/key"
    journal_record_nohash create "${TMP}/key" "generated key" "kind=private"
    journal_record create "${TMP}/key" "same file, hashed"
    _journal_valid_json
    run ! grep -q '"sha256_after"' <(sed -n 1p "$JOURNAL_FILE")
    grep -q '"kind":"private"' <(sed -n 1p "$JOURNAL_FILE")
    grep -q '"target":"'"${TMP}"'/key"' <(sed -n 1p "$JOURNAL_FILE")
    # The opt-out is per call; it must not leak into the next record.
    grep -q '"sha256_after"' <(sed -n 2p "$JOURNAL_FILE")
}

@test "journal_record does not hash a bare-name target, even through a planted symlink" {
    printf 'public\n' > "${TMP}/public"
    mkdir "${TMP}/cwd"
    ln -s "${TMP}/public" "${TMP}/cwd/lxd"
    journal_init "test" "v1"
    (cd "${TMP}/cwd" && journal_record install lxd "snap installed")
    _journal_valid_json
    run ! grep -q '"sha256_after"' "$JOURNAL_FILE"
}

# Stand-in for the race: the first `stat` call (the mode check in _sha256_of)
# answers for the regular file, then swaps a FIFO in at the same path before
# the read. $1 = "idle" (no writer) or "firehose" (a writer that never stops:
# `yes` holds the FIFO open read-write, so the pipe is full before dd opens it).
_race_fifo_after_stat() {
    _RACE_FILE="$1"
    _RACE_KIND="$2"
    # shellcheck disable=SC2317
    stat() {
        local rc=0
        command stat "$@" || rc=$?
        if [[ ! -p "$_RACE_FILE" ]]; then
            if [[ "$_RACE_KIND" != firehose ]]; then
                rm -f "$_RACE_FILE"
                mkfifo -m 0644 "$_RACE_FILE"
            fi
            if [[ "$_RACE_KIND" == firehose ]]; then
                # The endless writer was started in the test's own shell on a
                # side FIFO; swap that FIFO in by rename, as an attacker would.
                # Starting it here instead, inside journal.sh's
                # `mapfile < <(stat …)`, hangs bash 5.2: the process
                # substitution does not finish while its background child
                # lives. A real writer is never our child.
                rm -f "$_RACE_FILE"
                mv -f -- "${_RACE_FILE}.side" "$_RACE_FILE"
            fi
        fi
        return "$rc"
    }
}

@test "journal_record does not hang when a FIFO is swapped in after the mode check" {
    printf 'regular\n' > "${TMP}/racy"
    run timeout 10 bash -c '
        set -euo pipefail
        . "$1/log.sh"; . "$1/journal.sh"
        eval "$2"
        _race_fifo_after_stat "$3" idle
        journal_init test v1
        journal_record modify "$3" "raced"
        echo survived
    ' _ "$LIB" "$(declare -f _race_fifo_after_stat)" "${TMP}/racy"
    [ "$status" -eq 0 ]
    [[ "$output" == *survived* ]]
    [ -p "${TMP}/racy" ]
    _journal_valid_json
}

@test "journal_record cuts off a FIFO whose writer never stops" {
    SECONDS=0
    printf 'regular\n' > "${TMP}/firehose"
    # The stub records the writer's pid under $TMP for teardown to kill.
    export TMP
    run timeout 20 bash -c '
        . "$1/log.sh"; . "$1/journal.sh"
        eval "$2"
        _race_fifo_after_stat "$3" firehose
        mkfifo -m 0644 "$3.side"
        # Never ends; fd 1 is the side FIFO (read-write, so the open cannot
        # block); nothing else of this shell is inherited.
        yes 1<>"$3.side" 2>/dev/null </dev/null 3>&- 4>&- &
        echo $! > "$TMP/yes.pid"
        _JOURNAL_HASH_TIMEOUT=2
        journal_init test v1
        journal_record modify "$3" "firehose"
        echo survived
    ' _ "$LIB" "$(declare -f _race_fifo_after_stat)" "${TMP}/firehose"
    # Printed only if the test fails: which of hang (124), signal or error.
    echo "status=$status after ${SECONDS}s; output: $output"
    # The writer really ran, so the cut-off was exercised, not skipped.
    [ -s "${TMP}/yes.pid" ]
    kill "$(cat "${TMP}/yes.pid")" 2>/dev/null || true
    [ "$status" -eq 0 ]
    [[ "$output" == *survived* ]]
    [ -p "${TMP}/firehose" ]
    run ! grep -q '"sha256_after"' "$JOURNAL_FILE"
}

@test "a hash timeout of 0 or garbage falls back to the default" {
    # timeout(1) treats 0 as "no limit", which would switch off the guard
    # against a FIFO whose writer never stops.
    printf 'x\n' > "${TMP}/pub.conf"
    local v
    export TMP
    for v in 0 00 abc -5 ''; do
        rm -f "${TMP}/timeout.calls"
        run bash -c '
            timeout() { printf "%s\n" "$*" >> "$TMP/timeout.calls"; command timeout "$@"; }
            . "$1/log.sh"; . "$1/journal.sh"
            _JOURNAL_HASH_TIMEOUT="$3"
            journal_init test v1 >/dev/null
            journal_record modify "$2" "t"
        ' _ "$LIB" "${TMP}/pub.conf" "$v"
        grep -q '^-k 2 60 dd ' "${TMP}/timeout.calls" \
            || { echo "value '$v': $(cat "${TMP}/timeout.calls" 2>&1)"; false; }
    done
}

@test "journal_record does not prompt for sudo when the timestamp has expired" {
    journal_init "test" "v1"
    # Pretend the journal needs root, and sudo's timestamp has run out: -n
    # fails, and anything without -n would have prompted.
    _JOURNAL_SUDO=1
    # shellcheck disable=SC2317
    sudo() {
        [[ "${1:-}" == -n ]] && return 1
        printf '%s\n' "$*" >> "${TMP}/prompted"
        return 1
    }
    run journal_record install some-package "x"
    [ "$status" -eq 0 ]
    [ ! -e "${TMP}/prompted" ]
    [[ "$output" == *"Could not write journal entry"* ]]
}

@test "journal_record stays non-fatal and hashless on an unreadable file" {
    [[ "$EUID" -eq 0 ]] && skip "root can read anywhere"
    printf 'x\n' > "${TMP}/locked"
    chmod 0000 "${TMP}/locked"
    # sudo is unavailable: the hash must be omitted, never empty or partial,
    # and the caller's set -euo pipefail must not be tripped.
    run bash -c '
        set -euo pipefail
        sudo() { return 1; }
        . "$1/log.sh"; . "$1/journal.sh"
        journal_init test v1
        journal_record modify "$2" "unreadable"
        echo survived
    ' _ "$LIB" "${TMP}/locked"
    chmod 0600 "${TMP}/locked"
    [ "$status" -eq 0 ]
    [[ "$output" == *survived* ]]
    [ "$(wc -l < "$JOURNAL_FILE")" -eq 1 ]
    _journal_valid_json
    run ! grep -q '"sha256_after"' "$JOURNAL_FILE"
}

@test "_journal_needs_sudo is false for a missing dir under a writable parent" {
    run _journal_needs_sudo "${TMP}/a/b/c"
    [ "$status" -eq 1 ]
}

@test "_journal_needs_sudo is true under a parent the user cannot write" {
    [[ "$EUID" -eq 0 ]] && skip "root can write anywhere"
    mkdir "${TMP}/ro"
    chmod 0555 "${TMP}/ro"
    run _journal_needs_sudo "${TMP}/ro/journal"
    chmod 0755 "${TMP}/ro"
    [ "$status" -eq 0 ]
}

@test "journal_init creates a per-user journal without sudo" {
    # shellcheck disable=SC2317
    sudo() { printf '%s\n' "$*" >> "${TMP}/sudo.log"; "$@"; }
    JOURNAL_DIR="${TMP}/home/.local/state/tool"
    JOURNAL_FILE=""
    journal_init "test" "v1"
    journal_record install some-package "x"
    [ ! -e "${TMP}/sudo.log" ]
    [ -O "${TMP}/home/.local" ]
    [ -O "${TMP}/home/.local/state" ]
    [ "$(wc -l < "$JOURNAL_FILE")" -eq 1 ]
}

@test "journal file and lock follow a JOURNAL_DIR set after sourcing" {
    JOURNAL_DIR="${TMP}/late"
    JOURNAL_FILE=""
    journal_init "test" "v1"
    [ "$JOURNAL_FILE" = "${TMP}/late/changes.jsonl" ]
    [ "$JOURNAL_LOCK" = "${TMP}/late/.lock" ]
    journal_record install some-package "x"
    [ "$(wc -l < "${TMP}/late/changes.jsonl")" -eq 1 ]
}

# ── backup_file ───────────────────────────────────────────────────────────────

@test "backup_file does nothing when the target does not exist" {
    journal_init "test" "v1"
    run backup_file "${TMP}/absent"
    [ "$status" -eq 0 ]
    [ ! -e "${TMP}/absent.orig" ]
    [ ! -e "${TMP}/absent.bak" ]
}

@test "backup_file uses .bak for a file no package tracks" {
    journal_init "test" "v1"
    printf 'v1\n' > "${TMP}/untracked.conf"
    backup_file "${TMP}/untracked.conf"
    [ -f "${TMP}/untracked.conf.bak" ]
    [ ! -e "${TMP}/untracked.conf.orig" ]
}

@test "backup_file writes .orig once, then .bak, and never overwrites .orig" {
    journal_init "test" "v1"
    printf 'pristine\n' > "${TMP}/app.conf"

    # Pretend the packaging system shipped exactly this content.
    _maintainer_md5() { md5sum < "${TMP}/shipped" | cut -d' ' -f1; }
    cp "${TMP}/app.conf" "${TMP}/shipped"

    backup_file "${TMP}/app.conf"          # pristine -> .orig
    printf 'edited\n' > "${TMP}/app.conf"
    backup_file "${TMP}/app.conf"          # no longer pristine -> .bak
    printf 'edited again\n' > "${TMP}/app.conf"
    backup_file "${TMP}/app.conf"          # -> .bak again, overwritten

    [ "$(cat "${TMP}/app.conf.orig")" = "pristine" ]
    [ "$(cat "${TMP}/app.conf.bak")"  = "edited again" ]
}

@test "backup_file preserves mode" {
    journal_init "test" "v1"
    printf 'x\n' > "${TMP}/perm.conf"
    chmod 0640 "${TMP}/perm.conf"
    backup_file "${TMP}/perm.conf"
    [ "$(stat -c %a "${TMP}/perm.conf.bak")" = "640" ]
}

@test "backup_file records the backup path in the journal" {
    journal_init "test" "v1"
    printf 'x\n' > "${TMP}/j.conf"
    backup_file "${TMP}/j.conf" "because"
    grep -q "\"backup\":\"${TMP}/j.conf.bak\"" "$JOURNAL_FILE"
}

# ── apt_add_repo: signing-key fingerprints ────────────────────────────────────
# Since v1.5.0 a caller must pin the signing key (--fingerprint) or say
# explicitly that it will not (--no-fingerprint). Both a downloaded key and an
# existing keyring must hold only pinned primary keys; a keyring that does not
# is moved aside, never used. wget and apt-get are stubbed; the two fixture
# keys are generated once for the file.

setup_file() {
    export APTKEYS="${BATS_FILE_TMPDIR}/aptkeys"
    mkdir -p "${APTKEYS}/gnupg"
    chmod 700 "${APTKEYS}/gnupg"
    local k
    for k in a b; do
        GNUPGHOME="${APTKEYS}/gnupg" gpg --batch --quiet --passphrase '' \
            --quick-gen-key "Fixture ${k} <${k}@example.invalid>" ed25519 sign never 2>/dev/null
        GNUPGHOME="${APTKEYS}/gnupg" gpg --batch --armor --export "${k}@example.invalid" > "${APTKEYS}/${k}.asc"
        GNUPGHOME="${APTKEYS}/gnupg" gpg --batch --export "${k}@example.invalid" > "${APTKEYS}/${k}.gpg"
        GNUPGHOME="${APTKEYS}/gnupg" gpg --batch --with-colons --fingerprint "${k}@example.invalid" \
            | awk -F: '/^fpr:/ { print $10; exit }' > "${APTKEYS}/${k}.fpr"
    done
    cat "${APTKEYS}/a.asc" "${APTKEYS}/b.asc" > "${APTKEYS}/ab.asc"
}

# Point the library at the temp tree and stub the network and apt. WGET_SERVES
# names the fixture the stubbed wget returns; WGET_CALLED records a download.
_apt_env() {
    APT_KEYRING_DIR="${TMP}/keyrings"
    APT_SOURCES_DIR="${TMP}/sources"
    mkdir -p "$APT_SOURCES_DIR"
    FPR_A="$(cat "${APTKEYS}/a.fpr")"
    FPR_B="$(cat "${APTKEYS}/b.fpr")"
    WGET_CALLED="${TMP}/wget.called"
    # shellcheck disable=SC2317
    wget() {
        local out="" url=""
        while [[ $# -gt 0 ]]; do
            case "$1" in -qO) out="$2"; shift 2 ;; *) url="$1"; shift ;; esac
        done
        : > "$WGET_CALLED"
        cp "${APTKEYS}/${WGET_SERVES}" "$out"
    }
    _apt_stub
}

# A stub apt-get and dpkg, for everything in apt.sh that runs them. apt-get
# must be a real executable on PATH, not a shell function: the library goes
# through `sudo env … apt-get`, and env execs binaries directly, so a function
# is invisible to it. State lives under APT_STUB:
#   calls            one line per apt-get run: LC_ALL, DEBIAN_FRONTEND, arguments
#   sleeps           one line per sleep the library asked for (sleep is stubbed)
#   dpkg/<pkg>       "<status> <version>": what the stubbed dpkg -l reports
#   provided/<pkg>   install exits 0 without installing it (a provided package)
#   version          the version install installs (default 1.0)
#   lock-failures    N: the next N updates fail on the lists lock
#   update-fail      every update fails, not on a lock
#   update-stderr    every update fails, printing this file on stderr
#   tmp-probe        each run appends the number of entries in TMPDIR to tmp-count
#   plus-names       names ending in + that are real packages, one per line
#   validate-fail    a scoped update (Dir::Etc::sourcelist) fails, not on a lock
#   change-fail      install, remove and purge fail, changing nothing
# LC_ALL and DEBIAN_FRONTEND are unset here so that what the stub logs is what
# the library passed, not what the test environment (a CI runner) exported.
_apt_stub() {
    export APT_STUB="${TMP}/aptstub"
    mkdir -p "${APT_STUB}/dpkg" "${APT_STUB}/provided" "${TMP}/bin"
    unset LC_ALL DEBIAN_FRONTEND
    cat > "${TMP}/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
set -u
printf 'LC_ALL=%s DEBIAN_FRONTEND=%s %s\n' "${LC_ALL:-unset}" "${DEBIAN_FRONTEND:-unset}" "$*" \
    >> "${APT_STUB}/calls"
if [[ -e "${APT_STUB}/tmp-probe" ]]; then
    find "${TMPDIR:-/tmp}" -mindepth 1 | wc -l >> "${APT_STUB}/tmp-count"
fi
action="" skip=0 ended=0
pkgs=()
plain='^[a-z0-9][a-z0-9+.:-]*$'
for a in "$@"; do
    if [[ "$skip" -eq 1 ]]; then skip=0; continue; fi
    if [[ "$ended" -eq 0 ]]; then
        case "$a" in
            --) ended=1; continue ;;
            -o|-t|-c|--target-release) skip=1; continue ;;
            -*) continue ;;
        esac
    fi
    if [[ -z "$action" ]]; then action="$a"; continue; fi
    # Like apt, only a plain name is a package to install as named: not a
    # local file, a glob, or a <pkg>- / <pkg>+ suffix form (unless a package
    # really has that name: plus-names lists those).
    case "$a" in /*|./*|../*|*.deb) continue ;; esac
    a="${a%%[=/]*}"
    [[ "$a" =~ $plain && "$a" != *- ]] || continue
    if [[ "$a" == *+ ]] && ! grep -qxF -- "$a" "${APT_STUB}/plus-names" 2>/dev/null; then continue; fi
    pkgs+=("$a")
done
case "$action" in
    update)
        if [[ -f "${APT_STUB}/update-stderr" ]]; then
            cat "${APT_STUB}/update-stderr" >&2
            exit 100
        fi
        if [[ -f "${APT_STUB}/lock-failures" ]]; then
            n="$(cat "${APT_STUB}/lock-failures")"
            if [[ "$n" -gt 0 ]]; then
                echo "$(( n - 1 ))" > "${APT_STUB}/lock-failures"
                echo "E: Could not get lock /var/lib/apt/lists/lock. It is held by process 1 (apt-get)" >&2
                exit 100
            fi
        fi
        if [[ -e "${APT_STUB}/update-fail" ]] \
                || { [[ -e "${APT_STUB}/validate-fail" && "$*" == *Dir::Etc::sourcelist=* ]]; }; then
            echo "E: The repository does not have a Release file." >&2
            exit 100
        fi
        echo "stub update done" ;;
    install|remove|purge)
        if [[ -e "${APT_STUB}/change-fail" ]]; then
            echo "E: Unable to correct problems, you have held broken packages." >&2
            exit 100
        fi
        version=1.0
        [[ -f "${APT_STUB}/version" ]] && version="$(cat "${APT_STUB}/version")"
        for p in ${pkgs[@]+"${pkgs[@]}"}; do
            case "$action" in
                install)
                    [[ -e "${APT_STUB}/provided/${p}" ]] \
                        || echo "ii ${version}" > "${APT_STUB}/dpkg/${p}" ;;
                remove)
                    if [[ -f "${APT_STUB}/dpkg/${p}" ]]; then
                        echo "rc ${version}" > "${APT_STUB}/dpkg/${p}"
                    fi ;;
                purge)
                    rm -f "${APT_STUB}/dpkg/${p}" ;;
            esac
        done ;;
esac
exit 0
STUB
    chmod +x "${TMP}/bin/apt-get"
    PATH="${TMP}/bin:${PATH}"

    # shellcheck disable=SC2317
    sleep() { printf 'sleep %s\n' "$*" >> "${APT_STUB}/sleeps"; }
    # The shape of `dpkg -l <pkg>`: header lines, then status, name, version.
    # shellcheck disable=SC2317
    dpkg() {
        local st ver listed
        [[ "${1:-}" == -l && -f "${APT_STUB}/dpkg/${2:-}" ]] || return 1
        read -r st ver listed < "${APT_STUB}/dpkg/$2"
        printf '%s\n' 'Desired=Unknown/Install/Remove/Purge/Hold' '||/ Name  Version  Architecture  Description'
        printf '%s  %s  %s  all  stub package\n' "$st" "${listed:-$2}" "$ver"
    }
}

# _pkg_is <package> <status> [version] [listed-as] — set what the stubbed dpkg
# reports when asked for <package>. dpkg lists a package with or without an
# architecture qualifier whichever form it was asked for; [listed-as] is the
# name in its listing when that differs from the name asked for.
_pkg_is() {
    echo "$2 ${3:-1.0} ${4:-}" > "${APT_STUB}/dpkg/$1"
}

# _verify — provision-report --verify over the test journal.
_verify() {
    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --verify
}

# _calls — the apt-get runs so far, one per line; _journal — the records.
_calls() { cat "${APT_STUB}/calls" 2>/dev/null || true; }
_journal() { cat "$JOURNAL_FILE" 2>/dev/null || true; }

_add() {
    apt_add_repo "$@" fixture 'https://example.invalid/key' 'https://example.invalid/repo' stable
}

@test "apt_add_repo refuses a call with neither --fingerprint nor --no-fingerprint" {
    _apt_env; WGET_SERVES=a.asc
    run _add
    [ "$status" -ne 0 ]
    [[ "$output" == *"pass --fingerprint"* ]]
    [ ! -e "$WGET_CALLED" ]
}

@test "apt_add_repo refuses --fingerprint together with --no-fingerprint" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint "$FPR_A" --no-fingerprint
    [ "$status" -ne 0 ]
    [[ "$output" == *"mutually exclusive"* ]]
}

@test "apt_add_repo rejects a malformed fingerprint" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint 'E158C569'
    [ "$status" -ne 0 ]
    [[ "$output" == *"not a key fingerprint"* ]]
}

@test "apt_add_repo installs a served key that matches the pin" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    [ "$(apt_key_fingerprints "${APT_KEYRING_DIR}/fixture.gpg")" = "$FPR_A" ]
    grep -qxF "Signed-By: ${APT_KEYRING_DIR}/fixture.gpg" "${APT_SOURCES_DIR}/fixture.sources"
}

@test "apt_add_repo installs a binary (non-armoured) key as served" {
    _apt_env; WGET_SERVES=a.gpg
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    cmp "${APTKEYS}/a.gpg" "${APT_KEYRING_DIR}/fixture.gpg"
}

@test "apt_add_repo refuses a served key that is not pinned, and installs nothing" {
    _apt_env; WGET_SERVES=b.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -ne 0 ]
    [[ "$output" == *"not the pinned key"* ]]
    [ ! -e "${APT_KEYRING_DIR}/fixture.gpg" ]
    [ ! -e "${APT_SOURCES_DIR}/fixture.sources" ]
}

@test "apt_add_repo refuses a bundle carrying an extra, unpinned key" {
    _apt_env; WGET_SERVES=ab.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -ne 0 ]
    [ ! -e "${APT_KEYRING_DIR}/fixture.gpg" ]
}

@test "apt_add_repo accepts a bundle when every key is pinned, spaces and case ignored" {
    _apt_env; WGET_SERVES=ab.asc
    local list
    list="$(tr '[:upper:]' '[:lower:]' <<< "$FPR_A"), $(sed 's/.\{4\}/& /g' <<< "$FPR_B")"
    run _add --fingerprint "$list"
    [ "$status" -eq 0 ]
    [ "$(apt_key_fingerprints "${APT_KEYRING_DIR}/fixture.gpg" | sort | paste -sd, -)" = \
      "$(printf '%s\n' "$FPR_A" "$FPR_B" | sort | paste -sd, -)" ]
}

@test "apt_add_repo moves a mismatched existing keyring aside and fetches again" {
    _apt_env; WGET_SERVES=a.asc
    mkdir -p "$APT_KEYRING_DIR"
    cp "${APTKEYS}/b.gpg" "${APT_KEYRING_DIR}/fixture.gpg"
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    [ "$(apt_key_fingerprints "${APT_KEYRING_DIR}/fixture.gpg")" = "$FPR_A" ]
    ls "${APT_KEYRING_DIR}"/fixture.gpg.untrusted.* >/dev/null
    [ -e "$WGET_CALLED" ]
}

@test "apt_add_repo leaves a correctly configured, pinned repo alone" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    rm -f "$WGET_CALLED"
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured"* ]]
    [ ! -e "$WGET_CALLED" ]
}

@test "apt_add_repo refuses a glob as a fingerprint without expanding it" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint '*'
    [ "$status" -ne 0 ]
    [[ "$output" == *"'*' is not a key fingerprint"* ]]
}

@test "apt_add_repo leaves the keyring world-readable under a restrictive umask" {
    _apt_env; WGET_SERVES=a.asc
    # run executes in a subshell, so the umask does not leak out of the test.
    _add_umask077() { umask 077; _add "$@"; }
    run _add_umask077 --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    [ "$(stat -c %a "${APT_KEYRING_DIR}/fixture.gpg")" = 644 ]
}

@test "apt_add_repo --no-fingerprint installs whatever is served, with a warning" {
    _apt_env; WGET_SERVES=b.asc
    run _add --no-fingerprint
    [ "$status" -eq 0 ]
    [[ "$output" == *"--no-fingerprint"* ]]
    [ "$(apt_key_fingerprints "${APT_KEYRING_DIR}/fixture.gpg")" = "$FPR_B" ]
}

# ── apt_install_list parsing ──────────────────────────────────────────────────

@test "apt_install_list skips comments, blanks and whitespace" {
    cat > "${TMP}/pkgs.list" <<'LIST'
# a comment
alpha

  beta
gamma   # trailing comment

#delta
LIST

    # The stub must be a real executable on PATH, not a shell function:
    # apt_install_list goes through `sudo env … apt-get`, and env execs
    # binaries directly, so an exported bash function is invisible to it.
    mkdir -p "${TMP}/bin"
    cat > "${TMP}/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
STUB
    chmod +x "${TMP}/bin/apt-get"
    PATH="${TMP}/bin:${PATH}"

    run apt_install_list "${TMP}/pkgs.list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"3 packages"* ]]
    [[ "$output" == *alpha* && "$output" == *beta* && "$output" == *gamma* ]]
    [[ "$output" != *delta* ]]
}

@test "apt_install_list reads a last line that has no trailing newline" {
    printf 'alpha\nbeta' > "${TMP}/pkgs.list"
    mkdir -p "${TMP}/bin"
    cat > "${TMP}/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@"
STUB
    chmod +x "${TMP}/bin/apt-get"
    PATH="${TMP}/bin:${PATH}"

    run apt_install_list "${TMP}/pkgs.list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 packages"* ]]
    [[ "$output" == *beta* ]]
}

@test "apt_install_list fails loudly on a missing manifest" {
    run apt_install_list "${TMP}/nope.list"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Package list not found"* ]]
}

@test "apt_install_list waits for the dpkg lock and journals one record per package it installed" {
    _apt_stub
    journal_init "test" "v1"
    _pkg_is alpha ii
    printf '%s\n' alpha beta gamma > "${TMP}/pkgs.list"
    run apt_install_list "${TMP}/pkgs.list"
    [ "$status" -eq 0 ]
    [ "$(_calls | grep -c 'DPkg::Lock::Timeout=1200')" -eq 1 ]
    [ "$(_journal | wc -l)" -eq 2 ]
    [ "$(_journal | grep -c '"action":"install","target":"beta","detail":"package list pkgs.list ')" -eq 1 ]
    [ "$(_journal | grep -c '"action":"install","target":"gamma"')" -eq 1 ]
}

# ── apt locks ─────────────────────────────────────────────────────────────────
# On a freshly booted host another apt process usually holds one of apt's two
# locks. Installs, removes and purges pass apt's own dpkg-lock timeout; updates
# go through apt_update_wait, which retries on the lists lock.

@test "APT_LOCK_WAIT and APT_LOCK_RETRY default to 1200 and 10" {
    [ "$APT_LOCK_WAIT" -eq 1200 ]
    [ "$APT_LOCK_RETRY" -eq 10 ]
}

@test "APT_LOCK_WAIT and APT_LOCK_RETRY set before sourcing are kept" {
    run bash -c 'APT_LOCK_WAIT=60; APT_LOCK_RETRY=2; . "$1/log.sh"; . "$1/apt.sh"; echo "${APT_LOCK_WAIT} ${APT_LOCK_RETRY}"' _ "$LIB"
    [ "$status" -eq 0 ]
    [ "$output" = "60 2" ]
}

@test "apt_lock_wait_message names the wait in minutes" {
    APT_LOCK_WAIT=600
    run apt_lock_wait_message
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to 10 minutes"* ]]
    [ "${#lines[@]}" -eq 1 ]
}

@test "apt_update_wait retries while apt reports the lists lock, says so once, then succeeds" {
    _apt_stub
    echo 2 > "${APT_STUB}/lock-failures"
    run apt_update_wait -qq
    [ "$status" -eq 0 ]
    [ "$(_calls | wc -l)" -eq 3 ]
    [ "$(_calls | grep -c '^LC_ALL=C DEBIAN_FRONTEND=unset update -qq$')" -eq 3 ]
    [ "$(grep -c '^sleep 10$' "${APT_STUB}/sleeps")" -eq 2 ]
    [ "$(grep -c 'holds the package lists lock' <<< "$output")" -eq 1 ]
    [[ "$output" == *"[INFO]"*"holds the package lists lock"* ]]
    [[ "$output" == *"stub update done"* ]]
    # The lock errors of the attempts that were retried are not shown.
    [[ "$output" != *"Could not get lock"* ]]
}

@test "apt_update_wait returns a failure that is not a lock at once, with apt's status" {
    _apt_stub
    : > "${APT_STUB}/update-fail"
    run apt_update_wait
    [ "$status" -eq 100 ]
    [ "$(_calls | wc -l)" -eq 1 ]
    [ ! -e "${APT_STUB}/sleeps" ]
    [[ "$output" == *"does not have a Release file"* ]]
    [[ "$output" != *"holds the package lists lock"* ]]
}

@test "apt_update_wait gives up after APT_LOCK_WAIT seconds of waiting, with apt's status" {
    _apt_stub
    echo 99 > "${APT_STUB}/lock-failures"
    APT_LOCK_WAIT=30
    APT_LOCK_RETRY=10
    run apt_update_wait
    [ "$status" -eq 100 ]
    [ "$(_calls | wc -l)" -eq 4 ]
    [ "$(grep -c '^sleep 10$' "${APT_STUB}/sleeps")" -eq 3 ]
    [ "$(grep -c 'holds the package lists lock' <<< "$output")" -eq 1 ]
    [ "$(grep -c 'Could not get lock' <<< "$output")" -eq 1 ]
}

@test "apt_update_wait sends the waiting line to APT_WAIT_NOTICE_FD when set" {
    _apt_stub
    echo 1 > "${APT_STUB}/lock-failures"
    local out
    { out="$(APT_WAIT_NOTICE_FD=4 apt_update_wait 2>&1)"; } 4> "${TMP}/notice"
    grep -q 'holds the package lists lock' "${TMP}/notice"
    [[ "$out" != *"holds the package lists lock"* ]]
    [[ "$out" == *"stub update done"* ]]
}

@test "apt_update_wait does not take the phrase in the middle of a line for a lock" {
    _apt_stub
    echo 'E: Failed to fetch https://example.invalid/InRelease  Could not get lock on the mirror' > "${APT_STUB}/update-stderr"
    run apt_update_wait
    [ "$status" -eq 100 ]
    [ "$(_calls | wc -l)" -eq 1 ]
    [ ! -e "${APT_STUB}/sleeps" ]
    [[ "$output" != *"holds the package lists lock"* ]]
    [[ "$output" == *"Failed to fetch"* ]]
}

@test "apt_update_wait retries on apt's lock line whichever path it names" {
    _apt_stub
    APT_LOCK_WAIT=10
    printf '%s\n' 'E: Could not get lock /var/lib/apt/lists/ - open (11: Resource temporarily unavailable)' \
        'E: Unable to lock directory /var/lib/apt/lists/' > "${APT_STUB}/update-stderr"
    run apt_update_wait
    [ "$status" -eq 100 ]
    [ "$(_calls | wc -l)" -eq 2 ]
    [ "$(grep -c '^sleep 10$' "${APT_STUB}/sleeps")" -eq 1 ]
}

@test "apt_update_wait does not retry when apt may not open the lock" {
    _apt_stub
    printf '%s\n' 'E: Could not open lock file /var/lib/apt/lists/lock - open (13: Permission denied)' \
        'E: Unable to lock directory /var/lib/apt/lists/' > "${APT_STUB}/update-stderr"
    run apt_update_wait
    [ "$status" -eq 100 ]
    [ "$(_calls | wc -l)" -eq 1 ]
    [ ! -e "${APT_STUB}/sleeps" ]
}

@test "apt_update_wait leaves no temporary file, during the update or after it" {
    _apt_stub
    export TMPDIR="${TMP}/tmpdir"
    mkdir -p "$TMPDIR"
    : > "${APT_STUB}/tmp-probe"
    echo 1 > "${APT_STUB}/lock-failures"
    run apt_update_wait
    [ "$status" -eq 0 ]
    # Nothing there while apt-get ran (an interrupt then leaves nothing)…
    [ "$(sort -u "${APT_STUB}/tmp-count" | tr -d ' ')" = "0" ]
    [ "$(wc -l < "${APT_STUB}/tmp-count")" -eq 2 ]
    # …and nothing after, on the failed path either.
    : > "${APT_STUB}/update-fail"
    run apt_update_wait
    [ "$status" -eq 100 ]
    [ "$(find "$TMPDIR" -mindepth 1 | wc -l)" -eq 0 ]
}

@test "APT_LOCK_RETRY=0 falls back to 10 with one warning instead of spinning" {
    _apt_stub
    echo 99 > "${APT_STUB}/lock-failures"
    _twice() { APT_LOCK_WAIT=20; APT_LOCK_RETRY=0; apt_update_wait; echo "first: $?"; apt_update_wait; echo "second: $?"; }
    run _twice
    [ "$status" -eq 0 ]
    [[ "$output" == *"first: 100"* ]]
    [[ "$output" == *"second: 100"* ]]
    [ "$(grep -c "APT_LOCK_RETRY='0' is not a positive number" <<< "$output")" -eq 1 ]
    # Two calls, each one attempt plus two retries ten seconds apart.
    [ "$(_calls | wc -l)" -eq 6 ]
    [ "$(grep -c '^sleep 10$' "${APT_STUB}/sleeps")" -eq 4 ]
    [ "$(wc -l < "${APT_STUB}/sleeps")" -eq 4 ]
}

@test "a non-numeric APT_LOCK_WAIT falls back to 1200 with a warning and never reaches apt or arithmetic" {
    _apt_stub
    # An array subscript in arithmetic would run the command substitution.
    APT_LOCK_WAIT="x[\$(touch ${TMP}/pwned)]"
    run apt_install alpha
    [ "$status" -eq 0 ]
    [ "$(grep -c "is not a number of seconds; using 1200" <<< "$output")" -eq 1 ]
    _calls | grep -q ' install -y -o DPkg::Lock::Timeout=1200 alpha$'
    run apt_lock_wait_message
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to 20 minutes"* ]]
    echo 1 > "${APT_STUB}/lock-failures"
    run apt_update_wait
    [ "$status" -eq 0 ]
    [[ "$output" == *"up to 20 minutes"* ]]
    [ ! -e "${TMP}/pwned" ]
}

@test "apt_update_wait survives an APT_WAIT_NOTICE_FD that is not open, or not a number" {
    _apt_stub
    _strict() { set -euo pipefail; APT_WAIT_NOTICE_FD="$1" apt_update_wait; echo "returned $?"; }
    echo 1 > "${APT_STUB}/lock-failures"
    run _strict 97
    [ "$status" -eq 0 ]
    [[ "$output" == *"returned 0"* ]]
    [ "$(grep -c 'holds the package lists lock' <<< "$output")" -eq 1 ]
    echo 1 > "${APT_STUB}/lock-failures"
    run _strict '2; echo injected'
    [ "$status" -eq 0 ]
    [[ "$output" == *"returned 0"* ]]
    [ "$(grep -c 'holds the package lists lock' <<< "$output")" -eq 1 ]
    [[ "$output" != *injected* ]]
}

@test "apt_install passes the dpkg lock timeout, non-interactively" {
    _apt_stub
    run apt_install alpha
    [ "$status" -eq 0 ]
    [ "$(_calls | wc -l)" -eq 1 ]
    _calls | grep -q '^LC_ALL=unset DEBIAN_FRONTEND=noninteractive install -y -o DPkg::Lock::Timeout=1200 alpha$'
}

@test "apt_remove passes the dpkg lock timeout, non-interactively" {
    _apt_stub
    _pkg_is alpha ii
    APT_LOCK_WAIT=300
    run apt_remove alpha
    [ "$status" -eq 0 ]
    [ "$(_calls | wc -l)" -eq 1 ]
    _calls | grep -q '^LC_ALL=unset DEBIAN_FRONTEND=noninteractive remove -y -o DPkg::Lock::Timeout=300 alpha$'
}

@test "apt_purge passes the dpkg lock timeout, non-interactively" {
    _apt_stub
    _pkg_is alpha ii
    run apt_purge alpha
    [ "$status" -eq 0 ]
    [ "$(_calls | wc -l)" -eq 1 ]
    _calls | grep -q '^LC_ALL=unset DEBIAN_FRONTEND=noninteractive purge -y -o DPkg::Lock::Timeout=1200 alpha$'
}

# ── apt_change and its wrappers: journal only what changed ────────────────────
# apt-get exits 0 for a package it leaves alone, so "apt succeeded" is not
# "this was installed". The journal follows dpkg's state before and after.

@test "apt_pkg_state prints status and version, and nothing for an unknown package" {
    _apt_stub
    _pkg_is alpha ii 2.4-1
    run apt_pkg_state alpha
    [ "$status" -eq 0 ]
    [ "$output" = "ii 2.4-1" ]
    run apt_pkg_state nosuch
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "apt_pkg_state matches a name with or without the architecture qualifier on either side" {
    _apt_stub
    # Asked for with a qualifier, listed without one.
    _pkg_is alpha:amd64 ii 1.1 alpha
    run apt_pkg_state alpha:amd64
    [ "$status" -eq 0 ]
    [ "$output" = "ii 1.1" ]
    # Asked for without a qualifier, listed with one.
    _pkg_is beta ii 1.2 beta:amd64
    run apt_pkg_state beta
    [ "$status" -eq 0 ]
    [ "$output" = "ii 1.2" ]
    # Both qualified and the same.
    _pkg_is gamma:arm64 ii 1.3 gamma:arm64
    run apt_pkg_state gamma:arm64
    [ "$output" = "ii 1.3" ]
    # Two different architectures are not the same package.
    _pkg_is delta:arm64 ii 1.4 delta:amd64
    run apt_pkg_state delta:arm64
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    # A longer name that merely starts with the one asked for is not a match.
    _pkg_is eps ii 1.5 epsilon
    run apt_pkg_state eps
    [ -z "$output" ]
}

@test "apt_install sees a package asked for with an architecture that dpkg lists without one as installed" {
    _apt_stub
    journal_init "test" "v1"
    : > "${APT_STUB}/provided/alpha:amd64"
    _pkg_is alpha:amd64 ii 1.0 alpha
    run apt_install alpha:amd64
    [ "$status" -eq 0 ]
    [[ "$output" != *"did not install"* ]]
    [ "$(_journal | wc -l)" -eq 0 ]
}

@test "apt_install journals nothing for a package that is already installed" {
    _apt_stub
    journal_init "test" "v1"
    _pkg_is alpha ii
    run apt_install alpha
    [ "$status" -eq 0 ]
    [ "$(_calls | wc -l)" -eq 1 ]
    [ "$(_journal | wc -l)" -eq 0 ]
    [[ "$output" != *"[WARN]"* ]]
}

@test "apt_install journals one record, with both states, for each package it installed" {
    _apt_stub
    journal_init "test" "v1"
    _pkg_is alpha ii
    run apt_install alpha beta
    [ "$status" -eq 0 ]
    _calls | grep -q ' alpha beta$'
    [ "$(_journal | wc -l)" -eq 1 ]
    [ "$(_journal | grep -c '"action":"install","target":"beta"')" -eq 1 ]
    _journal | grep -qF '(dpkg: not known -> ii 1.0)'
    _journal | grep -qF '"operation":"install","before":"not known","after":"ii 1.0"'
}

@test "apt_install journals an upgrade: the version changed" {
    _apt_stub
    journal_init "test" "v1"
    _pkg_is alpha ii 0.9
    run apt_install alpha
    [ "$status" -eq 0 ]
    [ "$(_journal | wc -l)" -eq 1 ]
    _journal | grep -qF '"before":"ii 0.9","after":"ii 1.0"'
}

@test "apt_install warns about a provided package and does not record or die" {
    _apt_stub
    journal_init "test" "v1"
    : > "${APT_STUB}/provided/virtualpkg"
    run apt_install virtualpkg beta
    [ "$status" -eq 0 ]
    [[ "$output" == *"[WARN]"*"did not install 'virtualpkg'"* ]]
    [[ "$output" != *"did not install 'beta'"* ]]
    [ "$(_journal | wc -l)" -eq 1 ]
    [ "$(_journal | grep -c '"target":"virtualpkg"')" -eq 0 ]
    [ "$(_journal | grep -c '"target":"beta"')" -eq 1 ]
}

@test "apt_install passes the options before -- to apt-get, and tracks a versioned package by name" {
    _apt_stub
    journal_init "test" "v1"
    run apt_install --no-install-recommends --allow-downgrades -- alpha=1.0 beta
    [ "$status" -eq 0 ]
    _calls | grep -q ' install -y -o DPkg::Lock::Timeout=1200 --no-install-recommends --allow-downgrades -- alpha=1.0 beta$'
    [ "$(_journal | wc -l)" -eq 2 ]
    [ "$(_journal | grep -c '"action":"install","target":"alpha"')" -eq 1 ]
    [ "$(_journal | grep -c '"action":"install","target":"beta"')" -eq 1 ]
}

@test "apt_install --reason sets the journal detail and is not passed to apt-get" {
    _apt_stub
    journal_init "test" "v1"
    run apt_install --reason "needed by the widget" alpha
    [ "$status" -eq 0 ]
    [ "$(_calls | grep -c 'reason\|widget')" -eq 0 ]
    _calls | grep -q ' alpha$'
    _journal | grep -qF '"target":"alpha","detail":"needed by the widget (dpkg: not known -> ii 1.0)"'

    run apt_install --no-install-recommends --reason="second form" -- beta
    [ "$status" -eq 0 ]
    [ "$(_calls | grep -c 'reason\|second')" -eq 0 ]
    _calls | grep -q ' --no-install-recommends -- beta$'
    _journal | grep -qF '"target":"beta","detail":"second form (dpkg: not known -> ii 1.0)"'
}

@test "apt_install passes the caller's -- on to apt-get, and not when the caller gave none" {
    _apt_stub
    run apt_install -- alpha
    [ "$status" -eq 0 ]
    _calls | grep -q ' install -y -o DPkg::Lock::Timeout=1200 -- alpha$'
    run apt_remove --reason "gone" -- alpha
    [ "$status" -eq 0 ]
    _calls | grep -q ' remove -y -o DPkg::Lock::Timeout=1200 -- alpha$'
    run apt_purge -- alpha
    [ "$status" -eq 0 ]
    _calls | grep -q ' purge -y -o DPkg::Lock::Timeout=1200 -- alpha$'
    # The form without a -- is passed as it always was.
    run apt_install beta
    [ "$status" -eq 0 ]
    _calls | grep -q ' install -y -o DPkg::Lock::Timeout=1200 beta$'
}

@test "apt_install_list refuses a line that is not a package name, and runs nothing" {
    _apt_stub
    printf '%s\n' '# tools' alpha '-oFoo::Bar=1' beta > "${TMP}/pkgs.list"
    run apt_install_list "${TMP}/pkgs.list"
    [ "$status" -eq 1 ]
    [[ "$output" == *"${TMP}/pkgs.list: line 3 is not one package name: '-oFoo::Bar=1'"* ]]
    [ "$(_calls | wc -l)" -eq 0 ]
}

@test "apt_install_list refuses two names on one line, naming the line as written" {
    _apt_stub
    printf '%s\n' alpha '  foo bar  # two of them' beta > "${TMP}/pkgs.list"
    run apt_install_list "${TMP}/pkgs.list"
    [ "$status" -eq 1 ]
    [[ "$output" == *"${TMP}/pkgs.list: line 2 is not one package name: '  foo bar  # two of them'"* ]]
    [[ "$output" != *foobar* ]]
    [ "$(_calls | wc -l)" -eq 0 ]
}

@test "apt_install_list refuses a removal suffix, a glob, a path and an upper-case name" {
    _apt_stub
    local bad
    for bad in 'beta-' 'beta-=1.0' 'lib*' 'lib?' 'lib[ab]' './local.deb' '/tmp/x.deb' 'Alpha' 'alpha=1.0*' 'alpha/' 'alpha:'; do
        printf '%s\n' alpha "$bad" > "${TMP}/pkgs.list"
        run apt_install_list "${TMP}/pkgs.list"
        [ "$status" -eq 1 ]
        [[ "$output" == *"line 2 is not one package name: '${bad}'"* ]]
    done
    [ "$(_calls | wc -l)" -eq 0 ]
}

@test "apt_install_list accepts a name with an architecture, a version or a release" {
    _apt_stub
    printf '%s\n' 'alpha:amd64' ' beta=1:2.0-1~rc1+b2 ' 'gamma/some-backports  # pinned' 'g++' 'lib2.0-x' > "${TMP}/pkgs.list"
    run apt_install_list "${TMP}/pkgs.list"
    [ "$status" -eq 0 ]
    [[ "$output" == *"5 packages"* ]]
    _calls | grep -qF ' -- alpha:amd64 beta=1:2.0-1~rc1+b2 gamma/some-backports g++ lib2.0-x'
}

@test "apt_install_list passes its packages to apt-get after a --" {
    _apt_stub
    printf '%s\n' alpha beta > "${TMP}/pkgs.list"
    run apt_install_list "${TMP}/pkgs.list"
    [ "$status" -eq 0 ]
    _calls | grep -q ' install -y -o DPkg::Lock::Timeout=1200 -- alpha beta$'
}

@test "apt_change refuses --reason with no value before the --" {
    _apt_stub
    run apt_change install --reason -- alpha
    [ "$status" -eq 2 ]
    [[ "$output" == *"--reason needs a value"* ]]
    [ "$(_calls | wc -l)" -eq 0 ]
    run apt_change install --reason
    [ "$status" -eq 2 ]
    [[ "$output" == *"--reason needs a value"* ]]
}

@test "apt_change refuses a bare word before the --: a misplaced package" {
    _apt_stub
    run apt_change install --no-install-recommends alpha -- beta
    [ "$status" -eq 2 ]
    [[ "$output" == *"'alpha' is before the -- but is not an option"* ]]
    [ "$(_calls | wc -l)" -eq 0 ]
    # An option outside the four known to take a separate value needs it attached.
    run apt_change install --solver internal -- beta
    [ "$status" -eq 2 ]
    [[ "$output" == *"'internal' is before the -- but is not an option"* ]]
    [ "$(_calls | wc -l)" -eq 0 ]
}

@test "apt_change takes the separate value of -t, -o, -c and --target-release with its option" {
    _apt_stub
    journal_init "test" "v1"
    run apt_change install -t backports -o Foo::Bar=1 -c "${TMP}/apt.conf" --target-release other --solver=internal -- alpha
    [ "$status" -eq 0 ]
    _calls | grep -qF " -t backports -o Foo::Bar=1 -c ${TMP}/apt.conf --target-release other --solver=internal -- alpha"
    [ "$(_journal | wc -l)" -eq 1 ]
    [ "$(_journal | grep -c '"action":"install","target":"alpha"')" -eq 1 ]
    # One of them with nothing after it but the -- has no value.
    run apt_change install -t -- alpha
    [ "$status" -eq 2 ]
    [[ "$output" == *"-t needs a value"* ]]
}

@test "apt_install passes a local .deb, a glob and the - and + suffix forms untracked and unwarned" {
    _apt_stub
    journal_init "test" "v1"
    run apt_install -- ./local.deb "${TMP}/other.deb" 'lib*' beta- gamma+ alpha
    [ "$status" -eq 0 ]
    _calls | grep -qF " -- ./local.deb ${TMP}/other.deb lib* beta- gamma+ alpha"
    [[ "$output" != *"did not install"* ]]
    [ "$(_journal | wc -l)" -eq 1 ]
    [ "$(_journal | grep -c '"action":"install","target":"alpha"')" -eq 1 ]
}

@test "apt_install tracks a package whose name really ends in +" {
    _apt_stub
    journal_init "test" "v1"
    echo 'g++' > "${APT_STUB}/plus-names"
    run apt_install 'g++'
    [ "$status" -eq 0 ]
    [[ "$output" != *"did not install"* ]]
    [ "$(_journal | grep -c '"action":"install","target":"g++"')" -eq 1 ]
}

@test "apt_install still tracks <name>/<release> by name" {
    _apt_stub
    journal_init "test" "v1"
    run apt_install alpha/backports
    [ "$status" -eq 0 ]
    [ "$(_journal | grep -c '"action":"install","target":"alpha"')" -eq 1 ]
}

@test "apt_install with no packages runs nothing" {
    _apt_stub
    run apt_install
    [ "$status" -eq 0 ]
    run apt_install --reason "nothing to do" --
    [ "$status" -eq 0 ]
    [ "$(_calls | wc -l)" -eq 0 ]
}

@test "apt_change returns apt-get's status; apt_install, apt_remove and apt_purge die" {
    _apt_stub
    journal_init "test" "v1"
    : > "${APT_STUB}/change-fail"
    _after_change() { apt_change "$@" || echo "returned $?"; echo "still running"; }
    run _after_change install alpha
    [ "$status" -eq 0 ]
    [[ "$output" == *"returned 100"* ]]
    [[ "$output" == *"still running"* ]]

    _after_wrapper() { "$@"; echo "still running"; }
    run _after_wrapper apt_install alpha
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to install: alpha"* ]]
    [[ "$output" != *"still running"* ]]
    run _after_wrapper apt_remove alpha
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to remove: alpha"* ]]
    run _after_wrapper apt_purge alpha
    [ "$status" -eq 1 ]
    [[ "$output" == *"Failed to purge: alpha"* ]]
    [ "$(_journal | wc -l)" -eq 0 ]
}

@test "apt_change refuses an unknown action without running apt-get" {
    _apt_stub
    run apt_change upgrade alpha
    [ "$status" -eq 2 ]
    [[ "$output" == *"unknown action 'upgrade'"* ]]
    [ "$(_calls | wc -l)" -eq 0 ]
}

@test "apt_remove journals a removal, and nothing for a package that was not installed" {
    _apt_stub
    journal_init "test" "v1"
    _pkg_is alpha ii
    run apt_remove --reason "replaced" -- alpha beta
    [ "$status" -eq 0 ]
    [ "$(_journal | wc -l)" -eq 1 ]
    _journal | grep -qF '"action":"remove","target":"alpha","detail":"remove: replaced (dpkg: ii 1.0 -> rc 1.0)"'
    _journal | grep -qF '"operation":"remove","before":"ii 1.0","after":"rc 1.0"'
}

@test "apt_purge journals a purge with both states" {
    _apt_stub
    journal_init "test" "v1"
    _pkg_is alpha rc
    run apt_purge alpha
    [ "$status" -eq 0 ]
    [ "$(_journal | wc -l)" -eq 1 ]
    _journal | grep -qF '"action":"remove","target":"alpha","detail":"purge: apt-get purge (dpkg: rc 1.0 -> not known)"'
    _journal | grep -qF '"operation":"purge","before":"rc 1.0","after":"not known"'
}

# ── apt_add_repo / apt_remove_repo: backups and the journal ───────────────────
# A sources file that was there before the call is backed up before it is
# replaced or removed. One the call wrote itself is never backed up: that
# would overwrite an older backup with a file nobody has seen.

@test "apt_add_repo backs up a sources file it reconfigures and journals the backup path" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    sed -i 's/^Suites: .*/Suites: old/' "${APT_SOURCES_DIR}/fixture.sources"
    journal_init "test" "v1"
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    grep -qxF 'Suites: stable' "${APT_SOURCES_DIR}/fixture.sources"
    grep -qxF 'Suites: old' "${APT_SOURCES_DIR}/fixture.sources.bak"
    [ "$(_journal | grep -c '"action":"repo"')" -eq 1 ]
    _journal | grep '"action":"repo"' | grep -qF "\"backup\":\"${APT_SOURCES_DIR}/fixture.sources.bak\""
    _journal | grep '"action":"repo"' | grep -qF 'reconfigured APT repo fixture'
}

@test "apt_add_repo journals a new sources file without a backup" {
    _apt_env; WGET_SERVES=a.asc
    journal_init "test" "v1"
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    [ "$(_journal | grep -c '"action":"repo"')" -eq 1 ]
    [ "$(_journal | grep -c '"backup"')" -eq 0 ]
    [ ! -e "${APT_SOURCES_DIR}/fixture.sources.bak" ]
    # Validation and the refresh both went through apt_update_wait.
    [ "$(_calls | wc -l)" -eq 2 ]
    [ "$(_calls | grep -c '^LC_ALL=C DEBIAN_FRONTEND=unset update')" -eq 2 ]
}

@test "apt_add_repo does nothing at all for a repo that is already configured" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    journal_init "test" "v1"
    : > "${APT_STUB}/calls"
    rm -f "$WGET_CALLED"
    # A write would replace the content or at least move the mtime.
    touch -d '2001-01-01 00:00:00' "${APT_SOURCES_DIR}/fixture.sources" "${APT_KEYRING_DIR}/fixture.gpg"
    local before
    before="$(stat -c '%Y %s %i' "${APT_SOURCES_DIR}/fixture.sources" "${APT_KEYRING_DIR}/fixture.gpg")"
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured"* ]]
    [ "$(_calls | wc -l)" -eq 0 ]
    [ ! -e "$WGET_CALLED" ]
    [ "$(stat -c '%Y %s %i' "${APT_SOURCES_DIR}/fixture.sources" "${APT_KEYRING_DIR}/fixture.gpg")" = "$before" ]
    [ ! -e "${APT_SOURCES_DIR}/fixture.sources.bak" ]
    [ "$(_journal | wc -l)" -eq 0 ]
}

@test "apt_add_repo records a validated repo even when the full update after it fails, and a re-run is a no-op" {
    _apt_env; WGET_SERVES=a.asc
    journal_init "test" "v1"
    # The scoped validation passes; the full update after it does not.
    cat > "${TMP}/bin/apt-get.real" < "${TMP}/bin/apt-get"
    cat > "${TMP}/bin/apt-get" <<'STUB'
#!/usr/bin/env bash
if [[ "$*" != *Dir::Etc::sourcelist=* ]]; then : > "${APT_STUB}/update-fail"; fi
exec bash "$(dirname "$0")/apt-get.real" "$@"
STUB
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 1 ]
    [ "$(_calls | wc -l)" -eq 2 ]
    [[ "$output" == *"[WARN]"*"passed validation, but the full apt-get update after it failed"* ]]
    [[ "$output" == *"does not have a Release file"* ]]
    # The file is valid and stays, so it is recorded.
    [ -e "${APT_SOURCES_DIR}/fixture.sources" ]
    [ "$(_journal | grep -c '"action":"repo"')" -eq 1 ]
    _verify
    [[ "$output" != *MISSING* ]]
    # A re-run finds it configured and recorded, and does nothing more.
    rm -f "${APT_STUB}/update-fail"
    mv "${TMP}/bin/apt-get.real" "${TMP}/bin/apt-get"
    : > "${APT_STUB}/calls"
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    [[ "$output" == *"already configured"* ]]
    [ "$(_calls | wc -l)" -eq 0 ]
    [ "$(_journal | grep -c '"action":"repo"')" -eq 1 ]
}

@test "apt_add_repo and apt_remove_repo refuse a name that is not one plain file name" {
    _apt_env; WGET_SERVES=a.asc
    journal_init "test" "v1"
    mkdir -p "${TMP}/keyrings"
    echo 'not ours' > "${TMP}/x.sources"
    echo 'not ours' > "${TMP}/x.gpg"
    local bad
    for bad in '../x' '-x' 'a/b' '.hidden' 'a b'; do
        run apt_add_repo --fingerprint "$FPR_A" -- "$bad" 'https://example.invalid/key' 'https://example.invalid/repo' stable
        [ "$status" -eq 1 ]
        [[ "$output" == *"apt_add_repo: '${bad}' is not a usable repo name"* ]]
        run apt_remove_repo -- "$bad"
        [ "$status" -eq 1 ]
        [[ "$output" == *"apt_remove_repo: '${bad}' is not a usable repo name"* ]]
    done
    [ ! -e "$WGET_CALLED" ]
    [ "$(_calls | wc -l)" -eq 0 ]
    [ "$(_journal | wc -l)" -eq 0 ]
    [ "$(cat "${TMP}/x.sources")" = 'not ours' ]
    [ "$(cat "${TMP}/x.gpg")" = 'not ours' ]
    [ ! -e "${TMP}/x.sources.bak" ]
}

@test "apt_add_repo: a failed validation removes the file it created, journals nothing for it and leaves an earlier .bak alone" {
    _apt_env; WGET_SERVES=a.asc
    journal_init "test" "v1"
    echo 'from an earlier run' > "${APT_SOURCES_DIR}/fixture.sources.bak"
    : > "${APT_STUB}/validate-fail"
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 1 ]
    [[ "$output" == *"failed validation"* ]]
    [[ "$output" == *"does not have a Release file"* ]]
    [ ! -e "${APT_SOURCES_DIR}/fixture.sources" ]
    [ "$(cat "${APT_SOURCES_DIR}/fixture.sources.bak")" = 'from an earlier run' ]
    # Created and removed in one call: no change, so no record. The keyring
    # was installed and stays, and that is the only record.
    [ "$(_journal | grep -c 'fixture.sources')" -eq 0 ]
    [ "$(_journal | wc -l)" -eq 1 ]
    [ "$(_journal | grep -c "\"action\":\"create\",\"target\":\"${APT_KEYRING_DIR}/fixture.gpg\"")" -eq 1 ]
    # Nothing in the journal names a file that is no longer there.
    _verify
    [ "$status" -eq 0 ]
    [[ "$output" != *MISSING* ]]
    [[ "$output" != *CHANGED* ]]
}

@test "apt_add_repo: a failed validation after reconfiguring keeps the .bak of the version before the call" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    sed -i 's/^Suites: .*/Suites: old/' "${APT_SOURCES_DIR}/fixture.sources"
    journal_init "test" "v1"
    : > "${APT_STUB}/validate-fail"
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 1 ]
    [ ! -e "${APT_SOURCES_DIR}/fixture.sources" ]
    grep -qxF 'Suites: old' "${APT_SOURCES_DIR}/fixture.sources.bak"
    [ "$(_journal | grep -c '"action":"repo"')" -eq 0 ]
    [ "$(_journal | grep -c '"action":"backup"')" -eq 1 ]
    [ "$(_journal | grep -c '"action":"delete"')" -eq 1 ]
    _journal | grep '"action":"delete"' | grep -qF 'the version before this call is the backup'
    _journal | grep '"action":"delete"' | grep -qF "\"backup\":\"${APT_SOURCES_DIR}/fixture.sources.bak\""
    # The call's own record does not name a missing file as one to check.
    # (backup_file's `backup` record for the same path is not asserted on.)
    _verify
    [ "$status" -eq 0 ]
    [ "$(grep -c ' delete ' <<< "$output")" -eq 1 ]
    [ "$(grep ' delete ' <<< "$output" | grep -c 'MISSING')" -eq 0 ]
    # The action column is padded; "APT repo fixture" in a detail is not.
    [ "$(grep -c '  repo  ' <<< "$output")" -eq 0 ]
}

@test "apt_add_repo: a lock held for the whole wait is reported as not validated, not as a repo that does not publish" {
    _apt_env; WGET_SERVES=a.asc
    journal_init "test" "v1"
    echo 99 > "${APT_STUB}/lock-failures"
    APT_LOCK_WAIT=10
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[WARN]"*"was not validated: another apt process held the package lists lock for the whole wait"* ]]
    [[ "$output" != *"does not publish"* ]]
    [[ "$output" != *"failed validation"* ]]
    [[ "$output" == *"E: Could not get lock"* ]]
    # The previous state is restored: a file this call created is removed.
    [ ! -e "${APT_SOURCES_DIR}/fixture.sources" ]
    [ "$(_journal | grep -c 'fixture.sources')" -eq 0 ]
    # One attempt and one retry; no refresh to sit through the same wait again.
    [ "$(_calls | wc -l)" -eq 2 ]
}

@test "apt_add_repo: a lock held for the whole wait after a reconfigure keeps the .bak and journals why" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    sed -i 's/^Suites: .*/Suites: old/' "${APT_SOURCES_DIR}/fixture.sources"
    journal_init "test" "v1"
    echo 99 > "${APT_STUB}/lock-failures"
    APT_LOCK_WAIT=10
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 1 ]
    [[ "$output" != *"does not publish"* ]]
    [ ! -e "${APT_SOURCES_DIR}/fixture.sources" ]
    grep -qxF 'Suites: old' "${APT_SOURCES_DIR}/fixture.sources.bak"
    [ "$(_journal | grep -c '"action":"delete"')" -eq 1 ]
    _journal | grep '"action":"delete"' | grep -qF 'which could not be validated (the package lists lock was held for the whole wait)'
    _journal | grep '"action":"delete"' | grep -qF "\"backup\":\"${APT_SOURCES_DIR}/fixture.sources.bak\""
}

@test "apt_add_repo waits for the lists lock during validation and still shows the waiting line" {
    _apt_env; WGET_SERVES=a.asc
    echo 1 > "${APT_STUB}/lock-failures"
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    [ -e "${APT_SOURCES_DIR}/fixture.sources" ]
    [ "$(grep -c 'holds the package lists lock' <<< "$output")" -eq 1 ]
    [ "$(grep -c '^sleep 10$' "${APT_STUB}/sleeps")" -eq 1 ]
}

@test "apt_remove_repo backs up the sources file and the keyring, and journals both removals" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    journal_init "test" "v1"
    : > "${APT_STUB}/calls"
    run apt_remove_repo fixture
    [ "$status" -eq 0 ]
    [ ! -e "${APT_SOURCES_DIR}/fixture.sources" ]
    [ ! -e "${APT_KEYRING_DIR}/fixture.gpg" ]
    grep -qxF 'Suites: stable' "${APT_SOURCES_DIR}/fixture.sources.bak"
    cmp "${APTKEYS}/a.gpg" "${APT_KEYRING_DIR}/fixture.gpg.bak"
    [ "$(_journal | grep -c '"action":"delete"')" -eq 2 ]
    _journal | grep -qF "\"action\":\"delete\",\"target\":\"${APT_SOURCES_DIR}/fixture.sources\",\"detail\":\"removed APT repo fixture\",\"backup\":\"${APT_SOURCES_DIR}/fixture.sources.bak\""
    _journal | grep -F '"action":"delete"' | grep -F "\"target\":\"${APT_KEYRING_DIR}/fixture.gpg\"" | grep -qF "\"backup\":\"${APT_KEYRING_DIR}/fixture.gpg.bak\""
    [ "$(_calls | grep -c '^LC_ALL=C DEBIAN_FRONTEND=unset update -qq$')" -eq 1 ]
}

@test "apt_remove_repo --keep-key removes the sources file and leaves the keyring" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    journal_init "test" "v1"
    : > "${APT_STUB}/calls"
    run apt_remove_repo --keep-key fixture
    [ "$status" -eq 0 ]
    [ ! -e "${APT_SOURCES_DIR}/fixture.sources" ]
    grep -qxF 'Suites: stable' "${APT_SOURCES_DIR}/fixture.sources.bak"
    cmp "${APTKEYS}/a.gpg" "${APT_KEYRING_DIR}/fixture.gpg"
    [ ! -e "${APT_KEYRING_DIR}/fixture.gpg.bak" ]
    [ "$(_journal | grep -c '"action":"delete"')" -eq 1 ]
    [ "$(_journal | grep -c 'fixture.gpg')" -eq 0 ]
    [ "$(_calls | wc -l)" -eq 1 ]
}

@test "apt_remove_repo removes a keyring left behind without its sources file, with a backup" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    rm -f "${APT_SOURCES_DIR}/fixture.sources"
    journal_init "test" "v1"
    : > "${APT_STUB}/calls"
    run apt_remove_repo fixture
    [ "$status" -eq 0 ]
    [ ! -e "${APT_KEYRING_DIR}/fixture.gpg" ]
    cmp "${APTKEYS}/a.gpg" "${APT_KEYRING_DIR}/fixture.gpg.bak"
    [ "$(_journal | grep -c '"action":"delete"')" -eq 1 ]
    _journal | grep -F '"action":"delete"' | grep -F "\"target\":\"${APT_KEYRING_DIR}/fixture.gpg\"" | grep -qF "\"backup\":\"${APT_KEYRING_DIR}/fixture.gpg.bak\""
    # No sources file went away, so there is nothing for apt to forget.
    [ "$(_calls | wc -l)" -eq 0 ]
}

@test "apt_remove_repo --keep-key leaves a keyring without a sources file alone" {
    _apt_env; WGET_SERVES=a.asc
    run _add --fingerprint "$FPR_A"
    [ "$status" -eq 0 ]
    rm -f "${APT_SOURCES_DIR}/fixture.sources"
    journal_init "test" "v1"
    run apt_remove_repo --keep-key fixture
    [ "$status" -eq 0 ]
    cmp "${APTKEYS}/a.gpg" "${APT_KEYRING_DIR}/fixture.gpg"
    [ "$(_journal | wc -l)" -eq 0 ]
}

@test "apt_remove_repo refuses a missing name and an unknown option" {
    _apt_env
    run apt_remove_repo
    [ "$status" -eq 1 ]
    [[ "$output" == *"apt_remove_repo: name is required"* ]]
    run apt_remove_repo --keep-key
    [ "$status" -eq 1 ]
    [[ "$output" == *"apt_remove_repo: name is required"* ]]
    run apt_remove_repo --purge fixture
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option '--purge'"* ]]
    [ "$(_calls | wc -l)" -eq 0 ]
}

@test "apt_remove_repo does nothing when the repo is not configured" {
    _apt_env
    journal_init "test" "v1"
    run apt_remove_repo fixture
    [ "$status" -eq 0 ]
    [ "$(_calls | wc -l)" -eq 0 ]
    [ "$(_journal | wc -l)" -eq 0 ]
}

# ── provision-report field extraction ─────────────────────────────────────────

@test "provision-report reads back what journal_record wrote" {
    journal_init "reporter" "v9"
    printf 'x\n' > "${TMP}/target.conf"
    journal_record modify "${TMP}/target.conf" "a detail"

    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report"
    [ "$status" -eq 0 ]
    [[ "$output" == *reporter* ]]
    [[ "$output" == *"a detail"* ]]
    [[ "$output" == *"${TMP}/target.conf"* ]]
}

@test "provision-report --verify reports OK for an unchanged file" {
    journal_init "reporter" "v9"
    printf 'x\n' > "${TMP}/stable.conf"
    journal_record modify "${TMP}/stable.conf" "unchanged since"

    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --verify
    [[ "$output" == *"OK"* ]]
    [[ "$output" == *"1 ok"* ]]
}

@test "provision-report --verify reports CHANGED after the file is edited" {
    journal_init "reporter" "v9"
    printf 'before\n' > "${TMP}/drift.conf"
    journal_record modify "${TMP}/drift.conf" "recorded"
    printf 'after\n' > "${TMP}/drift.conf"

    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --verify
    [[ "$output" == *"CHANGED"* ]]
    [[ "$output" == *"1 changed"* ]]
}

@test "provision-report --verify reports MISSING for a deleted file" {
    journal_init "reporter" "v9"
    printf 'x\n' > "${TMP}/gone.conf"
    journal_record modify "${TMP}/gone.conf" "recorded"
    rm -f "${TMP}/gone.conf"

    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --verify
    [[ "$output" == *"MISSING"* ]]
    [[ "$output" == *"1 missing"* ]]
}

@test "provision-report --verify matches a file named with a backslash and a newline" {
    # sha256sum given such a name prefixes its line with a backslash; verify
    # must hash the way journal_record did, or it reports CHANGED forever.
    journal_init "reporter" "v9"
    local f="${TMP}/"$'odd\\name\nhere.conf'
    printf 'before\n' > "$f"
    journal_record modify "$f" "recorded"

    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"1 ok, 0 changed"* ]]

    printf 'after\n' > "$f"
    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 ok, 1 changed"* ]]
}

@test "provision-report decodes escapes in one pass" {
    # A backslash followed by "n" is not a newline, and \u00XX is a control
    # character; decoding one escape kind at a time got the first wrong.
    journal_init "reporter" "v9"
    local t=$'/etc/a\\new\001x\\\\"q'
    journal_record modify "$t" "d"
    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --targets
    [ "$status" -eq 0 ]
    # --targets is display output: the \u0001 decodes to a control character,
    # which is then shown as \x01.
    [ "$output" = '/etc/a\new\x01x\\"q' ]
}

@test "provision-report shows control characters in journalled strings visibly" {
    journal_init "reporter" "v9"
    journal_record modify $'/etc/a\033[31mred' $'detail \033]0;title\007'
    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report"
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\033'* && "$output" != *$'\007'* ]]
    [[ "$output" == *'/etc/a\x1b[31mred'* ]]
    [[ "$output" == *'detail \x1b]0;title\x07'* ]]
    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --targets
    [ "$output" = '/etc/a\x1b[31mred' ]
}

@test "provision-report falls back to the default hash timeout for 0" {
    printf 'x\n' > "${TMP}/pub.conf"
    journal_init "reporter" "v9"
    journal_record modify "${TMP}/pub.conf" "d"
    local real
    real="$(command -v timeout)"
    mkdir "${TMP}/stub"
    cat > "${TMP}/stub/timeout" <<STUB
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "${TMP}/timeout.calls"
exec "${real}" "\$@"
STUB
    chmod 0755 "${TMP}/stub/timeout"
    run env PATH="${TMP}/stub:$PATH" JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 \
        _JOURNAL_HASH_TIMEOUT=0 "${BIN}/provision-report" --verify
    [[ "$output" == *"1 ok"* ]]
    grep -q '^-k 2 60 dd ' "${TMP}/timeout.calls"
}

@test "provision-report escapes a UTF-8 C1 control under the C locale" {
    # C2 9B is U+009B, CSI. Under LC_ALL=C bash sees two bytes, neither of
    # them [[:cntrl:]], but a UTF-8 terminal still decodes the pair as CSI.
    journal_init "reporter" "v9"
    journal_record modify $'/etc/a\xc2\x9b31mred' "d"
    run env LC_ALL=C JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --targets
    [ "$status" -eq 0 ]
    [[ "$output" != *$'\x9b'* ]]
    [ "$output" = '/etc/a'$'\xc2''\x9b31mred' ]
}

@test "provision-report keeps printable multibyte names intact under a UTF-8 locale" {
    journal_init "reporter" "v9"
    journal_record modify $'/etc/caf\u00e9-\u00db\u009b' "d"
    run env LC_ALL=C.UTF-8 JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --targets
    [ "$status" -eq 0 ]
    [ "$output" = $'/etc/caf\u00e9-\u00db''\u009b' ]
}

@test "provision-report --verify will not hash a bare name, a private symlink target or a FIFO" {
    printf 'content\n' > "${TMP}/public"
    printf 'content\n' > "${TMP}/shadow"
    chmod 0600 "${TMP}/shadow"
    local sha
    sha="$(sha256sum < "${TMP}/public")"; sha="${sha%% *}"
    mkdir "${TMP}/cwd"
    # Resolved against the working directory, the bare name would match.
    ln -s "${TMP}/public" "${TMP}/cwd/lxd"
    ln -s "${TMP}/shadow" "${TMP}/to-shadow"
    mkfifo -m 0644 "${TMP}/fifo"
    # Records as a forged or older journal might hold them, each with a hash.
    mkdir -p "$JOURNAL_DIR"
    local t
    for t in lxd "${TMP}/to-shadow" "${TMP}/fifo"; do
        printf '{"ts":"2026-01-01T00:00:00Z","run":"r1","script":"s","action":"modify","target":"%s","detail":"d","sha256_after":"%s"}\n' \
            "$t" "$sha" >> "$JOURNAL_FILE"
    done
    run bash -c 'cd "$1" && JOURNAL_FILE="$2" NO_COLOR=1 timeout 20 "$3/provision-report" --verify' \
        _ "${TMP}/cwd" "$JOURNAL_FILE" "$BIN"
    # 124 would be timeout(1) killing a hung read.
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 ok, 0 changed, 0 missing, 3 unreadable, 0 present"* ]]
}

@test "provision-report --verify tracks a private file by presence: PRESENT, then MISSING" {
    printf 'secret\n' > "${TMP}/key"
    chmod 0600 "${TMP}/key"
    journal_init "reporter" "v9"
    journal_record create "${TMP}/key" "private key"
    journal_record delete "${TMP}/old.conf" "removed"
    run ! grep -q '"sha256_after"' "$JOURNAL_FILE"

    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"PRESENT"* ]]
    # The deletion is not a missing file: nothing to check.
    [[ "$output" == *"0 ok, 0 changed, 0 missing, 0 unreadable, 1 present"* ]]

    rm -f "${TMP}/key"
    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --verify
    [[ "$output" == *"0 ok, 0 changed, 1 missing, 0 unreadable, 0 present"* ]]
}

@test "provision-report --verify checks a root-only file's presence through sudo -n test -e" {
    [[ "$EUID" -eq 0 ]] && skip "root can see anywhere"
    mkdir -m 0700 "${TMP}/rootonly"
    printf 'x\n' > "${TMP}/rootonly/kept.conf"
    printf 'x\n' > "${TMP}/rootonly/gone.conf"
    journal_init "reporter" "v9"
    journal_record modify "${TMP}/rootonly/kept.conf" "recorded"
    journal_record modify "${TMP}/rootonly/gone.conf" "recorded"
    run ! grep -q '"sha256_after"' "$JOURNAL_FILE"
    rm -f "${TMP}/rootonly/gone.conf"
    chmod 0000 "${TMP}/rootonly"
    # Stand-in for root: opens the directory for the one command it runs, and
    # logs it. Content must never be read through it.
    mkdir "${TMP}/stub"
    cat > "${TMP}/stub/sudo" <<'STUB'
#!/usr/bin/env bash
[[ "${1:-}" == -n ]] && shift
printf '%s\n' "$*" >> "${TMP}/sudo.calls"
[[ -n "${SUDO_BROKEN:-}" ]] && exit 1
chmod 0700 "${TMP}/rootonly"; rc=0; "$@" || rc=$?; chmod 0000 "${TMP}/rootonly"
exit "$rc"
STUB
    chmod 0755 "${TMP}/stub/sudo"
    unset -f sudo

    run env PATH="${TMP}/stub:$PATH" TMP="$TMP" JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 \
        "${BIN}/provision-report" --verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"0 ok, 0 changed, 1 missing, 0 unreadable, 1 present"* ]]
    run ! grep -qv '^true$\|^test -e ' "${TMP}/sudo.calls"
    # Whether sudo can run is asked once for the whole journal, not per path.
    [ "$(grep -c '^true$' "${TMP}/sudo.calls")" -eq 1 ]
    [ "$(grep -c '^test -e ' "${TMP}/sudo.calls")" -eq 2 ]

    # Without a working sudo the answer is unknown, never MISSING.
    run env PATH="${TMP}/stub:$PATH" TMP="$TMP" SUDO_BROKEN=1 JOURNAL_FILE="$JOURNAL_FILE" \
        NO_COLOR=1 "${BIN}/provision-report" --verify
    chmod 0700 "${TMP}/rootonly"
    [[ "$output" == *"0 ok, 0 changed, 0 missing, 2 unreadable, 0 present"* ]]
}

# ── provision-report --verify: superseded records and backups ─────────────────
# Only the latest record for a path describes the file as it should be now.
# An earlier one is SUPERSEDED, not judged against a file a later record
# changed or removed. _row <action> prints the report's line(s) for records
# with that action under ${TMP}.

_row() { grep -E "  $1 +${TMP}/" <<< "$output" || true; }

@test "provision-report --verify: a backup followed by a delete is SUPERSEDED, and nothing is MISSING" {
    journal_init "reporter" "v9"
    printf 'x\n' > "${TMP}/gone.conf"
    backup_file "${TMP}/gone.conf" "removing it"
    rm -f "${TMP}/gone.conf"
    journal_record delete "${TMP}/gone.conf" "removed" "backup=${TMP}/gone.conf.bak"

    _verify
    [ "$status" -eq 0 ]
    [[ "$(_row backup)" == *SUPERSEDED* ]]
    [[ "$(_row delete)" == "     -    "* ]]
    [[ "$output" != *MISSING* ]]
    [[ "$output" == *"2 record(s)"*"0 ok, 0 changed, 0 missing, 0 unreadable, 0 present, 1 superseded"* ]]
}

@test "provision-report --verify: a create followed by a journalled modify is SUPERSEDED, then OK" {
    journal_init "reporter" "v9"
    printf 'one\n' > "${TMP}/two.conf"
    journal_record create "${TMP}/two.conf" "written"
    printf 'two\n' > "${TMP}/two.conf"
    journal_record modify "${TMP}/two.conf" "rewritten"

    _verify
    [[ "$(_row create)" == *SUPERSEDED* ]]
    [[ "$(_row modify)" == *" OK "* ]]
    [[ "$output" != *CHANGED* ]]
    [[ "$output" == *"1 ok, 0 changed, 0 missing, 0 unreadable, 0 present, 1 superseded"* ]]
}

@test "provision-report --verify: a delete followed by a re-create is SUPERSEDED, and the create is checked" {
    journal_init "reporter" "v9"
    journal_record delete "${TMP}/back.conf" "removed"
    printf 'again\n' > "${TMP}/back.conf"
    journal_record create "${TMP}/back.conf" "written again"

    _verify
    [[ "$(_row delete)" == *SUPERSEDED* ]]
    [[ "$(_row create)" == *" OK "* ]]
    rm -f "${TMP}/back.conf"
    _verify
    [[ "$(_row delete)" == *SUPERSEDED* ]]
    [[ "$(_row create)" == *MISSING* ]]
    [[ "$output" == *"0 ok, 0 changed, 1 missing, 0 unreadable, 0 present, 1 superseded"* ]]
}

@test "provision-report --verify --run: an earlier run's record is SUPERSEDED by a later run that is not shown" {
    journal_init "first" "v1"
    local first="$_JOURNAL_RUN_ID"
    printf 'one\n' > "${TMP}/runs.conf"
    journal_record create "${TMP}/runs.conf" "written"
    journal_init "second" "v1"
    printf 'two\n' > "${TMP}/runs.conf"
    journal_record modify "${TMP}/runs.conf" "rewritten"

    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --verify --run "$first"
    [ "$status" -eq 0 ]
    [[ "$(_row create)" == *SUPERSEDED* ]]
    [ -z "$(_row modify)" ]
    [[ "$output" != *CHANGED* ]]
    [[ "$output" == *"1 record(s)"*"0 ok, 0 changed, 0 missing, 0 unreadable, 0 present, 1 superseded"* ]]

    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report" --verify --script first
    [[ "$(_row create)" == *SUPERSEDED* ]]
}

@test "provision-report --verify: real drift on the latest record is still CHANGED or MISSING" {
    journal_init "reporter" "v9"
    printf 'one\n' > "${TMP}/drift2.conf"
    journal_record create "${TMP}/drift2.conf" "written"
    printf 'two\n' > "${TMP}/drift2.conf"
    journal_record modify "${TMP}/drift2.conf" "rewritten"
    printf 'three\n' > "${TMP}/drift2.conf"

    _verify
    [[ "$(_row create)" == *SUPERSEDED* ]]
    [[ "$(_row modify)" == *CHANGED* ]]
    [[ "$output" == *"0 ok, 1 changed, 0 missing, 0 unreadable, 0 present, 1 superseded"* ]]

    rm -f "${TMP}/drift2.conf"
    _verify
    [[ "$(_row create)" == *SUPERSEDED* ]]
    [[ "$(_row modify)" == *MISSING* ]]
    [[ "$output" == *"0 ok, 0 changed, 1 missing, 0 unreadable, 0 present, 1 superseded"* ]]
}

@test "provision-report --verify: a path with a space and a newline is superseded like any other" {
    journal_init "reporter" "v9"
    local odd="${TMP}/odd name"$'\n'"x.conf"
    printf 'one\n' > "$odd"
    journal_record create "$odd" "written"
    printf 'two\n' > "$odd"
    journal_record modify "$odd" "rewritten"
    # A different path that only shares the first line is not the same target.
    printf 'other\n' > "${TMP}/odd name"
    journal_record create "${TMP}/odd name" "another file"

    _verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"2 ok, 0 changed, 0 missing, 0 unreadable, 0 present, 1 superseded"* ]]
    [ "$(grep -c 'SUPERSEDED' <<< "$output")" -eq 1 ]
    [[ "$(grep 'SUPERSEDED' <<< "$output")" == *" create "* ]]
}

@test "provision-report --verify: repeated and trailing slashes do not make a path a different target" {
    journal_init "reporter" "v9"
    mkdir -p "${TMP}/sl"
    printf 'one\n' > "${TMP}/sl/n.conf"
    journal_record create "${TMP}//sl///n.conf" "written"
    printf 'two\n' > "${TMP}/sl/n.conf"
    journal_record modify "${TMP}/sl/n.conf" "rewritten"
    journal_record create "${TMP}/sl/" "made the directory"
    journal_record modify "${TMP}/sl" "changed its mode"

    _verify
    [ "$status" -eq 0 ]
    [ "$(grep -c 'SUPERSEDED' <<< "$output")" -eq 2 ]
    [[ "$(_row create)" != *" OK "* ]]
    # The journalled spelling is what is shown.
    [[ "$output" == *"create   ${TMP}//sl///n.conf"* ]]
    [[ "$output" == *"create   ${TMP}/sl/"* ]]
    [[ "$output" == *"1 ok, 0 changed, 0 missing, 0 unreadable, 1 present, 2 superseded"* ]]
}

@test "provision-report --verify: package and other non-path targets are never SUPERSEDED" {
    journal_init "reporter" "v9"
    journal_record install some-package "installed"
    journal_record remove some-package "removed"
    journal_record install some-package "installed again"

    _verify
    [[ "$output" != *SUPERSEDED* ]]
    [[ "$output" == *"3 record(s)"*"0 ok, 0 changed, 0 missing, 0 unreadable, 0 present, 0 superseded"* ]]
}

@test "provision-report --verify shows whether a record's backup is present, missing or unknown" {
    journal_init "reporter" "v9"
    printf 'now\n' > "${TMP}/kept.conf"
    printf 'then\n' > "${TMP}/kept.conf.bak"
    journal_record modify "${TMP}/kept.conf" "edited" "backup=${TMP}/kept.conf.bak"

    _verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"backup: ${TMP}/kept.conf.bak  [present]"* ]]
    [[ "$output" == *"1 ok, 0 changed, 0 missing, 0 unreadable, 0 present, 0 superseded  —  0 backup(s) missing"* ]]

    # A missing backup is counted on its own; the record itself is still OK.
    rm -f "${TMP}/kept.conf.bak"
    _verify
    [ "$status" -eq 0 ]
    [[ "$output" == *"backup: ${TMP}/kept.conf.bak  [missing]"* ]]
    [[ "$(_row modify)" == *" OK "* ]]
    [[ "$output" != *MISSING* ]]
    [[ "$output" == *"1 ok, 0 changed, 0 missing, 0 unreadable, 0 present, 0 superseded  —  1 backup(s) missing"* ]]
}

@test "provision-report --verify calls a relative backup path unknown, and checks a superseded record's backup too" {
    journal_init "reporter" "v9"
    printf 'now\n' > "${TMP}/rel.conf"
    journal_record modify "${TMP}/rel.conf" "edited" "backup=rel.conf.bak"
    journal_record modify "${TMP}/rel.conf" "edited again" "backup=${TMP}/rel.conf.gone"
    journal_record modify "${TMP}/rel.conf" "and again"
    # A file of that name in the working directory must not be consulted.
    printf 'decoy\n' > "${TMP}/rel.conf.bak"

    run bash -c 'cd "$1" && JOURNAL_FILE="$2" NO_COLOR=1 "$3/provision-report" --verify' _ "$TMP" "$JOURNAL_FILE" "$BIN"
    [ "$status" -eq 0 ]
    [[ "$output" == *"backup: rel.conf.bak  [unknown]"* ]]
    [[ "$output" == *"backup: ${TMP}/rel.conf.gone  [missing]"* ]]
    [[ "$output" == *"1 ok, 0 changed, 0 missing, 0 unreadable, 0 present, 2 superseded  —  1 backup(s) missing"* ]]
}

@test "provision-report without --verify prints exactly what it always has" {
    mkdir -p "$JOURNAL_DIR"
    printf '%s\n' \
        '{"ts":"2026-01-02T03:04:05Z","run":"abcd1234","script":"s","version":"v1","host":"h","user":"u","action":"modify","target":"/etc/example.conf","detail":"a detail","backup":"/etc/example.conf.bak"}' \
        '{"ts":"2026-01-02T03:04:06Z","run":"abcd1234","script":"s","version":"v1","host":"h","user":"u","action":"delete","target":"/etc/example.conf","detail":"gone"}' \
        '{"ts":"2026-01-02T03:04:07Z","run":"ef567890","script":"t","version":"v2","host":"h","user":"u","action":"install","target":"some-package","detail":""}' \
        > "$JOURNAL_FILE"
    local expected
    expected="$(printf '%s\n' \
        '● run abcd1234  s  v1' \
        '  2026-01-02T03:04:05  modify   /etc/example.conf' \
        '            a detail' \
        '            backup: /etc/example.conf.bak' \
        '  2026-01-02T03:04:06  delete   /etc/example.conf' \
        '            gone' \
        '' \
        '● run ef567890  t  v2' \
        '  2026-01-02T03:04:07  install  some-package' \
        '' \
        '3 record(s)')"
    run env JOURNAL_FILE="$JOURNAL_FILE" NO_COLOR=1 "${BIN}/provision-report"
    [ "$status" -eq 0 ]
    [ "$output" = "$expected" ]
}

@test "provision-report --help describes SUPERSEDED and the backup check" {
    run "${BIN}/provision-report" --help
    [ "$status" -eq 0 ]
    [[ "$output" == *SUPERSEDED* ]]
    [[ "$output" == *"[missing]"* ]]
}

# ── cleanup stack ─────────────────────────────────────────────────────────────

@test "cleanup handlers run in reverse registration order" {
    run bash -c "
        . '${LIB}/log.sh'
        . '${LIB}/cleanup.sh'
        cleanup_push 'echo first'
        cleanup_push 'echo second'
        exit 0
    "
    [ "${lines[0]}" = "second" ]
    [ "${lines[1]}" = "first" ]
}

@test "a failing cleanup handler does not mask the exit code" {
    run bash -c "
        . '${LIB}/log.sh'
        . '${LIB}/cleanup.sh'
        cleanup_push 'false'
        exit 42
    "
    [ "$status" -eq 42 ]
}

# ── net.sh ────────────────────────────────────────────────────────────────────

@test "mask_to_cidr converts common masks" {
    . "${LIB}/net.sh"
    [ "$(mask_to_cidr 255.255.255.0)" = "24" ]
    [ "$(mask_to_cidr 255.255.0.0)"   = "16" ]
    [ "$(mask_to_cidr 255.255.255.252)" = "30" ]
    [ "$(mask_to_cidr 255.255.255.255)" = "32" ]
    [ "$(mask_to_cidr 0.0.0.0)"       = "0" ]
}

@test "derive_network_addr masks an address to its network" {
    . "${LIB}/net.sh"
    [ "$(derive_network_addr 10.1.2.3 16)"     = "10.1.0.0" ]
    [ "$(derive_network_addr 192.168.7.99 24)" = "192.168.7.0" ]
    [ "$(derive_network_addr 172.16.30.5 12)"  = "172.16.0.0" ]
    [ "$(derive_network_addr 10.9.9.9 32)"     = "10.9.9.9" ]
    [ "$(derive_network_addr 10.9.9.9 0)"      = "0.0.0.0" ]
}

@test "ranges_overlap detects identical, containing and partial overlaps" {
    . "${LIB}/net.sh"
    ranges_overlap 10.0.0.0 16 10.0.0.0  16   # identical
    ranges_overlap 10.0.0.0 16 10.0.5.0  24   # containment
    ranges_overlap 10.0.0.0 15 10.1.0.0  16   # partial
}

@test "ranges_overlap rejects disjoint ranges" {
    . "${LIB}/net.sh"
    ! ranges_overlap 10.0.0.0  16 10.1.0.0    16
    ! ranges_overlap 192.168.1.0 24 192.168.2.0 24
    ! ranges_overlap 10.8.0.0  24 172.16.0.0  16
}

@test "ip_in_range decides membership" {
    . "${LIB}/net.sh"
    ip_in_range 10.0.5.7 10.0.0.0 16
    ! ip_in_range 10.1.5.7 10.0.0.0 16
}

# ── oui.sh ────────────────────────────────────────────────────────────────────

@test "oui_normalize accepts every common separator style" {
    . "${LIB}/oui.sh"
    [ "$(oui_normalize 00:11:22:33:44:55)" = "001122" ]
    [ "$(oui_normalize 00-11-22)"          = "001122" ]
    [ "$(oui_normalize 0011.2233.4455)"    = "001122" ]
    [ "$(oui_normalize '00 11 22')"        = "001122" ]
    [ "$(oui_normalize aabbccddeeff)"      = "AABBCC" ]
}

@test "oui_normalize rejects short and non-hex input" {
    . "${LIB}/oui.sh"
    run oui_normalize "00:11"
    [ "$status" -ne 0 ]
    run oui_normalize "zz:11:22"
    [ "$status" -ne 0 ]
}

@test "oui_format produces the IEEE record prefix" {
    . "${LIB}/oui.sh"
    [ "$(oui_format 001122)" = "00-11-22" ]
    [ "$(oui_format AABBCC)" = "AA-BB-CC" ]
}

@test "oui_lookup finds a vendor and reports an unassigned prefix" {
    . "${LIB}/oui.sh"
    export OUI_FILE="${TMP}/oui.txt"
    printf '%s\n' \
        '00-11-22   (hex)		CIMSYS Inc' \
        '' \
        '001122     (base 16)		CIMSYS Inc' \
        'AA-BB-CC   (hex)		Example Corp' \
        'AABBCC     (base 16)		Example Corp' > "$OUI_FILE"

    run oui_lookup 00:11:22:33:44:55
    [ "$status" -eq 0 ]
    [[ "$output" == *"CIMSYS"* ]]

    run oui_lookup ff:ff:ff:00:00:00
    [ "$status" -eq 1 ]
}

@test "oui_vendor extracts just the organisation name" {
    . "${LIB}/oui.sh"
    export OUI_FILE="${TMP}/oui.txt"
    printf '%s\n' '00-11-22   (hex)		CIMSYS Inc' > "$OUI_FILE"
    run oui_vendor 001122334455
    [ "$output" = "CIMSYS Inc" ]
}

@test "oui_random_for_vendor matches the vendor field, not the address" {
    . "${LIB}/oui.sh"
    export OUI_FILE="${TMP}/oui.txt"
    # The second record is a different company on a street named "Acme" —
    # a whole-line match would wrongly return its prefix.
    printf '%s\n' \
        'AA1111     (base 16)		Acme Networks' \
        'BB2222     (base 16)		Globex Ltd' \
        '				12 Acme Street' > "$OUI_FILE"

    for _ in 1 2 3 4 5; do
        run oui_random_for_vendor acme
        [ "$status" -eq 0 ]
        [ "$output" = "AA1111" ]
    done
}

@test "oui_random_for_vendor fails cleanly on an unknown vendor" {
    . "${LIB}/oui.sh"
    export OUI_FILE="${TMP}/oui.txt"
    printf '%s\n' 'AA1111     (base 16)		Acme Networks' > "$OUI_FILE"
    run oui_random_for_vendor nosuchvendor
    [ "$status" -ne 0 ]
}

# ── host.sh: set_hostname ─────────────────────────────────────────────────────
# hostnamectl is stubbed as a real executable on PATH rather than a shell
# function: set_hostname reaches it through `sudo`, and while this suite's sudo
# stub is a function that would see one, a binary stub is what actually models
# the call and cannot be silently bypassed.

_stub_hostnamectl() {
    # $1 = the static hostname to report, $2 = exit status for set-hostname
    mkdir -p "${TMP}/bin"
    cat > "${TMP}/bin/hostnamectl" <<STUB
#!/usr/bin/env bash
case "\$1" in
    --static)      printf '%s\n' '${1}' ;;
    set-hostname)  printf '%s\n' "\$2" > "${TMP}/set-to"; exit ${2:-0} ;;
esac
STUB
    chmod +x "${TMP}/bin/hostnamectl"
    PATH="${TMP}/bin:${PATH}"
}

@test "hostname_is_valid accepts ordinary names" {
    . "${LIB}/host.sh"
    for n in host1 my-host web01.example.com a A9 my_host; do
        run hostname_is_valid "$n"
        [ "$status" -eq 0 ]
    done
}

@test "hostname_is_valid allows underscores" {
    # DNS discourages them, systemd accepts them, and they appear in real
    # deployments — rejecting one would break a working setup.
    . "${LIB}/host.sh"
    run hostname_is_valid my_host
    [ "$status" -eq 0 ]
}

@test "hostname_is_valid rejects the unambiguously invalid" {
    . "${LIB}/host.sh"
    for n in "" "-lead" "trail-" ".lead" "trail." "a..b" "has space" \
             "bad!char" "tab	here" "new
line"; do
        run hostname_is_valid "$n"
        [ "$status" -ne 0 ]
    done
}

@test "hostname_is_valid enforces HOST_NAME_MAX" {
    # 64 on Linux, per `getconf HOST_NAME_MAX`.
    . "${LIB}/host.sh"
    run hostname_is_valid "$(printf '%064d' 0)"
    [ "$status" -eq 0 ]
    run hostname_is_valid "$(printf '%065d' 0)"
    [ "$status" -ne 0 ]
}

@test "set_hostname rejects an invalid name before touching the system" {
    . "${LIB}/host.sh"
    _stub_hostnamectl oldname
    journal_init "t" "v1"

    run set_hostname "bad name"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Invalid hostname"* ]]
    # Nothing was attempted and nothing was recorded.
    [ ! -f "${TMP}/set-to" ]
    [ ! -s "$JOURNAL_FILE" ] || ! grep -q '/etc/hostname' "$JOURNAL_FILE"
}

@test "set_hostname still treats empty as a skip, not an invalid name" {
    # The empty check must stay AHEAD of validation: sys-bld's checklist
    # depends on an unfilled step skipping rather than dying.
    . "${LIB}/host.sh"
    _stub_hostnamectl oldname
    journal_init "t" "v1"

    run set_hostname ""
    [ "$status" -eq 0 ]
    [[ "$output" == *skipping* ]]
    [[ "$output" != *"Invalid hostname"* ]]
}

@test "set_hostname surfaces hostnamectl's own error text" {
    # "Failed to set hostname" alone says nothing about why; the usual causes
    # (polkit, read-only /etc, hostnamed not running) are distinguishable only
    # from hostnamectl's output.
    mkdir -p "${TMP}/bin"
    cat > "${TMP}/bin/hostnamectl" <<'STUB'
#!/usr/bin/env bash
case "$1" in
    --static)     printf 'oldname\n' ;;
    set-hostname) echo "Could not contact systemd-hostnamed" >&2; exit 1 ;;
esac
STUB
    chmod +x "${TMP}/bin/hostnamectl"
    PATH="${TMP}/bin:${PATH}"

    . "${LIB}/host.sh"
    journal_init "t" "v1"
    run set_hostname newname
    [ "$status" -ne 0 ]
    [[ "$output" == *"systemd-hostnamed"* ]]
}

@test "set_hostname skips an empty name instead of failing" {
    # sys-bld's checklist calls `set_hostname ""` for a step you fill in per
    # machine, so an unfilled step must skip rather than abort the whole run.
    . "${LIB}/host.sh"
    _stub_hostnamectl oldname
    journal_init "t" "v1"

    run set_hostname ""
    [ "$status" -eq 0 ]
    [[ "$output" == *skipping* ]]
    [ ! -f "${TMP}/set-to" ]
}

@test "set_hostname is a no-op when the name already matches" {
    . "${LIB}/host.sh"
    _stub_hostnamectl alreadyset
    journal_init "t" "v1"

    run set_hostname alreadyset
    [ "$status" -eq 0 ]
    [[ "$output" == *"already alreadyset"* ]]
    [ ! -f "${TMP}/set-to" ]
}

@test "set_hostname sets a new name and journals the change" {
    . "${LIB}/host.sh"
    _stub_hostnamectl oldname
    journal_init "t" "v1"

    run set_hostname newname
    [ "$status" -eq 0 ]
    [ "$(cat "${TMP}/set-to")" = "newname" ]

    grep -q '"target":"/etc/hostname"' "$JOURNAL_FILE"
    grep -q 'oldname -> newname' "$JOURNAL_FILE"
}

@test "set_hostname records no journal entry when nothing changed" {
    # Re-running a provisioning checklist must not append a fresh entry each
    # time — the journal answers "what was done to this box", not "what ran".
    . "${LIB}/host.sh"
    _stub_hostnamectl samename
    journal_init "t" "v1"

    set_hostname samename >/dev/null
    [ ! -s "$JOURNAL_FILE" ] || ! grep -q '/etc/hostname' "$JOURNAL_FILE"
}

@test "set_hostname dies when hostnamectl fails" {
    . "${LIB}/host.sh"
    _stub_hostnamectl oldname 1
    journal_init "t" "v1"

    run set_hostname newname
    [ "$status" -ne 0 ]
    [[ "$output" == *"Failed to set hostname"* ]]
}

@test "set_hostname does not journal a failed change" {
    . "${LIB}/host.sh"
    _stub_hostnamectl oldname 1
    journal_init "t" "v1"

    run set_hostname newname
    [ "$status" -ne 0 ]
    [ ! -s "$JOURNAL_FILE" ] || ! grep -q '/etc/hostname' "$JOURNAL_FILE"
}

# ── bld: version stamping ─────────────────────────────────────────────────────
# Regression cover for the per-file stamp bug. bld is invoked with several
# sources at once, and writing dist/<first>.sh dirties the working tree — so a
# `git describe --dirty` evaluated per file stamped artifact one clean and
# every later one -dirty, from a pristine checkout. The stamp is the only
# record of which source produced a shipped artifact, and shell-ci now fails a
# committed dist/ carrying a -dirty stamp, so this must not regress.
#
# Nothing here cd's the test process into $TMP: teardown removes that tree, and
# a bats run whose cwd has been deleted aborts without reporting the failing
# test at all. bld is invoked in a subshell instead.

_bld_fixture_repo() {
    local repo="${TMP}/bldrepo" n
    mkdir -p "${repo}/dist"
    git -C "${repo}" init -q .
    git -C "${repo}" config user.email 'test@example.invalid'
    git -C "${repo}" config user.name 'test'

    for n in one two; do
        cat > "${repo}/${n}.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# >>> bash-includes >>>
# include: log.sh
_bootstrap_lib() { . "${LIB}/log.sh"; }
_bootstrap_lib
# <<< bash-includes <<<
SCRIPT_VERSION="\${SCRIPT_VERSION:-dev}"
EOF
        # A committed placeholder, so that bld writing the real artifact makes
        # the tree dirty. Without it the bug is invisible: nothing tracked
        # changes and every stamp comes out clean either way.
        printf 'placeholder\n' > "${repo}/dist/${n}.sh"
    done

    git -C "${repo}" add -A
    git -C "${repo}" commit -qm 'fixture'
}

_bld_run() {
    ( cd "${TMP}/bldrepo" && "${BIN}/bld" -L "${LIB}" -o dist "$@" )
}

_bld_stamp() {
    sed -n 's/^SCRIPT_VERSION="\(.*\)"$/\1/p' "${TMP}/bldrepo/dist/$1" | head -1
}

@test "bld stamps every artifact in a run with the same version" {
    _bld_fixture_repo
    run _bld_run one.sh two.sh
    [ "$status" -eq 0 ]

    first="$(_bld_stamp one.sh)"
    second="$(_bld_stamp two.sh)"

    [ -n "$first" ]
    [ "$first" = "$second" ]
}

@test "bld does not stamp -dirty for artifacts written after the first" {
    _bld_fixture_repo
    run _bld_run one.sh two.sh
    [ "$status" -eq 0 ]

    # The tree was clean when the run began, so neither artifact may claim
    # otherwise — including the second, written after dist/one.sh dirtied it.
    [[ "$(_bld_stamp one.sh)" != *-dirty ]]
    [[ "$(_bld_stamp two.sh)" != *-dirty ]]
}

@test "bld strips the development bootstrap from the artifact" {
    _bld_fixture_repo
    run _bld_run one.sh
    [ "$status" -eq 0 ]

    # The marker block and its bootstrap must not survive into dist/: that is
    # what makes the artifact standalone.
    ! grep -q '_bootstrap_lib' "${TMP}/bldrepo/dist/one.sh"
    ! grep -q '>>> bash-includes >>>' "${TMP}/bldrepo/dist/one.sh"
    # ...and the library it asked for must actually be inlined.
    grep -q 'log_open_transcript()' "${TMP}/bldrepo/dist/one.sh"
}


# ── bld: embedded files ───────────────────────────────────────────────────────
# A text file is embedded as a heredoc, and the closing delimiter must start a
# line. A file whose last line has no newline used to get the delimiter glued
# onto that line, so the artifact's heredoc never closed: it swallowed the rest
# of the script, and the extracted file was wrong. Found building openvpn-bld.
# Every embedded file must come back byte-for-byte, whatever its last byte.

_bld_embed_fixture() {
    local repo="${TMP}/bldembed"
    mkdir -p "${repo}/data" "${repo}/dist"
    git -C "${repo}" init -q .
    git -C "${repo}" config user.email 'test@example.invalid'
    git -C "${repo}" config user.name 'test'

    printf 'line one\nline two\n' > "${repo}/data/withnl.txt"
    printf 'line one\nlast line, no newline' > "${repo}/data/nonl.txt"
    : > "${repo}/data/empty.txt"

    cat > "${repo}/emb.sh" <<EOF
#!/usr/bin/env bash
set -euo pipefail
# >>> bash-includes >>>
# embed: data/*.txt
_bootstrap_lib() { :; }
_bootstrap_lib
# <<< bash-includes <<<
cat "\${BLD_EMBED_DIR}/data/\$1"
EOF
    git -C "${repo}" add -A
    git -C "${repo}" commit -qm 'fixture'
    ( cd "${repo}" && "${BIN}/bld" -L "${LIB}" -o dist emb.sh )
}

@test "bld embeds a text file without a trailing newline intact" {
    _bld_embed_fixture
    local repo="${TMP}/bldembed"
    bash -n "${repo}/dist/emb.sh"
    bash "${repo}/dist/emb.sh" nonl.txt > "${TMP}/out"
    cmp "${repo}/data/nonl.txt" "${TMP}/out"
}

@test "bld still embeds ordinary and empty text files byte-for-byte" {
    _bld_embed_fixture
    local repo="${TMP}/bldembed" f
    for f in withnl.txt empty.txt; do
        bash "${repo}/dist/emb.sh" "$f" > "${TMP}/out"
        cmp "${repo}/data/${f}" "${TMP}/out"
    done
    # An ordinary text file stays a readable heredoc in the artifact.
    grep -qx 'line two' "${repo}/dist/emb.sh"
}


# ── git.sh ────────────────────────────────────────────────────────────────────

@test "git_identity_config sets name, email and the default branch" {
    _git_home
    git_identity_config "Test User" "test@example.com"
    [ "$(git config --global user.name)"  = "Test User" ]
    [ "$(git config --global user.email)" = "test@example.com" ]
    [ "$(git config --global init.defaultBranch)" = "main" ]
}

@test "git_identity_config creates an empty global ignore and points at it" {
    _git_home
    git_identity_config "Test User" "test@example.com"
    ignore="$(git config --global core.excludesfile)"
    [ -f "$ignore" ]
    # Created empty of patterns: a comment line only.
    [ "$(grep -cv '^#' "$ignore")" -eq 0 ]
}

@test "git_identity_config refuses a missing name or email" {
    _git_home
    run git_identity_config "" "test@example.com"
    [ "$status" -ne 0 ]
    run git_identity_config "Test User" ""
    [ "$status" -ne 0 ]
}

@test "git_identity_config does not clobber an ignore file that already exists" {
    _git_home
    mkdir -p "${HOME}/.config/git"
    printf 'node_modules/\n' > "${HOME}/.config/git/ignore"
    git_identity_config "Test User" "test@example.com"
    grep -qx 'node_modules/' "${HOME}/.config/git/ignore"
}

@test "git_ensure_key generates an ed25519 key when none is there" {
    _git_home
    git_ensure_key "${HOME}/.ssh/git@github.com" "test@example.com"
    [ -f "${HOME}/.ssh/git@github.com" ]
    ssh-keygen -lf "${HOME}/.ssh/git@github.com" | grep -q ED25519
    [ "$(stat -c %a "${HOME}/.ssh/git@github.com")" = "600" ]
    [ "$(stat -c %a "${HOME}/.ssh/git@github.com.pub")" = "644" ]
    [ "$(stat -c %a "${HOME}/.ssh")" = "700" ]
}

@test "git_ensure_key leaves an existing key alone but fixes its mode" {
    _git_home
    mkdir -p "${HOME}/.ssh"
    printf 'NOT A REAL KEY\n' > "${HOME}/.ssh/git@github.com"
    chmod 0644 "${HOME}/.ssh/git@github.com"
    git_ensure_key "${HOME}/.ssh/git@github.com"
    [ "$(cat "${HOME}/.ssh/git@github.com")" = "NOT A REAL KEY" ]
    [ "$(stat -c %a "${HOME}/.ssh/git@github.com")" = "600" ]
}

@test "git_ensure_key needs a path" {
    _git_home
    run git_ensure_key ""
    [ "$status" -ne 0 ]
}

@test "_git_strip_github_host_block removes a Host github block" {
    _git_home
    printf 'Host github\n    User git\n\nHost other\n    User bob\n' > "${TMP}/cfg"
    run _git_strip_github_host_block "${TMP}/cfg"
    [ "$status" -eq 0 ]
    echo "$output" | grep -q 'Host other'
    ! echo "$output" | grep -q 'Host github'
    echo "$output" | grep -q 'User bob'
}

@test "_git_strip_github_host_block removes a Host github.com block too" {
    _git_home
    printf 'Host github.com\n    User git\n' > "${TMP}/cfg"
    run _git_strip_github_host_block "${TMP}/cfg"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "_git_strip_github_host_block keeps a host that merely resembles github" {
    _git_home
    printf 'Host githubbery\n    User git\n' > "${TMP}/cfg"
    run _git_strip_github_host_block "${TMP}/cfg"
    [ "$status" -ne 0 ]
}

@test "_git_strip_github_host_block reports nothing to do" {
    _git_home
    printf 'Host other\n    User bob\n' > "${TMP}/cfg"
    run _git_strip_github_host_block "${TMP}/cfg"
    [ "$status" -ne 0 ]
}

@test "git_github_ssh_stanza writes a 0600 stanza and includes it first" {
    _git_home
    git_github_ssh_stanza "${HOME}/.ssh/git@github.com"
    [ "$(stat -c %a "${HOME}/.ssh/config.d/10-github.conf")" = "600" ]
    grep -qx 'Host github' "${HOME}/.ssh/config.d/10-github.conf"
    grep -q 'AddKeysToAgent no' "${HOME}/.ssh/config.d/10-github.conf"
    grep -q 'HostKeyAlgorithms ssh-ed25519' "${HOME}/.ssh/config.d/10-github.conf"
    [ "$(head -1 "${HOME}/.ssh/config")" = 'Include ~/.ssh/config.d/*.conf' ]
}

@test "git_github_ssh_stanza is idempotent" {
    _git_home
    git_github_ssh_stanza
    before="$(cat "${HOME}/.ssh/config")"
    git_github_ssh_stanza
    [ "$(cat "${HOME}/.ssh/config")" = "$before" ]
    [ "$(grep -c 'Include' "${HOME}/.ssh/config")" -eq 1 ]
}

@test "git_github_ssh_stanza migrates a stanza appended to ~/.ssh/config" {
    _git_home
    mkdir -p "${HOME}/.ssh"
    printf 'Host other\n    User bob\n\nHost github\n    User git\n    AddKeysToAgent yes\n' \
        > "${HOME}/.ssh/config"
    git_github_ssh_stanza
    # The appended copy is gone from config, the unrelated host survives, and
    # the real stanza is now the file under config.d.
    ! grep -q 'Host github' "${HOME}/.ssh/config"
    grep -q 'Host other' "${HOME}/.ssh/config"
    grep -qx 'Host github' "${HOME}/.ssh/config.d/10-github.conf"
}

@test "git_github_ssh_stanza puts the include ahead of an existing Host block" {
    _git_home
    mkdir -p "${HOME}/.ssh"
    printf 'Host *\n    ServerAliveInterval 60\n' > "${HOME}/.ssh/config"
    git_github_ssh_stanza
    [ "$(head -1 "${HOME}/.ssh/config")" = 'Include ~/.ssh/config.d/*.conf' ]
    grep -q 'ServerAliveInterval 60' "${HOME}/.ssh/config"
}

@test "git_pin_github_host_key writes a key matching its own fingerprint" {
    _git_home
    git_pin_github_host_key
    grep -qxF "$GITHUB_HOST_KEY" "${HOME}/.ssh/known_hosts"
    got="$(ssh-keygen -lf "${HOME}/.ssh/known_hosts" | awk '{print $2}')"
    [ "$got" = "$GITHUB_HOST_FPR" ]
}

@test "git_pin_github_host_key is idempotent" {
    _git_home
    git_pin_github_host_key
    git_pin_github_host_key
    [ "$(grep -c 'ssh-ed25519' "${HOME}/.ssh/known_hosts")" -eq 1 ]
}

@test "git_pin_github_host_key replaces an entry acquired by trust-on-first-use" {
    _git_home
    mkdir -p "${HOME}/.ssh"
    ssh-keygen -t ed25519 -f "${TMP}/tofu" -N "" -q
    printf 'github.com %s\n' "$(cut -d" " -f1,2 < "${TMP}/tofu.pub")" \
        > "${HOME}/.ssh/known_hosts"
    git_pin_github_host_key
    grep -qxF "$GITHUB_HOST_KEY" "${HOME}/.ssh/known_hosts"
    [ "$(grep -c 'ssh-ed25519' "${HOME}/.ssh/known_hosts")" -eq 1 ]
}

@test "git_pin_github_host_key refuses a key that contradicts its fingerprint" {
    _git_home
    ssh-keygen -t ed25519 -f "${TMP}/wrong" -N "" -q
    GITHUB_HOST_KEY="github.com $(cut -d" " -f1,2 < "${TMP}/wrong.pub")"
    run git_pin_github_host_key
    [ "$status" -ne 0 ]
    [ ! -f "${HOME}/.ssh/known_hosts" ]
}

@test "git_pin_github_host_key leaves other hosts in known_hosts alone" {
    _git_home
    mkdir -p "${HOME}/.ssh"
    ssh-keygen -t ed25519 -f "${TMP}/elsewhere" -N "" -q
    printf 'example.com %s\n' "$(cut -d" " -f1,2 < "${TMP}/elsewhere.pub")" \
        > "${HOME}/.ssh/known_hosts"
    git_pin_github_host_key
    grep -q '^example.com ' "${HOME}/.ssh/known_hosts"
    grep -qxF "$GITHUB_HOST_KEY" "${HOME}/.ssh/known_hosts"
}

# ── require_unprivileged ──────────────────────────────────────────────────────
#
# These replace setup()'s permissive sudo stub with one that records how it was
# called and simulates a specific sudo configuration. The point of every test
# is which sudo invocations happen, not what they return: `sudo -v`
# authenticates even under NOPASSWD:ALL, so calling it when the non-interactive
# probe already succeeded is what produced a password prompt on every run of a
# correctly configured machine.

_sudo_calls() { cat "${TMP}/sudo.calls" 2>/dev/null; }

# Passwordless sudo available: `sudo -n true` succeeds.
_stub_sudo_nopasswd() {
    # shellcheck disable=SC2317
    sudo() {
        printf '%s\n' "$*" >> "${TMP}/sudo.calls"
        case "$1" in
            -n) return 0 ;;
            -v) return 0 ;;
            *)  return 0 ;;
        esac
    }
    export -f sudo
}

# Ordinary password sudo: the non-interactive probe fails, -v can still prompt.
_stub_sudo_password() {
    # shellcheck disable=SC2317
    sudo() {
        printf '%s\n' "$*" >> "${TMP}/sudo.calls"
        case "$1" in
            -n) return 1 ;;
            -v) return 0 ;;
            *)  return 0 ;;
        esac
    }
    export -f sudo
}

# No terminal and no NOPASSWD rule: both fail, as sudo does in a pipeline.
_stub_sudo_unavailable() {
    # shellcheck disable=SC2317
    sudo() {
        printf '%s\n' "$*" >> "${TMP}/sudo.calls"
        return 1
    }
    export -f sudo
}

@test "require_unprivileged does not run 'sudo -v' when sudo is already passwordless" {
    _stub_sudo_nopasswd
    run require_unprivileged
    [ "$status" -eq 0 ]
    # The regression this guards: -v authenticates despite NOPASSWD:ALL, so
    # reaching it here is a password prompt on a machine that needs none.
    ! _sudo_calls | grep -q -- '-v'
    _sudo_calls | grep -q -- '-n true'
}

@test "require_unprivileged primes the timestamp when the probe fails" {
    _stub_sudo_password
    run require_unprivileged
    [ "$status" -eq 0 ]
    _sudo_calls | grep -q -- '-n true'
    _sudo_calls | grep -q -- '-v'
}

@test "require_unprivileged dies when sudo is unavailable altogether" {
    _stub_sudo_unavailable
    run require_unprivileged
    [ "$status" -ne 0 ]
    [[ "$output" == *"sudo access is required"* ]]
}

@test "require_unprivileged says how to fix a run with no terminal" {
    _stub_sudo_unavailable
    run require_unprivileged
    [[ "$output" == *"NOPASSWD"* ]]
}

@test "require_unprivileged refuses to run as root" {
    # EUID is readonly, so the root branch can only be reached by having bash
    # inherit EUID from the environment. bash 5.3 does; older releases ignore
    # it and set EUID from the real process. Skipping beats asserting on a
    # branch that never ran — the failure mode this suite is meant to avoid is
    # a test that passes locally and means nothing in CI.
    [ "$(env EUID=0 bash -c 'echo $EUID')" = "0" ] \
        || skip "this bash does not inherit EUID from the environment"

    _stub_sudo_nopasswd
    run env EUID=0 bash -c '
        . "'"${LIB}"'/log.sh"
        . "'"${LIB}"'/privilege.sh"
        EUID=0 SUDO_USER=someone require_unprivileged
    '
    [ "$status" -ne 0 ]
    [[ "$output" == *"not as root"* ]]
}
