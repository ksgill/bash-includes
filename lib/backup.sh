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

# ── _backup_exists <-f|-e> <path> ─────────────────────────────────────────────
# `test <op> <path>`, answered through sudo when the invoking user cannot
# tell. A file in a directory the user may not search (a 0750 root-owned
# directory, a 0700 configuration directory) fails an unprivileged test
# exactly as a file that is not there does, and treating the two alike means
# replacing a file with no backup, or writing over a .orig that could not be
# seen.
#
# Status: 0 it is there; 1 it is not; 2 it could not be asked (root's answer
# was needed and sudo did not give one). The caller must not read 2 as 1.
#
# What "cannot see" covers, precisely:
#
#   - No sudo call on the fast path: the path is visible (whatever it is), or
#     its nearest existing ancestor is a directory the user can search, or is
#     not a directory at all — then it is visibly absent.
#   - A symlink the user can see whose target they cannot (a link into an
#     unsearchable directory, or a dangling one) is judged by its target: the
#     ancestor that decides is the target's, since the test follows the link.
#   - Root is asked only when the unsearchable ancestor is owned by root.
#     Root's directories are the case this exists for. A directory someone
#     else owns and has closed gets no privileged test of a path inside it:
#     the answer is "not there", as it always was, with a warning.
#   - A relative path is never put to root: it answers "not there" as soon as
#     the invoking user cannot tell, including when the working directory
#     itself cannot be searched.
#
# The privileged test reads metadata, never content. It answers in words
# (yes/no) and not through its exit status, because sudo's own failure to run
# anything is also status 1: that must not read as "the file is not there".
_backup_exists() {
    local op="$1" f="$2" walk d owner answer
    if test "$op" "$f"; then
        return 0
    fi
    # Visible, but not what was asked for (a directory, for -f).
    if [[ -e "$f" ]]; then
        return 1
    fi
    [[ "$f" == /* ]] || return 1

    # A visible link is followed to where it points; -m, because the target
    # may be out of sight.
    walk="$f"
    if [[ -L "$f" ]]; then
        walk="$(realpath -m -- "$f" 2>/dev/null)" || walk="$f"
    fi
    # Nearest existing ancestor. Parameter expansion, not $(dirname), which
    # strips a trailing newline. An absolute path always ends at "/".
    d="$walk"
    while [[ ! -e "$d" && "$d" != "/" ]]; do
        d="${d%/*}"
        d="${d:-/}"
    done
    if [[ ! -d "$d" || -x "$d" ]]; then
        return 1
    fi
    owner="$(_backup_dir_owner "$d")"
    if [[ "$owner" != 0 ]]; then
        log_warn "Cannot check ${f} for a backup: ${d} cannot be searched and is not root's (owner uid ${owner:-unknown}) — treating the file as absent"
        return 1
    fi
    # Deliberate: $1 and $2 are for the inner shell, not this one.
    # shellcheck disable=SC2016
    answer="$(sudo sh -c 'if test "$1" "$2"; then echo yes; else echo no; fi' sh "$op" "$f")" || answer=""
    case "$answer" in
        yes) return 0 ;;
        no)  return 1 ;;
        *)   return 2 ;;
    esac
}

# _backup_dir_owner <dir> — print the uid that owns a directory, or nothing.
# -L: a path that is a symlink to a directory is judged by the directory it
# points to, which is the one that cannot be searched, not by whoever made
# the link.
_backup_dir_owner() {
    stat -L -c '%u' -- "$1" 2>/dev/null || true
}

# ── backup_file <path> [reason] ───────────────────────────────────────────────
# Back up a file before modifying it, following the convention above.
# Prints nothing on success; the chosen destination goes to the journal.
#
# The file, and an existing .orig, are looked for through sudo when the
# invoking user cannot see into a root-owned directory (see _backup_exists for
# exactly when), so a root-only file is backed up like any other; the copy
# itself always runs through sudo. A file the user can see, or can see is
# absent, costs no sudo call for the test.
#
# A symlink is backed up as the file it points to: the backup is a copy of the
# content, with the target's mode, owner and timestamps, never a second link
# to the same target, which would change along with it. The copy is written
# at the backup's own path or not at all: a file or link already there is
# replaced, not written through, and if that path is a directory (or, with a
# cp that will not replace it, a link to one) the copy fails and this dies —
# it is never placed inside the directory.
#
# Fatal on failure by design: proceeding to modify a file whose backup failed is
# exactly the situation the convention exists to prevent. That includes not
# being able to ask root whether a file it alone can see is there.
backup_file() {
    local f="$1" reason="${2:-before modification}" dest kind rc=0

    _backup_exists -f "$f" || rc=$?
    case "$rc" in
        0) ;;
        1)
            # Nothing to preserve — the caller is creating the file, not changing it.
            return 0 ;;
        *)
            die "Could not find out whether ${f} exists (it is in a directory only root can search, and sudo gave no answer) — refusing to go on: it would be modified without a backup" ;;
    esac

    dest="${f}.bak"
    kind="previous version"
    if _is_pristine_maintainer_file "$f"; then
        rc=0
        _backup_exists -e "${f}.orig" || rc=$?
        case "$rc" in
            0) ;;
            1)
                dest="${f}.orig"
                kind="pristine maintainer version" ;;
            *)
                die "Could not find out whether ${f}.orig exists (sudo gave no answer) — refusing to go on: it might be overwritten" ;;
        esac
    fi

    # -a preserves mode, ownership and timestamps. Required for files like
    # /etc/sudoers that must keep a specific mode, and it keeps the original
    # mtime so you can tell when the file was actually shipped. -L copies what
    # a symlink points to (-a alone would copy the link).
    #
    # The backup lands at exactly ${dest} or not at all:
    # --remove-destination replaces a file or a link that is there instead of
    # writing through it, and -T treats ${dest} as the file to create, never
    # as a directory to copy into — without it a .bak that is a directory, or
    # a link to one, would receive the copy inside it. With both, GNU cp
    # replaces a link (to anything) and refuses a real directory; an
    # implementation that refuses the link as well fails the same safe way.
    # Either failure is fatal below, like any other failed copy.
    sudo cp -a -L --remove-destination -T -- "$f" "$dest" \
        || die "Could not back up ${f} to ${dest} — refusing to modify it"

    log_info "Backed up ${f} → ${dest} (${kind})"

    if declare -f journal_record >/dev/null 2>&1; then
        journal_record backup "$f" "${reason}: ${kind} preserved" "backup=${dest}"
    fi
}
