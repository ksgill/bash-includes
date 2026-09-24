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
    # shellcheck disable=SC2317
    apt-get() { return 0; }
}

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
