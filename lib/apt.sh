#!/usr/bin/env bash
# apt.sh — safe APT repository and package helpers.
# Part of the bash-includes library. Source this file; do not execute it.
#
# apt_add_repo replaces what used to be eight near-identical add_<name>_repo
# functions (kali, kismet, ovpn, ovpn3, virtualbox, vscode, docker, …), each a
# copy of the same wget-key / gpg --dearmor / write-.sources sequence with
# different constants. The mechanism lives here; which repositories you actually
# add is policy and belongs to the calling script, and so is the fingerprint
# of each repository's signing key: since v1.5.0 apt_add_repo requires either
# --fingerprint or an explicit --no-fingerprint.
#
# Waiting for apt's locks (since v1.6.0). On a freshly booted or freshly
# installed host another apt process is usually running: unattended-upgrades
# holding the dpkg frontend lock, often for many minutes, and apt-daily's own
# `apt-get update` holding the package lists lock. An apt-get that finds either
# lock taken fails at once. Two locks, two mechanisms (checked on apt 3.2.0):
#
#   installs, removes and purges take the dpkg lock, and pass
#     -o DPkg::Lock::Timeout="${APT_LOCK_WAIT}"
#   so apt itself waits up to that many seconds for it.
#
#   updates take the package lists lock, which that option does not cover, so
#   every update goes through apt_update_wait, which retries while apt reports
#   "Could not get lock", for up to APT_LOCK_WAIT seconds.
#
# Privilege: every apt-get here runs through sudo, like the rest of this
# library (backup.sh, journal.sh, the keyring handling below). The library's
# convention is a script run as a normal user (privilege.sh refuses root), so
# there is no "already root, skip sudo" branch.
#
# Depends on: log.sh; journal.sh and backup.sh if loaded. Uses gpg.

# include: log.sh
[[ -n "${_LIB_APT_SOURCED:-}" ]] && return 0
_LIB_APT_SOURCED=1

APT_KEYRING_DIR="/etc/apt/keyrings"
APT_SOURCES_DIR="/etc/apt/sources.list.d"

# Seconds apt-get waits for a lock held by another package operation, and the
# seconds between apt_update_wait's attempts. A caller may set either before
# sourcing this file (or assign it afterwards); both are read at call time.
# APT_LOCK_WAIT must be a whole number of seconds (0 means do not wait) and
# APT_LOCK_RETRY a positive one; see _apt_lock_settings.
: "${APT_LOCK_WAIT:=1200}"
: "${APT_LOCK_RETRY:=10}"

# _apt_lock_settings — called by everything that reads the two settings,
# before it does. A value that is not a number (or a retry interval of 0,
# which would spin without ever reaching the limit) is replaced by the default
# with a warning; the raw value never reaches arithmetic or apt's command
# line. The default is assigned back, so the warning is given once.
#
# Decimal without a leading zero, and bounded: "08" would pass a plain digit
# test and then fail in arithmetic, where a leading 0 means octal. The wait is
# 0 to 999999 seconds, the retry interval 1 to 9999.
#
# The warning needs log.sh. A script that sources this file before log.sh
# still gets the value corrected at that point, without the warning: there is
# nothing to say it with yet, and an undefined function must not stop a
# script that is only being loaded.
_apt_lock_settings() {
    local warn=log_warn
    declare -f log_warn >/dev/null 2>&1 || warn=:
    if [[ ! "${APT_LOCK_WAIT:-}" =~ ^(0|[1-9][0-9]{0,5})$ ]]; then
        "$warn" "APT_LOCK_WAIT='${APT_LOCK_WAIT:-}' is not a number of seconds (0 to 999999, no leading zero); using 1200"
        APT_LOCK_WAIT=1200
    fi
    if [[ ! "${APT_LOCK_RETRY:-}" =~ ^[1-9][0-9]{0,3}$ ]]; then
        "$warn" "APT_LOCK_RETRY='${APT_LOCK_RETRY:-}' is not a positive number of seconds (1 to 9999, no leading zero); using 10"
        APT_LOCK_RETRY=10
    fi
}
# Checked once here as well, in the shell that sources this file: a value set
# before sourcing is then corrected, and warned about, once — not again in
# every $(apt_lock_wait_message) subshell, where the correction is lost.
_apt_lock_settings

# ── apt_lock_wait_message ────────────────────────────────────────────────────
# Print (bare, on stdout) the sentence an entry point shows before its first
# apt-get call, so a run that sits waiting for a lock has said why:
#     log_info "$(apt_lock_wait_message)"
apt_lock_wait_message() {
    _apt_lock_settings
    printf '%s\n' "apt-get will wait up to $(( APT_LOCK_WAIT / 60 )) minutes if another package operation (such as unattended-upgrades or apt-daily) is running: installs wait for the dpkg lock, updates retry on the package lists lock"
}

# ── apt_update_wait [apt-get option...] ──────────────────────────────────────
# `apt-get update` with the given options (pass -qq for a quiet one), through
# sudo. apt's stdout passes through; its stderr is held back and shown once
# the update has succeeded or finally failed, so a lock retry does not print
# the same error every few seconds.
#
# When the update fails on the lists lock, it says so once and retries every
# APT_LOCK_RETRY seconds until APT_LOCK_WAIT seconds have been spent waiting
# (the time slept, not the time apt took). Any other failure, or the limit,
# returns apt's exit status at once, so the caller's own handling applies.
#
# The lock test is a line of apt's stderr that starts "E: Could not get lock ".
# apt 3.2.0 prints "E: Could not get lock <path>. It is held by process <pid>
# (<name>)", or "E: Could not get lock <path> - open (<errno>)", and the path
# is whatever lock it wanted, so the file or directory is not matched. The
# line that follows, "E: Unable to lock directory …", is not the test: apt
# prints it for a lock it may not open (not root) as well, which waiting does
# not cure. The phrase elsewhere in a line (a mirror's error text, say) is not
# a lock. Runs under LC_ALL=C so the message is the English one.
#
# The waiting line is a log_info, so it goes to stdout — or to file descriptor
# APT_WAIT_NOTICE_FD when that is set: a caller capturing the output points it
# at a descriptor of its own so the line still reaches the terminal:
#     { out="$(APT_WAIT_NOTICE_FD=3 apt_update_wait -qq 2>&1)"; } 3>&1
# A value that is not a descriptor number is ignored, and so is one that is
# not open: the line then goes to stdout.
#
# apt's stderr is held in a variable, not a temporary file, so there is
# nothing to remove on any path out of here, an interrupt included.
apt_update_wait() {
    local err rc waited=0 told=0 fd=1 notice
    _apt_lock_settings
    if [[ "${APT_WAIT_NOTICE_FD:-}" =~ ^[0-9]+$ ]]; then
        fd="$APT_WAIT_NOTICE_FD"
    fi
    while :; do
        rc=0
        # stdout passes through on fd 3; stderr is what is captured.
        { err="$(sudo env LC_ALL=C apt-get update "$@" 2>&1 1>&3 3>&-)"; } 3>&1 || rc=$?
        if [[ "$rc" -ne 0 && "$waited" -lt "$APT_LOCK_WAIT" ]] \
                && grep -q '^E: Could not get lock ' <<< "$err"; then
            if [[ "$told" -eq 0 ]]; then
                notice="Another apt process holds the package lists lock (apt-daily, probably); waiting for it (up to $(( APT_LOCK_WAIT / 60 )) minutes)…"
                # A descriptor that is not open fails the redirection, and
                # log_info then never runs: say it on stdout instead.
                { log_info "$notice" >&"$fd"; } 2>/dev/null || log_info "$notice"
                told=1
            fi
            sleep "$APT_LOCK_RETRY"
            waited=$(( waited + APT_LOCK_RETRY ))
            continue
        fi
        if [[ -n "$err" ]]; then
            printf '%s\n' "$err" >&2
        fi
        return "$rc"
    done
}

# _apt_update_quiet — the refresh after a sources file has been removed: no
# output and never fatal, but the lock-waiting line still shows.
_apt_update_quiet() {
    { APT_WAIT_NOTICE_FD=3 apt_update_wait -qq >/dev/null 2>&1; } 3>&1 || true
}

# _apt_backup <file> <reason> — backup_file, when backup.sh is loaded, leaving
# the path it chose (.orig or .bak) in _APT_BACKUP_DEST; empty when backup.sh
# is not loaded or there is no file. apt reads only *.list and *.sources from
# sources.list.d and ignores *.bak and *.orig silently, and reads a keyring
# only where a Signed-By names it, so both are safe in place.
#
# backup_file dies when the copy fails. It is run in a subshell here so that
# this returns non-zero instead, and the caller can give its own status.
_APT_BACKUP_DEST=""
_apt_backup() {
    local f="$1" had_orig=false
    _APT_BACKUP_DEST=""
    declare -f backup_file >/dev/null 2>&1 || return 0
    [[ -f "$f" ]] || return 0
    if [[ -e "${f}.orig" ]]; then
        had_orig=true
    fi
    ( backup_file "$f" "$2" ) || return 1
    if [[ "$had_orig" == false && -e "${f}.orig" ]]; then
        _APT_BACKUP_DEST="${f}.orig"
    else
        _APT_BACKUP_DEST="${f}.bak"
    fi
}

# ── apt_key_fingerprints <file> ──────────────────────────────────────────────
# Print the fingerprint of every primary key in <file>, one per line, upper
# case. <file> may be ASCII-armoured or a binary keyring. Runs gpg with a
# throwaway GNUPGHOME, so the caller's own keyring is never created or read.
# Returns non-zero if the file holds no key gpg can read.
apt_key_fingerprints() {
    local file="$1" home listing
    home="$(mktemp -d)" || return 1
    listing="$(GNUPGHOME="$home" gpg --batch --quiet --with-colons --show-keys -- "$file" 2>/dev/null)" \
        || { rm -rf "$home"; return 1; }
    rm -rf "$home"
    # The fpr record straight after a pub record is that primary key's.
    awk -F: '/^pub:/ { want = 1; next } want && /^fpr:/ { print toupper($10); want = 0 }' <<< "$listing" \
        | grep . || return 1
}

# ── _apt_installed_keyring_matches <keyring> <FPR>[,<FPR>...] ────────────────
# apt_keyring_matches for a keyring under APT_KEYRING_DIR, read through sudo:
# it is root-owned, and under a restrictive umask it may not be readable by
# the invoking user, which must not make a correct key look untrusted.
_apt_installed_keyring_matches() {
    local keyring="$1" list="$2" copy rc
    copy="$(_apt_keyring_copy "$keyring")" || return 1
    apt_keyring_matches "$copy" "$list"; rc=$?
    rm -f "$copy"
    return "$rc"
}

# _apt_keyring_copy <keyring> — print the path of a private temporary copy of
# a root-owned keyring, readable by the invoking user. Caller removes it.
_apt_keyring_copy() {
    local copy
    copy="$(mktemp)" || return 1
    # Deliberate: root reads the keyring, the invoking user writes the copy.
    # shellcheck disable=SC2024
    if ! sudo cat -- "$1" > "$copy" 2>/dev/null; then
        rm -f "$copy"
        return 1
    fi
    printf '%s\n' "$copy"
}

# ── apt_keyring_matches <file> <FPR>[,<FPR>...] ─────────────────────────────
# True when <file> holds at least one primary key and every primary key in it
# is on the list. An extra key refuses the file: apt would trust it for this
# repository too.
apt_keyring_matches() {
    local file="$1" allowed=",${2}," fpr found=0
    while IFS= read -r fpr; do
        found=1
        [[ "$allowed" == *",${fpr},"* ]] || return 1
    done < <(apt_key_fingerprints "$file" || true)
    [[ "$found" -eq 1 ]]
}

# _apt_fprs_normalise <who> <FPR>[,<FPR>...] — print the list with spaces
# dropped and in upper case, the form the keyring checks compare against, or
# log an error in <who>'s name and return 1 when an entry is not a
# fingerprint (40 hex digits for a v4 key, 64 for v5).
_apt_fprs_normalise() {
    local who="$1" fprs fpr
    local -a fpr_list
    fprs="$(tr -d ' ' <<< "$2" | tr '[:lower:]' '[:upper:]')"
    IFS=, read -r -a fpr_list <<< "$fprs"
    if [[ ${#fpr_list[@]} -eq 0 ]]; then
        log_error "${who}: the fingerprint list is empty"
        return 1
    fi
    for fpr in "${fpr_list[@]}"; do
        if [[ ! "$fpr" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]]; then
            log_error "${who}: '${fpr}' is not a key fingerprint (40 or 64 hex digits)"
            return 1
        fi
    done
    printf '%s\n' "$fprs"
}

# ── apt_repo_keyring_pinned <name> <FPR>[,<FPR>...] ──────────────────────────
# Is the keyring installed for repo <name> (APT_KEYRING_DIR/<name>.gpg) one of
# these pinned keys? The same check apt_add_repo makes of an existing keyring,
# for a caller that wants the answer without adding or changing anything.
#
#   0   the keyring exists, holds at least one primary key, and every primary
#       key in it is on the list
#   1   there is no keyring, it could not be read, it holds no key, or it
#       holds a key that is not on the list
#   2   <name> is not a usable repo name, or the list is not fingerprints (an
#       error is logged)
#
# Fingerprints are given as to apt_add_repo --fingerprint: spaces and case are
# ignored. The keyring is read through sudo, so one that the invoking user
# cannot read (a restrictive umask, a root-only directory) is still checked
# rather than reported as unpinned. Changes nothing.
apt_repo_keyring_pinned() {
    local name="${1:-}" fprs
    if [[ $# -ne 2 ]] || ! _apt_repo_name_ok "$name"; then
        log_error "apt_repo_keyring_pinned: usage: apt_repo_keyring_pinned <name> <FPR>[,<FPR>...] (got name '${name}')"
        return 2
    fi
    fprs="$(_apt_fprs_normalise "apt_repo_keyring_pinned ${name}" "$2")" || return 2
    _apt_installed_keyring_matches "${APT_KEYRING_DIR}/${name}.gpg" "$fprs"
}

# _apt_validation_class <exit status> <captured output> — say what the scoped
# validation update came to, from apt's own lines (it runs under LC_ALL=C):
#
#   ok           it succeeded, and nothing below was printed
#   locked       apt_update_wait gave up on the lists lock
#   signature    the repository's signature could not be verified with the
#                Signed-By keyring: signed by another key, an expired key, a
#                bad signature, or not signed at all
#   refused      the server refused access: HTTP 401 or 403
#   insecure     apt only warned that there is no Release file, which it does
#                when the host is configured to accept unsigned repositories;
#                the validation forces that off, so this is a last resort
#   unreachable  the repository could not be fetched from: the name does not
#                resolve, the connection failed, or the server answered with
#                an HTTP status other than 404 (a 5xx, say)
#   absent       apt reached the repository and it has no Release file for the
#                suite — the server answered 404 for it, or it is a file: or
#                copy: repository and the file is not there: the repository
#                does not serve the suite
#   unknown      it failed and none of the above was recognised
#
# Only `absent` means the repository itself is unsuitable, so the test for it
# is the narrowest and comes last: one exact line, a 404 (or no HTTP at all),
# and no sign of a signature or connection problem anywhere in the output —
# those always win. The wordings, and where each was confirmed:
#
#   seen in the output of apt 3.2.0, against local fixtures:
#     Err:2 <uri> <suite> Release
#       404  <the server's reason phrase> [IP: <address> <port>]
#     E: The repository '<uri> <suite> Release' does not have a Release file.
#        (a suite the server does not have; with nothing else, `absent`)
#     Err:2 file:<path> <suite> Release
#       File not found - <path>/dists/<suite>/Release (2: No such file or directory)
#     E: The repository 'file:<path> <suite> Release' does not have a Release file.
#        (a file: repository; no HTTP status)
#     E: The repository '<uri> <suite> Release' no longer has a Release file.
#        (the same, when lists from an earlier successful update are still
#        there; classed like the line above, 404 included)
#     W: OpenPGP signature verification failed: <uri> <suite> InRelease: The
#        following signatures couldn't be verified because the public key is
#        not available: NO_PUBKEY <id>
#     E: The repository '<uri> <suite> InRelease' is not signed.
#        (for a repository signed by a key not in the keyring, and for one
#        with no signature at all)
#     E: The repository '<uri> <suite> Release' is no longer signed.
#        (a signature that was there at an earlier update and is gone)
#     Err:1 <uri> <suite> InRelease
#       403  Forbidden [IP: <address> <port>]
#     E: Failed to fetch <url>  403  Forbidden [IP: <address> <port>]
#     E: The repository '<uri> <suite> InRelease' is not signed.
#        (403, and 401 with "Unauthorized": apt adds "is not signed", which
#        is why `refused` is tested for before `signature`)
#     E: Failed to fetch <url>  500  Internal Server Error [IP: …]
#        (and 503; followed by "Some index files failed to download")
#     [EW]: Failed to fetch <url>  Could not resolve '<host>'
#     [EW]: Failed to fetch <url>  Unable to connect to <host>:<port>:
#     [EW]: Some index files failed to download. They have been ignored, or
#        old ones used instead.
#        (E: with Error-Mode=any, W: and exit status 0 without it)
#     W: The repository '<uri> <suite> Release' is not signed.
#     W: The repository '<uri> <suite> Release' does not have a Release file.
#        (with Acquire::AllowInsecureRepositories=1; with it forced back to
#        0 on the command line, as the validation does, both are E: again)
#   present in apt 3.2.0's binaries (libapt-pkg, the gpgv method), not
#   produced here:
#     EXPKEYSIG; BADSIG; "The following signatures were invalid";
#     "An error occurred during the signature verification"
#   from apt's changelog only (2.9.32 replaced it with "OpenPGP signature
#   verification failed"), for apt before that:
#     W: GPG error: <uri> <suite> InRelease: …
#
# A signature or connection warning counts even when apt exits 0: apt keeps
# using old index files after a signature failure it calls transient, and an
# apt without Error-Mode exits 0 for a repository it never reached.
_apt_validation_class() {
    local rc="$1" out="$2"
    local release="The repository '.*' (does not have|no longer has) a Release file\\."
    if [[ "$rc" -ne 0 ]] && grep -q '^E: Could not get lock ' <<< "$out"; then
        printf 'locked\n'
    # Before the signature test: apt follows a refused InRelease with "is not
    # signed", and that is not what went wrong.
    elif [[ -n "$(_apt_validation_http "$out" refused)" ]]; then
        printf 'refused\n'
    elif grep -Eq 'OpenPGP signature verification failed|GPG error|NO_PUBKEY|EXPKEYSIG|BADSIG|signatures were invalid|during the signature verification|^[EW]: The repository .* is (not|no longer) signed\.' <<< "$out"; then
        printf 'signature\n'
    # Only a warning, where apt would stop: the host allows repositories with
    # no signature (Acquire::AllowInsecureRepositories). Before the connection
    # test, because apt then goes on to fetch index files that are not there.
    elif grep -Eq "^W: ${release}\$" <<< "$out"; then
        printf 'insecure\n'
    elif grep -Eq '^[EW]: (Failed to fetch |Some index files failed to download)|Could not resolve |Temporary failure resolving |Could not connect to |Unable to connect to ' <<< "$out" \
            || [[ -n "$(_apt_validation_http "$out" other)" ]]; then
        printf 'unreachable\n'
    elif [[ "$rc" -eq 0 ]]; then
        printf 'ok\n'
    elif grep -Eq "^E: ${release}\$" <<< "$out"; then
        # A missing Release file means "this suite is not served" only when
        # the server said the file is not there: a 404, or no HTTP at all (a
        # file: or copy: repository). Any other HTTP status was caught above.
        if grep -Eq "^E: The repository '(file|copy|cdrom):" <<< "$out" \
                || [[ -n "$(_apt_validation_http "$out" 404)" ]]; then
            printf 'absent\n'
        else
            printf 'unknown\n'
        fi
    else
        printf 'unknown\n'
    fi
}

# _apt_validation_http <captured output> <refused|other|404> — print the first
# HTTP status apt reported for a failed fetch that is, respectively, 401 or
# 403; anything but 404, 401 and 403; or 404. Nothing when there is none.
#
# apt prints the server's status line as the detail of an "Err:" block, two
# spaces in ("  404  Not Found [IP: …]" — the reason phrase is the server's
# own, so only the number is matched), and again in the "Failed to fetch"
# line when it treats the failure as an error ("…/InRelease  403  Forbidden").
_apt_validation_http() {
    local want="$2" code
    while IFS= read -r code; do
        case "${want}:${code}" in
            refused:401|refused:403|404:404)
                printf '%s\n' "$code"
                return 0 ;;
            other:401|other:403|other:404) ;;
            other:*)
                printf '%s\n' "$code"
                return 0 ;;
        esac
    done < <(sed -nE -e 's/^  ([1-5][0-9]{2})  .*/\1/p' \
                     -e 's/^[EW]: Failed to fetch .*  ([1-5][0-9]{2})  .*/\1/p' <<< "$1")
    return 0
}

# _apt_usage_die <message> — a call that is wrong as written (arguments, name,
# fingerprint policy): fatal, like die, but with exit status 2 so that a
# caller running apt_add_repo in a subshell never mistakes it for status 1,
# "the repository does not serve this suite".
_apt_usage_die() {
    log_error "$*"
    exit 2
}

# _apt_repo_name_ok <name> — a repo name becomes two file names, written and
# removed as root, so it must be one path component and must not look like an
# option: letters, digits, '.', '_' and '-', starting with a letter or digit.
_apt_repo_name_ok() {
    [[ "$1" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# ── apt_add_repo (--fingerprint <FPR>[,<FPR>...] | --no-fingerprint) ─────────
#                <name> <key_url> <uris> <suites> [components] [types] [arch]
#
#   --fingerprint  the signing key's primary fingerprint (40 hex digits for
#                  v4 keys, 64 for v5; spaces and case are ignored). Several,
#                  comma-separated, for a repository that publishes more than
#                  one key or is part-way through a rotation. Both a
#                  downloaded key and an existing keyring must hold only
#                  primary keys from this list.
#   --no-fingerprint
#                  trust whatever key_url serves, as before v1.5.0. Logs a
#                  warning on every call. One of the two is required: a
#                  caller that states neither is refused, so no repository is
#                  added unchecked by accident.
#   name        short identifier; names the keyring and .sources file.
#               Letters, digits, '.', '_' and '-', starting with a letter or
#               digit; anything else is refused.
#   key_url    URL of the ASCII-armoured or binary signing key
#   uris        repository base URL
#   suites      suite/codename, e.g. "noble" or "$(get_os_codename)" (os.sh,
#               which the caller includes itself)
#   components  defaults to "main"
#   types       defaults to "deb"
#   arch        optional Architectures: field. Set it for repos that publish
#               only some architectures — without it apt tries every enabled
#               foreign arch and reports spurious 404s on a multiarch host.
#
# Where to get a fingerprint to trust: the publisher's install instructions
# or a keyserver, and in any case confirm the key actually signs the
# repository — `gpgv --keyring <key.gpg> InRelease` against the suite's
# dists/<suite>/InRelease. Every OpenPGP key has a fingerprint, so any
# repository can be pinned; a publisher's key rotation then stops this
# function, with status 2, until the new key is checked and the pin updated,
# which is the point. That holds for both ways a rotation shows up: the key
# URL serves a key that is not the pinned one (refused before anything is
# installed), and the repository is signed by a new key while the keyring
# still holds the old, pinned one (the scoped validation fails on the
# signature). Neither is ever status 1.
#
# Idempotent: if the repo is already configured exactly as requested, and its
# keyring passes the fingerprint check, it returns without touching anything.
# A keyring that fails the check is moved aside (<name>.gpg.untrusted.<ts>),
# not deleted, and the key is fetched again.
#
# Validates the repo before accepting it. A scoped `apt-get update` reads ONLY
# the new sources file, so a failure is about this repository rather than an
# unrelated mirror. Whenever the validation does not succeed the sources file
# is removed again — an unvalidated source is never left configured — and
# what apt said decides the status (_apt_validation_class):
#
#   - apt reached the repository and it has no Release file for the suite —
#     the server answered 404 for it, or it is a file: repository without
#     one: the repository does not serve the suite. Status 1 — the caller
#     decides whether to fall back to distro-native packages or treat it as
#     fatal.
#   - the repository's signature could not be verified against the pinned
#     key (signed by another key, expired, not signed): status 2. The
#     validation forces Acquire::AllowInsecureRepositories off, so a host
#     configured to accept unsigned repositories cannot make one pass.
#   - the repository could not be reached (the name does not resolve, the
#     connection failed, the server refused access with 401 or 403, or
#     answered with any HTTP status other than 404): status 2. The validation
#     runs with APT::Update::Error-Mode=any so that apt reports a transient
#     failure as a failure.
#   - another apt process held the package lists lock for the whole of
#     APT_LOCK_WAIT, so the validation never ran: status 2. The refresh after
#     the removal is skipped then; it would wait on the same lock.
#   - anything it does not recognise: status 2.
#
# Status, and what each leaves behind:
#
#   0   Configured and validated, or already configured as requested (nothing
#       touched).
#
#   1   The repository does not serve this suite: apt's scoped update said
#       "The repository '…' does not have a Release file." (or "no longer
#       has"), the server's answer for that file was 404 (or the repository
#       is a file: one), and nothing was said about a signature or a
#       connection. The ONLY status a caller may treat as
#       "fall back to the distro's packages". The sources file this call
#       wrote is removed: none is left where there was none, and after a
#       reconfigure the version before the call is its backup (.bak / .orig),
#       not restored. The keyring, checked against the pin, stays.
#
#   2   Anything else; nothing was learned about the repository, and a caller
#       should not fall back on it:
#         - the call is wrong as written (arguments, name, fingerprint
#           options). Fatal: the shell exits 2, as die would with 1. Nothing
#           touched.
#         - an existing keyring is not the pinned key and could not be moved
#           aside. It is still in place and apt still trusts it for whatever
#           sources file names it.
#         - the keyring directory could not be created; the key could not be
#           fetched; the key served is not the pinned one; the key could not
#           be installed. No keyring is left (a partly written one is
#           removed). The sources file is as it was — except that an unpinned
#           keyring already moved aside stays aside, so an existing sources
#           file then names a keyring that is not there, and apt refuses that
#           repository until a pinned key is installed.
#         - an existing sources file could not be backed up before being
#           replaced. It is untouched.
#         - the sources file could not be written. It may be missing or
#           incomplete; after a reconfigure the version before is the backup.
#         - the scoped validation did not succeed, and not because the suite
#           is not served: the signature could not be verified against the
#           pinned key, the repository could not be reached or refused access
#           or answered with an HTTP status other than 404, apt only warned
#           about an unsigned repository, the lists lock was held for the
#           whole wait, or apt failed some other way. The
#           repository was NOT validated. Left as for status 1.
#         - the sources file failed validation and then could not be removed.
#           It is still in place, unvalidated.
#         - validation succeeded but the full update after it failed. The
#           repository stays configured and recorded; its packages may not be
#           visible until an update succeeds. A re-run returns 0.
#
# Backups and the journal (when backup.sh / journal.sh are loaded): replacing
# an existing sources file backs it up first (backup_file). The `repo` record
# is written once the scoped validation has succeeded — the file is valid and
# stays — and carries backup=<path> after a reconfigure. If the full update
# that follows then fails, that is warned about and the function returns 2,
# with the repo configured and recorded: a re-run finds it already configured
# and does nothing. The removal after a failed
# validation never backs up the file this call has just written, which would
# overwrite an older backup with a file nobody has seen:
#   created by this call     removed; any backup from an earlier run is left
#                            as it is. Nothing is journalled: the call left
#                            no sources file where there was none.
#   reconfigured by this call  removed; the backup taken earlier in the call,
#                            of the version before it, is kept. Journalled as
#                            one delete record carrying backup=<path>.
# Every `apt-get update` here goes through apt_update_wait.
apt_add_repo() {
    local fprs="" no_check=false fpr replaced=false backup=""
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --fingerprint)   fprs="${2:-}"; shift 2 || _apt_usage_die "apt_add_repo: --fingerprint needs a value" ;;
            --fingerprint=*) fprs="${1#*=}"; shift ;;
            --no-fingerprint) no_check=true; shift ;;
            --) shift; break ;;
            *) _apt_usage_die "apt_add_repo: unknown option '$1'" ;;
        esac
    done

    local name="${1:-}" key_url="${2:-}" uris="${3:-}" suites="${4:-}"
    local components="${5:-main}" types="${6:-deb}" arch="${7:-}"

    local keyring="${APT_KEYRING_DIR}/${name}.gpg"
    local sources="${APT_SOURCES_DIR}/${name}.sources"

    [[ -n "$name" && -n "$key_url" && -n "$uris" && -n "$suites" ]] \
        || _apt_usage_die "apt_add_repo: name, key_url, uris and suites are all required"
    _apt_repo_name_ok "$name" \
        || _apt_usage_die "apt_add_repo: '${name}' is not a usable repo name (letters, digits, '.', '_' and '-', starting with a letter or digit)"

    # ── Fingerprint policy: exactly one of the two options ───────────────────
    if [[ -n "$fprs" && "$no_check" == true ]]; then
        _apt_usage_die "apt_add_repo ${name}: --fingerprint and --no-fingerprint are mutually exclusive"
    fi
    if [[ -z "$fprs" && "$no_check" == false ]]; then
        _apt_usage_die "apt_add_repo ${name}: pass --fingerprint <FPR> for the signing key, or --no-fingerprint to trust ${key_url} as served"
    fi
    if [[ -n "$fprs" ]]; then
        # Drop spaces, upper case, and check each entry (the error is logged).
        fprs="$(_apt_fprs_normalise "apt_add_repo ${name}" "$fprs")" || exit 2
    else
        log_warn "APT repo '${name}': --no-fingerprint — trusting the key served at ${key_url} without checking it"
    fi

    # ── Existing keyring: must still pass the check ──────────────────────────
    if [[ -n "$fprs" && -f "$keyring" ]] && ! _apt_installed_keyring_matches "$keyring" "$fprs"; then
        local aside
        aside="${keyring}.untrusted.$(date +%s)"
        log_warn "APT repo '${name}': ${keyring} is not the pinned key (${fprs}); moving it to ${aside}"
        if ! sudo mv -f -- "$keyring" "$aside"; then
            log_error "APT repo '${name}': could not move the unpinned keyring ${keyring} aside; it is still in place and apt still trusts it"
            return 2
        fi
        if declare -f journal_record >/dev/null 2>&1; then
            journal_record modify "$keyring" "moved aside: not the pinned key for ${name}" "moved_to=${aside}"
        fi
    fi

    # ── Already configured correctly? ────────────────────────────────────────
    if [[ -f "$sources" ]]; then
        if grep -qxF "URIs: ${uris}"        "$sources" 2>/dev/null && \
           grep -qxF "Suites: ${suites}"    "$sources" 2>/dev/null && \
           grep -qxF "Signed-By: ${keyring}" "$sources" 2>/dev/null && \
           [[ -f "$keyring" ]]; then
            log_info "APT repo '${name}' already configured for '${suites}'"
            return 0
        fi

        log_warn "APT repo '${name}' exists with different settings — reconfiguring"
        if ! _apt_backup "$sources" "reconfiguring apt repo ${name}"; then
            log_error "APT repo '${name}': could not back up ${sources}; it is untouched"
            return 2
        fi
        replaced=true
        backup="$_APT_BACKUP_DEST"
    fi

    # ── Keyring ──────────────────────────────────────────────────────────────
    if [[ ! -d "$APT_KEYRING_DIR" ]]; then
        if ! sudo mkdir -p "$APT_KEYRING_DIR" || ! sudo chmod 0755 "$APT_KEYRING_DIR"; then
            log_error "APT repo '${name}': could not create ${APT_KEYRING_DIR}"
            return 2
        fi
    fi

    if [[ ! -f "$keyring" ]]; then
        log_info "Fetching signing key for '${name}'"
        # Download to a private temporary file, check it, and only then put it
        # in place: nothing unchecked ever lands in the keyring directory.
        local key_tmp
        key_tmp="$(mktemp)" || return 2
        if ! wget -qO "$key_tmp" "$key_url"; then
            log_error "Failed to fetch the signing key for '${name}' from ${key_url}"
            rm -f "$key_tmp"
            return 2
        fi
        if [[ -n "$fprs" ]] && ! apt_keyring_matches "$key_tmp" "$fprs"; then
            log_error "The key served at ${key_url} is not the pinned key for '${name}'"
            log_error "  expected: ${fprs}"
            log_error "  served:   $(apt_key_fingerprints "$key_tmp" | paste -sd, - || echo 'no readable key')"
            log_error "If the publisher has rotated its key, verify the new one and update the pin."
            rm -f "$key_tmp"
            return 2
        fi
        # Armoured keys are dearmoured; a binary key is installed as it is.
        # Pipeline runs as your user; only the final tee needs elevation.
        local write_ok=true
        if grep -q -- '-----BEGIN PGP PUBLIC KEY BLOCK-----' "$key_tmp"; then
            gpg --dearmor < "$key_tmp" | sudo tee "$keyring" >/dev/null || write_ok=false
        else
            sudo tee "$keyring" < "$key_tmp" >/dev/null || write_ok=false
        fi
        rm -f "$key_tmp"
        # 0644 before anything reads it back: a public key, and apt's own
        # unprivileged _apt user must be able to read it; under a restrictive
        # umask tee would have left it root-only.
        sudo chmod 0644 "$keyring" 2>/dev/null || write_ok=false
        # Check what actually landed, whatever the caller's pipefail setting.
        local landed="${fprs}" copy
        if [[ -z "$landed" ]] && copy="$(_apt_keyring_copy "$keyring")"; then
            # --no-fingerprint: accept whatever primary keys it holds, but it
            # must hold at least one.
            landed="$(apt_key_fingerprints "$copy" | paste -sd, - || true)"
            rm -f "$copy"
        fi
        if [[ "$write_ok" != true || -z "$landed" ]] \
                || ! _apt_installed_keyring_matches "$keyring" "$landed"; then
            log_error "Failed to install the signing key for '${name}' at ${keyring}"
            sudo rm -f "$keyring"
            return 2
        fi

        if declare -f journal_record >/dev/null 2>&1; then
            journal_record create "$keyring" "APT signing key for ${name}" "source=${key_url}" \
                "fingerprint=${fprs:-unchecked}"
        fi
    fi

    # ── Sources file ─────────────────────────────────────────────────────────
    log_info "Configuring APT repo '${name}' for suite '${suites}'"
    {
        printf 'Types: %s\n'      "$types"
        printf 'URIs: %s\n'       "$uris"
        printf 'Suites: %s\n'     "$suites"
        printf 'Components: %s\n' "$components"
        [[ -n "$arch" ]] && printf 'Architectures: %s\n' "$arch"
        printf 'Signed-By: %s\n'  "$keyring"
    } | sudo tee "$sources" >/dev/null \
        || { log_error "Failed to write ${sources}"; return 2; }

    # ── Validate in isolation ────────────────────────────────────────────────
    # Dir::Etc::sourcelist points at this one file and sourceparts is disabled,
    # so apt reads nothing else. Any error is about this repo alone.
    # The output is captured whole (2>&1), so the lists-lock waiting line goes
    # to fd 3, this function's stdout, to be seen while it waits.
    #
    # APT::Update::Error-Mode=any (apt-get update --error-on=any) makes a
    # transient failure — the name does not resolve, the connection is refused
    # — an error. Without it apt exits 0 with only W: lines, and a repository
    # that was never reached would pass. An apt that does not know the option
    # ignores it, as it does any unknown configuration key, so the W: lines
    # are tested for as well (_apt_validation_class).
    #
    # Acquire::AllowInsecureRepositories and …DowngradeToInsecureRepositories
    # are forced off for this one update: a host configured to accept
    # repositories with no signature must not make an unsigned one validate.
    # A command-line -o overrides the host's configuration files.
    log_info "Validating APT repo '${name}'"
    local out vrc=0 class
    { out="$(APT_WAIT_NOTICE_FD=3 apt_update_wait \
            -o Dir::Etc::sourcelist="$sources" \
            -o Dir::Etc::sourceparts="-" \
            -o APT::Get::List-Cleanup="0" \
            -o Acquire::AllowInsecureRepositories="0" \
            -o Acquire::AllowDowngradeToInsecureRepositories="0" \
            -o APT::Update::Error-Mode="any" 2>&1)"; } 3>&1 || vrc=$?
    class="$(_apt_validation_class "$vrc" "$out")"
    if [[ "$class" != ok ]]; then
        local why http
        case "$class" in
            absent)
                why="failed validation"
                log_warn "APT repo '${name}' failed validation for suite '${suites}':" ;;
            locked)
                why="could not be validated (the package lists lock was held for the whole wait)"
                log_warn "APT repo '${name}' was not validated: another apt process held the package lists lock for the whole wait:" ;;
            signature)
                why="could not be validated (its signature could not be verified against the pinned key)"
                log_error "APT repo '${name}': the repository's signature could not be verified against the pinned key (${keyring}${fprs:+, ${fprs}}):" ;;
            unreachable)
                http="$(_apt_validation_http "$out" other)"
                why="could not be validated (the repository could not be reached${http:+, HTTP ${http}})"
                log_error "APT repo '${name}' was not validated: the repository at ${uris} could not be reached${http:+ (the server answered HTTP ${http})}:" ;;
            refused)
                http="$(_apt_validation_http "$out" refused)"
                why="could not be validated (the server refused access, HTTP ${http})"
                log_error "APT repo '${name}' was not validated: the repository at ${uris} could not be reached: the server refused access (HTTP ${http}):" ;;
            insecure)
                why="could not be validated (unsigned repository accepted by host configuration)"
                log_error "APT repo '${name}' was not validated: unsigned repository accepted by host configuration (apt only warned that it has no Release file):" ;;
            *)
                why="could not be validated (apt-get update failed for a reason not recognised)"
                log_error "APT repo '${name}' was not validated: the scoped apt-get update failed (exit ${vrc}) for a reason this function does not recognise:" ;;
        esac
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        case "$class" in
            absent)
                log_warn "Removing '${name}' — it probably does not publish for '${suites}' yet" ;;
            locked)
                log_warn "Removing '${name}': an unvalidated repository is not left configured. Run this again once the other apt process has finished" ;;
            signature)
                log_error "Removing '${name}': an unvalidated repository is not left configured. If the publisher has rotated its key, verify the new one and update the pin" ;;
            *)
                log_error "Removing '${name}': an unvalidated repository is not left configured" ;;
        esac
        # No backup here: this call wrote the file. See the header.
        sudo rm -f -- "$sources" \
            || { log_error "Could not remove ${sources}; it is still in place, unvalidated"; return 2; }
        # A file created and removed in the same call is no change, so it is
        # not journalled. After a reconfigure the earlier version is gone.
        if [[ "$replaced" == true ]] && declare -f journal_record >/dev/null 2>&1; then
            if [[ -n "$backup" ]]; then
                journal_record delete "$sources" \
                    "removed APT repo ${name}: reconfigured for '${suites}', which ${why} (the version before this call is the backup)" \
                    "backup=${backup}"
            else
                journal_record delete "$sources" \
                    "removed APT repo ${name}: reconfigured for '${suites}', which ${why} (backup.sh not loaded, the version before this call was not kept)"
            fi
        fi
        # The refresh makes apt forget what it fetched for the removed file.
        # With the lock never obtained nothing was fetched, and a refresh
        # would only sit through the same wait again.
        if [[ "$class" != locked ]]; then
            _apt_update_quiet
        fi
        # Status 1 is "this repository does not serve the suite", the one a
        # caller may fall back on. Nothing else is that.
        if [[ "$class" == absent ]]; then
            return 1
        fi
        return 2
    fi

    # Valid, and staying: recorded now, whatever the full update below does.
    if declare -f journal_record >/dev/null 2>&1; then
        if [[ "$replaced" == true ]]; then
            journal_record repo "$sources" "reconfigured APT repo ${name} (${uris} ${suites})" \
                ${backup:+"backup=${backup}"}
        else
            journal_record repo "$sources" "added APT repo ${name} (${uris} ${suites})"
        fi
    fi

    if ! apt_update_wait; then
        log_warn "APT repo '${name}' is configured and passed validation, but the full apt-get update after it failed (see above): its packages may not be visible until an update succeeds"
        return 2
    fi

    log_success "APT repo '${name}' configured"
}

# ── apt_remove_repo [--keep-key] <name> ───────────────────────────────────────
# Remove <name>'s sources file and keyring; when the sources file was there,
# refresh the package lists afterwards (through apt_update_wait; quiet and
# never fatal). A keyring left behind without its sources file is removed
# too. Does nothing when neither file exists.
#
#   --keep-key   remove the sources file only and leave the keyring, for a
#                caller that keeps its pinned key while the source is dropped
#
# Each file is backed up first when backup.sh is loaded: the sources file may
# have been edited since it was written, and backup.sh makes no exception for
# a keyring — whatever is removed or replaced is backed up next to the
# original. Each removal is journalled as a delete carrying backup=<path>.
#
# Status: 0 when what was there has been removed, or nothing was there. 1,
# with an error logged, when a file could not be backed up — it is then left
# untouched, and nothing after it is removed — or could not be removed. A
# missing or unusable name, or an unknown option, is fatal (die).
apt_remove_repo() {
    local keep_key=false
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --keep-key) keep_key=true; shift ;;
            --) shift; break ;;
            *) die "apt_remove_repo: unknown option '$1'" ;;
        esac
    done

    local name="${1:-}" f what updated=false
    [[ -n "$name" ]] || die "apt_remove_repo: name is required"
    _apt_repo_name_ok "$name" \
        || die "apt_remove_repo: '${name}' is not a usable repo name (letters, digits, '.', '_' and '-', starting with a letter or digit)"
    local keyring="${APT_KEYRING_DIR}/${name}.gpg"
    local sources="${APT_SOURCES_DIR}/${name}.sources"

    for f in "$sources" "$keyring"; do
        [[ -f "$f" ]] || continue
        if [[ "$f" == "$keyring" ]]; then
            [[ "$keep_key" == false ]] || continue
            what="removed the signing key of APT repo ${name}"
        else
            what="removed APT repo ${name}"
            updated=true
        fi
        log_info "Removing ${f}"
        _apt_backup "$f" "removing apt repo ${name}" \
            || { log_error "Could not back up ${f}; it is untouched"; return 1; }
        sudo rm -f -- "$f" || { log_error "Could not remove ${f}"; return 1; }
        if declare -f journal_record >/dev/null 2>&1; then
            journal_record delete "$f" "$what" ${_APT_BACKUP_DEST:+"backup=${_APT_BACKUP_DEST}"}
        fi
    done
    if [[ "$updated" == true ]]; then
        _apt_update_quiet
    fi
}

# ── apt_pkg_state <package> ──────────────────────────────────────────────────
# Print dpkg's status abbreviation and version for <package> ("ii 1.7.1-3",
# "rc 1.7.1-3", "un <none>"), or nothing when dpkg does not know it. Never
# fails.
#
# dpkg lists a package as <name> or as <name>:<arch> depending on whether it
# is multi-arch, whichever form was asked for. The name is matched with or
# without the qualifier on either side; two different architectures do not
# match.
apt_pkg_state() {
    { dpkg -l "$1" 2>/dev/null || true; } | awk -v p="$1" '
        BEGIN { pn = p; pa = ""; i = index(p, ":")
                if (i) { pn = substr(p, 1, i - 1); pa = substr(p, i + 1) } }
        {
            n = $2; a = ""; i = index($2, ":")
            if (i) { n = substr($2, 1, i - 1); a = substr($2, i + 1) }
            if (n == pn && (pa == "" || a == "" || pa == a)) { print $1, $3; exit }
        }'
}

# _apt_change_parse [--reason <text>] [apt-get option... --] <package>...
# The argument convention shared by apt_change and its wrappers (described at
# apt_change), parsed into _APT_REASON, _APT_OPTS, _APT_PKGS and _APT_SEP
# (true when the `--` form was used). Returns 2, with an error logged, for
# arguments it cannot place.
_APT_REASON=""
_APT_OPTS=()
_APT_PKGS=()
_APT_SEP=false
_apt_change_parse() {
    local a
    _APT_REASON=""
    _APT_OPTS=()
    _APT_PKGS=()
    _APT_SEP=false
    for a in "$@"; do
        if [[ "$a" == -- ]]; then
            _APT_SEP=true
            break
        fi
    done

    # No `--`: only a leading --reason is taken, and the rest are packages.
    if [[ "$_APT_SEP" == false ]]; then
        case "${1:-}" in
            --reason)
                [[ $# -ge 2 ]] || { log_error "apt_change: --reason needs a value"; return 2; }
                _APT_REASON="$2"
                shift 2 ;;
            --reason=*)
                _APT_REASON="${1#*=}"
                shift ;;
        esac
        _APT_PKGS=("$@")
        return 0
    fi

    # With a `--`, every word before it is an option, the value of --reason,
    # or the separate value of one of the four apt-get options known to take
    # one. Anything else there is a package in the wrong place. There is
    # always a $2 here: the `--` is still ahead.
    while [[ "$1" != -- ]]; do
        case "$1" in
            --reason)
                [[ "$2" != -- ]] || { log_error "apt_change: --reason needs a value"; return 2; }
                _APT_REASON="$2"
                shift 2 ;;
            --reason=*)
                _APT_REASON="${1#*=}"
                shift ;;
            -t|-o|-c|--target-release)
                [[ "$2" != -- ]] || { log_error "apt_change: $1 needs a value"; return 2; }
                _APT_OPTS+=("$1" "$2")
                shift 2 ;;
            -*)
                _APT_OPTS+=("$1")
                shift ;;
            *)
                log_error "apt_change: '$1' is before the -- but is not an option; packages go after the --, and an option's value is attached (--option=value) unless the option is -t, -o, -c or --target-release"
                return 2 ;;
        esac
    done
    shift
    _APT_PKGS=("$@")
}

# _apt_tracked_name <word> — print the package name a word on apt-get's
# command line is tracked under, or nothing when it is not a plain package
# name and so is passed to apt-get untracked: an option (the form without
# `--`), a local file (a path, or anything ending .deb), a glob, and apt's
# <pkg>- "remove this one" suffix. <name>=<version> and <name>/<release> are
# tracked as <name>; <name>:<arch> as it is.
_apt_tracked_name() {
    local p="$1" name re='^[a-z0-9][a-z0-9+.-]*(:[a-z0-9-]+)?$'
    case "$p" in
        -*|/*|./*|../*|*.deb|*[*?[]*) return 0 ;;
    esac
    name="${p%%[=/]*}"
    [[ "$name" =~ $re && "$name" != *- ]] || return 0
    printf '%s\n' "$name"
}

# ── apt_change <install|remove|purge> [--reason <text>] ──────────────────────
#               [apt-get option... --] <package>...
#
# One non-interactive apt-get run for the packages, waiting for the dpkg lock
# (see the header). The lower-level function: it RETURNS apt-get's exit status
# and the caller decides whether that is fatal. apt_install, apt_remove and
# apt_purge are the same call with `|| die`. Returns 2, having run nothing,
# for an unknown action or arguments it cannot place; 0 with no packages.
#
# Arguments:
#   --reason <text>   what the journal records as the reason (also
#                     --reason=<text>). Defaults to "apt-get <action>". With
#                     no `--` it must be the first argument; with one it may
#                     be anywhere before it. A value of `--` is refused.
#   options -- pkgs   when the arguments contain a `--`, everything before it
#                     is passed to apt-get as options, verbatim, and
#                     everything after it is a package:
#                         apt_change install --no-install-recommends -- foo bar
#                         apt_change install --reason "pinned for the old kernel" \
#                             --allow-downgrades -- foo=1.2-3
#                     apt-get is run as `… <options> -- <packages>`, so a
#                     package can never be read as an option, whatever it
#                     starts with. Every word before the `--` must start with
#                     `-`. The exceptions are the separate values of -t, -o,
#                     -c and --target-release (`-t <release>`, `-o Key=Val`),
#                     which are taken with their option; any other option
#                     that has a value needs it attached (--option=value). A
#                     bare word anywhere else before the `--` is a misplaced
#                     package and is refused.
#   pkgs              with no `--`, every argument is a package, as before
#                     v1.6.0 (a leading --reason is still taken), and apt-get
#                     is run without a `--`. An argument starting with `-` is
#                     then still handed to apt-get in place, but an option
#                     that takes a separate value (-t <release>) needs the
#                     `--` form: its value would be tracked as a package.
#
# apt-get runs through `sudo env DEBIAN_FRONTEND=noninteractive`: -y does not
# answer debconf or conffile prompts, and `sudo VAR=… cmd` depends on the
# sudoers env_reset/SETENV policy and is rejected outright under some
# configurations; going through env(1) is unambiguous everywhere. Run
# apt_update_wait first, after the last change to the apt sources.
#
# The journal records only what really changed. Each package's dpkg state
# (apt_pkg_state: status and version) is read before and after; a package
# whose state changed gets one record of its own — `install` or `remove`, with
# the reason and both states in the detail and as before=/after=/operation=
# fields — and a package whose state did not change gets none, so a run that
# changes nothing journals nothing. That holds when apt-get fails too: what it
# changed before failing is recorded.
#
# An install that leaves a package not installed ("ii") is warned about and
# not recorded, even though apt-get reported success: apt-get exits 0 for a
# name that another installed package Provides, and dpkg never lists that
# name. It is a warning, not an error — the caller knows whether a provided
# package is good enough.
#
# A package may be given as <name>=<version> or <name>/<release>; the state is
# looked up, and the record written, under <name>. A word that is not a plain
# package name — a local .deb (a path starting /, ./ or ../, or anything
# ending .deb), a glob, apt's <pkg>- suffix — is passed to apt-get but not
# tracked: no record and no warning, since there is no one name to look up.
# A name ending in + is tracked when dpkg knows it (g++), without the warning
# when it does not (apt's <pkg>+ suffix).
apt_change() {
    local action="${1:-}" verb reason p name after i rc=0
    [[ $# -gt 0 ]] && shift
    case "$action" in
        install) verb="Installing" ;;
        remove)  verb="Removing" ;;
        purge)   verb="Purging" ;;
        *)
            log_error "apt_change: unknown action '${action}' (expected install, remove or purge)"
            return 2 ;;
    esac
    _apt_change_parse "$@" || return 2
    [[ ${#_APT_PKGS[@]} -gt 0 ]] || return 0
    _apt_lock_settings

    reason="${_APT_REASON:-apt-get ${action}}"
    local -a opts=(${_APT_OPTS[@]+"${_APT_OPTS[@]}"}) pkgs=("${_APT_PKGS[@]}")
    local -a names=() before=() sep=()
    # The caller's `--` goes on to apt-get: nothing after it is an option.
    if [[ "$_APT_SEP" == true ]]; then
        sep=(--)
    fi
    for p in "${pkgs[@]}"; do
        name="$(_apt_tracked_name "$p")"
        names+=("$name")
        if [[ -n "$name" ]]; then
            before+=("$(apt_pkg_state "$name")")
        else
            before+=("")
        fi
    done

    log_info "${verb}: ${pkgs[*]}"
    # Three literal lines, so each action sits next to its lock timeout.
    case "$action" in
        install)
            sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y -o DPkg::Lock::Timeout="${APT_LOCK_WAIT}" ${opts[@]+"${opts[@]}"} ${sep[@]+"${sep[@]}"} "${pkgs[@]}" || rc=$? ;;
        remove)
            sudo env DEBIAN_FRONTEND=noninteractive apt-get remove -y -o DPkg::Lock::Timeout="${APT_LOCK_WAIT}" ${opts[@]+"${opts[@]}"} ${sep[@]+"${sep[@]}"} "${pkgs[@]}" || rc=$? ;;
        purge)
            sudo env DEBIAN_FRONTEND=noninteractive apt-get purge -y -o DPkg::Lock::Timeout="${APT_LOCK_WAIT}" ${opts[@]+"${opts[@]}"} ${sep[@]+"${sep[@]}"} "${pkgs[@]}" || rc=$? ;;
    esac

    for i in "${!pkgs[@]}"; do
        name="${names[$i]}"
        [[ -n "$name" ]] || continue
        after="$(apt_pkg_state "$name")"
        if [[ "$action" == install && "$after" != "ii "* ]]; then
            # <pkg>+ is apt's "install this one" suffix unless a package has
            # that very name; dpkg not knowing it is then no surprise.
            [[ "$name" != *+ ]] || continue
            log_warn "apt-get did not install '${name}' (dpkg state before: ${before[$i]:-not known}, after: ${after:-not known}) — not recorded as installed. Another package may provide it."
            continue
        fi
        [[ "$after" != "${before[$i]}" ]] || continue
        if declare -f journal_record >/dev/null 2>&1; then
            if [[ "$action" == install ]]; then
                journal_record install "$name" \
                    "${reason} (dpkg: ${before[$i]:-not known} -> ${after})" \
                    "operation=install" "before=${before[$i]:-not known}" "after=${after}"
            else
                journal_record remove "$name" \
                    "${action}: ${reason} (dpkg: ${before[$i]:-not known} -> ${after:-not known})" \
                    "operation=${action}" "before=${before[$i]:-not known}" "after=${after:-not known}"
            fi
        fi
    done
    return "$rc"
}

# ── apt_install [--reason <text>] [apt-get option... --] <package>... ────────
# apt_change install, fatal on failure: dies if apt-get fails. The arguments,
# the journalling and the provided-package warning are apt_change's; plain
# `apt_install pkg…` works as it always has. With no packages it does nothing.
apt_install() {
    apt_change install "$@" || die "Failed to install: ${_APT_PKGS[*]:-$*}"
}

# ── apt_remove [--reason <text>] [apt-get option... --] <package>... ─────────
# apt_change remove, fatal on failure. Configuration files stay (dpkg "rc").
# Use apt_change directly where a failed removal should not stop the run.
apt_remove() {
    apt_change remove "$@" || die "Failed to remove: ${_APT_PKGS[*]:-$*}"
}

# ── apt_purge [--reason <text>] [apt-get option... --] <package>... ──────────
# apt_change purge, fatal on failure. Configuration files go too.
apt_purge() {
    apt_change purge "$@" || die "Failed to purge: ${_APT_PKGS[*]:-$*}"
}

# ── apt_install_list <path> ───────────────────────────────────────────────────
# Install from a package manifest: one package per line, # comments and blank
# lines ignored. Package sets that need no configuration are data, not code —
# this is what reads them. One apt-get run for the whole list, through
# apt_change: one journal record per package it really installed or upgraded,
# with the list's name as the reason. Dies if apt-get fails.
#
# A manifest is data, and may come from somewhere less trusted than the
# script, so each line is held to exactly one package. After the comment
# (from the first #) and the whitespace at either end are dropped, a line is:
#
#     <name>[:<arch>][=<version> | /<release>]
#
#   <name>     a Debian package name: a lower-case letter or digit, then
#              lower-case letters, digits, '+', '.' and '-'; not ending in
#              '-', which is apt's "remove this one" suffix
#   <arch>     lower-case letters, digits and '-'
#   <version>  letters, digits and '.', '+', '~', ':', '-'
#   <release>  letters, digits and '.', '_', '+', '-'
#
# Nothing else is accepted: no glob (*, ?, [), no path, no option, and no
# whitespace inside the line — two names on one line are an error, not one
# name. A line that does not fit kills the run, naming its number and the
# line as written. The packages are passed to apt-get after a `--`, so none
# of them can be read as an option.
apt_install_list() {
    local list="$1" pkgs=()
    [[ -r "$list" ]] || die "Package list not found: ${list}"

    local line raw name n=0
    local re='^[a-z0-9][a-z0-9+.-]*(:[a-z0-9-]+)?(=[A-Za-z0-9.+~:-]+|/[A-Za-z0-9._+-]+)?$'
    while IFS= read -r raw || [[ -n "$raw" ]]; do
        n=$(( n + 1 ))
        line="${raw%%#*}"
        # Trim the ends only; whitespace left inside is an error below.
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -n "$line" ]] || continue
        name="${line%%[:=/]*}"
        [[ "$line" =~ $re && "$name" != *- ]] \
            || die "Package list ${list}: line ${n} is not one package name: '${raw}'"
        pkgs+=("$line")
    done < "$list"

    [[ ${#pkgs[@]} -gt 0 ]] || { log_warn "No packages listed in ${list}"; return 0; }

    log_info "Installing package list $(basename -- "$list") (${#pkgs[@]} packages)"
    apt_change install --reason "package list $(basename -- "$list")" -- "${pkgs[@]}" \
        || die "Failed to install package list: ${list}"
}
