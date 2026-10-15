#!/usr/bin/env bash
# child.sh — run a privileged command as a tracked background child and stop it
# reliably, under both sudo and sudo-rs.
# Part of the bash-includes library. Source this file; do not execute it.
#
# The problem this solves. A long-running helper that needs root (a packet
# capture, a transient hostapd, a DHCP client) is started in the background so
# the script can carry on and later tear it down. Two traps make the naive
# `sudo cmd &; kill $!` unreliable:
#
#   1. The library's sudo() wrapper. Backgrounded, `sudo cmd &` would run the
#      wrapper in a subshell, so `$!` is that subshell and not sudo — a later
#      `kill $!` signals the subshell, never the helper. start_child uses
#      `command sudo` to bypass the wrapper, so `$!` is sudo itself.
#   2. The process tree. sudo (sudo-rs included) relays SIGTERM to the command,
#      but not SIGKILL, and does not always keep the command as its direct
#      child: started from a terminal, sudo-rs keeps a monitor process in
#      between (sudo, sudo, command). So the SIGKILL fallback walks the whole
#      tree under the sudo child rather than signalling one pid.
#
# A held pid can also be recycled once bash reaps the exited child, so
# _child_alive additionally requires the process to still be THIS script's
# child before anything is signalled.
#
# stop_child sets STOP_CHILD_KILLED=1 when SIGTERM was not enough and it had to
# escalate to SIGKILL; a caller that wants to warn about an ungraceful stop
# resets it to 0 before the call and reads it after. The helper's stdout and
# stderr go to the <log> path, opened by the unprivileged caller.
#
# Depends on: nothing (uses command sudo, sudo, ps, pgrep and kill directly).

[[ -n "${_LIB_CHILD_SOURCED:-}" ]] && return 0
_LIB_CHILD_SOURCED=1

# Set to 1 by stop_child when a SIGTERM did not stop the child and it was
# killed. Declared here so a caller may read it under `set -u` without first
# assigning it.
STOP_CHILD_KILLED=0

# ── start_child <pid-var> <log> <command...> ──────────────────────────────────
# Start <command...> under sudo in the background, writing its combined output
# to <log>, and store the sudo pid in the variable named <pid-var>. stdin is
# /dev/null so sudo does not take the terminal: a Ctrl-C then reaches the
# calling script directly rather than being swallowed by sudo.
start_child() {
    local var="$1" log="$2"
    shift 2
    # shellcheck disable=SC2024  # the log is deliberately opened as the user
    command sudo -n "$@" </dev/null >"$log" 2>&1 &
    printf -v "$var" '%s' "$!"
}

# ── _child_alive <pid> ────────────────────────────────────────────────────────
# True when <pid> is running, is our own child, and is not a zombie. Requiring
# it to be our child guards against a recycled pid after bash has reaped it.
_child_alive() {
    local ppid st
    [[ -n "${1:-}" ]] || return 1
    read -r ppid st < <(ps -o ppid=,stat= -p "$1" 2>/dev/null) || return 1
    [[ "$ppid" == "$$" && -n "$st" && "$st" != Z* ]]
}

# ── _descendants <pid> ────────────────────────────────────────────────────────
# Print every descendant of <pid>, one per line, parents before children, so a
# parent dying cannot hide its children from a kill.
_descendants() {
    local c
    for c in $(pgrep -P "$1" 2>/dev/null); do
        printf '%s\n' "$c"
        _descendants "$c"
    done
}

# ── stop_child <pid-var> ──────────────────────────────────────────────────────
# Stop the child whose pid is held in the variable named <pid-var>: SIGTERM,
# wait up to five seconds, then SIGKILL the whole tree under the sudo child if
# it is still alive. Clears the variable. Idempotent: an empty or already-dead
# pid returns 0. Sets STOP_CHILD_KILLED=1 if it had to escalate to SIGKILL.
stop_child() {
    local var="$1" pid i
    pid="${!var}"
    [[ -n "$pid" ]] || return 0
    printf -v "$var" '%s' ""
    if ! _child_alive "$pid"; then
        wait "$pid" 2>/dev/null || true
        return 0
    fi
    kill -TERM "$pid" 2>/dev/null || true
    for (( i = 0; i < 20; i++ )); do
        _child_alive "$pid" || break
        sleep 0.25
    done
    if _child_alive "$pid"; then
        # SIGKILL is not relayed by sudo, and a privileged helper may have
        # privilege-separated helpers of its own: kill the whole tree under our
        # sudo child. It is collected first, so a parent dying cannot hide its
        # children.
        local -a tree=()
        mapfile -t tree < <(_descendants "$pid")
        [[ "${#tree[@]}" -eq 0 ]] || sudo kill -KILL "${tree[@]}" 2>/dev/null || true
        sudo kill -KILL "$pid" 2>/dev/null || true
        STOP_CHILD_KILLED=1
    fi
    wait "$pid" 2>/dev/null || true
}
