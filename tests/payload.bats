#!/usr/bin/env bats
# Unit tests for payload.sh — a built payload checked before use and rendered
# under a settings header — and for log.sh's log_printable, the sibling of
# the comment strip payload_render applies.
#
# Everything runs against small files in a temp tree: a payload is a few
# lines with a shebang and a dispatch line, a "development checkout" is a
# _bootstrap_lib function defined in the test, and _PAYLOAD_LIBDIR is
# pointed at a directory of the test's own, so the library's real lib/ (far
# newer than any fixture) never enters the modification-time comparison.
# Nothing here needs root or a built consumer.

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    TMP="$(mktemp -d)"
    export TMP
    # shellcheck source=/dev/null
    . "${LIB}/log.sh"
    # shellcheck source=/dev/null
    . "${LIB}/payload.sh"

    # A payload as bld writes one: a shebang, code, a dispatch line last.
    P="${TMP}/payload.sh"
    printf '#!/usr/bin/env bash\nset -euo pipefail\nmain() { :; }\nmain\n' > "$P"
    SRC="${TMP}/src.sh"
    printf '#!/usr/bin/env bash\n' > "$SRC"
    LIBDIR="${TMP}/lib"
    mkdir "$LIBDIR"
}

teardown() {
    rm -rf -- "$TMP"
}

# Fixed, distinct modification times (whole seconds; -nt is at least that fine).
T_OLD=1700000000
T_MID=1700000100
T_NEW=1700000200

# ── payload_check: content, in both modes ────────────────────────────────────

@test "payload_check: a missing and an empty artefact are refused with distinct messages" {
    run payload_check "${TMP}/none" "$SRC"
    [ "$status" -eq 1 ]
    [[ "$output" == *"${TMP}/none is missing"*"Run ./build.sh again (a checkout) or reinstall the built script. Nothing was written or changed."* ]]
    : > "${TMP}/empty"
    run payload_check "${TMP}/empty" "$SRC"
    [ "$status" -eq 1 ]
    [[ "$output" == *"${TMP}/empty is empty"*"Nothing was written or changed."* ]]
    # A directory is not a payload either.
    run payload_check "$LIBDIR" "$SRC"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is empty"* ]]
    # The good payload passes (no _bootstrap_lib here: content only).
    run payload_check "$P" "$SRC"
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "payload_check: --last main refuses a file ending in another line and accepts one ending in main followed by blank lines" {
    printf '#!/bin/bash\nmain() { :; }\nmain\n\n   \n\t\n' > "$P"
    run payload_check --last main "$P" "$SRC"
    [ "$status" -eq 0 ]
    printf '#!/bin/bash\nmain() { :; }\nmain\nmain() { :; }\n' > "$P"
    run payload_check --last main "$P" "$SRC"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not end with the line 'main'"*"cut short or not a built copy of ${SRC}"* ]]
    # The same file passes without --last: the last line is the caller's
    # contract, not the library's.
    run payload_check "$P" "$SRC"
    [ "$status" -eq 0 ]
    # The whole line must match, not a prefix or a suffix.
    printf '#!/bin/bash\nmain() { :; }\nmain "$@"\n' > "$P"
    run payload_check --last main "$P" "$SRC"
    [ "$status" -eq 1 ]
    # A file of blank lines only is "empty" by the last-line check, not a crash.
    printf '\n\n' > "$P"
    run payload_check --last main "$P" "$SRC"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not end with the line 'main'"* ]]
}

@test "payload_check: a payload that does not parse (bash -n) is refused" {
    printf '#!/bin/bash\nif true; then\n' > "$P"
    run payload_check "$P" "$SRC"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not parse (bash -n)"* ]]
    # Cut at a line boundary it parses, and only --last catches it.
    printf '#!/bin/bash\nmain() { :; }\n' > "$P"
    run payload_check "$P" "$SRC"
    [ "$status" -eq 0 ]
    run payload_check --last main "$P" "$SRC"
    [ "$status" -eq 1 ]
}

@test "payload_check: the exact marker line or a _bootstrap_lib() definition is refused; a payload that only mentions _bootstrap_lib passes" {
    printf '#!/bin/bash\n# >>> bash-includes >>>\n# include: log.sh\n# <<< bash-includes <<<\nmain\n' > "$P"
    run payload_check "$P" "$SRC"
    [ "$status" -eq 1 ]
    [[ "$output" == *"still holds the development bootstrap"* ]]
    printf '#!/bin/bash\n_bootstrap_lib() {\n    :\n}\n_bootstrap_lib\nmain\n' > "$P"
    run payload_check "$P" "$SRC"
    [ "$status" -eq 1 ]
    [[ "$output" == *"still holds the development bootstrap"* ]]
    # The regression that rules out a substring grep: a built payload that
    # includes payload.sh carries the name in its code, and a comment can
    # carry the marker text inline.
    printf '#!/bin/bash\ndeclare -f _bootstrap_lib >/dev/null 2>&1 || :\n# the block is # >>> bash-includes >>> to # <<< bash-includes <<<\nx="# >>> bash-includes >>>"\nmain\n' > "$P"
    run payload_check "$P" "$SRC"
    [ "$status" -eq 0 ]
    # payload.sh itself, built into a payload, passes its own check.
    { printf '#!/bin/bash\n'; cat "${LIB}/log.sh" "${LIB}/payload.sh"; printf 'main\n'; } > "$P"
    run payload_check --last main "$P" "$SRC"
    [ "$status" -eq 0 ]
}

# ── payload_check: modification times, in a checkout only ────────────────────

@test "payload_check: with _bootstrap_lib defined, an artefact older than its source, a dependency or a file in _PAYLOAD_LIBDIR is refused" {
    _bootstrap_lib() { :; }
    _PAYLOAD_LIBDIR="$LIBDIR"
    local dep="${TMP}/LIB_VERSION" libf="${LIBDIR}/x.sh"
    printf 'v1\n' > "$dep"
    printf '# x\n' > "$libf"
    touch -d "@${T_MID}" "$P"
    touch -d "@${T_OLD}" "$SRC" "$dep" "$libf"
    run payload_check "$P" "$SRC" "$dep"
    [ "$status" -eq 0 ]

    touch -d "@${T_NEW}" "$SRC"
    run payload_check "$P" "$SRC" "$dep"
    [ "$status" -eq 1 ]
    [[ "$output" == *"${P} is older than ${SRC}"*"Nothing was written or changed."* ]]
    touch -d "@${T_OLD}" "$SRC"

    touch -d "@${T_NEW}" "$dep"
    run payload_check "$P" "$SRC" "$dep"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is older than ${dep}"* ]]
    # Only the dependencies given count.
    run payload_check "$P" "$SRC"
    [ "$status" -eq 0 ]
    touch -d "@${T_OLD}" "$dep"

    touch -d "@${T_NEW}" "$libf"
    run payload_check "$P" "$SRC" "$dep"
    [ "$status" -eq 1 ]
    [[ "$output" == *"is older than ${libf}"* ]]
    # Only *.sh in the library directory count.
    touch -d "@${T_OLD}" "$libf"
    printf 'v\n' > "${LIBDIR}/VERSION"
    touch -d "@${T_NEW}" "${LIBDIR}/VERSION"
    run payload_check "$P" "$SRC" "$dep"
    [ "$status" -eq 0 ]

    # A source or dependency that does not exist is skipped, not an error.
    run payload_check "$P" "${TMP}/nosrc" "${TMP}/nodep"
    [ "$status" -eq 0 ]
    # Content is still checked first.
    printf '#!/bin/bash\nif\n' > "$P"
    run payload_check "$P" "$SRC"
    [ "$status" -eq 1 ]
    [[ "$output" == *"does not parse"* ]]
}

@test "payload_check: without _bootstrap_lib the modification times are ignored and the content checks still run" {
    run ! declare -f _bootstrap_lib
    _PAYLOAD_LIBDIR="$LIBDIR"
    printf '# x\n' > "${LIBDIR}/x.sh"
    touch -d "@${T_OLD}" "$P"
    touch -d "@${T_NEW}" "$SRC" "${LIBDIR}/x.sh"
    run payload_check "$P" "$SRC" "${LIBDIR}/x.sh"
    [ "$status" -eq 0 ]
    printf '#!/bin/bash\nmain() { :; }\n' > "$P"
    touch -d "@${T_OLD}" "$P"
    run payload_check --last main "$P" "$SRC"
    [ "$status" -eq 1 ]
}

@test "payload_check: _PAYLOAD_LIBDIR is the directory payload.sh was sourced from" {
    [ "$_PAYLOAD_LIBDIR" = "$(cd "$LIB" && pwd -P)" ]
    local out
    # Absolute whatever the sourcing path, so a later cd in the entry point
    # cannot empty the lib-newer-than-artefact comparison.
    local abs
    abs="$(cd "$LIB" && pwd -P)"
    out="$(cd "$LIB" && bash -c '. ./log.sh; . ./payload.sh; printf %s "$_PAYLOAD_LIBDIR"')"
    [ "$out" = "$abs" ]
    out="$(cd "$LIB" && bash -c '. log.sh; . payload.sh; printf %s "$_PAYLOAD_LIBDIR"')"
    [ "$out" = "$abs" ]
    out="$(cd "$LIB/.." && bash -c '. lib/log.sh; . lib/payload.sh; cd /; printf %s "$_PAYLOAD_LIBDIR"')"
    [ "$out" = "$abs" ]
}

@test "payload_check: returns rather than exits, under the caller's strict mode" {
    run bash -c "set -euo pipefail; . '${LIB}/log.sh'; . '${LIB}/payload.sh'; payload_check '${TMP}/none' '${SRC}' || echo rc=\$?; echo after"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=1"*"after" ]]
}

@test "payload_check: a bad call is refused before anything is read" {
    run payload_check --last
    [ "$status" -eq 1 ]
    [[ "$output" == *"--last needs a value"* ]]
    run payload_check --bogus "$P" "$SRC"
    [ "$status" -eq 1 ]
    run payload_check "$P"
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage"* ]]
    # -- ends the options, so an artefact named like one is still a path.
    run payload_check -- "$P" "$SRC"
    [ "$status" -eq 0 ]
}

# ── payload_render ───────────────────────────────────────────────────────────

@test "payload_render: --shebang replaces line 1; without it the payload's own stays; the body follows from line 2" {
    run payload_render --shebang '#!/bin/bash' "$P"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = '#!/bin/bash' ]
    [ "${lines[1]}" = 'set -euo pipefail' ]
    [ "${#lines[@]}" -eq 4 ]
    run payload_render "$P"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = '#!/usr/bin/env bash' ]
    [ "$(payload_render "$P" | tail -n +2)" = "$(tail -n +2 "$P")" ]
    # The rendered file runs.
    payload_render --shebang '#!/bin/bash' "$P" > "${TMP}/out"
    bash "${TMP}/out"
}

@test "payload_render: a payload whose line 1 is not #! is refused, and so is a --shebang that is not one" {
    printf 'echo hi\nmain\n' > "$P"
    run --separate-stderr payload_render --shebang '#!/bin/bash' "$P"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"does not start with a shebang line"* ]]
    run --separate-stderr payload_render "$P"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    : > "$P"
    run --separate-stderr payload_render "$P"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run --separate-stderr payload_render "${TMP}/none"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"cannot read"* ]]
    printf '#!/bin/bash\nmain\n' > "$P"
    run --separate-stderr payload_render --shebang 'bash' "$P"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run --separate-stderr payload_render --shebang $'#!/bin/bash\nrm -rf /' "$P"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"--shebang line must start with #!"* ]]
}

@test "payload_render: --shebang '' is a shebang that is not one, not an absent option" {
    # An unset variable passed as the value must not quietly hand a
    # root-run hook the payload's own line 1.
    run --separate-stderr payload_render --shebang '' "$P"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *'--shebang line must start with #!'* ]]
}

@test "payload_render: a --comment with an embedded newline and ESC comes out as one comment line; several keep their order" {
    run payload_render --comment $'one\ntwo\e[31m three' --comment 'four' "$P"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = '#!/usr/bin/env bash' ]
    [ "${lines[1]}" = '# onetwo[31m three' ]
    [ "${lines[2]}" = '# four' ]
    [ "${lines[3]}" = 'set -euo pipefail' ]
    # The strip is under the C locale: a multibyte character is not a
    # control character and stays, and so does U+0085 (NEL), which a UTF-8
    # locale's [[:cntrl:]] would take out — the bytes are a comment's, and
    # bash never reads them.
    run payload_render --comment 'café' "$P"
    [ "${lines[1]}" = '# café' ]
    LC_ALL=C.UTF-8 run payload_render --comment $'a\xc2\x85b' "$P"
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = $'# a\xc2\x85b' ]
}

@test "payload_render: NAME=%q round-trips a value with a space, &, ', a newline and a multibyte character (LC_ALL=C: bytewise escapes)" {
    # The value is seen by payload_render through the caller's scope.
    A=$'sp ace&\'quote$\\back\nnew\tline é|;'
    B=plain
    payload_render --shebang '#!/bin/bash' "$P" A B > "${TMP}/out"
    [ "$(sed -n '1p' "${TMP}/out")" = '#!/bin/bash' ]
    [ "$(sed -n '3p' "${TMP}/out")" = 'B=plain' ]
    # Bytewise, whatever the locale the caller runs in.
    grep -qF '\303\251' "${TMP}/out"
    local got
    got="$(bash -c ". '${TMP}/out'; printf '%s' \"\$A\"")"
    [ "$got" = "$A" ]
    got="$(bash -c ". '${TMP}/out'; printf '%s' \"\$B\"")"
    [ "$got" = plain ]
    local loc
    loc="$(locale -a 2>/dev/null | grep -ix 'en_US.utf8\|C.utf8' | head -1)" || loc=""
    if [[ -n "$loc" ]]; then
        LC_ALL="$loc" payload_render "$P" A > "${TMP}/out2"
        grep -qF '\303\251' "${TMP}/out2"
        got="$(bash -c ". '${TMP}/out2'; printf '%s' \"\$A\"")"
        [ "$got" = "$A" ]
    fi
}

@test "payload_render: NAME=value takes the literal, --readonly prefixes every setting, settings keep their order" {
    LIST="10.0.0.0/8 192.168.1.0/24"
    run payload_render --readonly "$P" 'FOO=bar baz' 'WG_HELPER_PARAMS=1' 'VPN_LAN_NETS=' "LIST"
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = 'readonly FOO=bar\ baz' ]
    [ "${lines[2]}" = 'readonly WG_HELPER_PARAMS=1' ]
    [ "${lines[3]}" = "readonly VPN_LAN_NETS=''" ]
    [ "${lines[4]}" = 'readonly LIST=10.0.0.0/8\ 192.168.1.0/24' ]
    [ "${lines[5]}" = 'set -euo pipefail' ]
    # A literal with an = in the value keeps everything after the first.
    run payload_render "$P" 'EQ=a=b'
    [ "${lines[1]}" = 'EQ=a=b' ]
    # A bare NAME is not readonly without the flag.
    run payload_render "$P" LIST
    [ "${lines[1]}" = 'LIST=10.0.0.0/8\ 192.168.1.0/24' ]
}

@test "payload_render: an invalid NAME (a-b, 1x, x;y, a space, empty) is refused, bare or with a value, and nothing is printed" {
    local n
    for n in a-b 1x 'x;y' 'a b' '' 'é' 'a[$(echo INJECTED >&2)]'; do
        run --separate-stderr payload_render "$P" "$n"
        [ "$status" -eq 1 ]
        [ -z "$output" ]
        [[ "$stderr" == *"is not a setting name"* ]]
        # The name is echoed back as text, never evaluated.
        run ! grep -qx INJECTED <<< "$stderr"
        run --separate-stderr payload_render "$P" "${n}=value"
        [ "$status" -eq 1 ]
        [ -z "$output" ]
    done
    # Checked before anything is printed, even when it is the last setting.
    GOOD=1
    run --separate-stderr payload_render "$P" GOOD 'a-b=1'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "payload_render: an unset NAME is refused while an empty one is accepted" {
    unset UNSET_SETTING
    run --separate-stderr payload_render "$P" UNSET_SETTING
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"UNSET_SETTING is not set"* ]]
    EMPTY_SETTING=""
    run payload_render "$P" EMPTY_SETTING
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = "EMPTY_SETTING=''" ]
}

@test "payload_render: a NAME equal to one of its own _payload_ locals is refused, so \${!NAME} can never read a local" {
    _payload_file="leaked"
    run --separate-stderr payload_render "$P" _payload_file
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"not a setting name"* ]]
    run --separate-stderr payload_render "$P" '_payload_ro=x'
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    # Other underscore names are fine.
    _PRIVATE=1
    run payload_render "$P" _PRIVATE
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = '_PRIVATE=1' ]
    # No local named LC_ALL either: a caller's LC_ALL is rendered as its own.
    LC_ALL=C.UTF-8
    run payload_render "$P" LC_ALL
    [ "$status" -eq 0 ]
    [ "${lines[1]}" = 'LC_ALL=C.UTF-8' ]
}

@test "payload_render: a bad call is refused; -- ends the options" {
    run payload_render
    [ "$status" -eq 1 ]
    [[ "$output" == *"usage"* ]]
    run payload_render --comment
    [ "$status" -eq 1 ]
    run payload_render --shebang
    [ "$status" -eq 1 ]
    run payload_render --bogus "$P"
    [ "$status" -eq 1 ]
    run payload_render -- "$P"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = '#!/usr/bin/env bash' ]
}

@test "payload_render: every step returns 1 to a caller under strict mode when the output cannot be written" {
    run bash -c "set -euo pipefail; . '${LIB}/log.sh'; . '${LIB}/payload.sh'; payload_render '${P}' > /dev/full || echo rc=\$?; echo after"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=1"*"after" ]]
}

@test "payload.sh runs no command at source time and includes only log.sh" {
    run bash -c "set -euo pipefail; PATH=/nonexistent; . '${LIB}/log.sh'; . '${LIB}/payload.sh'; declare -F payload_check payload_render >/dev/null && echo ok"
    [ "$status" -eq 0 ]
    [ "$output" = ok ]
    [ "$(grep '^# include:' "${LIB}/payload.sh")" = '# include: log.sh' ]
}

# ── log_printable ────────────────────────────────────────────────────────────

@test "log_printable: every byte outside printable ASCII is a ?, under the C locale whatever the caller's" {
    [ "$(log_printable 'plain text 10.8.0.1:22')" = 'plain text 10.8.0.1:22' ]
    [ "$(log_printable $'a\tb\e[0m c\n')" = 'a?b?[0m c?' ]
    [ "$(log_printable 'é')" = '??' ]
    [ "$(log_printable '')" = '' ]
    local loc
    loc="$(locale -a 2>/dev/null | grep -ix 'en_US.utf8\|C.utf8' | head -1)" || loc=""
    if [[ -n "$loc" ]]; then
        [ "$(LC_ALL="$loc" log_printable 'é')" = '??' ]
    fi
    # One line out, whatever went in.
    [ "$(log_printable $'x\ny' | wc -l)" -eq 1 ]
}
