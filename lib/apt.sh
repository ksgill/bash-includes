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
# Depends on: log.sh, os.sh; journal.sh and backup.sh if loaded. Uses gpg.

# include: log.sh
# include: os.sh
[[ -n "${_LIB_APT_SOURCED:-}" ]] && return 0
_LIB_APT_SOURCED=1

APT_KEYRING_DIR="/etc/apt/keyrings"
APT_SOURCES_DIR="/etc/apt/sources.list.d"

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
#   name        short identifier; names the keyring and .sources file
#   key_url     URL of the ASCII-armoured or binary signing key
#   uris        repository base URL
#   suites      suite/codename, e.g. "noble" or "$(get_os_codename)"
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
# function until the new key is checked and the pin updated, which is the
# point.
#
# Idempotent: if the repo is already configured exactly as requested, and its
# keyring passes the fingerprint check, it returns without touching anything.
# A keyring that fails the check is moved aside (<name>.gpg.untrusted.<ts>),
# not deleted, and the key is fetched again.
#
# Validates the repo before accepting it. A scoped `apt-get update` reads ONLY
# the new sources file, so a failure is unambiguously about this repository
# rather than an unrelated network or mirror problem. On failure the repo is
# removed and the function returns non-zero — the caller decides whether to fall
# back to distro-native packages or treat it as fatal.
apt_add_repo() {
    local fprs="" no_check=false fpr
    while [[ "${1:-}" == --* ]]; do
        case "$1" in
            --fingerprint)   fprs="${2:-}"; shift 2 || die "apt_add_repo: --fingerprint needs a value" ;;
            --fingerprint=*) fprs="${1#*=}"; shift ;;
            --no-fingerprint) no_check=true; shift ;;
            --) shift; break ;;
            *) die "apt_add_repo: unknown option '$1'" ;;
        esac
    done

    local name="${1:-}" key_url="${2:-}" uris="${3:-}" suites="${4:-}"
    local components="${5:-main}" types="${6:-deb}" arch="${7:-}"

    local keyring="${APT_KEYRING_DIR}/${name}.gpg"
    local sources="${APT_SOURCES_DIR}/${name}.sources"

    [[ -n "$name" && -n "$key_url" && -n "$uris" && -n "$suites" ]] \
        || die "apt_add_repo: name, key_url, uris and suites are all required"

    # ── Fingerprint policy: exactly one of the two options ───────────────────
    if [[ -n "$fprs" && "$no_check" == true ]]; then
        die "apt_add_repo ${name}: --fingerprint and --no-fingerprint are mutually exclusive"
    fi
    if [[ -z "$fprs" && "$no_check" == false ]]; then
        die "apt_add_repo ${name}: pass --fingerprint <FPR> for the signing key, or --no-fingerprint to trust ${key_url} as served"
    fi
    if [[ -n "$fprs" ]]; then
        # Normalise: drop spaces, upper case; then check each entry.
        fprs="$(tr -d ' ' <<< "$fprs" | tr '[:lower:]' '[:upper:]')"
        local -a fpr_list
        IFS=, read -r -a fpr_list <<< "$fprs"
        [[ ${#fpr_list[@]} -gt 0 ]] || die "apt_add_repo ${name}: --fingerprint is empty"
        for fpr in "${fpr_list[@]}"; do
            [[ "$fpr" =~ ^([0-9A-F]{40}|[0-9A-F]{64})$ ]] \
                || die "apt_add_repo ${name}: '${fpr}' is not a key fingerprint (40 or 64 hex digits)"
        done
    else
        log_warn "APT repo '${name}': --no-fingerprint — trusting the key served at ${key_url} without checking it"
    fi

    # ── Existing keyring: must still pass the check ──────────────────────────
    if [[ -n "$fprs" && -f "$keyring" ]] && ! _apt_installed_keyring_matches "$keyring" "$fprs"; then
        local aside
        aside="${keyring}.untrusted.$(date +%s)"
        log_warn "APT repo '${name}': ${keyring} is not the pinned key (${fprs}); moving it to ${aside}"
        sudo mv -f -- "$keyring" "$aside" || return 1
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
        if declare -f backup_file >/dev/null 2>&1; then
            backup_file "$sources" "reconfiguring apt repo ${name}"
        fi
    fi

    # ── Keyring ──────────────────────────────────────────────────────────────
    if [[ ! -d "$APT_KEYRING_DIR" ]]; then
        sudo mkdir -p "$APT_KEYRING_DIR" || return 1
        sudo chmod 0755 "$APT_KEYRING_DIR" || return 1
    fi

    if [[ ! -f "$keyring" ]]; then
        log_info "Fetching signing key for '${name}'"
        # Download to a private temporary file, check it, and only then put it
        # in place: nothing unchecked ever lands in the keyring directory.
        local key_tmp
        key_tmp="$(mktemp)" || return 1
        if ! wget -qO "$key_tmp" "$key_url"; then
            log_error "Failed to fetch the signing key for '${name}' from ${key_url}"
            rm -f "$key_tmp"
            return 1
        fi
        if [[ -n "$fprs" ]] && ! apt_keyring_matches "$key_tmp" "$fprs"; then
            log_error "The key served at ${key_url} is not the pinned key for '${name}'"
            log_error "  expected: ${fprs}"
            log_error "  served:   $(apt_key_fingerprints "$key_tmp" | paste -sd, - || echo 'no readable key')"
            log_error "If the publisher has rotated its key, verify the new one and update the pin."
            rm -f "$key_tmp"
            return 1
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
            return 1
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
    } | sudo tee "$sources" >/dev/null

    # ── Validate in isolation ────────────────────────────────────────────────
    # Dir::Etc::sourcelist points at this one file and sourceparts is disabled,
    # so apt reads nothing else. Any error is about this repo alone.
    log_info "Validating APT repo '${name}'"
    local out
    if ! out=$(sudo apt-get update \
            -o Dir::Etc::sourcelist="$sources" \
            -o Dir::Etc::sourceparts="-" \
            -o APT::Get::List-Cleanup="0" 2>&1); then
        log_warn "APT repo '${name}' failed validation for suite '${suites}':"
        printf '%s\n' "$out" | sed 's/^/    /' >&2
        log_warn "Removing '${name}' — it probably does not publish for '${suites}' yet"
        sudo rm -f "$sources"
        sudo apt-get update >/dev/null 2>&1 || true
        return 1
    fi

    sudo apt-get update || return 1

    if declare -f journal_record >/dev/null 2>&1; then
        journal_record repo "$sources" "added APT repo ${name} (${uris} ${suites})"
    fi

    log_success "APT repo '${name}' configured"
}

# ── apt_remove_repo <name> ────────────────────────────────────────────────────
apt_remove_repo() {
    local name="$1"
    local keyring="${APT_KEYRING_DIR}/${name}.gpg"
    local sources="${APT_SOURCES_DIR}/${name}.sources"

    [[ -f "$sources" ]] || return 0

    log_info "Removing APT repo '${name}'"
    sudo rm -f "$sources" "$keyring"
    sudo apt-get update >/dev/null 2>&1 || true

    if declare -f journal_record >/dev/null 2>&1; then
        journal_record delete "$sources" "removed APT repo ${name}"
    fi
}

# ── apt_install <package>... ──────────────────────────────────────────────────
# Non-interactive install with a single journal entry for the set.
#
# `sudo env VAR=… cmd` rather than `sudo VAR=… cmd`: the latter depends on the
# sudoers env_reset/SETENV policy and is rejected outright under some
# configurations. Going through env(1) is unambiguous everywhere.
apt_install() {
    [[ $# -gt 0 ]] || return 0

    log_info "Installing: $*"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" \
        || die "Failed to install: $*"

    if declare -f journal_record >/dev/null 2>&1; then
        journal_record install "$*" "installed $# package(s) via apt"
    fi
}

# ── apt_install_list <path> ───────────────────────────────────────────────────
# Install from a package manifest: one package per line, # comments and blank
# lines ignored. Package sets that need no configuration are data, not code —
# this is what reads them.
apt_install_list() {
    local list="$1" pkgs=()
    [[ -r "$list" ]] || die "Package list not found: ${list}"

    local line
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line//[[:space:]]/}"
        [[ -n "$line" ]] && pkgs+=("$line")
    done < "$list"

    [[ ${#pkgs[@]} -gt 0 ]] || { log_warn "No packages listed in ${list}"; return 0; }

    log_info "Installing package list $(basename -- "$list") (${#pkgs[@]} packages)"
    sudo env DEBIAN_FRONTEND=noninteractive apt-get install -y "${pkgs[@]}" \
        || die "Failed to install package list: ${list}"

    if declare -f journal_record >/dev/null 2>&1; then
        journal_record install "$(basename -- "$list")" \
            "installed ${#pkgs[@]} packages from list" "packages=${pkgs[*]}"
    fi
}
