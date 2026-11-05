#!/usr/bin/env bats
# Unit tests for command.sh — command_path, commands_present, require_commands.
#
# PATH is a temp bin plus /usr/bin and /bin. The directories --sbin searches
# (_COMMAND_SBIN_DIRS, set after sourcing: the library assigns it) are a temp
# sbin, holding an executable, a file without the execute bit and a directory
# of the right name, and the temp bin, so a command can be in PATH, in the
# list, or in both. No tool outside coreutils is needed.

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    export LIB
    TMP="$(mktemp -d)"
    export TMP
    mkdir -p "${TMP}/bin/dirpath" "${TMP}/sbin/dirtool"
    printf '#!/bin/sh\nexit 0\n' > "${TMP}/bin/pathtool"
    printf '#!/bin/sh\nexit 0\n' > "${TMP}/bin/noexecpath"
    printf '#!/bin/sh\nexit 0\n' > "${TMP}/sbin/sbintool"
    printf '#!/bin/sh\nexit 0\n' > "${TMP}/sbin/noexec"
    chmod 0755 "${TMP}/bin/pathtool" "${TMP}/sbin/sbintool"
    chmod 0644 "${TMP}/bin/noexecpath" "${TMP}/sbin/noexec"
    export PATH="${TMP}/bin:/usr/bin:/bin"
    # shellcheck source=/dev/null
    . "${LIB}/log.sh"
    # shellcheck source=/dev/null
    . "${LIB}/command.sh"
    _COMMAND_SBIN_DIRS="${TMP}/sbin ${TMP}/bin"
    export _COMMAND_SBIN_DIRS
}

teardown() {
    rm -rf -- "$TMP"
}

# A case that changes PATH or the cwd runs in a fresh bash, so nothing leaks
# into the test process (teardown removes $TMP, and a bats run whose cwd is
# gone aborts without naming the failing test). The library assigns
# _COMMAND_SBIN_DIRS at source time, so the fresh bash sets it afterwards.
_SOURCE='. "${LIB}/log.sh"; . "${LIB}/command.sh"; _COMMAND_SBIN_DIRS="${TMP}/sbin ${TMP}/bin";'

# Negatives are `run -N`: a bare `! cmd` that is not a test's last line never
# fails it (errexit ignores an inverted command).

@test "command_path: the absolute path of a PATH command" {
    run command_path pathtool
    [ "$status" -eq 0 ]
    [ "$output" = "${TMP}/bin/pathtool" ]
    [ "$(command_path printf)" = /usr/bin/printf ]
}

@test "command_path: an sbin command only with --sbin" {
    run command_path sbintool
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run command_path --sbin sbintool
    [ "$status" -eq 0 ]
    [ "$output" = "${TMP}/sbin/sbintool" ]
    [ "$(command_path --sbin pathtool)" = "${TMP}/bin/pathtool" ]
}

@test "command_path: --sbin does not consult PATH at all" {
    # /usr/bin is in PATH and not in the list.
    run command_path --sbin printf
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    # A stub ahead of the list in PATH is what this shell would run, not
    # what root runs: the list's copy is printed, never the stub.
    mkdir "${TMP}/ahead"
    printf '#!/bin/sh\nexit 0\n' > "${TMP}/ahead/sbintool"
    chmod 0755 "${TMP}/ahead/sbintool"
    run bash -c "export PATH=\"${TMP}/ahead:\$PATH\"; ${_SOURCE} command_path sbintool; command_path --sbin sbintool"
    [ "$status" -eq 0 ]
    [ "$output" = "${TMP}/ahead/sbintool"$'\n'"${TMP}/sbin/sbintool" ]
}

@test "command_path: a file without the execute bit, or a directory, is not a command, in PATH or with --sbin" {
    run command_path noexecpath
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run command_path dirpath
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run command_path --sbin noexec
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run command_path --sbin dirtool
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "command_path: a name with a slash, or an empty name, is refused" {
    run command_path "${TMP}/bin/pathtool"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run command_path bin/pathtool
    [ "$status" -eq 1 ]
    run -1 command_path ""
    run -1 command_path
    run -1 command_path --sbin
    run -1 command_path --sbin "${TMP}/sbin/sbintool"
}

@test "command_path: a shell function is not a command, the file behind a builtin's name is" {
    # shellcheck disable=SC2317
    f() { :; }
    run -1 command_path f
    [ "$(command_path printf)" = /usr/bin/printf ]
}

@test "command_path: a relative PATH entry does not count, even from the directory it names" {
    run bash -c "cd \"${TMP}/bin\" && export PATH=.:/usr/bin && ${_SOURCE} command_path pathtool"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    # The same command, by its absolute PATH entry, is found from there.
    run bash -c "cd \"${TMP}/bin\" && export PATH=\"${TMP}/bin:/usr/bin\" && ${_SOURCE} command_path pathtool"
    [ "$status" -eq 0 ]
    [ "$output" = "${TMP}/bin/pathtool" ]
}

@test "command_path: _COMMAND_SBIN_DIRS is the library's, not the environment's" {
    run bash -c "export _COMMAND_SBIN_DIRS=\"${TMP}/sbin\"; . \"\${LIB}/log.sh\"; . \"\${LIB}/command.sh\"; printf '%s\n' \"\$_COMMAND_SBIN_DIRS\""
    [ "$status" -eq 0 ]
    [ "$output" = "/usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin" ]
}

@test "command_path: an empty _COMMAND_SBIN_DIRS makes --sbin find nothing" {
    _COMMAND_SBIN_DIRS=""
    run -1 command_path --sbin sbintool
    run -1 command_path --sbin pathtool
    run -0 command_path pathtool
}

@test "command_path: a relative entry in _COMMAND_SBIN_DIRS is ignored" {
    _COMMAND_SBIN_DIRS="${TMP#/}/sbin"
    run -1 command_path --sbin sbintool
    run bash -c "cd / && ${_SOURCE} _COMMAND_SBIN_DIRS=\"${TMP#/}/sbin bin ${TMP}/sbin\"; command_path --sbin sbintool"
    [ "$status" -eq 0 ]
    [ "$output" = "${TMP}/sbin/sbintool" ]
}

@test "command_path: --sbin splits the list on spaces whatever IFS is" {
    IFS=$'\n\t'
    run command_path --sbin sbintool
    [ "$status" -eq 0 ]
    [ "$output" = "${TMP}/sbin/sbintool" ]
    [ "$(command_path --sbin pathtool)" = "${TMP}/bin/pathtool" ]
}

@test "commands_present: the missing names on one line, in the order given, status 1, nothing logged" {
    run --separate-stderr commands_present nope1 sbintool pathtool
    [ "$status" -eq 1 ]
    [ "$output" = "nope1 sbintool" ]
    [ -z "$stderr" ]
    run --separate-stderr commands_present --sbin nope1 sbintool pathtool
    [ "$status" -eq 1 ]
    [ "$output" = "nope1" ]
    [ -z "$stderr" ]
}

@test "commands_present: every name found is 0 and prints nothing; so is no name at all" {
    run --separate-stderr commands_present pathtool printf
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    run --separate-stderr commands_present --sbin pathtool sbintool
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    run --separate-stderr commands_present
    [ "$status" -eq 0 ]
    [ -z "$output" ]
    [ -z "$stderr" ]
    run --separate-stderr commands_present --
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "commands_present: -- ends the options, so a name may look like one" {
    run commands_present -- --sbin pathtool
    [ "$status" -eq 1 ]
    [ "$output" = "--sbin" ]
    run commands_present --sbin -- sbintool
    [ "$status" -eq 0 ]
}

@test "require_commands: returns when every command is found, and the caller goes on" {
    run bash -c "${_SOURCE} require_commands --sbin sbintool pathtool; echo NEXT"
    [ "$status" -eq 0 ]
    [ "$output" = NEXT ]
    run bash -c "${_SOURCE} require_commands pathtool printf; echo NEXT"
    [ "$status" -eq 0 ]
    [ "$output" = NEXT ]
}

@test "require_commands: names every missing command on stderr and exits 1 before the next line" {
    run --separate-stderr bash -c "${_SOURCE} require_commands a b pathtool; echo NEXT"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"[ERROR] Missing required commands: a b" ]]
    # Without --sbin an sbin-only command is missing too.
    run --separate-stderr bash -c "${_SOURCE} require_commands sbintool; echo NEXT"
    [ "$status" -eq 1 ]
    [[ "$stderr" == *"Missing required commands: sbintool" ]]
}

@test "require_commands: a name after -- is a name, even --sbin" {
    run --separate-stderr bash -c "${_SOURCE} require_commands -- --sbin pathtool; echo NEXT"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"[ERROR] Missing required commands: --sbin" ]]
}

@test "require_commands: --hint adds the caller's line after the missing names" {
    run --separate-stderr bash -c "${_SOURCE} require_commands --hint 'run x --install' a pathtool; echo NEXT"
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"[ERROR] Missing required commands: a"$'\n'*"[ERROR] run x --install" ]]
    # Nothing missing: no hint either.
    run --separate-stderr bash -c "${_SOURCE} require_commands --hint 'run x --install' -- pathtool; echo NEXT"
    [ "$status" -eq 0 ]
    [ "$output" = NEXT ]
    [ -z "$stderr" ]
}

@test "require_commands: an unknown option, or --hint with no text, dies" {
    run require_commands --hnt x pathtool
    [ "$status" -eq 1 ]
    [[ "$output" == *"require_commands: unknown option --hnt"* ]]
    run require_commands --hint
    [ "$status" -eq 1 ]
    [[ "$output" == *"require_commands: --hint needs text"* ]]
}
