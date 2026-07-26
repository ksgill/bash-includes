#!/usr/bin/env bash
# apt.sh — safe APT repository and package helpers.
# Part of the bash-includes library. Source this file; do not execute it.
#
# apt_add_repo replaces what used to be eight near-identical add_<name>_repo
# functions (kali, kismet, ovpn, ovpn3, virtualbox, vscode, docker, …), each a
# copy of the same wget-key / gpg --dearmor / write-.sources sequence with
# different constants. The mechanism lives here; which repositories you actually
# add is policy and belongs to the calling script.
#
# Depends on: log.sh, os.sh; journal.sh and backup.sh if loaded.

# include: log.sh
# include: os.sh
[[ -n "${_LIB_APT_SOURCED:-}" ]] && return 0
_LIB_APT_SOURCED=1

APT_KEYRING_DIR="/etc/apt/keyrings"
APT_SOURCES_DIR="/etc/apt/sources.list.d"

# ── apt_add_repo <name> <key_url> <uris> <suites> [components] [types] [arch] ─
#
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
# Idempotent: if the repo is already configured exactly as requested it returns
# without touching anything.
#
# Validates the repo before accepting it. A scoped `apt-get update` reads ONLY
# the new sources file, so a failure is unambiguously about this repository
# rather than an unrelated network or mirror problem. On failure the repo is
# removed and the function returns non-zero — the caller decides whether to fall
# back to distro-native packages or treat it as fatal.
apt_add_repo() {
    local name="$1" key_url="$2" uris="$3" suites="$4"
    local components="${5:-main}" types="${6:-deb}" arch="${7:-}"

    local keyring="${APT_KEYRING_DIR}/${name}.gpg"
    local sources="${APT_SOURCES_DIR}/${name}.sources"

    [[ -n "$name" && -n "$key_url" && -n "$uris" && -n "$suites" ]] \
        || die "apt_add_repo: name, key_url, uris and suites are all required"

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
        # Pipeline runs as your user; only the final tee needs elevation.
        if ! wget -qO- "$key_url" | gpg --dearmor | sudo tee "$keyring" >/dev/null; then
            log_error "Failed to fetch or dearmour the signing key for '${name}'"
            sudo rm -f "$keyring"
            return 1
        fi
        sudo chmod 0644 "$keyring"

        if declare -f journal_record >/dev/null 2>&1; then
            journal_record create "$keyring" "APT signing key for ${name}" "source=${key_url}"
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
