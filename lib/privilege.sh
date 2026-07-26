#!/usr/bin/env bash
# privilege.sh — enforce the "run as your user, escalate per command" convention.
# Part of the bash-includes library. Source this file; do not execute it.
#
# The convention: you invoke scripts as your normal user. The script calls sudo
# for the individual commands that need it. Running the whole script under sudo
# is a mistake — everything it creates on your behalf ends up owned by root,
# including working directories and helper tools you are meant to run later.
#
# require_unprivileged turns that mistake into an immediate, explanatory failure
# instead of a pile of root-owned files you discover an hour later.
#
# Depends on: log.sh

# include: log.sh
[[ -n "${_LIB_PRIVILEGE_SOURCED:-}" ]] && return 0
_LIB_PRIVILEGE_SOURCED=1

_SUDO_KEEPALIVE_PID=""

# ── require_unprivileged ──────────────────────────────────────────────────────
# Call at the top of every entry point, before any work.
require_unprivileged() {
    if [[ "${EUID}" -eq 0 ]]; then
        log_error "This script must be run as your normal user, not as root."
        log_error "It calls sudo for the specific commands that need elevation."
        if [[ -n "${SUDO_USER:-}" ]]; then
            die "Re-run it without sudo:  $0 $*"
        fi
        die "Log in as your normal user and re-run it."
    fi

    command -v sudo >/dev/null 2>&1 \
        || die "sudo is required but is not installed"

    # Prime the sudo timestamp now so the password prompt happens here, at a
    # predictable moment, rather than partway through a long run.
    sudo -v || die "sudo access is required to continue"
}

# ── sudo_keepalive_start ──────────────────────────────────────────────────────
# Refresh the sudo timestamp every 60s so long runs (PKI generation, large apt
# transactions) do not stall on a re-auth prompt. The default timeout is 15
# minutes, which several of these scripts exceed.
#
# Registers its own teardown if cleanup.sh is loaded; otherwise call
# sudo_keepalive_stop yourself.
sudo_keepalive_start() {
    [[ -n "$_SUDO_KEEPALIVE_PID" ]] && return 0

    # Two details here are load-bearing:
    #
    # 1. stdio is detached to /dev/null. A background job inherits the caller's
    #    stdout, and `sleep` inherits it in turn. If the script's output is
    #    piped (`script.sh | tee`, `script.sh | sed`), that lingering sleep
    #    holds the pipe open and the reader never sees EOF — so the pipeline
    #    hangs long after the script itself has exited.
    #
    # 2. the wait is broken into short sleeps rather than one long one, so the
    #    loop notices the parent is gone within seconds instead of holding a
    #    60-second sleep that outlives teardown.
    {
        while sudo -n true 2>/dev/null; do
            local i
            for (( i = 0; i < 12; i++ )); do
                sleep 5
                kill -0 "$$" 2>/dev/null || exit 0
            done
        done
    } </dev/null >/dev/null 2>&1 &
    _SUDO_KEEPALIVE_PID=$!

    if declare -f cleanup_push >/dev/null 2>&1; then
        cleanup_push sudo_keepalive_stop
    fi
}

sudo_keepalive_stop() {
    [[ -z "$_SUDO_KEEPALIVE_PID" ]] && return 0
    kill "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    wait "$_SUDO_KEEPALIVE_PID" 2>/dev/null || true
    _SUDO_KEEPALIVE_PID=""
}
