#!/usr/bin/env bash
# log.sh — timestamped, colour-aware logging.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Colour is decided per stream: stdout-bound messages are only coloured when
# stdout is a terminal, stderr-bound only when stderr is. That way
# `script > run.log` gets clean text in the file while warnings stay coloured
# on screen. Honours NO_COLOR (https://no-color.org).
#
# Optional transcript: call log_open_transcript "$(log_transcript_path <tool>)"
# to also append every message, uncoloured, to a file. Colour on the terminal
# is preserved because we write to the file separately rather than piping
# through tee.
#
# Depends on: nothing.

# Guard against double-sourcing — later modules may pull this in transitively.
[[ -n "${_LIB_LOG_SOURCED:-}" ]] && return 0
_LIB_LOG_SOURCED=1

# The one piece of process state the library sets: every consumer runs under
# umask 022 from the moment it loads this module, whatever the caller's shell
# had. sudo-rs (0.2.13, Ubuntu 26.04) hands the caller's umask on, so from an
# interactive shell at 077 a `sudo tee` or `sudo install` without an explicit
# mode leaves a 0600 root-only file: apt keyrings _apt cannot read, sources
# files rewritten on every run (that was v1.7.0's apt_add_repo fix, one site
# at a time). Pinning it here, in the module every consumer includes first,
# covers every write site in every consumer at once, and is what lets the
# interactive shells of the fleet move to 077 (ksgill, 2026-10-15). A file
# that must be private is still given its mode explicitly, as before.
umask 022

_LOG_RED=$'\033[0;31m'
_LOG_GRN=$'\033[0;32m'
_LOG_YEL=$'\033[1;33m'
_LOG_CYN=$'\033[0;36m'
_LOG_RST=$'\033[0m'

_LOG_FILE=""

# Where run transcripts live: <root>/<tool>/<label>-<UTC timestamp>.log.
#
# Not /var/log. On Ubuntu /var/log is root:syslog 0775 with no sticky bit, so
# the syslog account can create /var/log/<tool> before a tool's first run, or
# rename a root-owned one away between any two commands, and whatever root
# then creates, chowns or chmods "in the log directory" lands where that
# account pointed it. No sequence of checks on a path under such a parent
# closes that. Under /var/lib/provision — next to the change journal — every
# directory from / down is writable by root alone, so nobody else can put
# anything in the way.
LOG_TRANSCRIPT_ROOT="${LOG_TRANSCRIPT_ROOT:-/var/lib/provision/log}"

# ── log_transcript_path <tool> [label] ────────────────────────────────────────
# Print the transcript path for this run of <tool>:
#   <LOG_TRANSCRIPT_ROOT>/<tool>/<label>-<UTC timestamp>.log   (label: "run")
# <tool> and <label> are single path components of [A-Za-z0-9._-], starting
# with a letter or digit; anything else returns 1 and prints nothing.
log_transcript_path() {
    local tool="${1:-}" label="${2:-run}"
    if [[ ! "$tool" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ || ! "$label" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
        return 1
    fi
    # ${…%/}: a root given with a trailing slash is the same root.
    printf '%s/%s/%s-%s.log\n' "${LOG_TRANSCRIPT_ROOT%/}" "$tool" "$label" "$(date -u +%Y%m%dT%H%M%SZ)"
}

# _log_others_can_write <octal mode> — true if group or other has write.
_log_others_can_write() {
    local mode="$1" g o
    [[ "$mode" =~ ^[0-7]{3,4}$ ]] || return 0
    g="${mode: -2:1}"
    o="${mode: -1}"
    (( (g & 2) || (o & 2) ))
}

# _log_chain <dir> — set the array LOG_CHAIN to <dir> and every ancestor, root
# first. An array, not lines of output: a path component may hold a newline.
_log_chain() {
    local dir="$1" rest part acc=""
    LOG_CHAIN=("/")
    rest="${dir#/}"
    while [[ -n "$rest" ]]; do
        part="${rest%%/*}"
        acc+="/${part}"
        LOG_CHAIN+=("$acc")
        if [[ "$rest" == */* ]]; then
            rest="${rest#*/}"
        else
            rest=""
        fi
    done
}

# _log_kind <raw mode, hex> — print directory, file, link or other, from the
# type bits of stat's raw mode. Not the file-type text: GNU stat translates it.
_log_kind() {
    local hex="$1"
    [[ "$hex" =~ ^[0-9a-fA-F]{1,8}$ ]] || { printf 'other\n'; return 0; }
    case "$(( 0x${hex} & 0xf000 ))" in
        16384) printf 'directory\n' ;;
        32768) printf 'file\n' ;;
        40960) printf 'link\n' ;;
        *)     printf 'other\n' ;;
    esac
}

# _log_sudo <command...> — run as root without ever prompting: the caller has
# already established that sudo works (require_unprivileged), and a transcript
# is not worth a password prompt in the middle of a run. Already root: run it.
_log_sudo() {
    if [[ "$EUID" -eq 0 ]]; then
        "$@"
    else
        sudo -n "$@"
    fi
}

# _log_root_only_dir <dir> — make <dir> a directory that only root can have
# put anything into, creating what is missing, and succeed only if it is one.
#
# Every component from / down to <dir> must be a real directory (not a
# symlink), owned by root, and not writable by group or other. Missing ones
# are created root:root 0755, one at a time and top down, so none takes its
# mode from a umask and none is created inside a parent that has not passed.
# Once a parent is root-only, only root can change what is in it — which is
# why a chain that passes cannot have been interfered with by anyone else.
# The chain is walked a second time after the creations as a plain re-check.
#
# On failure prints the reason on stdout and returns 1.
_log_root_only_dir() {
    local dir="$1" c line uid mode kind pass
    local -a LOG_CHAIN=()
    _log_chain "$dir"

    for pass in create verify; do
        for c in "${LOG_CHAIN[@]}"; do
            if ! _log_sudo test -e "$c" && ! _log_sudo test -L "$c"; then
                if [[ "$pass" == "verify" ]]; then
                    printf '%s is missing\n' "$c"
                    return 1
                fi
                if ! _log_sudo install -d -m 0755 -o root -g root -- "$c" 2>/dev/null; then
                    printf 'could not create %s\n' "$c"
                    return 1
                fi
            fi
            line="$(_log_sudo stat -c '%u %a %f' -- "$c" 2>/dev/null)" || line=""
            read -r uid mode kind <<< "$line"
            kind="$(_log_kind "${kind:-}")"
            if [[ "$kind" != "directory" ]]; then
                printf '%s is not a directory (%s)\n' "$c" "$kind"
                return 1
            fi
            if [[ "$uid" != 0 ]]; then
                printf '%s is not owned by root\n' "$c"
                return 1
            fi
            if _log_others_can_write "$mode"; then
                printf '%s is writable by group or other (mode %s)\n' "$c" "$mode"
                return 1
            fi
        done
    done
    return 0
}

# _log_own_dir <dir> — the unprivileged counterpart: <dir> is, or can be made
# with a plain mkdir, a directory only the invoking user can put things into,
# reached through a chain nobody else can rearrange. Nothing here runs as
# root, so there is nothing to hand over.
#
# <dir> itself: a real directory owned by the invoking user, not writable by
# group or other. Every ancestor: a real directory owned by root or the user,
# and either not writable by group or other, or sticky — in a sticky
# directory (/tmp) only an entry's owner can rename or remove it, and the
# next component down is the user's or root's.
#
# Top down, one component at a time: a missing one is created with a plain
# mkdir only inside a parent that has already passed, and is then checked
# like any other. The chain is walked a second time as a re-check. On
# failure prints the reason and returns 1.
_log_own_dir() {
    local dir="$1" c line uid mode kind me pass
    local -a LOG_CHAIN=()
    me="$(id -u)"
    _log_chain "$dir"

    for pass in create verify; do
        for c in "${LOG_CHAIN[@]}"; do
            if [[ ! -e "$c" && ! -L "$c" ]]; then
                if [[ "$pass" == "verify" ]]; then
                    printf '%s is missing\n' "$c"
                    return 1
                fi
                if ! ( umask 022; mkdir -- "$c" ) 2>/dev/null; then
                    printf 'could not create %s\n' "$c"
                    return 1
                fi
            fi
            line="$(stat -c '%u %a %f' -- "$c" 2>/dev/null)" || line=""
            read -r uid mode kind <<< "$line"
            kind="$(_log_kind "${kind:-}")"
            if [[ "$kind" != "directory" ]]; then
                printf '%s is not a directory (%s)\n' "$c" "$kind"
                return 1
            fi
            if [[ "$c" == "$dir" ]]; then
                if [[ "$uid" != "$me" ]]; then
                    printf '%s is not owned by %s\n' "$c" "$(id -un)"
                    return 1
                fi
                if _log_others_can_write "$mode"; then
                    printf '%s is writable by group or other (mode %s)\n' "$c" "$mode"
                    return 1
                fi
            else
                if [[ "$uid" != 0 && "$uid" != "$me" ]]; then
                    printf '%s is owned by someone else\n' "$c"
                    return 1
                fi
                # Four digits with the 1000 bit set: sticky.
                if _log_others_can_write "$mode" \
                   && ! { [[ ${#mode} -eq 4 ]] && (( ${mode:0:1} & 1 )); }; then
                    printf '%s is writable by group or other and not sticky (mode %s)\n' "$c" "$mode"
                    return 1
                fi
            fi
        done
    done
    return 0
}

# ── log_open_transcript <path> ────────────────────────────────────────────────
# Append all subsequent log output to <path> as well as the terminal. Use
# log_transcript_path for <path>.
#
# The transcript's directory has to be one nobody else can interfere with —
# or the file, and every line appended to it for the rest of the run, lands
# wherever someone else pointed the path:
#   - a directory whose whole chain from / is root-owned and closed to group
#     and other (created if missing). The file is created by root, owned by
#     the invoking user, mode 0640; or
#   - a directory the invoking user owns that group and other cannot write,
#     under ancestors that are root's or the user's and closed to others or
#     sticky (created if missing, without sudo). The file is created without
#     sudo.
# Anything else — a path under Ubuntu's syslog-writable /var/log, a new
# directory directly under /tmp — is refused with a warning naming the
# component that is in the way.
#
# An existing <path> is reused only if it is a regular file owned by the
# invoking user (a second run in the same second); a link or anything else
# there is refused, never written through.
#
# Never fatal: if the file cannot be opened we warn and carry on unlogged,
# because losing the transcript is far less bad than aborting a provisioning
# run halfway through.
log_open_transcript() {
    local path="${1:-}" dir why line uid kind
    local me
    me="$(id -u)"

    # Absolute first: the walk up to the nearest existing ancestor below ends
    # at "/" only for an absolute path.
    if [[ "$path" != /* || "$path" == */ || "$path" == *//* || "$path" =~ /\.\.?(/|$) \
          || "$path" == *[[:cntrl:]]* ]]; then
        log_warn "Transcript path must be absolute and plain (got '${path}') — continuing without a transcript"
        return 0
    fi
    dir="${path%/*}"
    [[ -n "$dir" ]] || dir="/"

    # A directory of the user's own — or one to be made inside one — needs no
    # privilege and gets none. Decided by the nearest ancestor that exists.
    local privileged=1 near="$dir"
    while [[ -n "$near" && ! -e "$near" && ! -L "$near" ]]; do
        near="${near%/*}"
    done
    if [[ "$me" != 0 && -n "$near" && -d "$near" && ! -L "$near" && -O "$near" ]]; then
        privileged=0
    fi

    if [[ "$privileged" -eq 0 ]]; then
        if ! why="$(_log_own_dir "$dir")"; then
            log_warn "Not writing a transcript to $path: ${why} — continuing without one"
            return 0
        fi
        if [[ -e "$path" || -L "$path" ]]; then
            if [[ -L "$path" || ! -f "$path" || ! -O "$path" ]]; then
                log_warn "Not writing a transcript to $path: something else is already there — continuing without one"
                return 0
            fi
        # noclobber: the create fails rather than follow a link that
        # appeared since the test above.
        elif ! ( set -C; umask 027; : > "$path" ) 2>/dev/null; then
            log_warn "Could not create transcript $path — continuing without one"
            return 0
        fi
    else
        # One probe, so "sudo will not run" is reported as that and not as a
        # missing directory.
        if ! _log_sudo true 2>/dev/null; then
            log_warn "Not writing a transcript to $path: sudo is not available without a prompt — continuing without one"
            return 0
        fi
        if ! why="$(_log_root_only_dir "$dir")"; then
            log_warn "Not writing a transcript to $path: ${why}. Transcripts belong under ${LOG_TRANSCRIPT_ROOT} (log_transcript_path) — continuing without one"
            return 0
        fi
        # Only root can have put anything in $dir, so these are not racing
        # anyone.
        if _log_sudo test -e "$path" || _log_sudo test -L "$path"; then
            line="$(_log_sudo stat -c '%u %a %f' -- "$path" 2>/dev/null)" || line=""
            read -r uid _ kind <<< "$line"
            if [[ "$uid" != "$me" || "$(_log_kind "${kind:-}")" != "file" ]]; then
                log_warn "Not writing a transcript to $path: something else is already there — continuing without one"
                return 0
            fi
        # The file must be owned by the invoking user: every append happens
        # unprivileged. 0640, not world-readable — a transcript names hosts,
        # networks and backup paths.
        # -T: the destination is the file itself, never a directory to
        # create "null" inside.
        elif ! _log_sudo install -T -m 0640 -o "$me" -g "$(id -g)" -- /dev/null "$path" 2>/dev/null; then
            log_warn "Could not create transcript $path — continuing without one"
            return 0
        fi
    fi

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

die() { log_error "$*"; exit 1; }

# ── section <title> ───────────────────────────────────────────────────────────
# Visual separator for long provisioning runs.
section() {
    local title="$*"
    _log "$_LOG_CYN" "STEP" 1 "──────── ${title} ────────"
}
