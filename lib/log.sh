#!/usr/bin/env bash
# log.sh — timestamped, colour-aware logging.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Colour is decided per stream: stdout-bound messages are only coloured when
# stdout is a terminal, stderr-bound only when stderr is. That way
# `script > run.log` gets clean text in the file while warnings stay coloured
# on screen. Honours NO_COLOR (https://no-color.org).
#
# Optional transcript: call log_open_transcript <path> to also append every
# message, uncoloured, to a file. Colour on the terminal is preserved because
# we write to the file separately rather than piping through tee.
#
# Depends on: nothing.

# Guard against double-sourcing — later modules may pull this in transitively.
[[ -n "${_LIB_LOG_SOURCED:-}" ]] && return 0
_LIB_LOG_SOURCED=1

_LOG_RED=$'\033[0;31m'
_LOG_GRN=$'\033[0;32m'
_LOG_YEL=$'\033[1;33m'
_LOG_CYN=$'\033[0;36m'
_LOG_RST=$'\033[0m'

_LOG_FILE=""

# ── log_open_transcript <path> ────────────────────────────────────────────────
# Append all subsequent log output to <path> as well as the terminal.
# Creates the parent directory if needed. Never fatal: if the file cannot be
# opened we warn and carry on unlogged, because losing the transcript is far
# less bad than aborting a provisioning run halfway through.
log_open_transcript() {
    local path="$1" dir
    dir="$(dirname -- "$path")"

    if [[ ! -d "$dir" ]] && ! sudo mkdir -p -- "$dir" 2>/dev/null; then
        log_warn "Could not create log directory $dir — continuing without a transcript"
        return 0
    fi
    if ! sudo touch -- "$path" 2>/dev/null; then
        log_warn "Could not open transcript $path — continuing without one"
        return 0
    fi
    # The file must be owned by the invoking user: sudo touch creates it
    # root-owned, and every subsequent append happens unprivileged — against a
    # root-owned 0644 file each one fails, so the transcript stays empty.
    sudo chown -- "$(id -un)" "$path" 2>/dev/null || true
    sudo chmod 0644 -- "$path" 2>/dev/null || true

    _LOG_FILE="$path"
    log_info "Transcript: $path"
}

_log_ts() { date '+%Y-%m-%d %H:%M:%S'; }

# _log <colour> <label> <fd> <message...>
_log() {
    local colour="$1" label="$2" fd="$3"
    shift 3
    local ts c='' r=''
    ts="$(_log_ts)"

    if [[ -z "${NO_COLOR:-}" ]]; then
        if { [[ "$fd" == 1 ]] && [[ -t 1 ]]; } || { [[ "$fd" == 2 ]] && [[ -t 2 ]]; }; then
            c="$colour"
            r="$_LOG_RST"
        fi
    fi

    printf '%s[%s] [%s]%s %s\n' "$c" "$ts" "$label" "$r" "$*" >&"$fd"

    # Transcript always gets the uncoloured form.
    if [[ -n "$_LOG_FILE" ]]; then
        # Brace group so the redirect failure itself is silenced: redirections
        # process left to right, and a failed >> reports to stderr before a
        # trailing 2>/dev/null takes effect.
        { printf '[%s] [%s] %s\n' "$ts" "$label" "$*" >> "$_LOG_FILE"; } 2>/dev/null || true
    fi
}

log_info()    { _log "$_LOG_CYN" "INFO"    1 "$@"; }
log_success() { _log "$_LOG_GRN" "SUCCESS" 1 "$@"; }
log_check()   { _log "$_LOG_CYN" "CHECK"   1 "$@"; }
log_warn()    { _log "$_LOG_YEL" "WARN"    2 "$@"; }
log_error()   { _log "$_LOG_RED" "ERROR"   2 "$@"; }

# log_warning is an alias kept for openvpn-bld.sh, which used that spelling.
# Prefer log_warn in new code; this will be dropped after the call sites migrate.
log_warning() { log_warn "$@"; }

die() { log_error "$*"; exit 1; }

# ── section <title> ───────────────────────────────────────────────────────────
# Visual separator for long provisioning runs.
section() {
    local title="$*"
    _log "$_LOG_CYN" "STEP" 1 "──────── ${title} ────────"
}
