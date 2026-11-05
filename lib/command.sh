#!/usr/bin/env bash
# command.sh — whether the commands a script needs are installed, every
# missing one named at once.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Two lookups, for the two ways a script runs a command:
#
#   Without --sbin: the path a bare-name call from this shell would run. A
#   regular executable file of that name in an absolute PATH entry, via
#   `type -P`; functions, aliases and builtins do not count, so a test's
#   stub function cannot satisfy a preflight, and a relative PATH entry
#   ('.', an empty component) does not count either.
#
#   With --sbin: the path sudo's secure_path resolves, for a command the
#   script runs through sudo. The caller's PATH is not consulted at all: a
#   stub in ~/.local/bin ahead of /usr/sbin in PATH is what this shell
#   would run, not what root runs, and a path printed from PATH and then
#   run under sudo would bypass secure_path. The list searched is
#   _COMMAND_SBIN_DIRS, sudo's secure_path in its order (verified with
#   `sudo -n printenv PATH` on Ubuntu 26.04, x86_64 and Pi). Do not use
#   --sbin for a command the script calls by bare name without sudo: a
#   normal user's PATH can omit the sbin directories (Debian's non-root
#   default does), so the check would pass and the call fail.
#
# Mechanism only: which commands a script needs, which package provides each
# and what to tell the operator are the caller's. Whether a package is
# installed is apt_pkg_state (apt.sh), not this file.
#
# Lifted from cell-pi-setup, rbp-encrypt and rbp-img-bld (require_tools),
# open-wifi-scanner (require_commands) and wifi-cap-test (_find_bin,
# check_deps) (FA-fleet-025).
#
# Depends on: log.sh

# include: log.sh
[[ -n "${_LIB_COMMAND_SOURCED:-}" ]] && return 0
_LIB_COMMAND_SOURCED=1

# The directories --sbin searches, space-separated, in sudo's secure_path
# order. Assigned, not inherited from the environment, so a built script
# cannot be pointed elsewhere by its caller; a test sets it after sourcing
# to point at a temp tree. An entry that is not absolute is ignored; empty,
# --sbin finds nothing.
_COMMAND_SBIN_DIRS="/usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin"

# ── command_path [--sbin] <name> ──────────────────────────────────────────────
# Print the absolute path of the executable <name> resolves to: from PATH,
# or with --sbin from the secure_path directories only. Return 1, printing
# nothing, when there is none. A name that is empty or contains '/' is
# refused (1): this looks names up, it does not test paths.
command_path() {
    local sbin=false name found="" dir
    local -a dirs=()
    if [[ "${1:-}" == --sbin ]]; then sbin=true; shift; fi
    name="${1:-}"
    [[ -n "$name" && "$name" != */* ]] || return 1
    if [[ "$sbin" == false ]]; then
        # A relative PATH entry that shadows an absolute one makes the command
        # report as missing: type -P returns the relative hit, the /* guard
        # rejects it, and that is accepted (such a PATH is the caller's bug).
        found="$(type -P -- "$name" 2>/dev/null)" || found=""
        [[ "$found" == /* && -f "$found" && -x "$found" ]] || return 1
        printf '%s\n' "$found"
        return 0
    fi
    # The list is split on spaces whatever IFS the caller runs under.
    IFS=' ' read -r -a dirs <<< "$_COMMAND_SBIN_DIRS"
    for dir in ${dirs[@]+"${dirs[@]}"}; do
        [[ "$dir" == /* ]] || continue
        if [[ -f "${dir}/${name}" && -x "${dir}/${name}" ]]; then
            printf '%s\n' "${dir}/${name}"
            return 0
        fi
    done
    return 1
}

# ── commands_present [--sbin] [--] <name>... ──────────────────────────────────
# True when every <name> is found (command_path). Otherwise print the missing
# names on one line, space-separated, in the order given, and return 1. Logs
# nothing, so it is safe inside $(...); test it, since a bare assignment
# exits under set -e:
#   if ! missing="$(commands_present a b c)"; then ...
# `--` ends the options, so a name may start with '-'. No names: true.
commands_present() {
    local sbin=false name missing=""
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sbin) sbin=true; shift ;;
            --)     shift; break ;;
            *)      break ;;
        esac
    done
    for name in "$@"; do
        if [[ "$sbin" == true ]]; then
            command_path --sbin "$name" >/dev/null || missing+="${missing:+ }${name}"
        else
            command_path "$name" >/dev/null || missing+="${missing:+ }${name}"
        fi
    done
    if [[ -z "$missing" ]]; then return 0; fi
    printf '%s\n' "$missing"
    return 1
}

# ── require_commands [--sbin] [--hint <text>] [--] <name>... ──────────────────
# Return when every <name> is found. Otherwise log
# "Missing required commands: <every missing name>", then <text> on a line of
# its own when given (the caller's install advice), and exit 1.
require_commands() {
    local sbin=false hint="" missing
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --sbin) sbin=true; shift ;;
            --hint) [[ $# -ge 2 ]] || die "require_commands: --hint needs text"
                    hint="$2"; shift 2 ;;
            --)     shift; break ;;
            -*)     die "require_commands: unknown option $1" ;;
            *)      break ;;
        esac
    done
    if [[ "$sbin" == true ]]; then
        missing="$(commands_present --sbin -- "$@")" && return 0
    else
        missing="$(commands_present -- "$@")" && return 0
    fi
    log_error "Missing required commands: ${missing}"
    [[ -z "$hint" ]] || log_error "$hint"
    exit 1
}
