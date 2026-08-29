#!/usr/bin/env bash
# host.sh — host identity.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Setting a hostname is mechanism, not policy: the procedure is the same
# everywhere, and *which* name a machine gets is the caller's business. It
# lives here because two consumers need it — sys-bld sets it during
# provisioning, systool sets it ad hoc — and a second copy would be the
# reimplemented-mechanism problem §1 exists to prevent.
#
# Depends on: log.sh, journal.sh

# include: log.sh
# include: journal.sh
[[ -n "${_LIB_HOST_SOURCED:-}" ]] && return 0
_LIB_HOST_SOURCED=1

# ── set_hostname <name> ───────────────────────────────────────────────────────
# Set the static hostname, idempotently, and journal the change.
#
# An EMPTY name is a no-op, not an error. That is deliberate: sys-bld's
# checklist calls `set_hostname ""` as a step you fill in per machine, so an
# unfilled step must skip rather than abort the run. A command-line caller that
# wants an empty name to be an error should reject it before calling — systool
# does exactly that, so the user gets "need a name" rather than a silent skip.
#
# Returns 0 when the hostname already matches, so re-running a provisioning
# checklist is safe.
set_hostname() {
    local new="${1:-}"

    if [[ -z "$new" ]]; then
        log_warn "set_hostname: no hostname given, skipping"
        return 0
    fi

    local current
    current="$(hostnamectl --static 2>/dev/null || hostname)"
    if [[ "$current" == "$new" ]]; then
        log_info "Hostname already ${new}"
        return 0
    fi

    sudo hostnamectl set-hostname "$new" || die "Failed to set hostname"
    journal_record modify /etc/hostname "hostname ${current} -> ${new}"
    log_success "Hostname set to ${new}"

    # The 127.0.1.1 line in /etc/hosts is deliberately NOT rewritten here.
    # hostnamectl does not touch it, and on most systems nothing breaks: the
    # stale entry still resolves the old name and systemd-resolved answers for
    # the new one. Rewriting it needs a backup_file first, which would pull a
    # third dependency into this module for a change that is usually
    # unnecessary. If sudo starts warning "unable to resolve host", fix
    # /etc/hosts explicitly at the call site.
}
