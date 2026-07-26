#!/usr/bin/env bash
# oui.sh — IEEE OUI (MAC address vendor prefix) database handling.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Mechanism: how to normalise a MAC, query the IEEE registry, and refresh it.
# Which vendors you care about is the caller's business.
#
# The default database path is the one Debian's `ieee-data` package provides.
# That makes the file package-owned, so oui_update backs it up through
# backup_file before replacing it — a plain overwrite would silently diverge
# from the package with no way back.
#
# include: log.sh
[[ -n "${_LIB_OUI_SOURCED:-}" ]] && return 0
_LIB_OUI_SOURCED=1

OUI_FILE="${OUI_FILE:-/var/lib/ieee-data/oui.txt}"
OUI_URL="${OUI_URL:-https://standards-oui.ieee.org/oui/oui.txt}"

# ── oui_normalize <mac-or-oui> ────────────────────────────────────────────────
# Strip separators, uppercase, and return the leading 6 hex digits.
# Accepts 00:11:22:33:44:55, 00-11-22, 0011.2233.4455, "00 11 22", etc.
# Fails if fewer than 6 hex digits remain, or if any non-hex character survives.
oui_normalize() {
    local raw="${1:-}" clean
    # The dash must come LAST in the delete set: ':.- ' would be read as a
    # range from '.' to ' ', which is reversed and makes tr error out.
    clean="$(tr -d ':. -' <<< "$raw" | tr 'a-f' 'A-F')"

    [[ "$clean" =~ ^[0-9A-F]+$ ]] \
        || { log_warn "Not a valid MAC/OUI: ${raw}"; return 1; }
    [[ "${#clean}" -ge 6 ]] \
        || { log_warn "Need at least 6 hex digits, got ${#clean}: ${raw}"; return 1; }

    printf '%s' "${clean:0:6}"
}

# ── oui_format <6-hex-digits> ─────────────────────────────────────────────────
# 001122 -> 00-11-22, the form the IEEE file uses at the start of a record.
oui_format() {
    sed 's/\(..\)/\1-/g; s/-$//' <<< "${1:-}"
}

# ── oui_db_present ────────────────────────────────────────────────────────────
oui_db_present() { [[ -r "$OUI_FILE" ]]; }

# ── oui_lookup <mac-or-oui> ───────────────────────────────────────────────────
# Print the matching IEEE record. Returns 1 if the prefix is unassigned.
oui_lookup() {
    local oui formatted
    oui_db_present || { log_error "OUI database not found at ${OUI_FILE}"; return 2; }
    oui="$(oui_normalize "${1:-}")" || return 1
    formatted="$(oui_format "$oui")"

    # -F and an anchor via grep -m1 on the literal prefix: records start with
    # the formatted OUI, so a fixed-string match is both correct and faster.
    grep -m1 "^${formatted}" "$OUI_FILE" || {
        log_warn "No vendor registered for OUI ${formatted}"
        return 1
    }
}

# ── oui_vendor <mac-or-oui> ───────────────────────────────────────────────────
# Just the organisation name from the record.
oui_vendor() {
    local record
    record="$(oui_lookup "${1:-}")" || return $?
    # Record format: "00-11-22   (hex)\t\tVendor Name"
    sed 's/.*(hex)[[:space:]]*//' <<< "$record"
}

# ── oui_random_for_vendor <name> ──────────────────────────────────────────────
# A random OUI belonging to a vendor, as 6 hex digits.
#
# Matches only the vendor field of "(base 16)" records — matching the whole
# line would also hit street addresses, so searching for "Apple" could return
# a prefix belonging to a company on Apple Street.
oui_random_for_vendor() {
    local vendor="${1:-}" hit
    oui_db_present || { log_error "OUI database not found at ${OUI_FILE}"; return 2; }
    [[ -n "$vendor" ]] || { log_error "oui_random_for_vendor: need a vendor name"; return 1; }

    hit="$(awk -v v="${vendor,,}" '
        /\(base 16\)/ {
            line = $0
            sub(/^[^(]*\(base 16\)[[:space:]]*/, "", line)   # vendor field only
            if (index(tolower(line), v)) { print $1 }
        }' "$OUI_FILE" | shuf -n 1)"

    [[ -n "$hit" ]] || { log_warn "No OUI found for vendor '${vendor}'"; return 1; }
    printf '%s' "$hit"
}

# ── oui_update ────────────────────────────────────────────────────────────────
# Refresh the database from IEEE. Downloads to a temp file first so a failed or
# truncated transfer never replaces a working database.
oui_update() {
    local dir tmp
    dir="$(dirname -- "$OUI_FILE")"

    [[ -d "$dir" ]] || sudo mkdir -p -- "$dir" || { log_error "Cannot create ${dir}"; return 1; }

    tmp="$(mktemp)"
    if declare -f cleanup_push >/dev/null 2>&1; then
        cleanup_push "rm -f '$tmp'"
    fi

    log_info "Fetching OUI database from ${OUI_URL}"
    if command -v curl >/dev/null 2>&1 && curl -fsSL "$OUI_URL" -o "$tmp"; then
        :
    elif command -v wget >/dev/null 2>&1 && wget -q "$OUI_URL" -O "$tmp"; then
        :
    else
        log_error "Could not download the OUI database (need curl or wget)"
        rm -f "$tmp"
        return 1
    fi

    # A truncated download that still exits 0 would otherwise replace a good
    # database with a stub. The real file is several megabytes.
    [[ -s "$tmp" ]] && grep -q "(base 16)" "$tmp" \
        || { log_error "Downloaded file does not look like an OUI database"; rm -f "$tmp"; return 1; }

    if declare -f backup_file >/dev/null 2>&1; then
        backup_file "$OUI_FILE" "refreshing the IEEE OUI database"
    fi

    # install, not mv: mv would leave the file owned by the invoking user in a
    # system directory.
    sudo install -m 0644 -o root -g root "$tmp" "$OUI_FILE" \
        || { log_error "Could not install ${OUI_FILE}"; return 1; }
    rm -f "$tmp"

    if declare -f journal_record >/dev/null 2>&1; then
        journal_record modify "$OUI_FILE" "refreshed IEEE OUI database" "source=${OUI_URL}"
    fi
    log_success "OUI database updated: ${OUI_FILE} ($(wc -l < "$OUI_FILE") lines)"
}
