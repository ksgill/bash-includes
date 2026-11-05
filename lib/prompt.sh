#!/usr/bin/env bash
# prompt.sh — ask the operator a yes/no question, or answer it for an
# unattended run.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Mechanism only. Which questions a script asks, what an unattended run
# answers, and what a "no" leads to are the caller's: confirm returns a
# status and never exits on an answer, so `confirm ... || die "Aborted"` is a
# line in the caller.
#
# Lifted from git-bootstrap, rbp-img-bld, rover-bld and wifi-cap-test, which
# carried four copies that had diverged in their default, their EOF handling
# and the global they read (FA-fleet-025).
#
# Depends on: log.sh

# include: log.sh
[[ -n "${_LIB_PROMPT_SOURCED:-}" ]] && return 0
_LIB_PROMPT_SOURCED=1

# _prompt_tty — true when stdin is a terminal. A function so a test can stand
# in for one; nothing else should redefine it.
_prompt_tty() { [[ -t 0 ]]; }

# _prompt_drain — discard whatever was already typed when stdin is a
# terminal, complete lines and a partial one alike, so a `y` typed before
# the question was printed does not answer it. On anything but a terminal
# nothing is done: a test that stands in for the terminal (_prompt_tty)
# feeds the answer from a here-string that this would otherwise consume.
_prompt_drain() {
    [[ -t 0 ]] || return 0
    # -n puts the terminal in non-canonical mode for the read, so a partial
    # line typed ahead (a `y` with no Enter yet) is drained with the complete
    # ones; the loop ends on the first read that times out with nothing.
    while read -r -s -t 0.02 -n 4096 _; do :; done
    return 0
}

# ── confirm --default yes|no [--assume yes|no|''] [--] <question> ─────────────
# Ask <question> on the terminal, suffixed " [Y/n] " or " [y/N] " after the
# default, and wait for an answer.
#
#   0  yes: y or yes in any case, or an empty reply when the default is yes
#   1  no:  n or no in any case, or an empty reply when the default is no
#   2  no answer: stdin is not a terminal (nothing is read from it), or it
#      reached end of file (Ctrl-D) before a full line
#
# --default is required: the answer an empty reply (Enter) stands for. It
# applies to an empty reply only, never to end of file or a missing terminal.
# Anything else typed is not an answer; the question is asked again.
#
# --assume answers without asking, whatever stdin is, and logs the question
# and the answer with log_info so a transcript shows what an unattended run
# agreed to. '' (the default) means ask. A caller keeps its own flag and
# passes the answer it implies:
#   ASSUME=""   ...   --yes) ASSUME=yes ;;   ...   confirm --assume "$ASSUME" ...
#
# The prompt goes to stderr, written before the read (not by `read -p`,
# which shows its prompt only when stdin is a terminal, so a test that
# stands in for one would see no prompt). Lines typed before the prompt are
# discarded first (_prompt_drain): an answer is what is typed to the
# question, not ahead of it. The question is passed through log_printable,
# in the prompt and in the assumed line, so text read from a device or a
# tool's output cannot reshape the line. A question that starts with '-'
# needs `--` before it. A bad option or a missing question is a bug in the
# caller, and dies.
confirm() {
    local default="" assume="" question reply suffix
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --default) [[ $# -ge 2 ]] || die "confirm: --default needs yes or no"
                       default="$2"; shift 2 ;;
            --assume)  [[ $# -ge 2 ]] || die "confirm: --assume needs yes, no or ''"
                       assume="$2"; shift 2 ;;
            --)        shift; break ;;
            -*)        die "confirm: unknown option $1" ;;
            *)         break ;;
        esac
    done
    case "$default" in
        yes|no) ;;
        *) die "confirm: --default must be yes or no, not '${default}'" ;;
    esac
    case "$assume" in
        yes|no|'') ;;
        *) die "confirm: --assume must be yes, no or empty, not '${assume}'" ;;
    esac
    question="$*"
    [[ -n "$question" ]] || die "confirm: no question given"
    question="$(log_printable "$question")"

    if [[ -n "$assume" ]]; then
        log_info "${question} ${assume} (assumed)"
        if [[ "$assume" == yes ]]; then return 0; fi
        return 1
    fi

    _prompt_tty || return 2
    _prompt_drain
    if [[ "$default" == yes ]]; then suffix="[Y/n]"; else suffix="[y/N]"; fi
    while :; do
        reply=""
        printf '%s %s ' "$question" "$suffix" >&2
        if ! read -r reply; then
            # End the prompt's line, so the caller's next message starts its own.
            printf '\n' >&2
            return 2
        fi
        case "$reply" in
            '')                if [[ "$default" == yes ]]; then return 0; fi
                               return 1 ;;
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo])     return 1 ;;
            *)                 printf 'Please answer yes or no.\n' >&2 ;;
        esac
    done
}
