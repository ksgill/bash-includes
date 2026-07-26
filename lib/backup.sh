#!/usr/bin/env bash
# backup.sh — the .orig / .bak backup convention.
# Part of the bash-includes library. Source this file; do not execute it.
#
# The rule:
#   .orig  the pristine, package-shipped version of a file. Written at most
#          once, the first time we modify a file that still matches what the
#          maintainer shipped. Never overwritten.
#   .bak   the state immediately before the current change, for everything else
#          (file already modified, file not package-owned, .orig already taken).
#          Overwritten each run — .orig holds the pristine copy, so the two
#          together always give you both endpoints that matter.
#
# Suffix choice follows established practice: .orig is patch(1)'s default backup
# suffix and means "before any of my changes"; .bak is the sed -i.bak idiom for
# "previous version". Spelled-out forms (.original, .backup) match no tool.
#
# Backups are written in place, next to the original, so they are discoverable
# by anyone looking at the directory. The journal records the exact path.
#
# Depends on: log.sh, journal.sh

# include: log.sh
# include: journal.sh
[[ -n "${_LIB_BACKUP_SOURCED:-}" ]] && return 0
_LIB_BACKUP_SOURCED=1

# ── _maintainer_md5 <path> ────────────────────────────────────────────────────
# Print the checksum the packaging system recorded for a file, or nothing.
#
# Debian tracks shipped files in three separate places, and configuration files
# — the ones we actually back up — are deliberately EXCLUDED from the obvious
# one. All three have to be consulted:
#
#   1. dpkg conffiles   Config files a package ships and expects you to edit.
#                       Recorded in /var/lib/dpkg/status, NOT in *.md5sums.
#                       e.g. /etc/sudoers, /etc/ssh/ssh_config
#   2. ucf hashfile     Config files managed by ucf, which many packages use so
#                       upgrades can merge local edits. Not in dpkg's conffiles
#                       at all. e.g. /etc/chrony/chrony.conf
#   3. package md5sums  Everything else a package ships (binaries, defaults,
#                       units). Rarely something we back up, but free to check.
#
# Checking only *.md5sums — the intuitive choice — silently never matches any
# config file, which would make .orig unreachable and send every backup to .bak.
_maintainer_md5() {
    local f="$1" entry pkg md5file want

    # 1. ucf hashfile — checked FIRST and independently of dpkg, because
    #    ucf-managed files are frequently not owned by any package at all
    #    (/etc/chrony/chrony.conf is generated at install time and `dpkg -S`
    #    finds nothing for it). Gating this behind a package lookup would make
    #    the whole branch unreachable.
    #    Format is "<md5>  <path>" — reversed columns relative to dpkg.
    if [[ -r /var/lib/ucf/hashfile ]]; then
        want="$(awk -v p="$f" '$2 == p { print $1; exit }' /var/lib/ucf/hashfile)"
        if [[ -n "$want" ]]; then
            printf '%s' "$want"
            return 0
        fi
    fi

    command -v dpkg-query >/dev/null 2>&1 || return 1

    # dpkg -S prints "package: /path"; package may carry an architecture suffix
    # ("libfoo:amd64") on multiarch systems.
    entry="$(dpkg-query -S "$f" 2>/dev/null | head -1)" || return 1
    entry="${entry%%: *}"
    [[ -n "$entry" ]] || return 1

    # 2. dpkg conffiles — format is "<path> <md5>", one per line.
    want="$(dpkg-query -W -f='${Conffiles}\n' "$entry" 2>/dev/null \
            | awk -v p="$f" '$1 == p { print $2; exit }')"
    if [[ -n "$want" ]]; then
        printf '%s' "$want"
        return 0
    fi

    # 3. package md5sums — paths recorded without the leading slash.
    md5file="/var/lib/dpkg/info/${entry}.md5sums"
    if [[ ! -r "$md5file" ]]; then
        pkg="${entry%%:*}"
        md5file="/var/lib/dpkg/info/${pkg}.md5sums"
    fi
    if [[ -r "$md5file" ]]; then
        want="$(awk -v p="${f#/}" '$2 == p { print $1; exit }' "$md5file")"
        if [[ -n "$want" ]]; then
            printf '%s' "$want"
            return 0
        fi
    fi

    return 1
}

# ── _is_pristine_maintainer_file <path> ───────────────────────────────────────
# True when the file is owned by an installed package AND still byte-identical
# to what that package shipped. Both halves matter: a package-owned file that
# has already been edited is not pristine, and .orig must capture only the
# genuinely original content.
_is_pristine_maintainer_file() {
    local f="$1" want have

    want="$(_maintainer_md5 "$f")" || return 1
    [[ -n "$want" ]] || return 1

    have="$(sudo md5sum -- "$f" 2>/dev/null | cut -d' ' -f1)"
    [[ -n "$have" ]] || return 1

    [[ "$want" == "$have" ]]
}

# ── backup_file <path> [reason] ───────────────────────────────────────────────
# Back up a file before modifying it, following the convention above.
# Prints nothing on success; the chosen destination goes to the journal.
#
# Fatal on failure by design: proceeding to modify a file whose backup failed is
# exactly the situation the convention exists to prevent.
backup_file() {
    local f="$1" reason="${2:-before modification}" dest kind

    if [[ ! -f "$f" ]]; then
        # Nothing to preserve — the caller is creating the file, not changing it.
        return 0
    fi

    if _is_pristine_maintainer_file "$f" && [[ ! -e "${f}.orig" ]]; then
        dest="${f}.orig"
        kind="pristine maintainer version"
    else
        dest="${f}.bak"
        kind="previous version"
    fi

    # -a preserves mode, ownership and timestamps. Required for files like
    # /etc/sudoers that must keep a specific mode, and it keeps the original
    # mtime so you can tell when the file was actually shipped.
    sudo cp -a -- "$f" "$dest" \
        || die "Could not back up ${f} to ${dest} — refusing to modify it"

    log_info "Backed up ${f} → ${dest} (${kind})"

    if declare -f journal_record >/dev/null 2>&1; then
        journal_record backup "$f" "${reason}: ${kind} preserved" "backup=${dest}"
    fi
}
