#!/usr/bin/env bash
# cleanup.sh — a stack of teardown handlers run on exit.
# Part of the bash-includes library. Source this file; do not execute it.
#
# A single `trap ... EXIT` per script means the last one registered silently
# replaces every earlier one. That is a real hazard once modules each want their
# own teardown (detach a loop device, remove a temp dir, stop the sudo
# keepalive). This module owns the trap and runs registered handlers in reverse
# order of registration, so teardown unwinds in the opposite order of setup.
#
# Handlers must be idempotent: a script that fails partway may run a handler for
# a resource that was never fully created.
#
# Depends on: log.sh

# include: log.sh
[[ -n "${_LIB_CLEANUP_SOURCED:-}" ]] && return 0
_LIB_CLEANUP_SOURCED=1

_CLEANUP_STACK=()

# ── cleanup_push <command string> ─────────────────────────────────────────────
# Register a teardown command. Evaluated with `eval` at exit, so quote as you
# would for the command line:
#
#   cleanup_push "sudo losetup -d '$LOOP_DEV'"
#   cleanup_push sudo_keepalive_stop
#
# Handlers run with INT, TERM, HUP and PIPE ignored, and so does everything
# they start: keep them short, and do not launch anything long-lived from one.
cleanup_push() {
    _CLEANUP_STACK+=("$*")
}

_cleanup_run() {
    local rc=$?
    local i

    # A signal during teardown must not cut it short: the handlers below run
    # `exit`, and `exit` inside the EXIT trap ends the shell with the rest of
    # the stack unrun. Ctrl-C twice, or the terminal closing (SIGHUP) while a
    # Ctrl-C is still being cleaned up after, would leave resources behind.
    # Ignored rather than trapped so the commands a handler starts ignore
    # them too. SIGQUIT (Ctrl-\) still stops a teardown that hangs.
    # PIPE as well: a hangup also kills the `tee` in `script | tee log`, and
    # the first log line of the teardown would then kill the shell.
    trap '' INT TERM HUP PIPE

    # Reverse order: last registered is torn down first.
    for (( i=${#_CLEANUP_STACK[@]} - 1; i >= 0; i-- )); do
        # A failing handler must not mask the original exit code or prevent the
        # remaining handlers from running.
        eval "${_CLEANUP_STACK[$i]}" || \
            log_warn "cleanup: handler failed: ${_CLEANUP_STACK[$i]}"
    done

    _CLEANUP_STACK=()
    return "$rc"
}

trap _cleanup_run EXIT
# Explicit exit codes on signals so the EXIT trap still fires and callers can
# tell an interrupt apart from a normal failure.
trap 'exit 130' INT
trap 'exit 143' TERM
# A closed terminal or dropped SSH session: without this bash dies on the
# default action and no handler runs. Under nohup, HUP is ignored on entry
# and bash keeps it that way; this line then does nothing.
trap 'exit 129' HUP
