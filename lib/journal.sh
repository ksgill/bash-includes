#!/usr/bin/env bash
# journal.sh — durable, append-only record of persistent system changes.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Purpose: pick up a machine months later and answer "what was done to this box,
# by what, when, and where do I look for the originals?"
#
# Scope: persistent system changes only — config edits, package installs,
# service and repo changes, key/cert creation. Not progress, not reads, not
# computed values. A script that touches nothing durable should not journal.
#
# Location: /var/lib, not /var/log. This is state, not a log, and it must
# survive log rotation. Run transcripts live in /var/log/<script>/ separately.
#
# Format: JSON Lines. Append-only, one object per line — a torn write costs one
# record instead of the file, and it stays greppable without tooling.
#
# NEVER record file contents. Several callers handle private keys and
# certificates; this file records paths, hashes, and descriptions only.
#
# Depends on: log.sh

# include: log.sh
[[ -n "${_LIB_JOURNAL_SOURCED:-}" ]] && return 0
_LIB_JOURNAL_SOURCED=1

JOURNAL_DIR="${JOURNAL_DIR:-/var/lib/provision}"
JOURNAL_FILE="${JOURNAL_FILE:-${JOURNAL_DIR}/changes.jsonl}"
JOURNAL_LOCK="${JOURNAL_DIR}/.lock"

_JOURNAL_RUN_ID=""
_JOURNAL_SCRIPT=""
_JOURNAL_VERSION=""
_JOURNAL_READY=0

# ── journal_init [script-name] [version] ──────────────────────────────────────
# Call once at the start of a script that makes persistent changes.
# Version should come from the build stamp (git describe); "unknown" is fine
# for scripts not yet built through build.sh.
journal_init() {
    _JOURNAL_SCRIPT="${1:-$(basename -- "$0")}"
    _JOURNAL_VERSION="${2:-${SCRIPT_VERSION:-unknown}}"

    # Run id ties every record from one invocation together. Prefer the kernel
    # UUID source; fall back to pid+time, which is good enough to correlate.
    if [[ -r /proc/sys/kernel/random/uuid ]]; then
        _JOURNAL_RUN_ID="$(cut -c1-8 < /proc/sys/kernel/random/uuid)"
    else
        _JOURNAL_RUN_ID="$(printf '%x%x' "$$" "$(date +%s)" | cut -c1-8)"
    fi

    if ! sudo mkdir -p -- "$JOURNAL_DIR" 2>/dev/null; then
        log_warn "Cannot create $JOURNAL_DIR — changes will not be journalled"
        return 0
    fi
    sudo chmod 0755 -- "$JOURNAL_DIR" 2>/dev/null || true
    sudo touch -- "$JOURNAL_FILE" 2>/dev/null || true
    sudo chmod 0644 -- "$JOURNAL_FILE" 2>/dev/null || true

    _JOURNAL_READY=1
    log_info "Journal run ${_JOURNAL_RUN_ID} → ${JOURNAL_FILE}"
}

# Escape a string for inclusion in a JSON double-quoted value.
_json_escape() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//	/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    printf '%s' "$s"
}

_sha256_of() {
    [[ -f "$1" ]] || return 1
    sudo sha256sum -- "$1" 2>/dev/null | cut -d' ' -f1
}

# ── journal_record <action> <target> [detail] [key=value ...] ─────────────────
# action: create | modify | delete | install | remove | backup | service | repo
# target: the path or package/unit name the action applied to
# detail: short human-readable description of what was done and why
#
# Any extra key=value arguments are added as additional JSON fields — used by
# backup.sh to attach the backup path, for instance.
#
# Never fatal. A full disk or a read-only /var must not abort a provisioning
# run partway through; a missing journal line is the lesser loss.
journal_record() {
    local action="${1:-}" target="${2:-}" detail="${3:-}"
    shift 3 2>/dev/null || shift $#

    if [[ "$_JOURNAL_READY" -ne 1 ]]; then
        log_warn "journal_record called before journal_init — skipping: ${action} ${target}"
        return 0
    fi

    local sha extra="" kv k v
    sha="$(_sha256_of "$target" 2>/dev/null || true)"

    for kv in "$@"; do
        k="${kv%%=*}"
        v="${kv#*=}"
        extra+=",\"$(_json_escape "$k")\":\"$(_json_escape "$v")\""
    done

    local line
    line="{\"ts\":\"$(date -u '+%Y-%m-%dT%H:%M:%SZ')\""
    line+=",\"run\":\"${_JOURNAL_RUN_ID}\""
    line+=",\"script\":\"$(_json_escape "$_JOURNAL_SCRIPT")\""
    line+=",\"version\":\"$(_json_escape "$_JOURNAL_VERSION")\""
    line+=",\"host\":\"$(_json_escape "$(hostname)")\""
    line+=",\"user\":\"$(_json_escape "$(id -un)")\""
    line+=",\"action\":\"$(_json_escape "$action")\""
    line+=",\"target\":\"$(_json_escape "$target")\""
    line+=",\"detail\":\"$(_json_escape "$detail")\""
    [[ -n "$sha" ]] && line+=",\"sha256_after\":\"${sha}\""
    line+="${extra}}"

    # flock serialises concurrent appends; without it two scripts running at
    # once can interleave partial lines.
    if ! printf '%s\n' "$line" | sudo flock "$JOURNAL_LOCK" tee -a "$JOURNAL_FILE" >/dev/null 2>&1; then
        log_warn "Could not write journal entry for ${target}"
    fi
    return 0
}
