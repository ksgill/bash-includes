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

# Only the directory is defaulted here. The file and lock paths are derived in
# journal_init, because callers that keep a per-user journal set JOURNAL_DIR
# after sourcing — deriving them now pinned the lock to /var/lib/provision
# whatever the caller chose, and every append failed where that did not exist.
JOURNAL_DIR="${JOURNAL_DIR:-/var/lib/provision}"
JOURNAL_FILE="${JOURNAL_FILE:-}"
JOURNAL_LOCK=""

_JOURNAL_RUN_ID=""
_JOURNAL_SCRIPT=""
_JOURNAL_VERSION=""
_JOURNAL_READY=0
_JOURNAL_SUDO=0
# Set to 1 (as a local) by journal_record_nohash to suppress sha256_after.
_JOURNAL_NOHASH=0

# ── _journal_needs_sudo <dir> ─────────────────────────────────────────────────
# Succeeds when <dir> cannot be created or written as the invoking user. Walks
# up to the nearest existing ancestor and tests that. A journal under $HOME
# must never be created through sudo: `sudo mkdir -p` makes every missing
# component root-owned, and a root-owned ~/.local breaks anything else that
# installs there.
_journal_needs_sudo() {
    local d="$1"
    while [[ ! -e "$d" && "$d" != "/" && -n "$d" ]]; do
        d="$(dirname -- "$d")"
    done
    [[ -d "$d" && -w "$d" && -x "$d" ]] && return 1
    return 0
}

# Run a journal write as the invoking user, or through sudo when the journal
# lives somewhere only root can write.
_journal_priv() {
    if [[ "$_JOURNAL_SUDO" -eq 1 ]]; then
        sudo "$@"
    else
        "$@"
    fi
}

# The same, for journal_record's append: `sudo -n`, never prompting. A record
# is written right after the change it describes, so the timestamp is normally
# fresh; if it has expired the record is lost with a warning rather than the
# run stopping at a password prompt it did not ask for. journal_init keeps the
# prompting form above: it runs once at startup, where a prompt is expected,
# and making it non-interactive would silently disable the journal for any
# caller that has not primed sudo by then.
_journal_priv_n() {
    if [[ "$_JOURNAL_SUDO" -eq 1 ]]; then
        sudo -n "$@"
    else
        "$@"
    fi
}

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

    JOURNAL_FILE="${JOURNAL_FILE:-${JOURNAL_DIR}/changes.jsonl}"
    JOURNAL_LOCK="${JOURNAL_DIR}/.lock"

    _JOURNAL_SUDO=0
    if _journal_needs_sudo "$JOURNAL_DIR"; then
        _JOURNAL_SUDO=1
    fi

    if ! _journal_priv mkdir -p -- "$JOURNAL_DIR" 2>/dev/null; then
        log_warn "Cannot create $JOURNAL_DIR — changes will not be journalled"
        return 0
    fi
    _journal_priv chmod 0755 -- "$JOURNAL_DIR" 2>/dev/null || true
    _journal_priv touch -- "$JOURNAL_FILE" 2>/dev/null || true
    _journal_priv chmod 0644 -- "$JOURNAL_FILE" 2>/dev/null || true

    _JOURNAL_READY=1
    log_info "Journal run ${_JOURNAL_RUN_ID} → ${JOURNAL_FILE}"
}

# ── _json_escape <string> ────────────────────────────────────────────────────
# Print a string escaped for a JSON double-quoted value: backslash and quote,
# the named escapes \t \n \r \b \f, and \u00XX for every other control
# character in U+0001..U+001F, which JSON forbids raw. DEL (0x7f) is legal in
# JSON and passes through. NUL cannot occur in a bash string.
_json_escape() {
    local s="$1" i c
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//$'\t'/\\t}"
    s="${s//$'\n'/\\n}"
    s="${s//$'\r'/\\r}"
    s="${s//$'\b'/\\b}"
    s="${s//$'\f'/\\f}"
    # Anything left in U+0001..U+001F has no short form. Walk the string only
    # when one is present; the common case never enters the loop.
    if [[ "$s" == *[[:cntrl:]]* ]]; then
        local out=""
        for (( i = 0; i < ${#s}; i++ )); do
            c="${s:i:1}"
            case "$c" in
                [$'\001'-$'\037'])
                    printf -v c '\\u%04x' "'$c" ;;
            esac
            out+="$c"
        done
        s="$out"
    fi
    printf '%s' "$s"
}

# ── _sha256_of <path> ─────────────────────────────────────────────────────────
# Print the bare 64-hex sha256 of a file whose content anyone on the machine
# can read, or fail and print nothing.
#
# Policy: the journal is mode 0644, so a hash in it is published to every local
# account — and a hash is a confirmation oracle for anyone holding a candidate
# content. So a hash is recorded only for content that is world-readable
# already: the file has the other-read bit AND every ancestor directory has the
# other-execute bit. A 0600 key never gets one; neither does a 0644 file inside
# a 0700 directory (~/.ssh/config, /etc/wireguard/*). The record is still
# written, without sha256_after. Nothing here uses sudo: a file that fails the
# rule is not worth escalating for, and one that passes it is readable as-is.
#
# Symlinks are followed, and the rule is applied to what they resolve to: the
# path is canonicalised (`realpath -e`), and the canonical file's own mode and
# its canonical ancestors decide. Whoever can read the content through the
# canonical path can read it everywhere, so the link's own location does not
# matter, and a link into a private directory fails the rule like the target.
#
# Only an absolute path is considered. Package, unit, interface and user names
# are journalled as targets too, and a bare name would otherwise be resolved
# against the caller's working directory.
#
# The read opens the canonical path with O_NOFOLLOW and O_NONBLOCK (`dd
# iflag=nofollow,nonblock`) under `timeout`. A symlink swapped in as the last
# component after the check fails with ELOOP; a FIFO reads as empty (no
# writer), fails with EAGAIN (idle writer) or is cut off (endless writer).
# What a swap can still achieve is a hash of a regular file the swapper owns or
# can read and write (fs.protected_hardlinks) — content they already have.
# dd is the coreutils reader that has both open flags (GNU and uutils alike).
#
# Residual: O_NOFOLLOW covers only the last path component, and the mode checks
# precede the read. Someone who can write an ancestor directory can swap an
# intermediate component for a symlink between check and read, so the rule is
# only as strong as the ancestors of the journalled path — which for the
# system paths this journals are writable by root alone.
#
# The content is hashed from stdin, never by name: GNU sha256sum prefixes its
# output line with `\` when the file name holds a backslash or newline. The
# result must be exactly 64 hex digits, so a failed, killed or partial read
# yields no field.
#
# _JOURNAL_HASH_TIMEOUT (seconds, default 60) bounds each read. It must be a
# positive integer: `timeout 0` means no limit at all, which would switch the
# FIFO guard off, so 0 and anything unparseable fall back to the default.
_JOURNAL_HASH_TIMEOUT="${_JOURNAL_HASH_TIMEOUT:-60}"

_sha256_of() {
    local f="$1" c d m out t="${_JOURNAL_HASH_TIMEOUT:-60}"
    local -a dirs=() modes=()
    [[ "$t" =~ ^[1-9][0-9]*$ ]] || t=60
    [[ "$f" == /* ]] || return 1

    # The trailing dot survives command substitution, which would otherwise
    # strip a newline that ends the name.
    c="$(realpath -e -- "$f" 2>/dev/null && printf .)" || return 1
    c="${c%.}"
    c="${c%$'\n'}"
    [[ "$c" == /* && -f "$c" && ! -L "$c" ]] || return 1

    # Parameter expansion, not $(dirname), which strips a trailing newline.
    d="$c"
    while [[ "$d" != "/" ]]; do
        d="${d%/*}"
        d="${d:-/}"
        dirs+=("$d")
    done
    # One mode per line, file first; a path stat cannot see prints nothing,
    # which the count check catches.
    mapfile -t modes < <(stat -c '%a' -- "$c" "${dirs[@]}" 2>/dev/null)
    [[ ${#modes[@]} -eq $(( ${#dirs[@]} + 1 )) ]] || return 1
    for m in "${modes[@]}"; do
        [[ "$m" =~ ^[0-7]{3,4}$ ]] || return 1
    done
    (( (8#${modes[0]} & 8#4) != 0 )) || return 1
    for m in "${modes[@]:1}"; do
        (( (8#$m & 8#1) != 0 )) || return 1
    done

    out="$(set -o pipefail
           timeout -k 2 "$t" dd if="$c" iflag=nofollow,nonblock status=none 2>/dev/null \
               | sha256sum 2>/dev/null)" || return 1
    out="${out%% *}"
    [[ "$out" =~ ^[0-9a-f]{64}$ ]] || return 1
    printf '%s\n' "$out"
}

# ── journal_record <action> <target> [detail] [key=value ...] ─────────────────
# action: create | modify | delete | install | remove | backup | service | repo
# target: the path or package/unit name the action applied to
# detail: short human-readable description of what was done and why
#
# Any extra key=value arguments are added as additional JSON fields — used by
# backup.sh to attach the backup path, for instance.
#
# When <target> is an absolute path to a file whose content is world-readable
# (other-read on the file, other-execute on every ancestor directory), its
# sha256 is recorded as sha256_after. Any other file is recorded without one —
# the journal is world-readable, and a hash would publish a confirmation oracle
# for content that is not. Use journal_record_nohash to leave the hash out of a
# world-readable file's record as well.
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

    local sha="" extra="" kv k v
    if [[ "${_JOURNAL_NOHASH:-0}" -ne 1 ]]; then
        sha="$(_sha256_of "$target" 2>/dev/null || true)"
    fi

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
    if ! printf '%s\n' "$line" | _journal_priv_n flock "$JOURNAL_LOCK" tee -a "$JOURNAL_FILE" >/dev/null 2>&1; then
        log_warn "Could not write journal entry for ${target}"
    fi
    return 0
}

# ── journal_record_nohash <action> <target> [detail] [key=value ...] ──────────
# Exactly journal_record, but never records sha256_after for <target>.
#
# A file that is not world-readable never gets a hash in any case (see
# _sha256_of), so a private key or a 0600 config needs nothing extra. This is
# for a world-readable file whose hash should still not be kept, and for a
# caller that wants the choice visible at the call site. It is a separate
# function rather than a reserved key=value so it cannot collide with a
# caller's own field name, and so a script built against an older journal.sh
# fails loudly instead of silently hashing anyway.
journal_record_nohash() {
    local _JOURNAL_NOHASH=1
    journal_record "$@"
}
