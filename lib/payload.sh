#!/usr/bin/env bash
# payload.sh — a built payload checked before it is used, and rendered under a
# settings header.
# Part of the bash-includes library. Source this file; do not execute it.
#
# A script that embeds a bld-built payload (CONVENTIONS §9: an SSH payload, a
# root-run service hook, a client helper) has two things to get right every
# time it hands one out, and the two VPN builders each got one of them right
# and the other wrong (FA-fleet-023, FA-fleet-024):
#
#   payload_check [--last <line>] <artefact> <source> [<dependency>...]
#
#     Is <artefact> a whole, current, built copy of <source>? Content first,
#     in both modes (the built script's embedded copy included): bld writes
#     build/<x>.sh in place and leaves it there when its own `bash -n`
#     fails, and a payload cut at a line boundary still parses — installed
#     as a hook, it exits 0 having done nothing, and the unit starts with no
#     firewall. So the artefact must exist, must not be empty, must parse,
#     must not still hold the development bootstrap (bld replaces the
#     marker block with the library inlined), and with --last its last
#     non-blank line must be exactly <line> (`main` for a hook whose last
#     line is its dispatch; leave it out for a payload whose last line is
#     not a dispatch line, or the caller is bound to whatever the source
#     happens to end in). Then, in a development checkout only, the
#     modification times: the artefact must be newer than <source>, than
#     every <dependency> (the caller's lib/*.sh and LIB_VERSION, say), and
#     than every *.sh in the directory this file was sourced from
#     (_PAYLOAD_LIBDIR), so a library checkout that moved under an
#     unchanged LIB_VERSION is seen too. A checkout is one where
#     _bootstrap_lib is defined: that is the bootstrap name README
#     documents and every marker-block source defines, and bld removes it,
#     so its presence is the build's own signal. The bootstrap-still-present
#     test matches bld's marker line exactly (`grep -x`), or a line that
#     defines _bootstrap_lib(); not the bare name, which a payload that
#     includes this very file carries in its code. Paths are the caller's,
#     absolute; the library knows neither SCRIPT_DIR nor LIB_VERSION. Every
#     refusal is logged with log_error and returns 1; nothing exits, so the
#     caller writes `payload_check … || exit 1` (or `|| die`), and the
#     message says what to do: rebuild in a checkout, reinstall the built
#     script otherwise.
#
#   payload_render [--shebang <line>] [--readonly] [--comment <text>]... [--]
#                  <payload> [NAME | NAME=value]...
#
#     The payload as installed, on stdout: line 1, comment lines, the
#     settings as `[readonly ]NAME=<value>` lines, then the payload from its
#     second line on. Which settings, what the comments say and where the
#     text goes are the caller's; the rendering is what a header pasted
#     into a root-run script has to get right, and it is the same in all
#     four places the builders write one:
#       - Line 1 is <line> with --shebang (`#!/bin/bash`: a hook pins PATH
#         only once it runs, so the interpreter must not be looked up
#         through systemd's PATH), otherwise the payload's own first line.
#         Either way the payload's first line must start with `#!`, since it
#         is the line dropped; anything else is refused rather than lost
#         silently. A --shebang value must start with `#!` and carry no
#         control character for the same reason: it is the first line of a
#         script root runs.
#       - A comment is printed as `# <text>` with every control character
#         removed under the C locale: a newline in a value that reaches a
#         comment (SCRIPT_VERSION from the environment in a checkout) would
#         otherwise end the comment and start a line the hook executes.
#       - A setting is printed with printf %q under the C locale, so a path
#         with a space or an '&' survives intact and a multibyte value
#         escapes bytewise ($'\303\251'), the same on every host. A bare
#         NAME takes the variable's value and must be set (an empty value is
#         allowed: a list setting may be empty); NAME=value takes the
#         literal (a normalised list, an effective value, a flag like
#         HELPER_PARAMS=1). NAME must be a bash identifier, since it is
#         pasted as code; and it must not start with `_payload_`, the prefix
#         of this function's own locals, which ${!NAME} would otherwise read
#         instead of the caller's variable. Everything is checked before
#         anything is printed.
#     Each step is `|| return 1`, and a refusal is logged with log_error: a
#     caller writes `payload_render … > "$tmp" || die …` and installs the
#     result with install_atomic (file.sh).
#
# Depends on: log.sh.

# include: log.sh
[[ -n "${_LIB_PAYLOAD_SOURCED:-}" ]] && return 0
_LIB_PAYLOAD_SOURCED=1

# The directory this module was sourced from, for the checkout-only
# modification-time comparison in payload_check: in a checkout that is the
# library's lib/, whose every *.sh the artefact must be newer than. In the
# built script it is the script's own directory and is never used, since
# there is no _bootstrap_lib. A bare name (sourced from the current
# directory) has no slash to cut at. Resolved to an absolute path (two
# builtins, nothing on PATH).
_PAYLOAD_LIBDIR="${BASH_SOURCE[0]%/*}"
[[ "$_PAYLOAD_LIBDIR" != "${BASH_SOURCE[0]}" ]] || _PAYLOAD_LIBDIR="."
# Absolute, so a `cd` in the entry point after the library is sourced (a
# relative BASH_INCLUDES_DIR) does not silently empty the comparison.
_PAYLOAD_LIBDIR="$(cd -- "$_PAYLOAD_LIBDIR" 2>/dev/null && pwd -P)" || _PAYLOAD_LIBDIR="${BASH_SOURCE[0]%/*}"

# bld's opening marker, as an exact line. Held in a variable rather than
# written as a comment line of its own, so this file can itself be built
# into a payload that payload_check then reads.
_PAYLOAD_MARK='# >>> bash-includes >>>'
_PAYLOAD_ADVICE='Run ./build.sh again (a checkout) or reinstall the built script. Nothing was written or changed.'

# ── payload_check [--last <line>] <artefact> <source> [<dependency>...] ───────
# The checks described in the header. 0 when the artefact passes every one;
# 1, after a log_error naming the first that failed, otherwise.
payload_check() {
    local last="" artefact src f tail_line
    while [[ $# -gt 0 && "$1" == --* ]]; do
        case "$1" in
            --last)
                [[ $# -ge 2 ]] || { log_error "payload_check: --last needs a value"; return 1; }
                last="$2"; shift 2 ;;
            --) shift; break ;;
            *) log_error "payload_check: unknown option '$1'"; return 1 ;;
        esac
    done
    if [[ $# -lt 2 ]]; then
        log_error "payload_check: usage: payload_check [--last <line>] <artefact> <source> [<dependency>...]"
        return 1
    fi
    artefact="$1"; src="$2"; shift 2

    # Content, in both modes.
    if [[ ! -e "$artefact" ]]; then
        log_error "${artefact} is missing: it has not been built from ${src}, or the built script's embedded copy was not extracted. ${_PAYLOAD_ADVICE}"
        return 1
    fi
    if [[ ! -f "$artefact" || ! -s "$artefact" ]]; then
        log_error "${artefact} is empty: it is not a built copy of ${src}. ${_PAYLOAD_ADVICE}"
        return 1
    fi
    if [[ -n "$last" ]]; then
        tail_line="$(grep -v '^[[:space:]]*$' -- "$artefact" | tail -n 1)" || tail_line=""
        if [[ "$tail_line" != "$last" ]]; then
            log_error "${artefact} does not end with the line '${last}': it is cut short or not a built copy of ${src}. ${_PAYLOAD_ADVICE}"
            return 1
        fi
    fi
    if ! bash -n -- "$artefact" 2>/dev/null; then
        log_error "${artefact} does not parse (bash -n): it is cut short or not a built copy of ${src}. ${_PAYLOAD_ADVICE}"
        return 1
    fi
    if grep -qxF -e "$_PAYLOAD_MARK" -- "$artefact" || grep -q -e '^_bootstrap_lib()' -- "$artefact"; then
        log_error "${artefact} still holds the development bootstrap: it is not a built copy of ${src}. ${_PAYLOAD_ADVICE}"
        return 1
    fi

    # Modification times, in a checkout only.
    declare -f _bootstrap_lib >/dev/null 2>&1 || return 0
    for f in "$src" "$@" "${_PAYLOAD_LIBDIR}"/*.sh; do
        if [[ -e "$f" && "$f" -nt "$artefact" ]]; then
            log_error "${artefact} is older than ${f}: it was built before the last change to its source. ${_PAYLOAD_ADVICE}"
            return 1
        fi
    done
    return 0
}

# _payload_name_ok <name> — a bash identifier, judged under the C locale (a
# bracket range in another locale matches more than ASCII), that does not
# start with this module's own local prefix.
_payload_name_ok() {
    local LC_ALL=C
    [[ "$1" =~ ^[A-Za-z_][A-Za-z0-9_]*$ && "$1" != _payload_* ]]
}

# _payload_comment <text> — one comment line, control characters removed.
_payload_comment() {
    local LC_ALL=C
    printf '# %s\n' "${1//[[:cntrl:]]/}"
}

# ── payload_render [options] [--] <payload> [NAME | NAME=value]... ────────────
# The rendering described in the header. Every local here is _payload_-
# prefixed and no caller may pass such a NAME: ${!NAME} is evaluated in
# this scope. No `local LC_ALL` either, for the same reason (a caller's
# LC_ALL setting would be read as C); the locale is set per command.
payload_render() {
    local _payload_shebang="" _payload_has_shebang="" _payload_ro="" _payload_file _payload_line1
    local _payload_item _payload_name _payload_value _payload_i
    local -a _payload_comments=() _payload_names=() _payload_values=()
    while [[ $# -gt 0 && "$1" == --* ]]; do
        case "$1" in
            --shebang)
                [[ $# -ge 2 ]] || { log_error "payload_render: --shebang needs a value"; return 1; }
                _payload_shebang="$2"; _payload_has_shebang=1; shift 2 ;;
            --readonly) _payload_ro="readonly "; shift ;;
            --comment)
                [[ $# -ge 2 ]] || { log_error "payload_render: --comment needs a value"; return 1; }
                _payload_comments+=("$2"); shift 2 ;;
            --) shift; break ;;
            *) log_error "payload_render: unknown option '$1'"; return 1 ;;
        esac
    done
    if [[ $# -lt 1 ]]; then
        log_error "payload_render: usage: payload_render [--shebang <line>] [--readonly] [--comment <text>]... [--] <payload> [NAME | NAME=value]..."
        return 1
    fi
    _payload_file="$1"; shift

    # Everything checked before anything is printed.
    # Presence, not emptiness: an empty value from an unset variable must
    # not quietly hand a root-run hook the payload's own line 1.
    if [[ -n "$_payload_has_shebang" ]] \
       && [[ "$_payload_shebang" != '#!'* || "$_payload_shebang" == *[[:cntrl:]]* ]]; then
        log_error "payload_render: the --shebang line must start with #! and carry no control character"
        return 1
    fi
    if ! _payload_line1="$(head -n 1 -- "$_payload_file" 2>/dev/null)"; then
        log_error "payload_render: cannot read ${_payload_file}"
        return 1
    fi
    if [[ "$_payload_line1" != '#!'* ]]; then
        log_error "payload_render: ${_payload_file} does not start with a shebang line; not rendering it (its first line would be dropped)"
        return 1
    fi
    for _payload_item in "$@"; do
        if [[ "$_payload_item" == *=* ]]; then
            _payload_name="${_payload_item%%=*}"
            _payload_value="${_payload_item#*=}"
        else
            _payload_name="$_payload_item"
            if ! _payload_name_ok "$_payload_name"; then
                log_error "payload_render: '$(log_printable "$_payload_name")' is not a setting name (a bash identifier not starting with _payload_)"
                return 1
            fi
            if [[ ! -v "$_payload_name" ]]; then
                log_error "payload_render: ${_payload_name} is not set"
                return 1
            fi
            _payload_value="${!_payload_name}"
        fi
        if ! _payload_name_ok "$_payload_name"; then
            log_error "payload_render: '$(log_printable "$_payload_name")' is not a setting name (a bash identifier not starting with _payload_)"
            return 1
        fi
        _payload_names+=("$_payload_name")
        _payload_values+=("$_payload_value")
    done

    if [[ -n "$_payload_has_shebang" ]]; then
        printf '%s\n' "$_payload_shebang" || return 1
    else
        printf '%s\n' "$_payload_line1" || return 1
    fi
    for _payload_item in "${_payload_comments[@]}"; do
        _payload_comment "$_payload_item" || return 1
    done
    for (( _payload_i = 0; _payload_i < ${#_payload_names[@]}; _payload_i++ )); do
        LC_ALL=C printf '%s%s=%q\n' "$_payload_ro" "${_payload_names[_payload_i]}" "${_payload_values[_payload_i]}" \
            || return 1
    done
    tail -n +2 -- "$_payload_file" || return 1
}
