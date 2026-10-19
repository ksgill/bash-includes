#!/usr/bin/env bash
# file.sh — root-owned files written only when they change.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Every provisioning script writes configuration files that belong to root:
# a drop-in, a unit, a policy, a ruleset. Each used to carry its own version
# of the same sequence — compare, back up, make the directory, write, journal
# — and the versions drifted: one wrote in place and could leave a truncated
# file behind, one compared content but not mode, one made a two-level
# directory with a single `install -d` and got 0700 parents from a caller's
# umask, none checked who else could write the directory. This is that
# sequence once:
#
#   install_file_if_changed [--mode M] [--allow-empty] [--no-backup] [--quiet]
#                           <dest> <reason>        # the content on stdin
#
#   1. The content is staged in a temporary file of the invoking user's, in
#      TMPDIR. Content with nothing but whitespace in it is refused unless
#      --allow-empty is given: a helper that printed nothing, or `<<< "$var"`
#      with an unset variable (which still yields one newline), is far more
#      often a bug than a request for an empty file.
#   2. Nothing is done when <dest> already holds exactly those bytes with
#      that mode (default 0644), owned by root. Mode and owner count as
#      content: a unit left group-writable is a change to make even when the
#      text matches. The comparison is byte for byte; content that carries a
#      per-run stamp is rewritten on every run and belongs with a caller-side
#      comparison, or without the stamp.
#   3. Otherwise an existing <dest> whose content differs is backed up with
#      backup_file (.orig or .bak, journalled), unless --no-backup, which
#      records the previous content's sha256 in the journal instead — for
#      directories whose loader reads every file in them whatever its name,
#      where a .bak beside the original would be loaded as a second copy. A
#      file whose content matches and only whose mode or owner differs is
#      not backed up: the .bak would be a copy of what is being kept.
#   4. Missing parent directories are created one level at a time, 0755 and
#      root's (mkdir_root_p). Existing ones are left exactly as they are.
#   5. The content is installed as a root-owned file with a random name
#      beside <dest> and renamed over it (install_atomic), so the path never
#      goes missing part-way and nothing is ever written through a name
#      someone else chose. A run killed outright between the two steps
#      leaves that hidden `.<name>.XXXXXXXX~` file behind, root's, inert
#      to every loader that skips dotfiles or editor backups; with cleanup.sh
#      loaded an interrupted run removes it.
#   6. A `create` or `modify` record goes to the journal with <reason>.
#
#   INSTALL_FILE_CHANGED is 1 after a write and 0 after a no-op, for callers
#   that reload or restart something only when the file changed. Returns 0 in
#   both cases, and 1 after a failure that was logged, with the previous
#   file, if any, still in place. One failure does not return: backup_file
#   exits the script when the backup cannot be made, as it does for every
#   caller, and the staged content is removed on the way out when cleanup.sh
#   is loaded.
#
# Feed the content with a heredoc, `<<<` or `< file`, never a pipe: a
# `printf ... | install_file_if_changed` runs the function in a subshell, where
# INSTALL_FILE_CHANGED and the temp-file registration are lost to the caller.
#
# Where root may write. The same rule backup_file applies to the directory it
# writes a backup into (lib/backup.sh, _backup_dir_closed) is applied here to
# every directory root is about to use: every component from the file's
# directory up to / must be a directory owned by root or by the invoking user
# and not writable by anyone else, or sticky and world-writable with the
# kernel's protected_symlinks and protected_regular on. Anything less, and an
# account that can write that directory could plant a link where root is
# about to write. The rule is applied to <dest>'s directory (its nearest
# existing ancestor when parents are missing), to the directory of a <dest>
# that is a symbolic link before the link is followed, to the link's target's
# directory after, and to TMPDIR, where the content waits as the user's file
# before root reads it. A link is followed only when the link itself is owned
# by root or the invoking user: realpath resolves it in user space, where the
# kernel's protected_symlinks rule for sticky directories does not reach. A refusal is logged and returns 1; nothing is
# written. A <dest> that is a symbolic link is otherwise followed: the file
# it points to is the one compared and replaced, and the link stays.
#
# The smaller pieces are usable on their own, under the same rule:
#   file_differs <src> <dest> <mode>   predicate: <dest> missing, or its
#                                      content, mode or owner differ from <src>
#                                      installed with <mode>; "cannot tell"
#                                      (a failed sudo, a bad mode) is "differs",
#                                      so a broken check costs a rewrite and a
#                                      .bak per run, never a skipped write
#   install_atomic <src> <mode> <dest> stage beside <dest>, rename over it
#   install_atomic_glob <dest>         the glob that finds a staging file
#                                      install_atomic left beside <dest> when
#                                      it was killed between the two steps
#   mkdir_root_p <dir>                 <dir> and missing parents, 0755, root's
#
# "root" throughout means the account sudo runs commands as, read once with
# `sudo id -u`; under a test stub that runs commands as the caller it is the
# caller, so the helpers behave the same unprivileged.
#
# Depends on: log.sh, journal.sh, backup.sh. cleanup.sh is used when loaded
# (the staged content is then removed on an interrupted run).

# include: log.sh
# include: journal.sh
# include: backup.sh
[[ -n "${_LIB_FILE_SOURCED:-}" ]] && return 0
_LIB_FILE_SOURCED=1

# Set by install_file_if_changed: 1 when the call wrote the file, 0 when the
# installed file already matched or the call failed.
INSTALL_FILE_CHANGED=0

# The account sudo runs commands as, learned once per run.
_FILE_UID=""
_FILE_GID=""
_file_owner() {
    [[ -n "$_FILE_UID" && -n "$_FILE_GID" ]] && return 0
    _FILE_UID="$(sudo id -u 2>/dev/null)" || _FILE_UID=""
    _FILE_GID="$(sudo id -g 2>/dev/null)" || _FILE_GID=""
    if [[ ! "$_FILE_UID" =~ ^[0-9]+$ || ! "$_FILE_GID" =~ ^[0-9]+$ ]]; then
        _FILE_UID=""; _FILE_GID=""
        log_error "file: could not learn which account sudo runs commands as"
        return 1
    fi
}

# _file_link_trusted <link> — true when the link itself (lstat, not what it
# points to) is owned by root or by the invoking user, and what it points to
# is not another link. A link is resolved here with realpath, in user space,
# so the kernel's protected_symlinks rule (follow a link in a sticky
# world-writable directory only when its owner is the follower's or the
# directory's) never applies: this is that rule, done by hand, for the one
# kind of directory the directory rule admits that others can write to. The
# one-hop limit is the same rule for the second hop: a trusted link pointing
# at a name in such a directory that someone else later fills with a link of
# their own would otherwise be followed through it.
_file_link_trusted() {
    local owner hop rc
    owner="$(sudo stat -c '%u' -- "$1" 2>/dev/null)" || return 1
    [[ "$owner" == "$_FILE_UID" || "$owner" == "$(id -u)" ]] || return 1
    hop="$(sudo readlink -- "$1" 2>/dev/null)" || return 1
    [[ "$hop" == /* ]] || hop="${1%/*}/${hop}"
    rc=0; _backup_exists -L "$hop" || rc=$?
    (( rc == 1 ))
}

# Print <mode> as stat -c %a prints it: octal, no leading zero (0644 -> 644).
# Three permission digits, with or without a leading 0; setuid, setgid and
# sticky bits are refused, since nothing a provisioning script writes wants
# them and a typo must not grant them. Returns 1 for anything else.
_file_mode() {
    [[ "$1" =~ ^0?[0-7]{3}$ ]] || return 1
    printf '%o' "$((8#$1))"
}

# Temporary files of the current call: the user's staging copy and root's.
# One cleanup handler for the module, registered on first use, so a call
# interrupted after staging leaves nothing behind; the arrays are emptied
# when a call ends normally, so the handler never grows with the run.
_FILE_TMPS=()
_FILE_ROOT_TMPS=()
_FILE_TMP_HANDLER=""
_file_tmp_cleanup() {
    local t
    for t in "${_FILE_TMPS[@]}"; do rm -f -- "$t" 2>/dev/null || true; done
    # -n: a handler must never wait at a password prompt.
    for t in "${_FILE_ROOT_TMPS[@]}"; do sudo -n rm -f -- "$t" 2>/dev/null || true; done
    _FILE_TMPS=(); _FILE_ROOT_TMPS=()
}
_file_tmp_register() {
    if [[ "$1" == root ]]; then _FILE_ROOT_TMPS+=("$2"); else _FILE_TMPS+=("$2"); fi
    if [[ -z "$_FILE_TMP_HANDLER" ]] && declare -f cleanup_push >/dev/null; then
        cleanup_push _file_tmp_cleanup
        _FILE_TMP_HANDLER=1
    fi
}
# Remove this call's temporary files now (every exit path of a call).
_file_tmp_drop() { _file_tmp_cleanup; }
# Forget one root-side name the rename has consumed, so a standalone
# install_atomic leaves nothing for the handler to remove at exit.
_file_tmp_forget_root() {
    local t
    local -a keep=()
    for t in "${_FILE_ROOT_TMPS[@]}"; do [[ "$t" == "$1" ]] || keep+=("$t"); done
    _FILE_ROOT_TMPS=("${keep[@]}")
}

# _file_dir_trusted <path> — print the canonical directory that will hold
# <path>'s last component, once every directory along the path AS WRITTEN
# passes the directory rule, or print the reason and return 1.
#
# Walked from / down, one component at a time. At each step the directory
# reached so far is checked (_backup_dir_closed judges it and its canonical
# chain); the next component is then looked at with lstat: a link is followed
# only because the directory holding it has just passed, so only root or the
# invoking user can have placed it, and the walk continues at its canonical
# target, which the next step checks in turn. A canonical-only check would
# miss a link planted as a middle component in a directory others can write,
# whose target is a closed directory of the planter's choosing. Components
# that do not exist yet are appended to the canonical directory reached, so a
# caller creating them does so under the checked path, not the written one.
_file_dir_trusted() {
    local p="$1" rest cur comp next canon rc
    [[ "$p" == /* ]] || { printf 'not an absolute path: %s\n' "$p"; return 1; }
    rest="${p#/}"
    rest="${rest%/*}"           # the directory part, relative to /
    [[ "$p" == */* && "${p#/}" == */* ]] || rest=""
    cur="/"
    while [[ -n "$rest" ]]; do
        comp="${rest%%/*}"
        rest="${rest#"$comp"}"; rest="${rest#/}"
        [[ -n "$comp" && "$comp" != "." ]] && {
            canon="$(_backup_dir_closed "${cur%/}/.")" || { printf '%s\n' "$canon"; return 1; }
            next="${canon%/}/${comp}"
            rc=0; _backup_exists -e "$next" || rc=$?
            if (( rc == 1 )); then
                # From here down nothing exists: the rest is created under
                # canon, so it must be plain names — a . or .. there would be
                # resolved against directories not yet checked.
                [[ "/${rest}/" != *"/./"* && "/${rest}/" != *"/../"* ]] \
                    || { printf '%s: . and .. are not allowed in components that do not exist yet\n' "$p"; return 1; }
                printf '%s%s\n' "$next" "${rest:+/$rest}"
                return 0
            fi
            (( rc == 0 )) || { printf '%s cannot be examined\n' "$next"; return 1; }
            rc=0; _backup_exists -L "$next" || rc=$?
            if (( rc == 0 )); then
                _file_link_trusted "$next" \
                    || { printf 'the link %s is not owned by root or the invoking user, or points at another link\n' "$next"; return 1; }
                next="$(sudo realpath -e -- "$next" 2>/dev/null)" \
                    || { printf 'the link %s cannot be resolved\n' "${canon%/}/${comp}"; return 1; }
            elif (( rc != 1 )); then
                printf '%s cannot be examined\n' "$next"; return 1
            fi
            cur="$next"
        }
    done
    _backup_dir_closed "${cur%/}/."
}

# ── mkdir_root_p <dir> ────────────────────────────────────────────────────────
# Create <dir> and any missing parents, each 0755 and root's. Directories that
# already exist are not touched: `install -d -m` on an existing directory
# resets its mode, and parents usually belong to other packages.
#
# One `mkdir` per missing level, outermost first, then a chown and a check
# that what is there is a real directory of root's. mkdir, not `install -d`:
# install follows a symbolic link at the path and would chmod and chown what
# it points to, while mkdir gets EEXIST and never follows. `mkdir -m 0755 a`
# one level at a time rather than `mkdir -p -m 0755 a/b/c`, which gives the
# mode to c only; a and b get whatever the umask leaves, and sudo-rs hands the
# caller's umask on, so from a shell at 077 they came out 0700 and nothing
# but root could reach the file written inside. The nearest existing
# ancestor must pass the directory rule first.
mkdir_root_p() {
    local dir="$1" canon level d rc kind owner perm
    local -a missing=()

    [[ "$dir" == /* ]] || { log_error "mkdir_root_p: not an absolute path: '${dir}'"; return 1; }
    _file_owner || return 1
    # The checked path: canonical where it exists, as written below that.
    if ! canon="$(_file_dir_trusted "${dir%/}/.")"; then
        log_error "mkdir_root_p: refusing to create under ${dir}: ${canon}"
        return 1
    fi
    d="${canon%/}"
    d="${d:-/}"
    while [[ "$d" != "/" ]]; do
        rc=0; _backup_exists -e "$d" || rc=$?
        if (( rc == 0 )); then
            rc=0; _backup_exists -d "$d" || rc=$?
            (( rc == 0 )) || { log_error "mkdir_root_p: ${d} $( (( rc == 1 )) && echo 'exists and is not a directory' || echo 'cannot be examined')"; return 1; }
            break
        fi
        (( rc == 1 )) || { log_error "mkdir_root_p: ${d} cannot be examined"; return 1; }
        missing=("$d" "${missing[@]}")
        d="${d%/*}"
        d="${d:-/}"
    done
    for level in "${missing[@]}"; do
        sudo mkdir -m 0755 -- "$level" \
            || { log_error "mkdir_root_p: could not create ${level}"; return 1; }
        sudo chown -h "${_FILE_UID}:${_FILE_GID}" -- "$level" \
            || { log_error "mkdir_root_p: could not set the owner of ${level}"; return 1; }
        # lstat, so a link planted at the path is seen as a link; %f is the
        # raw st_mode in hex (S_IFDIR is 0x4000), not the translated %F.
        read -r kind owner perm <<< "$(sudo stat -c '%f %u %a' -- "$level" 2>/dev/null)"
        [[ "$owner" == "$_FILE_UID" && "$perm" == 755 ]] && (( (16#${kind:-0} & 16#F000) == 16#4000 )) \
            || { log_error "mkdir_root_p: ${level} is not the root-owned 0755 directory just created"; return 1; }
    done
    return 0
}

# The staging file's name beside its target, in one place for the mktemp
# template install_atomic uses and the glob install_atomic_glob prints, so
# the two cannot drift: a dot, the target's name, a dot, _FILE_STAGE_RANDOM
# characters mktemp draws from [[:alnum:]], and _FILE_STAGE_SUFFIX.
# _file_stage_name <base> <template|glob> prints the name without the
# suffix: with "template" the random characters are X's (what mktemp takes,
# the suffix passed with --suffix); with "glob" each is a [[:alnum:]]
# bracket, one per character, so a target whose own name holds the letters
# of a template never matches.
_FILE_STAGE_RANDOM=8
_FILE_STAGE_SUFFIX='~'
_file_stage_name() {
    local base="$1" kind="$2" rnd="" i
    for (( i = 0; i < _FILE_STAGE_RANDOM; i++ )); do
        if [[ "$kind" == glob ]]; then
            rnd+='[[:alnum:]]'
        else
            rnd+='X'
        fi
    done
    printf '.%s.%s\n' "$base" "$rnd"
}

# ── file_dir_trusted <dir> ────────────────────────────────────────────────────
# Whether root may safely create or replace files in <dir>: every directory
# along the path that exists passes the directory rule (root's or the
# invoking user's; not writable by group or other unless sticky and
# world-writable with the kernel's protected_* sysctls on; a link only
# where root or the user placed it), and what does not exist yet would be
# created under the checked part. The check the writers apply when they
# write (install_file_if_changed, install_atomic, mkdir_root_p), offered on
# its own for a preflight that names the problem before anything on the
# host changes: Debian ships /usr/local as root:staff 2775, so a tool that
# installs a root-run file under it is refused there until the mode is
# fixed, and a build that learns this at its last step has already changed
# the host. 0 when trusted; 1 after a log_error naming the directory and
# the reason. Nothing is created or changed.
file_dir_trusted() {
    local dir="${1:-}" reason
    [[ "$dir" == /* ]] || { log_error "file_dir_trusted: not an absolute path: '${dir}'"; return 1; }
    if ! reason="$(_file_dir_trusted "${dir%/}/.")"; then
        log_error "file_dir_trusted: root must not write under ${dir}: ${reason} (close the directory, chmod g-w,o-w, or use another path)"
        return 1
    fi
}

# ── install_atomic_glob <dest> ────────────────────────────────────────────────
# The glob that matches a staging file install_atomic left beside <dest>
# when it was killed between its mktemp and its rename (`.<name>.` then
# eight alphanumerics and `~`): for a caller that looks for leftovers in the
# directory it installs into and treats them as it treats the file itself
# (wireguard-bld's existing-install detection). The name only, no
# directory, for `find -name` or a `[[ == ]]` pattern, matched under
# LC_ALL=C (in a UTF-8 locale `[[:alnum:]]` takes letters mktemp never
# writes). 1 and nothing printed for a <dest> that is not an absolute path
# to a file, or whose name holds a glob metacharacter (`*`, `?`, `[`, `\`)
# or a control character: the name goes into the pattern as it is, and such
# a name would widen it to files that are not staging files.
install_atomic_glob() {
    local LC_ALL=C dest="${1:-}" base
    [[ "$dest" == /* && "$dest" != */ ]] || return 1
    base="${dest##*/}"
    case "$base" in
        *[\\*?\[]*|*[[:cntrl:]]*) return 1 ;;
    esac
    printf '%s%s\n' "$(_file_stage_name "$base" glob)" "$_FILE_STAGE_SUFFIX"
}

# ── install_atomic <src> <mode> <dest> ───────────────────────────────────────
# Install <src> as <dest>, <mode>, root's, without a moment in which <dest> is
# missing or half-written. `install` alone unlinks and recreates the target,
# so a run killed, or a disk filling, in that moment leaves it missing; for a
# state file that can be a policy change ("no file" spelling "no policy").
#
# <dest>'s directory must pass the directory rule and must exist. The content
# is installed into a file root creates with mktemp beside the target
# (`.<name>.XXXXXXXX~`, _file_stage_name: hidden and ending in `~`, which the
# loaders that read whole directories skip, and random, so nothing can be
# planted there first) and renamed over the target; rename(2) replaces it in
# one step. -T keeps a directory at <dest> an error instead of a place to
# move the file into. The staging file is removed on failure, and at exit if
# the run is interrupted with cleanup.sh loaded; one left by a kill between
# the two steps is found with install_atomic_glob. Returns 1 without a
# message; the caller knows what the file was for.
install_atomic() {
    local src="$1" mode="$2" dest="$3" canon base staged src_canon reason

    _file_owner || return 1
    [[ "$dest" == /* && "$dest" != */ ]] || return 1
    _file_mode "$mode" >/dev/null || return 1
    # The source waits in the caller's file until root reads it, so the
    # directory it waits in gets the same rule as the one root writes to:
    # another account that can rename a file into that directory between
    # the caller's write and root's `install` would have root install its
    # content (the hooks the VPN builders render into TMPDIR run as root).
    # A sticky world-writable directory with the protected_* sysctls on
    # passes the rule, so the default /tmp is fine; a shared non-sticky
    # TMPDIR is not.
    src_canon="$(realpath -e -- "$src" 2>/dev/null)" \
        || src_canon="$(sudo realpath -e -- "$src" 2>/dev/null)" \
        || { log_error "install_atomic: ${src} cannot be resolved — ${dest} is unchanged"; return 1; }
    if ! reason="$(_file_dir_trusted "$src_canon")"; then
        log_error "install_atomic: refusing to read ${src} from its directory: ${reason} — set TMPDIR to a private directory; ${dest} is unchanged"
        return 1
    fi
    canon="$(_file_dir_trusted "$dest")" || return 1
    # The parent itself must exist (the walk appends what does not).
    _backup_exists -d "$canon" || return 1
    base="${dest##*/}"
    staged="$(sudo mktemp --suffix="$_FILE_STAGE_SUFFIX" -- "${canon}/$(_file_stage_name "$base" template)")" || return 1
    _file_tmp_register root "$staged"
    if ! sudo install -m "$mode" -o "$_FILE_UID" -g "$_FILE_GID" -T -- "$src" "$staged"; then
        sudo rm -f -- "$staged"; _file_tmp_forget_root "$staged"
        return 1
    fi
    if ! sudo mv -f -T -- "$staged" "${canon}/${base}"; then
        sudo rm -f -- "$staged"; _file_tmp_forget_root "$staged"
        return 1
    fi
    _file_tmp_forget_root "$staged"
}

# ── file_differs <src> <dest> <mode> ─────────────────────────────────────────
# True when installing <src> as <dest> with <mode> would change anything:
# <dest> missing, or its content, mode or owner different. A predicate only,
# so it can sit in an `if`; it logs nothing. A link at <dest> is judged by
# what it points to.
file_differs() {
    local src="$1" dest="$2" mode="$3" want have
    _backup_exists -e "$dest" || return 0
    # Not a regular file (a directory, a FIFO that would hang cmp): differs.
    _backup_exists -f "$dest" || return 0
    sudo cmp -s -- "$src" "$dest" 2>/dev/null || return 0
    want="$(_file_mode "$mode")" || return 0
    _file_owner || return 0
    have="$(sudo stat -L -c '%a %u %g' -- "$dest" 2>/dev/null)" || return 0
    [[ "$have" != "${want} ${_FILE_UID} ${_FILE_GID}" ]]
}

# ── install_file_if_changed [options] <dest> <reason> ────────────────────────
# The sequence described in the header. Content on stdin.
install_file_if_changed() {
    local mode=0644 allow_empty=0 no_backup=0 quiet=0
    while [[ $# -gt 0 && "$1" == --* ]]; do
        case "$1" in
            --mode)
                [[ $# -ge 2 ]] || { log_error "install_file_if_changed: --mode needs a value"; return 1; }
                mode="$2"; shift 2 ;;
            --allow-empty) allow_empty=1; shift ;;
            --no-backup)   no_backup=1; shift ;;
            --quiet)       quiet=1; shift ;;
            *) log_error "install_file_if_changed: unknown option '$1'"; return 1 ;;
        esac
    done
    local dest="${1:-}" reason="${2:-}"
    local tmpdir tmp canon real dir rc action=create before="" same_content=0

    INSTALL_FILE_CHANGED=0
    if [[ $# -ne 2 || "$dest" != /* || "$dest" == */ || -z "$reason" ]]; then
        log_error "install_file_if_changed: usage: [--mode M] [--allow-empty] [--no-backup] [--quiet] /absolute/path \"reason\" < content"
        return 1
    fi
    if ! _file_mode "$mode" >/dev/null; then
        log_error "install_file_if_changed: '${mode}' is not a mode of three octal digits — ${dest} is unchanged"
        return 1
    fi
    _file_owner || return 1

    # The content waits in the user's file until root reads it, so the
    # directory it waits in gets the same rule as the ones root writes to.
    tmpdir="${TMPDIR:-/tmp}"
    if ! canon="$(_file_dir_trusted "${tmpdir%/}/.")"; then
        log_error "install_file_if_changed: refusing to stage content in ${tmpdir}: ${canon} — set TMPDIR to a private directory"
        return 1
    fi
    tmp="$(mktemp -p "$canon")" || { log_error "Could not create a temp file for ${dest} — it is unchanged"; return 1; }
    _file_tmp_register user "$tmp"
    if ! cat > "$tmp"; then
        _file_tmp_drop
        log_error "Could not stage the new content of ${dest} — it is unchanged"
        return 1
    fi
    if (( ! allow_empty )) && ! grep -q '[^[:space:]]' "$tmp"; then
        _file_tmp_drop
        log_error "Refusing to write ${dest} with empty content — it is unchanged"
        return 1
    fi

    # Where root is about to write: the destination's directory first, then,
    # for a link, the directory of what it points to.
    if ! canon="$(_file_dir_trusted "$dest")"; then
        _file_tmp_drop
        log_error "Refusing to write ${dest}: ${canon}"
        return 1
    fi
    rc=0; _backup_exists -L "$dest" || rc=$?
    if (( rc == 0 )); then
        if ! _file_link_trusted "$dest"; then
            _file_tmp_drop
            log_error "Refusing to follow ${dest}: the link is not owned by root or the invoking user, or points at another link"
            return 1
        fi
        real="$(sudo realpath -e -- "$dest" 2>/dev/null)" \
            || { _file_tmp_drop; log_error "Could not resolve the link ${dest} — nothing written"; return 1; }
        dest="$real"
        if ! canon="$(_file_dir_trusted "$dest")"; then
            _file_tmp_drop
            log_error "Refusing to write through the link to ${dest}: ${canon}"
            return 1
        fi
    elif (( rc != 1 )); then
        _file_tmp_drop
        log_error "Cannot tell what ${dest} is — nothing written"
        return 1
    fi
    rc=0; _backup_exists -e "$dest" || rc=$?
    if (( rc == 2 )); then
        _file_tmp_drop
        log_error "Cannot tell whether ${dest} exists — nothing written"
        return 1
    fi
    if (( rc == 0 )); then
        # Only a regular file is compared and replaced: a directory is a
        # mistake, and a FIFO someone planted at a not-yet-existing name in a
        # sticky directory would hang root's cmp.
        if ! _backup_exists -f "$dest"; then
            _file_tmp_drop
            log_error "${dest} exists and is not a regular file — nothing written"
            return 1
        fi
        if ! file_differs "$tmp" "$dest" "$mode"; then
            _file_tmp_drop
            (( quiet )) || log_info "${dest} unchanged"
            return 0
        fi
        action=modify
        sudo cmp -s -- "$tmp" "$dest" 2>/dev/null && same_content=1
        if (( same_content )); then
            reason="${reason} (mode or owner only)"
        elif (( no_backup )); then
            # The journal's own rule: a hash only of world-readable content.
            before="$(_sha256_of "$dest" 2>/dev/null || true)"
            [[ -n "$before" ]] \
                || log_warn "${dest}: previous content replaced without a backup, and not hashed (not world-readable)"
        else
            backup_file "$dest" "$reason"
        fi
    fi

    # canon is the checked directory for dest's last component (canonical
    # where it exists, as written below that): create and write there.
    dir="$canon"
    dest="${canon%/}/${dest##*/}"
    mkdir_root_p "$dir" \
        || { _file_tmp_drop; log_error "Could not create ${dir} — ${dest} not written"; return 1; }
    install_atomic "$tmp" "$mode" "$dest" \
        || { _file_tmp_drop; log_error "Could not install ${dest} — what was there before is still in place"; return 1; }
    _file_tmp_drop

    if [[ -n "$before" ]]; then
        journal_record "$action" "$dest" "$reason" "sha256_before=${before}"
    else
        journal_record "$action" "$dest" "$reason"
    fi
    INSTALL_FILE_CHANGED=1
    (( quiet )) || log_info "Wrote ${dest}"
    return 0
}
