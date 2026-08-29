#!/usr/bin/env bats
# Unit tests for the pure parts of the library.
#
# Scope: functions with real logic and no side effects on the host — JSON
# escaping, manifest parsing, the .orig/.bak branch, the journal round trip.
# The provisioning functions are not usefully unit-testable; a container smoke
# test would tell you more than mocking apt.
#
# sudo is stubbed so everything runs unprivileged inside a temp tree.

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    BIN="${BATS_TEST_DIRNAME}/../bin"
    TMP="$(mktemp -d)"

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
}

teardown() {
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

@test "apt_install_list fails loudly on a missing manifest" {
    run apt_install_list "${TMP}/nope.list"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Package list not found"* ]]
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
