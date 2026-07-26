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
    # shellcheck source=/dev/null
    . "${LIB}/cleanup.sh"
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
    # Capture what would be installed rather than installing it.
    apt-get() { printf '%s\n' "$@"; }
    export -f apt-get
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
