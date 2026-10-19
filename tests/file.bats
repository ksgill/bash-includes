#!/usr/bin/env bats
# Unit tests for file.sh — root-owned files written only when they change.
#
# sudo is a shell function that runs the command as the caller, so "root" is
# the test user throughout (file.sh reads the owner from `sudo id -u`) and
# every file lives in a temp tree. Root ownership itself is therefore not
# verified here; the content, mode, backup, journal, directory-rule and
# atomicity logic is. TMPDIR is a directory of this test's own, checked empty
# after every path: a staging file left behind fails the test.

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    TMP="$(mktemp -d)"
    chmod 0755 "$TMP"
    umask 022
    W="${TMP}/etc"
    mkdir -p "$W"
    export TMPDIR="${TMP}/tmp"
    mkdir -m 0700 "$TMPDIR"

    # shellcheck disable=SC2317
    sudo() { case "${1:-}" in -v|-n) shift ;; esac; [[ $# -eq 0 ]] && return 0; "$@"; }
    export -f sudo

    export JOURNAL_DIR="${TMP}/var/lib/provision"
    export JOURNAL_FILE="${JOURNAL_DIR}/changes.jsonl"

    # shellcheck source=/dev/null
    . "${LIB}/log.sh"
    # shellcheck source=/dev/null
    . "${LIB}/journal.sh"
    # shellcheck source=/dev/null
    . "${LIB}/backup.sh"
    # shellcheck source=/dev/null
    . "${LIB}/file.sh"
    journal_init "test" "v1"
}

teardown() {
    rm -rf "$TMP"
}

mode_of() { stat -c '%a' "$1"; }
# No staging file of either side left: TMPDIR empty, nothing hidden beside the target.
no_leftovers() { [ -z "$(ls -A "$TMPDIR")" ] && [ -z "$(find "$W" -name '.*~' -print)" ]; }
# Run <body> in a child bash under the caller's strict mode, with the library
# loaded as a consumer loads it (cleanup.sh included).
strict() {
    bash -c "set -euo pipefail; export -f sudo; . '${LIB}/log.sh'; . '${LIB}/cleanup.sh'; . '${LIB}/journal.sh'; . '${LIB}/backup.sh'; . '${LIB}/file.sh'; journal_init t v; $1"
}

# ── install_file_if_changed ──────────────────────────────────────────────────

@test "a new file is written with the mode asked for, its parents made 0755, a create record journalled, nothing left behind" {
    run install_file_if_changed --mode 0640 "${W}/a/b/new.conf" "first write" <<< "hello"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Wrote ${W}/a/b/new.conf"* ]]
    [ "$(cat "${W}/a/b/new.conf")" = "hello" ]
    [ "$(mode_of "${W}/a/b/new.conf")" = "640" ]
    [ "$(mode_of "${W}/a")" = "755" ]
    [ "$(mode_of "${W}/a/b")" = "755" ]
    [ ! -e "${W}/a/b/new.conf.bak" ]
    grep -q "\"action\":\"create\",\"target\":\"${W}/a/b/new.conf\",\"detail\":\"first write\"" "$JOURNAL_FILE"
    no_leftovers
}

@test "INSTALL_FILE_CHANGED is 1 after a write, 0 after a no-op and 0 after a failure, in the caller's shell" {
    install_file_if_changed "${W}/f.conf" "r" <<< "one"
    [ "$INSTALL_FILE_CHANGED" -eq 1 ]
    install_file_if_changed "${W}/f.conf" "r" <<< "one"
    [ "$INSTALL_FILE_CHANGED" -eq 0 ]
    install_file_if_changed "${W}/f.conf" "r" <<< "two"
    [ "$INSTALL_FILE_CHANGED" -eq 1 ]
    install_file_if_changed "${W}/f.conf" "r" < /dev/null || true
    [ "$INSTALL_FILE_CHANGED" -eq 0 ]
}

@test "under set -euo pipefail a write, a no-op and a refused write all return to the caller" {
    run strict "install_file_if_changed '${W}/s.conf' r <<< 'x'; echo c=\$INSTALL_FILE_CHANGED; install_file_if_changed '${W}/s.conf' r <<< 'x'; echo c=\$INSTALL_FILE_CHANGED; install_file_if_changed '${W}/s.conf' r < /dev/null || echo rc=\$?; echo c=\$INSTALL_FILE_CHANGED; echo end"
    [ "$status" -eq 0 ]
    [[ "$output" == *"c=1"*"c=0"*"rc=1"*"c=0"*"end" ]]
    no_leftovers
}

@test "the same content and mode is a no-op: no backup, no record, 'unchanged' logged; --quiet logs neither line" {
    install_file_if_changed "${W}/same.conf" "r" <<< "x"
    local before_lines
    before_lines="$(wc -l < "$JOURNAL_FILE")"
    run install_file_if_changed "${W}/same.conf" "r" <<< "x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"${W}/same.conf unchanged"* ]]
    [ ! -e "${W}/same.conf.bak" ]
    [ "$(wc -l < "$JOURNAL_FILE")" = "$before_lines" ]
    run install_file_if_changed --quiet "${W}/same.conf" "r" <<< "x"
    [ "$status" -eq 0 ]
    [[ "$output" != *"unchanged"* && "$output" != *"Wrote"* ]]
    no_leftovers
}

@test "changed content is backed up as .bak and journalled as modify" {
    install_file_if_changed "${W}/c.conf" "r" <<< "old"
    run install_file_if_changed "${W}/c.conf" "second write" <<< "new"
    [ "$status" -eq 0 ]
    [ "$(cat "${W}/c.conf")" = "new" ]
    [ "$(cat "${W}/c.conf.bak")" = "old" ]
    grep -q "\"action\":\"modify\",\"target\":\"${W}/c.conf\",\"detail\":\"second write\"" "$JOURNAL_FILE"
    grep -q "\"backup\":\"${W}/c.conf.bak\"" "$JOURNAL_FILE"
    no_leftovers
}

@test "a mode that differs with the same content is rewritten and journalled, but not backed up" {
    install_file_if_changed "${W}/m.conf" "r" <<< "x"
    chmod 0664 "${W}/m.conf"
    run install_file_if_changed "${W}/m.conf" "r" <<< "x"
    [ "$status" -eq 0 ]
    [[ "$output" == *"Wrote"* ]]
    [ "$(mode_of "${W}/m.conf")" = "644" ]
    [ ! -e "${W}/m.conf.bak" ]
    grep -q "\"action\":\"modify\",\"target\":\"${W}/m.conf\",\"detail\":\"r (mode or owner only)\"" "$JOURNAL_FILE"
}

@test "--no-backup leaves no .bak and records the previous content's sha256 — only for a world-readable file" {
    install_file_if_changed "${W}/k.conf" "r" <<< "old"
    local sha
    sha="$(sha256sum "${W}/k.conf" | cut -d' ' -f1)"
    run install_file_if_changed --no-backup "${W}/k.conf" "r" <<< "new"
    [ "$status" -eq 0 ]
    [ ! -e "${W}/k.conf.bak" ]
    grep -q "\"action\":\"modify\",\"target\":\"${W}/k.conf\".*\"sha256_before\":\"${sha}\"" "$JOURNAL_FILE"

    # A private file: the journal is world-readable, so no hash of it.
    install_file_if_changed --mode 0600 "${W}/p.conf" "r" <<< "secret one"
    run install_file_if_changed --no-backup --mode 0600 "${W}/p.conf" "r" <<< "secret two"
    [ "$status" -eq 0 ]
    [ ! -e "${W}/p.conf.bak" ]
    run ! grep -q "\"target\":\"${W}/p.conf\".*sha256_before" "$JOURNAL_FILE"
    grep -q "\"action\":\"modify\",\"target\":\"${W}/p.conf\"" "$JOURNAL_FILE"
}

@test "content that is empty or whitespace only is refused and the target untouched; --allow-empty writes it" {
    printf 'keep\n' > "${W}/e.conf"
    run install_file_if_changed "${W}/e.conf" "r" < /dev/null
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing to write ${W}/e.conf with empty content"* ]]
    unset_var=""
    run install_file_if_changed "${W}/e.conf" "r" <<< "$unset_var"
    [ "$status" -eq 1 ]
    run install_file_if_changed "${W}/e.conf" "r" <<< $'  \n\t\n'
    [ "$status" -eq 1 ]
    [ "$(cat "${W}/e.conf")" = "keep" ]
    no_leftovers
    run install_file_if_changed --allow-empty "${W}/e.conf" "r" < /dev/null
    [ "$status" -eq 0 ]
    [ ! -s "${W}/e.conf" ]
    [ "$(cat "${W}/e.conf.bak")" = "keep" ]
    no_leftovers
}

@test "a destination that is a directory is refused and left intact" {
    mkdir "${W}/dir"
    printf 'inside\n' > "${W}/dir/keep"
    run install_file_if_changed "${W}/dir" "r" <<< "x"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a regular file"* ]]
    [ -d "${W}/dir" ]
    [ "$(cat "${W}/dir/keep")" = "inside" ]
    no_leftovers
}

@test "a destination that is a symlink has its target replaced and the link kept; a dangling link is refused" {
    printf 'old\n' > "${W}/target.conf"
    ln -s "${W}/target.conf" "${W}/link.conf"
    run install_file_if_changed "${W}/link.conf" "r" <<< "new"
    [ "$status" -eq 0 ]
    [ -L "${W}/link.conf" ]
    [ "$(cat "${W}/target.conf")" = "new" ]
    [ "$(cat "${W}/target.conf.bak")" = "old" ]
    grep -q "\"target\":\"${W}/target.conf\"" "$JOURNAL_FILE"
    ln -s "${W}/nowhere" "${W}/dangling.conf"
    run install_file_if_changed "${W}/dangling.conf" "r" <<< "new"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Could not resolve the link"* ]]
    [ -L "${W}/dangling.conf" ]
    no_leftovers
}

@test "a relative path, a trailing slash, a missing reason, a bad or setuid mode, --mode without a value or an unknown option is refused before anything is written" {
    run install_file_if_changed "etc/x" "r" <<< "x"
    [ "$status" -eq 1 ]
    run install_file_if_changed "${W}/x/" "r" <<< "x"
    [ "$status" -eq 1 ]
    run install_file_if_changed "${W}/x" "" <<< "x"
    [ "$status" -eq 1 ]
    run install_file_if_changed --mode 0999 "${W}/x" "r" <<< "x"
    [ "$status" -eq 1 ]
    [[ "$output" == *"not a mode of three octal digits"* ]]
    run install_file_if_changed --mode 4755 "${W}/x" "r" <<< "x"
    [ "$status" -eq 1 ]
    run timeout 5 bash -c "export -f sudo; . '${LIB}/log.sh'; . '${LIB}/journal.sh'; . '${LIB}/backup.sh'; . '${LIB}/file.sh'; install_file_if_changed --mode"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--mode needs a value"* ]]
    run install_file_if_changed --bogus "${W}/x" "r" <<< "x"
    [ "$status" -eq 1 ]
    [ ! -e "${W}/x" ]
    no_leftovers
}

@test "a destination directory someone else can write is refused, as is a link that points into one" {
    mkdir -m 0775 "${W}/shared"
    run install_file_if_changed "${W}/shared/x.conf" "r" <<< "x"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing to write ${W}/shared/x.conf"*"writable by group or other"* ]]
    [ ! -e "${W}/shared/x.conf" ]
    # Missing parents under a writable ancestor are refused too, and not created.
    run install_file_if_changed "${W}/shared/deeper/x.conf" "r" <<< "x"
    [ "$status" -eq 1 ]
    [ ! -e "${W}/shared/deeper" ]
    # A link in a closed directory pointing into the open one.
    printf 'old\n' > "${W}/shared/t.conf"
    ln -s "${W}/shared/t.conf" "${W}/into-shared.conf"
    run install_file_if_changed "${W}/into-shared.conf" "r" <<< "new"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing to write through the link"* ]]
    [ "$(cat "${W}/shared/t.conf")" = "old" ]
    no_leftovers
}

@test "a link planted as a middle component inside an open directory is refused, even when it points at a closed one" {
    mkdir -m 0777 "${W}/open"
    mkdir -m 0755 "${W}/closed"
    ln -s "${W}/closed" "${W}/open/cfg"
    run install_file_if_changed "${W}/open/cfg/x.conf" "r" <<< "x"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing to write ${W}/open/cfg/x.conf"*"writable by group or other"* ]]
    [ ! -e "${W}/closed/x.conf" ]
    run mkdir_root_p "${W}/open/cfg/new/sub"
    [ "$status" -eq 1 ]
    [ ! -e "${W}/closed/new" ]
    run install_atomic "${W}/closed" 0644 "${W}/open/cfg/y.conf"
    [ "$status" -eq 1 ]
    [ ! -e "${W}/closed/y.conf" ]
    # TMPDIR reached through such a link is refused as well.
    ln -s "$TMPDIR" "${W}/open/tmplink"
    TMPDIR="${W}/open/tmplink" run install_file_if_changed "${W}/t.conf" "r" <<< "x"
    [ "$status" -eq 1 ]
    [ ! -e "${W}/t.conf" ]
    no_leftovers
}

@test "a link as a middle component inside a closed directory is followed: the file is written and journalled at the canonical path" {
    mkdir -m 0755 "${W}/real"
    ln -s "${W}/real" "${W}/alias"
    run install_file_if_changed "${W}/alias/deeper/x.conf" "r" <<< "x"
    [ "$status" -eq 0 ]
    [ "$(cat "${W}/real/deeper/x.conf")" = "x" ]
    [ "$(mode_of "${W}/real/deeper")" = "755" ]
    grep -q "\"target\":\"${W}/real/deeper/x.conf\"" "$JOURNAL_FILE"
    run install_file_if_changed "${W}/alias/deeper/x.conf" "r" <<< "x"
    [[ "$output" == *"unchanged"* ]]
    no_leftovers
}

@test "a link owned by another account is never followed, as a final or a middle component (owner faked through the sudo stub)" {
    printf 'old\n' > "${W}/victim.conf"
    ln -s "${W}/victim.conf" "${W}/foreign.conf"
    mkdir -m 0755 "${W}/real"
    ln -s "${W}/real" "${W}/foreigndir"
    # stat -c %u on either link answers "someone else"; everything else runs for real.
    # shellcheck disable=SC2317
    sudo() {
        case "${1:-}" in -v|-n) shift ;; esac
        [[ $# -eq 0 ]] && return 0
        if [[ "$1" == stat && "$2" == -c && "$3" == %u && ( "${5:-}" == "${W}/foreign.conf" || "${5:-}" == "${W}/foreigndir" ) ]]; then
            echo 65534; return 0
        fi
        "$@"
    }
    run install_file_if_changed "${W}/foreign.conf" "r" <<< "new"
    [ "$status" -eq 1 ]
    [[ "$output" == *"Refusing to follow ${W}/foreign.conf"* ]]
    [ "$(cat "${W}/victim.conf")" = "old" ]
    run install_file_if_changed "${W}/foreigndir/x.conf" "r" <<< "new"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not owned by root or the invoking user"* ]]
    [ ! -e "${W}/real/x.conf" ]
    run install_atomic "${W}/victim.conf" 0644 "${W}/foreigndir/y.conf"
    [ "$status" -eq 1 ]
    [ ! -e "${W}/real/y.conf" ]
    no_leftovers
}

@test "a link that points at another link is not followed, as a final or a middle component" {
    printf 'old\n' > "${W}/victim.conf"
    ln -s "${W}/victim.conf" "${W}/hop.conf"
    ln -s "${W}/hop.conf" "${W}/chain.conf"
    run install_file_if_changed "${W}/chain.conf" "r" <<< "new"
    [ "$status" -eq 1 ]
    [[ "$output" == *"points at another link"* ]]
    [ "$(cat "${W}/victim.conf")" = "old" ]
    mkdir -m 0755 "${W}/real"
    ln -s "${W}/real" "${W}/hopdir"
    ln -s "${W}/hopdir" "${W}/chaindir"
    run install_file_if_changed "${W}/chaindir/x.conf" "r" <<< "x"
    [ "$status" -eq 1 ]
    [ ! -e "${W}/real/x.conf" ]
    # One hop is fine, relative targets included.
    ln -s real "${W}/onehop"
    run install_file_if_changed "${W}/onehop/x.conf" "r" <<< "x"
    [ "$status" -eq 0 ]
    [ "$(cat "${W}/real/x.conf")" = "x" ]
    no_leftovers
}

@test "a . or .. among components that do not exist yet is refused before anything is created" {
    mkdir -m 0755 "${W}/closed"
    run install_file_if_changed "${W}/closed/new/../x.conf" "r" <<< "x"
    [ "$status" -eq 1 ]
    [[ "$output" == *". and .. are not allowed"* ]]
    [ ! -e "${W}/closed/new" ]
    run mkdir_root_p "${W}/closed/new2/./sub"
    [ "$status" -eq 1 ]
    [ ! -e "${W}/closed/new2" ]
    # Existing dot components resolve against checked directories and are fine.
    run install_file_if_changed "${W}/closed/./y.conf" "r" <<< "y"
    [ "$status" -eq 0 ]
    [ "$(cat "${W}/closed/y.conf")" = "y" ]
}

@test "a destination that exists and is not a regular file (a FIFO) is refused without hanging" {
    mkfifo "${W}/fifo.conf"
    run timeout 10 bash -c "export -f sudo; . '${LIB}/log.sh'; . '${LIB}/journal.sh'; . '${LIB}/backup.sh'; . '${LIB}/file.sh'; journal_init t v; install_file_if_changed '${W}/fifo.conf' r <<< 'x'"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a regular file"* ]]
    [ -p "${W}/fifo.conf" ]
    no_leftovers
}

@test "a TMPDIR someone else can write is refused before any content is staged" {
    mkdir -m 0777 "${TMP}/opentmp"
    TMPDIR="${TMP}/opentmp" run install_file_if_changed "${W}/t.conf" "r" <<< "x"
    [ "$status" -eq 1 ]
    [[ "$output" == *"refusing to stage content in ${TMP}/opentmp"* ]]
    [ -z "$(ls -A "${TMP}/opentmp")" ]
    [ ! -e "${W}/t.conf" ]
}

@test "with cleanup.sh loaded, a run that dies after staging leaves no temp file behind" {
    printf 'old\n' > "${W}/d.conf"
    # backup_file refuses a backup it cannot write: make the copy fail by
    # taking the .bak name with a directory. It dies, and the exit handler
    # must remove the staged content.
    mkdir "${W}/d.conf.bak"
    run strict "install_file_if_changed '${W}/d.conf' r <<< 'new'; echo not-reached"
    [ "$status" -ne 0 ]
    [[ "$output" == *"Could not back up"* ]]
    [[ "$output" != *"not-reached"* ]]
    [ "$(cat "${W}/d.conf")" = "old" ]
    no_leftovers
}

@test "called through a pipe it still writes (the result just cannot reach the caller)" {
    run bash -c "export -f sudo; . '${LIB}/log.sh'; . '${LIB}/journal.sh'; . '${LIB}/backup.sh'; . '${LIB}/file.sh'; journal_init t v; printf 'x\n' | install_file_if_changed '${W}/p.conf' r"
    [ "$status" -eq 0 ]
    [ "$(cat "${W}/p.conf")" = "x" ]
    no_leftovers
}

# ── file_differs ─────────────────────────────────────────────────────────────

@test "file_differs: true for a missing target, different content or different mode; false when all match, also through a link" {
    printf 'x\n' > "${W}/src"
    file_differs "${W}/src" "${W}/absent" 0644
    printf 'y\n' > "${W}/dest"; chmod 0644 "${W}/dest"
    file_differs "${W}/src" "${W}/dest" 0644
    printf 'x\n' > "${W}/dest"
    run ! file_differs "${W}/src" "${W}/dest" 0644
    run ! file_differs "${W}/src" "${W}/dest" 644
    file_differs "${W}/src" "${W}/dest" 0600
    ln -s "${W}/dest" "${W}/dlink"
    run ! file_differs "${W}/src" "${W}/dlink" 0644
    mkfifo "${W}/fifo"
    timeout 10 bash -c "export -f sudo; . '${LIB}/log.sh'; . '${LIB}/journal.sh'; . '${LIB}/backup.sh'; . '${LIB}/file.sh'; file_differs '${W}/src' '${W}/fifo' 0644"
}

# ── install_atomic ───────────────────────────────────────────────────────────

@test "install_atomic: installs with the mode asked for, replaces by rename (new inode), leaves no staging file" {
    printf 'new\n' > "${W}/src"
    printf 'old\n' > "${W}/dest"
    local before after
    before="$(stat -c %i "${W}/dest")"
    install_atomic "${W}/src" 0640 "${W}/dest"
    after="$(stat -c %i "${W}/dest")"
    [ "$before" != "$after" ]
    [ "$(cat "${W}/dest")" = "new" ]
    [ "$(mode_of "${W}/dest")" = "640" ]
    # The consumed staging name is forgotten, so nothing waits for the exit handler.
    [ "${#_FILE_ROOT_TMPS[@]}" -eq 0 ]
    no_leftovers
}

@test "install_atomic: a source in a directory another account could write (group- or other-writable, not sticky) is refused; a private or a sticky world-writable one is read" {
    printf 'old\n' > "${W}/dest"
    # Another user's rename into this directory, between the caller's write
    # and root's install, would be what root installs.
    mkdir -m 0775 "${W}/shared"
    printf 'new\n' > "${W}/shared/src"
    run --separate-stderr install_atomic "${W}/shared/src" 0640 "${W}/dest"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"refusing to read ${W}/shared/src from its directory"* ]]
    [[ "$stderr" == *"set TMPDIR to a private directory"* ]]
    [ "$(cat "${W}/dest")" = "old" ]
    no_leftovers
    chmod 0777 "${W}/shared"
    run ! install_atomic "${W}/shared/src" 0640 "${W}/dest"
    [ "$(cat "${W}/dest")" = "old" ]
    # A private directory, and the default /tmp's shape (sticky, world-
    # writable, with the kernel's protected_* sysctls on) are both read.
    mkdir -m 0700 "${W}/private"
    printf 'new\n' > "${W}/private/src"
    install_atomic "${W}/private/src" 0640 "${W}/dest"
    [ "$(cat "${W}/dest")" = "new" ]
    if [[ "$(cat /proc/sys/fs/protected_symlinks 2>/dev/null)" == 1 \
          && "$(cat /proc/sys/fs/protected_regular 2>/dev/null)" =~ ^[1-9] ]]; then
        mkdir -m 1777 "${W}/sticky"
        printf 'newer\n' > "${W}/sticky/src"
        install_atomic "${W}/sticky/src" 0640 "${W}/dest"
        [ "$(cat "${W}/dest")" = "newer" ]
    fi
    # A relative source is resolved before the check, not refused for its shape.
    printf 'rel\n' > "${W}/private/rel"
    (cd "${W}/private" && install_atomic rel 0640 "${W}/dest")
    [ "$(cat "${W}/dest")" = "rel" ]
    # A source that does not exist is named, and nothing is staged.
    run --separate-stderr install_atomic "${W}/private/nosuch" 0640 "${W}/dest"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"cannot be resolved"* ]]
    no_leftovers
}

@test "install_atomic: a missing source, a directory at the target, a missing parent or an open parent returns 1 and keeps what is there" {
    printf 'old\n' > "${W}/dest"
    run install_atomic "${W}/nosuch" 0644 "${W}/dest"
    [ "$status" -eq 1 ]
    [ "$(cat "${W}/dest")" = "old" ]
    printf 'new\n' > "${W}/src"
    mkdir "${W}/ddir"; printf 'inside\n' > "${W}/ddir/keep"
    run install_atomic "${W}/src" 0644 "${W}/ddir"
    [ "$status" -eq 1 ]
    [ -d "${W}/ddir" ]
    [ "$(cat "${W}/ddir/keep")" = "inside" ]
    [ ! -e "${W}/ddir/src" ]
    run install_atomic "${W}/src" 0644 "${W}/nodir/dest"
    [ "$status" -eq 1 ]
    [ ! -e "${W}/nodir" ]
    mkdir -m 0777 "${W}/open"
    run install_atomic "${W}/src" 0644 "${W}/open/dest"
    [ "$status" -eq 1 ]
    [ -z "$(ls -A "${W}/open")" ]
    no_leftovers
}

# ── install_atomic_glob ──────────────────────────────────────────────────────

@test "file_dir_trusted: a closed chain passes, a group-writable ancestor (Debian's /usr/local root:staff 2775) is refused by name and mode, nothing is created" {
    mkdir -m 0755 "${W}/usr"
    mkdir -m 0755 "${W}/usr/local"
    file_dir_trusted "${W}/usr/local/libexec/tool"
    [ ! -e "${W}/usr/local/libexec" ]
    chmod 2775 "${W}/usr/local"
    run --separate-stderr file_dir_trusted "${W}/usr/local/libexec/tool"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"root must not write under ${W}/usr/local/libexec/tool: ${W}/usr/local is writable by group or other (mode 2775)"* ]]
    [[ "$stderr" == *"chmod g-w,o-w"* ]]
    [ ! -e "${W}/usr/local/libexec" ]
    chmod 0755 "${W}/usr/local"
    file_dir_trusted "${W}/usr/local/libexec/tool"
    # The directory itself, when it exists, is judged too.
    mkdir -m 0775 "${W}/usr/local/libexec"
    run ! file_dir_trusted "${W}/usr/local/libexec"
    chmod 0755 "${W}/usr/local/libexec"
    file_dir_trusted "${W}/usr/local/libexec"
    file_dir_trusted "${W}/usr/local/libexec/"
    run --separate-stderr file_dir_trusted relative/dir
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"not an absolute path"* ]]
    run --separate-stderr file_dir_trusted
    [ "$status" -eq 1 ]
    # The first file.sh call of a run: root's uid is learned before the walk,
    # so a root-owned link on the chain is judged by it, not by an empty
    # string (v1.16.3).
    _FILE_UID="" _FILE_GID=""
    file_dir_trusted "${W}/usr/local/libexec"
    [[ "$_FILE_UID" =~ ^[0-9]+$ ]]
}

@test "install_atomic_glob: the name install_atomic stages under, made from the same template; 1 for a path that is not absolute" {
    local glob
    glob="$(install_atomic_glob "${W}/fw-up-test.sh")"
    [ "$glob" = '.fw-up-test.sh.[[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]][[:alnum:]]~' ]
    # A name made with the template install_atomic hands to mktemp matches
    # the glob, the way a leftover is looked for (find -name).
    local staged
    staged="$(mktemp --suffix="$_FILE_STAGE_SUFFIX" -- "${W}/$(_file_stage_name fw-up-test.sh template)")"
    [ "$(find "$W" -maxdepth 1 -name "$glob" -print)" = "$staged" ]
    # The glob is exact in length: a name one character shorter or longer
    # is not a staging file, and neither is one without the ~.
    : > "${W}/.fw-up-test.sh.abcdefg~" "${W}/.fw-up-test.sh.abcdefghi~" "${W}/.fw-up-test.sh.abcdefgh"
    [ "$(find "$W" -maxdepth 1 -name "$glob" -print)" = "$staged" ]
    rm -f -- "$staged" "${W}"/.fw-up-test.sh.*
    run install_atomic_glob relative/path
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run install_atomic_glob "${W}/"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run install_atomic_glob
    [ "$status" -eq 1 ]
    # A name that would widen the pattern (glob metacharacters, a control
    # character) is refused rather than escaped: no installed file of the
    # fleet is named that way, and a widened glob removes the wrong files.
    local bad
    for bad in 'a*b' 'a?b' 'a[1].sh' 'a\\b' $'a\nb' $'a\tb'; do
        run install_atomic_glob "${W}/${bad}"
        [ "$status" -eq 1 ]
        [ -z "$output" ]
    done
    # An ordinary name with a dot, a dash and a plus is fine.
    install_atomic_glob "${W}/fw-up.v1+2.sh" > /dev/null
}

@test "install_atomic_glob: the staged name install_atomic really creates matches it, and a refused rename leaves nothing for the glob to find" {
    printf 'new\n' > "${W}/src"
    printf 'old\n' > "${W}/dest"
    local glob
    glob="$(install_atomic_glob "${W}/dest")"
    # The mv after the stage is refused; the stub records the staged name.
    # shellcheck disable=SC2317
    sudo() {
        case "${1:-}" in -v|-n) shift ;; esac
        [[ $# -eq 0 ]] && return 0
        if [[ "$1" == mv ]]; then
            printf '%s\n' "$5" > "${TMP}/staged"
            return 1
        fi
        "$@"
    }
    run install_atomic "${W}/src" 0640 "${W}/dest"
    [ "$status" -eq 1 ]
    local staged
    staged="$(cat "${TMP}/staged")"
    [ "${staged%/*}" = "$W" ]
    # shellcheck disable=SC2053
    [[ "${staged##*/}" == $glob ]]
    [ "$(cat "${W}/dest")" = "old" ]
    # install_atomic removed its staging file: the glob finds nothing.
    [ -z "$(find "$W" -maxdepth 1 -name "$glob" -print)" ]
    no_leftovers
}

# ── mkdir_root_p ─────────────────────────────────────────────────────────────

@test "mkdir_root_p: every missing level is 0755 whatever the umask; existing levels are not touched; an existing file or open ancestor is refused" {
    mkdir -m 0700 "${W}/private"
    (umask 077; mkdir_root_p "${W}/private/a/b")
    [ "$(mode_of "${W}/private")" = "700" ]
    [ "$(mode_of "${W}/private/a")" = "755" ]
    [ "$(mode_of "${W}/private/a/b")" = "755" ]
    mkdir_root_p "${W}/private/a/b"
    run mkdir_root_p "relative/dir"
    [ "$status" -eq 1 ]
    printf 'x\n' > "${W}/afile"
    run mkdir_root_p "${W}/afile/sub"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is not a directory"* ]]
    mkdir -m 0777 "${W}/open"
    run mkdir_root_p "${W}/open/sub"
    [ "$status" -eq 1 ]
    [ ! -e "${W}/open/sub" ]
}

@test "mkdir_root_p: a symlink at an existing level inside a closed directory is followed, and the target's mode is kept" {
    mkdir -m 0700 "${W}/victim"
    ln -s "${W}/victim" "${W}/planted"
    # Only root or the invoker can have placed the link (its directory passes
    # the rule), so it is followed like any existing level: sub is created
    # inside the target, and the target's own mode is kept.
    run mkdir_root_p "${W}/planted/sub"
    [ "$status" -eq 0 ]
    [ -d "${W}/victim/sub" ]
    [ "$(mode_of "${W}/victim")" = "700" ]
    [ "$(mode_of "${W}/victim/sub")" = "755" ]
}
