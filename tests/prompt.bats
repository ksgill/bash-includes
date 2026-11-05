#!/usr/bin/env bats
# Unit tests for prompt.sh — confirm.
#
# The terminal test is the seam: setup replaces _prompt_tty with one that
# always says yes, so a here-string or /dev/null stands in for the operator's
# typing. The one test that needs the real seam runs confirm in a fresh bash
# with stdin a pipe. No terminal needed.
#
# The prompt ends in a space and no newline, which `run` trims from what it
# captures (with --keep-empty-lines too), so the tests that check the prompt
# text send stderr to a file and compare it with cmp.

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    export LIB
    TMP="$(mktemp -d)"
    export TMP
    # shellcheck source=/dev/null
    . "${LIB}/log.sh"
    # shellcheck source=/dev/null
    . "${LIB}/prompt.sh"
    # shellcheck disable=SC2317
    _prompt_tty() { :; }
}

teardown() {
    rm -rf -- "$TMP"
}

# Negatives are `run -N`: a bare `! cmd` that is not a test's last line never
# fails it (errexit ignores an inverted command).

@test "confirm: y, Y, yes and YeS are yes against a default of no" {
    local reply
    for reply in y Y yes YeS; do
        run confirm --default no Go? <<< "$reply"
        [ "$status" -eq 0 ]
    done
}

@test "confirm: n and No are no against a default of yes" {
    run -1 confirm --default yes Go? <<< "n"
    run -1 confirm --default yes Go? <<< "No"
}

@test "confirm: an empty reply takes the default" {
    run -1 confirm --default no Go? <<< ""
    run -0 confirm --default yes Go? <<< ""
}

@test "confirm: surrounding blanks around a reply are not part of it" {
    run -0 confirm --default no Go? <<< "  y  "
    run -1 confirm --default yes Go? <<< "  n  "
}

@test "confirm: anything else asks again, once per bad reply, on stderr" {
    local rc=0
    confirm --default no Go? < <(printf 'maybe\ny\n') >"${TMP}/out" 2>"${TMP}/err" || rc=$?
    [ "$rc" -eq 0 ]
    [ ! -s "${TMP}/out" ]
    cmp -s "${TMP}/err" <(printf 'Go? [y/N] Please answer yes or no.\nGo? [y/N] ')
}

@test "confirm: a bad reply followed by end of file is no answer (2)" {
    local rc=0
    confirm --default yes Go? < <(printf 'maybe\n') >"${TMP}/out" 2>"${TMP}/err" || rc=$?
    [ "$rc" -eq 2 ]
    [ ! -s "${TMP}/out" ]
    cmp -s "${TMP}/err" <(printf 'Go? [Y/n] Please answer yes or no.\nGo? [Y/n] \n')
}

@test "confirm: end of file straight away is no answer (2), whatever the default" {
    run -2 confirm --default yes Go? </dev/null
    run -2 confirm --default no Go? </dev/null
    # The prompt's line is ended, so the caller's next message starts its own.
    local rc=0
    confirm --default no Go? </dev/null 2>"${TMP}/err" || rc=$?
    [ "$rc" -eq 2 ]
    cmp -s "${TMP}/err" <(printf 'Go? [y/N] \n')
}

@test "confirm: the prompt is the question and the suffix for the default, on stderr, nothing on stdout" {
    confirm --default no Go? <<< "y" >"${TMP}/out" 2>"${TMP}/err"
    [ ! -s "${TMP}/out" ]
    cmp -s "${TMP}/err" <(printf 'Go? [y/N] ')
    confirm --default yes Go? <<< "y" >"${TMP}/out" 2>"${TMP}/err"
    [ ! -s "${TMP}/out" ]
    cmp -s "${TMP}/err" <(printf 'Go? [Y/n] ')
}

@test "confirm: --assume yes answers yes without reading, logged on stdout" {
    run --separate-stderr confirm --assume yes --default no Go? <<< "n"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO] Go? yes (assumed)" ]]
    [ -z "$stderr" ]
}

@test "confirm: --assume no answers no without reading, logged on stdout" {
    run --separate-stderr confirm --assume no --default yes Go? <<< "y"
    [ "$status" -eq 1 ]
    [[ "$output" == *"[INFO] Go? no (assumed)" ]]
    [ -z "$stderr" ]
}

@test "confirm: --assume '' asks" {
    confirm --assume '' --default no Go? <<< "y" >"${TMP}/out" 2>"${TMP}/err"
    [ ! -s "${TMP}/out" ]
    cmp -s "${TMP}/err" <(printf 'Go? [y/N] ')
    run -1 confirm --assume '' --default no Go? <<< "n"
}

@test "confirm: with stdin a pipe and the real terminal test, nothing is read (2) and the next reader gets it all" {
    run bash -c '. "${LIB}/log.sh"; . "${LIB}/prompt.sh"; confirm --default no Go?; echo "rc=$?"; cat' \
        < <(printf 'y\nREST\n')
    [ "$status" -eq 0 ]
    [ "$output" = $'rc=2\ny\nREST' ]
}

@test "confirm: a 2 under set -e stops the caller like any other failure" {
    run bash -c 'set -euo pipefail; . "${LIB}/log.sh"; . "${LIB}/prompt.sh"; confirm --default yes Go? </dev/null; echo REACHED'
    [ "$status" -eq 2 ]
    [[ "$output" != *REACHED* ]]
}

@test "confirm: --default is required and must be yes or no" {
    run confirm Go? <<< "y"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--default must be yes or no"* ]]
    run confirm --default maybe Go? <<< "y"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--default must be yes or no, not 'maybe'"* ]]
    run confirm --default
    [ "$status" -eq 1 ]
    [[ "$output" == *"--default needs yes or no"* ]]
}

@test "confirm: --assume must be yes, no or empty" {
    run confirm --assume 1 --default no Go? <<< "y"
    [ "$status" -eq 1 ]
    [[ "$output" == *"--assume must be yes, no or empty, not '1'"* ]]
    run confirm --default no --assume
    [ "$status" -eq 1 ]
    [[ "$output" == *"--assume needs yes, no or ''"* ]]
}

@test "confirm: no question dies" {
    run confirm --default no <<< "y"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no question given"* ]]
    run confirm --default no -- <<< "y"
    [ "$status" -eq 1 ]
    [[ "$output" == *"no question given"* ]]
}

@test "confirm: an unknown option dies naming it" {
    run confirm --default no -x Go? <<< "y"
    [ "$status" -eq 1 ]
    [[ "$output" == *"unknown option -x"* ]]
}

@test "confirm: -- ends the options, so a question may start with a dash" {
    confirm --default no -- -x? <<< "y" 2>"${TMP}/err"
    cmp -s "${TMP}/err" <(printf -- '-x? [y/N] ')
}

@test "confirm: a question of several words is joined with single spaces" {
    confirm --default yes Wipe the disk? <<< "" 2>"${TMP}/err"
    cmp -s "${TMP}/err" <(printf 'Wipe the disk? [Y/n] ')
}

@test "confirm: a reply without a newline is not a full line (2)" {
    run -2 confirm --default no Go? < <(printf y)
    run -2 confirm --default yes Go? < <(printf n)
}

@test "confirm: a bare N is no" {
    run -1 confirm --default yes Go? <<< "N"
    run -1 confirm --default yes Go? <<< "NO"
}

@test "confirm: a control character in the question is printed as ?, in the prompt and in the assumed line" {
    confirm --default no $'Go\e[1m?' <<< "y" 2>"${TMP}/err"
    cmp -s "${TMP}/err" <(printf 'Go?[1m? [y/N] ')
    run --separate-stderr confirm --assume yes --default no $'Go\e[1m?' <<< "n"
    [ "$status" -eq 0 ]
    [[ "$output" == *"[INFO] Go?[1m? yes (assumed)" ]]
    [[ "$output" != *$'\e'* ]]
}

# The one case that needs a terminal: a line typed before the question was
# printed must not answer it. python's pty module gives confirm a real
# terminal; the child sleeps 0.3 s before sourcing anything, and the
# typeahead is written as soon as it is forked, so it is pending long before
# the prompt can exist. The answer proper is written once the prompt has
# been seen. Without the drain the typeahead answers (rc 0 here); with it
# the later n does (rc 1). The second run feeds y after the prompt, which
# shows the harness itself can answer.
@test "confirm: a line typed ahead of the prompt is discarded on a real terminal" {
    command -v python3 >/dev/null || skip "python3 not installed"
    cat > "${TMP}/pty.py" <<'EOF'
import os, pty, select, sys, time
lib, mode = sys.argv[1], sys.argv[2]
pid, fd = pty.fork()
if pid == 0:
    os.execvp("bash", ["bash", "-c",
        'sleep 0.3; . "$1/log.sh"; . "$1/prompt.sh"; confirm --default no Go?; echo "rc=$?"',
        "_", lib])
if mode == "ahead":
    os.write(fd, b"y\n")
buf = b""
deadline = time.time() + 15
def pump():
    global buf
    r, _, _ = select.select([fd], [], [], 0.2)
    if not r:
        return True
    try:
        d = os.read(fd, 4096)
    except OSError:
        return False
    if not d:
        return False
    buf += d
    return True
while b"Go? [y/N] " not in buf and time.time() < deadline:
    if not pump():
        break
os.write(fd, b"n\n" if mode == "ahead" else b"y\n")
while time.time() < deadline:
    if not pump():
        break
os.waitpid(pid, 0)
sys.stdout.write(buf.decode("utf-8", "replace"))
EOF
    run python3 -I "${TMP}/pty.py" "$LIB" ahead
    [ "$status" -eq 0 ]
    [[ "$output" == *"Go? [y/N] "* ]]
    [[ "$output" == *"rc=1"* ]]
    [[ "$output" != *"Please answer"* ]]
    run python3 -I "${TMP}/pty.py" "$LIB" after
    [ "$status" -eq 0 ]
    [[ "$output" == *"rc=0"* ]]
}
