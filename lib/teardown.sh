#!/usr/bin/env bash
# teardown.sh — copy what a rebuild is about to remove into a snapshot, stop
# the units that use it, then remove it.
# Part of the bash-includes library. Source this file; do not execute it.
#
# For a tool that replaces an installation it made earlier (a VPN server, its
# keys, hooks and units). The order is the point:
#
#   snapshot_create     a new root-only directory for this run's copies
#   snapshot_add ...    copy each path in; any failed copy is fatal, and so far
#                       nothing has been stopped or removed
#   unit_stop_disable   stop the service
#   snapshot_remove_all remove each path, but only one whose copy is in the
#                       snapshot at that moment
#
# A snapshot directory rather than backup.sh's in-place .orig/.bak: the
# originals' directories are themselves removed, so a copy beside the original
# would go with it. Snapshots hold private keys; the root and each snapshot are
# root-owned 0700, and pruning them is manual.
#
# What is NOT here is everything that differs between tools: which paths, what
# must be checked before the point of no return, firewall cleanup, and what to
# tell the operator when a removal fails half way (SNAPSHOT_ON_FAIL).
#
# Depends on: log.sh, journal.sh

# include: log.sh
# include: journal.sh
[[ -n "${_LIB_TEARDOWN_SOURCED:-}" ]] && return 0
_LIB_TEARDOWN_SOURCED=1

# The snapshot directory of this run, set by snapshot_create.
SNAPSHOT_DIR=""

# Journal detail for each copy snapshot_add makes.
SNAPSHOT_COPY_DETAIL="${SNAPSHOT_COPY_DETAIL:-copied into the snapshot}"

# Appended to the message when the snapshot cannot be created or a copy fails,
# so the caller can say what else is untouched ("... and the service was not
# touched").
SNAPSHOT_FAIL_NOTE="${SNAPSHOT_FAIL_NOTE:-nothing has been removed}"

# Name of a function to call when snapshot_remove_all fails after the point of
# no return, in place of the generic report (snapshot_failure_report, which it
# may call). It receives:
#   $1  what failed
#   $2  the path whose removal failed and may be half gone (empty if none)
#   $3  that path's copy in the snapshot (empty if none)
# and reads SNAPSHOT_REMOVED_SRC / SNAPSHOT_REMOVED_COPY for what is already
# gone. It should exit; if it returns, the run ends with status 1 anyway.
SNAPSHOT_ON_FAIL="${SNAPSHOT_ON_FAIL:-}"

# Parallel arrays: every path to remove, and where its copy is.
_SNAPSHOT_SRC=()
_SNAPSHOT_COPY=()

# Parallel arrays: what snapshot_remove_all has removed so far in this run.
SNAPSHOT_REMOVED_SRC=()
SNAPSHOT_REMOVED_COPY=()

# True when the path exists as anything at all, a dangling symlink included.
# Through sudo: the directories these tools keep keys in are root 0700, and an
# unprivileged test there cannot tell "absent" from "not allowed to look".
_snapshot_present() {
    sudo test -e "$1" || sudo test -L "$1"
}

_snapshot_copy_failed() {
    die "$1; ${SNAPSHOT_FAIL_NOTE}"
}

# ── snapshot_create [--keep-root] <root> <name> ───────────────────────────────
# Make <root>/<name>-<YYYYmmdd-HHMMSS> and set SNAPSHOT_DIR to it. Forgets any
# paths registered for an earlier snapshot in this run.
#
# <root> is made root-owned 0700, and reset to that if it already exists:
# install -d applies the mode and owner either way, where mkdir -p -m would
# only touch a directory it creates. With --keep-root an existing <root> is
# left exactly as it is, for a root someone else legitimately owns. A <root>
# that is a symlink is refused, never written through.
#
# The snapshot itself is made without -p, so a second run in the same second
# fails here instead of mixing two snapshots in one directory.
snapshot_create() {
    local keep_root=0
    if [[ "${1:-}" == "--keep-root" ]]; then
        keep_root=1
        shift
    fi
    local root="${1:-}" name="${2:-}"

    [[ "$root" == /* && "$root" != "/" ]] \
        || die "snapshot_create: the snapshot root must be an absolute path, got '${root}'"
    [[ -n "$name" && "$name" != */* && "$name" != "." && "$name" != ".." ]] \
        || die "snapshot_create: the snapshot name must be a single path component, got '${name}'"

    SNAPSHOT_DIR=""
    _SNAPSHOT_SRC=()
    _SNAPSHOT_COPY=()
    SNAPSHOT_REMOVED_SRC=()
    SNAPSHOT_REMOVED_COPY=()

    if sudo test -L "$root"; then
        _snapshot_copy_failed "${root} is a symlink; refusing to write a snapshot through it"
    fi
    if [[ "$keep_root" -eq 0 ]] || ! sudo test -d "$root"; then
        sudo install -d -m 0700 -o root -g root -- "$root" \
            || _snapshot_copy_failed "Could not create ${root}"
    fi

    local dir
    dir="${root}/${name}-$(date +%Y%m%d-%H%M%S)"
    log_info "Creating backup at: ${dir}"
    sudo mkdir -m 0700 -- "$dir" \
        || _snapshot_copy_failed "Could not create ${dir}"
    SNAPSHOT_DIR="$dir"
}

# ── snapshot_register <path> <copy> ───────────────────────────────────────────
# Record that <path> is to be removed by snapshot_remove_all and that its copy
# is (or will be) at <copy>. snapshot_add calls this; call it directly for a
# path the caller copies its own way.
#
# <path> ends up as the operand of a root `rm -rf`, so it must be absolute,
# cannot be the root directory however it is spelled (/, //), and cannot have
# a . or .. component, which would make it name something other than it reads.
snapshot_register() {
    local src="${1:-}" copy="${2:-}" trimmed
    trimmed="$src"
    while [[ "$trimmed" == */ ]]; do trimmed="${trimmed%/}"; done
    [[ "$src" == /* && -n "$trimmed" && ! "/${src}/" =~ /\.\.?/ ]] \
        || die "snapshot_register: refusing to register '${src}' for removal (not a plain absolute path below /)"
    [[ "$copy" == /* ]] \
        || die "snapshot_register: the copy of ${src} must be an absolute path, got '${copy}'"
    _SNAPSHOT_SRC+=("$src")
    _SNAPSHOT_COPY+=("$copy")
}

# ── snapshot_add <path> [name] ────────────────────────────────────────────────
# Copy <path> into the snapshot as <name> (default: its own basename) and
# register it for removal. cp -a keeps mode, ownership and timestamps, so a
# root-owned 0600 key lands exactly as it was; a symlink is copied as a link.
#
# A path that is not there is registered and not copied. If it has appeared by
# the time snapshot_remove_all runs, the removal stops there: nothing goes
# without a copy.
#
# Fatal when the copy fails, and when <name> is already taken in the snapshot
# (cp would nest a directory inside the earlier copy, or overwrite a file).
snapshot_add() {
    local src="${1:-}" name="${2:-}" dest
    [[ -n "$SNAPSHOT_DIR" ]] || die "snapshot_add called before snapshot_create"
    [[ -n "$name" ]] || name="$(basename -- "$src")"
    [[ -n "$name" && "$name" != */* && "$name" != "." && "$name" != ".." ]] \
        || die "snapshot_add: the name of the copy of ${src} must be a single path component, got '${name}'"
    dest="${SNAPSHOT_DIR}/${name}"

    snapshot_register "$src" "$dest"
    _snapshot_present "$src" || return 0

    if _snapshot_present "$dest"; then
        _snapshot_copy_failed "Could not back up ${src}: ${dest} is already in the snapshot"
    fi
    log_info "Backing up ${src}..."
    # -T: <dest> is the copy itself, never a directory to copy into.
    sudo cp -a -T -- "$src" "$dest" \
        || _snapshot_copy_failed "Could not back up ${src} to ${dest}"
    journal_record backup "$src" "$SNAPSHOT_COPY_DETAIL" "backup=${dest}"
}

# ── snapshot_failure_report <what failed> [partial path] [its copy] ────────────
# The generic account of a removal that failed: what is already gone, where
# the copies are, and the commands that put it back. Used when no
# SNAPSHOT_ON_FAIL is set; a handler that only has something to add (how to
# start its service again) can call this first with the arguments it was
# given. Logs only; it does not exit.
snapshot_failure_report() {
    local what="${1:-}" partial="${2:-}" partial_copy="${3:-}" i

    log_error "$what"
    if (( ${#SNAPSHOT_REMOVED_SRC[@]} > 0 )); then
        log_error "Already removed (each with its copy in the snapshot):"
        for i in "${!SNAPSHOT_REMOVED_SRC[@]}"; do
            log_error "  ${SNAPSHOT_REMOVED_SRC[$i]}   (copy: ${SNAPSHOT_REMOVED_COPY[$i]})"
        done
    else
        log_error "Nothing has been removed yet."
    fi
    log_error "The snapshot at ${SNAPSHOT_DIR} now holds the only copy of what was removed. Do not delete it."
    if (( ${#SNAPSHOT_REMOVED_SRC[@]} > 0 )) || [[ -n "$partial" ]]; then
        log_error "To put back what was removed:"
        for i in "${!SNAPSHOT_REMOVED_SRC[@]}"; do
            log_error "  sudo cp -a -T -- '${SNAPSHOT_REMOVED_COPY[$i]}' '${SNAPSHOT_REMOVED_SRC[$i]}'"
        done
        # What is left of a half-removed directory goes first: cp onto it
        # would merge the copy into the remains.
        if [[ -n "$partial" ]]; then
            log_error "  sudo rm -rf -- '${partial}'   (what is left of the removal that failed)"
            log_error "  sudo cp -a -T -- '${partial_copy}' '${partial}'"
        fi
    fi
}

# A removal has failed: hand over to the caller's handler or give the generic
# report. Ends the run either way.
_snapshot_remove_failed() {
    if [[ -n "$SNAPSHOT_ON_FAIL" ]] && declare -f "$SNAPSHOT_ON_FAIL" >/dev/null 2>&1; then
        "$SNAPSHOT_ON_FAIL" "$@"
    else
        snapshot_failure_report "$@"
    fi
    exit 1
}

# ── snapshot_remove_all [detail] ──────────────────────────────────────────────
# Remove every registered path that exists, in the order registered, each
# journalled with where its copy is. [detail] is the journal text (default
# "removed after snapshot").
#
# A path goes only if its copy is in the snapshot at that moment. A missing
# copy, or a failed rm, ends the run through SNAPSHOT_ON_FAIL (or the generic
# report): what follows in the list is left alone.
#
# rm -rf, so a directory at a registered path goes whole. rm never follows a
# symlink operand: a link is removed, not what it points to.
snapshot_remove_all() {
    local detail="${1:-removed after snapshot}" i src copy
    [[ -n "$SNAPSHOT_DIR" ]] || die "snapshot_remove_all called before snapshot_create"

    SNAPSHOT_REMOVED_SRC=()
    SNAPSHOT_REMOVED_COPY=()
    for i in "${!_SNAPSHOT_SRC[@]}"; do
        src="${_SNAPSHOT_SRC[$i]}"
        copy="${_SNAPSHOT_COPY[$i]}"
        _snapshot_present "$src" || continue
        if ! _snapshot_present "$copy"; then
            _snapshot_remove_failed "Not removing ${src}: its copy ${copy} is not in the snapshot."
        fi
        log_info "Removing ${src}..."
        sudo rm -rf -- "$src" \
            || _snapshot_remove_failed "Failed to remove ${src} (it may be partly removed; its copy is ${copy})." "$src" "$copy"
        SNAPSHOT_REMOVED_SRC+=("$src")
        SNAPSHOT_REMOVED_COPY+=("$copy")
        journal_record delete "$src" "$detail" "backup=${copy}"
    done
}

# Set by unit_stop_disable: 1 when it stopped the unit, 0 when the unit was
# neither active nor failed and nothing was done.
UNIT_STOPPED=0

# ── unit_stop_disable <unit> <reason> ─────────────────────────────────────────
# Stop a systemd unit that is active or failed, clear a failed state, and
# disable it, journalling each step as "... for <reason>". A unit that is
# neither active nor failed is left alone.
#
# Through the unit, not the daemon's own "down" command: systemctl stop runs
# ExecStop/ExecStopPost and clears an active(exited) state. A failed unit stays
# failed after stop, which exits 0 either way (systemd 259); reset-failed
# clears it.
#
# Status: 0 unless the stop itself failed, then 1, with nothing journalled and
# the unit's state unknown. The caller says what that means for its service. A
# failed reset-failed or disable is only a warning: a rebuild starts and
# enables the unit again.
unit_stop_disable() {
    local unit="${1:-}" reason="${2:-teardown}"
    UNIT_STOPPED=0

    systemctl is-active --quiet "$unit" 2>/dev/null \
        || systemctl is-failed --quiet "$unit" 2>/dev/null \
        || return 0

    log_info "Stopping ${unit}..."
    sudo systemctl stop "$unit" || return 1
    UNIT_STOPPED=1
    journal_record service "$unit" "stopped for ${reason}"

    if systemctl is-failed --quiet "$unit" 2>/dev/null; then
        if sudo systemctl reset-failed "$unit"; then
            journal_record service "$unit" "failed state reset for ${reason}"
        else
            log_warn "systemctl reset-failed ${unit} failed — continuing"
        fi
    fi
    if sudo systemctl disable "$unit"; then
        journal_record service "$unit" "disabled for ${reason}"
    else
        log_warn "systemctl disable ${unit} failed — continuing"
    fi
    return 0
}
