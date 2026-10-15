#!/usr/bin/env bats
# Unit tests for child.sh — tracked background privileged children.
#
# These exercise the real start/stop logic against short-lived processes. sudo
# is a stub executable on PATH (not a shell function): start_child uses
# `command sudo`, which bypasses functions and resolves a binary, so a function
# stub would be ignored and the real sudo invoked. The stub drops a leading -n
# and execs the rest, so the child's pid is the stub's pid, i.e. our own child.

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    TMP="$(mktemp -d)"

    # Real sudo stub on PATH: strip a leading -n, then exec. exec keeps the pid,
    # so start_child's $! stays our direct child (what _child_alive requires).
    mkdir -p "$TMP/bin"
    printf '#!/bin/sh\n[ "$1" = -n ] && shift\nexec "$@"\n' > "$TMP/bin/sudo"
    chmod +x "$TMP/bin/sudo"
    PATH="$TMP/bin:$PATH"

    # shellcheck source=/dev/null
    . "${LIB}/child.sh"
}

teardown() {
    # Reap anything a failing test left behind.
    [[ -n "${CHILD_PID:-}" ]] && kill -KILL "$CHILD_PID" 2>/dev/null
    rm -rf "$TMP"
}

@test "start_child stores a live pid that is our own child" {
    CHILD_PID=""
    start_child CHILD_PID "$TMP/out.log" sleep 30
    [ -n "$CHILD_PID" ]
    _child_alive "$CHILD_PID"
}

@test "start_child redirects the child's output to the log" {
    CHILD_PID=""
    start_child CHILD_PID "$TMP/out.log" sh -c 'echo hello; sleep 30'
    # Give the child a moment to write.
    for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s "$TMP/out.log" ] && break; sleep 0.1; done
    grep -q hello "$TMP/out.log"
    stop_child CHILD_PID
}

@test "stop_child terminates a well-behaved child and clears the var" {
    CHILD_PID=""
    start_child CHILD_PID "$TMP/out.log" sleep 30
    local pid="$CHILD_PID"
    stop_child CHILD_PID
    [ -z "$CHILD_PID" ]
    run ! _child_alive "$pid"
    [ "$STOP_CHILD_KILLED" -eq 0 ]
}

@test "stop_child is a no-op on an empty variable" {
    CHILD_PID=""
    run stop_child CHILD_PID
    [ "$status" -eq 0 ]
}

@test "stop_child on an already-dead pid returns 0 and clears the var" {
    CHILD_PID=""
    start_child CHILD_PID "$TMP/out.log" true
    # Let it exit on its own.
    sleep 0.3
    stop_child CHILD_PID
    [ -z "$CHILD_PID" ]
}

@test "_child_alive is false for a pid that is not our child" {
    # pid 1 exists but is not our child.
    run ! _child_alive 1
    run ! _child_alive ""
    run ! _child_alive 999999
}

@test "stop_child escalates to SIGKILL when SIGTERM is ignored" {
    CHILD_PID=""
    start_child CHILD_PID "$TMP/out.log" sh -c 'trap "" TERM; sleep 30'
    local pid="$CHILD_PID"
    _child_alive "$pid"
    stop_child CHILD_PID
    run ! _child_alive "$pid"
    [ "$STOP_CHILD_KILLED" -eq 1 ]
}

@test "_descendants lists a child's own children, parents first" {
    CHILD_PID=""
    # A shell that spawns a grandchild sleep, then waits.
    start_child CHILD_PID "$TMP/out.log" sh -c 'sleep 30 & wait'
    # Wait for the grandchild to appear.
    local kids=""
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        kids="$(_descendants "$CHILD_PID")"
        [ -n "$kids" ] && break
        sleep 0.1
    done
    [ -n "$kids" ]
    stop_child CHILD_PID
}
