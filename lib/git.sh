#!/usr/bin/env bash
# git.sh — git identity, and the GitHub SSH client setup.
# Part of the bash-includes library. Source this file; do not execute it.
#
# What a machine needs before it can clone or push: git's identity, a global
# ignore file, the client stanza that selects the right key, and a pinned host
# key so the first connection is verified rather than trusted blindly. All of
# that is mechanism — WHICH name, email and key a machine gets is the caller's
# business, so none of it is hardcoded here.
#
# It lives here because two consumers need it: sys-bld configures a machine it
# is provisioning, git-bootstrap configures one from a keypair carried on
# removable media. They differ only in how the key is OBTAINED — generated in
# place versus installed from a stick — so that step is deliberately NOT here.
# Everything downstream of "a key now exists at this path" is identical, and a
# second copy would be the reimplemented-mechanism problem §1 exists to prevent.
#
# Depends on: log.sh, journal.sh, backup.sh

# include: log.sh
# include: journal.sh
# include: backup.sh
[[ -n "${_LIB_GIT_SOURCED:-}" ]] && return 0
_LIB_GIT_SOURCED=1

# GitHub's Ed25519 host key, and the fingerprint it must produce.
#
# Taken from https://api.github.com/meta (the ssh_keys field), which is
# authenticated by TLS, and cross-checked against the fingerprint GitHub
# publishes in its documentation. ssh-keyscan is NOT a sufficient source on its
# own: it is itself trust-on-first-use, so pinning its output would relocate the
# problem rather than solve it.
#
# Ed25519 only, deliberately. GitHub also serves RSA and ECDSA host keys; not
# pinning them, combined with the HostKeyAlgorithms line in the stanza below,
# keeps a connection from negotiating a key type that was never verified.
#
# WHEN GITHUB ROTATES THIS KEY every consumer breaks loudly with "REMOTE HOST
# IDENTIFICATION HAS CHANGED". That is intended, but it makes these two lines a
# maintenance point: re-check api.github.com/meta and update BOTH together.
# GitHub last rotated its RSA host key in March 2023 after a brief exposure, so
# this is not hypothetical. Overridable so tests can substitute a known-bad key.
GITHUB_HOST_KEY="${GITHUB_HOST_KEY:-github.com ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl}"
GITHUB_HOST_FPR="${GITHUB_HOST_FPR:-SHA256:+DiY3wvvV6TuJJhbpZisF/zLDA0zPMSvHdkr4UvCOqU}"

# ── git_identity_config <name> <email> ────────────────────────────────────────
# Set git's global identity and point it at a global ignore file.
#
# Name and email are arguments rather than constants because this is a library:
# it is policy-free, and a checklist that hardcoded one person's address book
# would be wrong for every other machine.
#
# The ignore file is created EMPTY on purpose. git already reads
# $XDG_CONFIG_HOME/git/ignore without being told to; setting core.excludesfile
# explicitly makes the location discoverable from `git config --list` rather
# than being folklore. What belongs inside it is the user's business.
#
# Idempotent: re-running only rewrites values that git already stores.
git_identity_config() {
    local name="${1:-}" email="${2:-}"
    local ignore="${GIT_GLOBAL_IGNORE:-${XDG_CONFIG_HOME:-${HOME}/.config}/git/ignore}"

    [[ -n "$name" && -n "$email" ]] \
        || die "git_identity_config: need a name and an email"
    command -v git >/dev/null 2>&1 \
        || die "git is not installed — install it before configuring an identity"

    git config --global user.name  "$name"  || die "Could not set git user.name"
    git config --global user.email "$email" || die "Could not set git user.email"
    git config --global init.defaultBranch main

    if [[ ! -f "$ignore" ]]; then
        mkdir -p -- "$(dirname -- "$ignore")"
        printf '# Global git ignore patterns. Managed by you, not by any script.\n' > "$ignore"
        journal_record create "$ignore" "created empty global gitignore"
    fi
    git config --global core.excludesfile "$ignore"

    journal_record modify "${HOME}/.gitconfig" \
        "git identity ${name} <${email}>, default branch main"
    log_success "git identity configured for ${name} <${email}>"
}

# ── git_ensure_key <path> [comment] ───────────────────────────────────────────
# Generate an Ed25519 keypair at <path> if nothing is there yet, and make sure
# the permissions are right either way.
#
# Passphraseless, matching create_ssh_keys. A passphrase is strictly better if
# you are willing to type it once per session and load an agent, but that is a
# policy choice the caller makes by generating the key itself instead.
#
# The chmod runs unconditionally, not only after generating: a ~/.ssh restored
# from a backup or unpacked from an image is routinely group-readable, and ssh
# only complains about that later, on some paths, in a message that does not
# obviously name the cause.
#
# Callers that INSTALL an existing key rather than generating one should not use
# this — see git-bootstrap, which carries its own installer.
git_ensure_key() {
    local key="${1:-}" comment="${2:-}"
    local dir keygen_args=()

    [[ -n "$key" ]] || die "git_ensure_key: need a key path"

    dir="$(dirname -- "$key")"
    mkdir -p -- "$dir"
    chmod 0700 "$dir"

    if [[ ! -e "$key" ]]; then
        keygen_args=(-t ed25519 -f "$key" -N "" -a 100)
        [[ -n "$comment" ]] && keygen_args+=(-C "$comment")
        ssh-keygen "${keygen_args[@]}" >/dev/null \
            || die "Could not generate ${key}"
        journal_record create "$key" "generated ed25519 key${comment:+ for ${comment}}"
    fi

    # 600: ssh refuses a private key that is group- or world-readable.
    chmod 0600 "$key"
    # 644: the public half is public.
    [[ -e "${key}.pub" ]] && chmod 0644 "${key}.pub"

    return 0
}

# ── _git_strip_github_host_block <file> ───────────────────────────────────────
# Remove any `Host` block naming github or github.com from an ssh config file,
# printing what remains. Returns 0 if something was removed, 1 if not.
#
# This exists for migration. Earlier versions appended the stanza directly to
# ~/.ssh/config; the stanza now lives in its own file under config.d. Left
# alone, the appended copy still matches, and ssh takes the FIRST value it
# obtains for most keywords — so which definition wins would depend on where
# the Include landed. Two definitions of the same host is a trap regardless of
# which one is correct.
#
# A block runs from its Host line to the next Host line or end of file, which
# is how ssh itself parses one.
_git_strip_github_host_block() {
    local file="${1:-}"

    [[ -f "$file" ]] || return 1

    awk '
        /^[[:space:]]*Host[[:space:]]/ {
            skip = 0
            for (i = 2; i <= NF; i++)
                if ($i == "github" || $i == "github.com") skip = 1
            if (skip) { removed = 1; next }
        }
        skip { next }
        { print }
        END { exit (removed ? 0 : 1) }
    ' "$file"
}

# ── git_github_ssh_stanza [key] ───────────────────────────────────────────────
# Write the ssh client stanza that selects <key> for GitHub, as its own file
# under ~/.ssh/config.d, and make sure ~/.ssh/config includes it.
#
# A separate file rather than an append, because an append cannot UPDATE. The
# usual append idiom greps for a sentinel and skips if it matches, which means
# changing a directive later is silently a no-op on every machine that already
# ran it. Owning a whole file makes the stanza always exactly what this code
# says, and `# Managed by` states that plainly to anyone who opens it.
#
# The host is keyed on the alias `github` alone, so remotes read
# `github:owner/repo`. ssh matches Host patterns against the literal string in
# the remote, so a full `git@github.com:` URL does NOT match this stanza and
# falls through to the default identity list. That is deliberate; add
# `github.com` to the Host line if you want both. Host key verification is
# unaffected either way, because known_hosts is keyed on the resolved HostName.
git_github_ssh_stanza() {
    local key="${1:-${HOME}/.ssh/git@github.com}"
    local dir="${HOME}/.ssh" cfgdir="${HOME}/.ssh/config.d"
    local cfg="${dir}/config" host="${cfgdir}/10-github.conf"
    local inc='Include ~/.ssh/config.d/*.conf'
    local want body

    mkdir -p -- "$dir"
    chmod 0700 "$dir"
    [[ -d "$cfgdir" ]] || { mkdir -p -- "$cfgdir" && chmod 0700 "$cfgdir"; }

    # IdentitiesOnly: without it an agent offers every key it holds, and a
    # server with MaxAuthTries 3 can refuse the connection before the right one
    # is tried. AddKeysToAgent no: agent caching exists to save re-entering a
    # passphrase, so it earns nothing for a key that has none — and this says
    # what the directive does rather than asserting anything about the key.
    # HostKeyAlgorithms: only accept the host key type that is actually pinned.
    want="$(cat <<EOF
# Managed by bash-includes (git.sh) — this file is overwritten.
Host github
    HostName github.com
    User git
    IdentityFile ${key}
    IdentitiesOnly yes
    AddKeysToAgent no
    HostKeyAlgorithms ssh-ed25519
EOF
    )"

    if [[ -f "$host" ]] && [[ "$(cat -- "$host")" == "$want" ]]; then
        log_info "GitHub ssh stanza already current: ${host}"
    else
        # Created at 0600 BEFORE any content is written, never written loose and
        # tightened afterwards.
        install -m 0600 /dev/null "$host" || die "Could not create ${host}"
        printf '%s\n' "$want" > "$host" || die "Could not write ${host}"
        journal_record create "$host" "ssh client stanza for github"
    fi

    # Migration: drop a stanza appended to ~/.ssh/config by an earlier version.
    if [[ -f "$cfg" ]] && body="$(_git_strip_github_host_block "$cfg")"; then
        backup_file "$cfg" "removing the appended github stanza, now in config.d"
        printf '%s\n' "$body" > "$cfg" || die "Could not rewrite ${cfg}"
        journal_record modify "$cfg" "removed appended github stanza"
        log_warn "Removed a github stanza that was appended to ${cfg}; it now lives in ${host}"
    fi

    # The Include has to come FIRST. ssh takes the first value it obtains for
    # most keywords, so an Include placed after an existing `Host *` block is
    # overridden by it rather than overriding it.
    if [[ ! -f "$cfg" ]]; then
        install -m 0600 /dev/null "$cfg" || die "Could not create ${cfg}"
        printf '%s\n' "$inc" > "$cfg"
        journal_record create "$cfg" "created with the config.d include"
    elif ! grep -qxF "$inc" "$cfg"; then
        backup_file "$cfg" "prepending the config.d include"
        body="$(cat -- "$cfg")"
        # Written back through the existing file so its mode and ownership
        # survive; a mv would replace them with a new file's.
        printf '%s\n\n%s\n' "$inc" "$body" > "$cfg" \
            || die "Could not rewrite ${cfg}"
        journal_record modify "$cfg" "prepended the config.d include"
    fi

    log_success "GitHub ssh stanza written to ${host}"
}

# ── git_pin_github_host_key ───────────────────────────────────────────────────
# Put GitHub's Ed25519 host key in ~/.ssh/known_hosts so the first connection is
# verified against a known value instead of accepted on sight.
#
# The alternative, StrictHostKeyChecking=accept-new, is trust-on-first-use: it
# silently accepts a host it has never seen and only objects if the key later
# changes. On a freshly installed machine known_hosts is empty, so EVERY run is
# a first connection — exactly the unprotected case. Pinning removes the window,
# and lets callers use StrictHostKeyChecking=yes.
#
# Idempotent, and safe to run against a known_hosts that already has an entry
# for github.com from an earlier trust-on-first-use connection.
git_pin_github_host_key() {
    local dir="${HOME}/.ssh" known="${HOME}/.ssh/known_hosts"
    local fpr

    mkdir -p -- "$dir"
    chmod 0700 "$dir"

    if [[ -f "$known" ]] && grep -qxF "$GITHUB_HOST_KEY" "$known"; then
        log_info "GitHub host key already pinned"
        return 0
    fi

    # Verify the constant before trusting it. A typo in that base64 would
    # otherwise be pinned silently and only surface later as a connection that
    # fails for reasons pointing at the network.
    fpr="$(printf '%s\n' "$GITHUB_HOST_KEY" | ssh-keygen -lf - 2>/dev/null | awk '{print $2}')" \
        || die "Could not parse GITHUB_HOST_KEY"
    [[ "$fpr" == "$GITHUB_HOST_FPR" ]] \
        || die "Pinned host key does not match its fingerprint: got ${fpr}, expected ${GITHUB_HOST_FPR}"

    # Remove any existing github.com entry first. One acquired earlier by
    # trust-on-first-use would collide with the pin, and ssh would report a
    # changed host key rather than using the right one.
    if [[ -f "$known" ]] && ssh-keygen -F github.com -f "$known" >/dev/null 2>&1; then
        log_warn "Replacing an existing github.com entry in ${known}"
        ssh-keygen -R github.com -f "$known" >/dev/null 2>&1 \
            || die "Could not remove the existing github.com entry"
        journal_record modify "$known" "removed a pre-existing github.com host key"
    fi

    printf '%s\n' "$GITHUB_HOST_KEY" >> "$known" \
        || die "Could not write ${known}"
    chmod 0644 "$known"
    journal_record modify "$known" "pinned github.com host key ${GITHUB_HOST_FPR}"

    log_success "Pinned GitHub host key ${GITHUB_HOST_FPR}"
}
