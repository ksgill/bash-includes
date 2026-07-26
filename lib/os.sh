#!/usr/bin/env bash
# os.sh — system attribute detection helpers
# Part of the bash-includes library. Source this file; do not execute it.
#
# All functions return values via stdout for use with $(...) capture.
# Functions exit non-zero and emit a warning on stderr when detection fails.
#
# This is the single OS-detection implementation. Earlier versions of this
# library reimplemented /etc/os-release parsing in three other files; those
# were removed in favour of this one.
#
# Depends on: /etc/os-release (systemd standard), dpkg, uname, systemd-detect-virt
# Logging: uses log_warn/log_error if defined; falls back to bare stderr printf.

[[ -n "${_LIB_OS_SOURCED:-}" ]] && return 0
_LIB_OS_SOURCED=1

# ── Internal logging fallbacks ────────────────────────────────────────────────
# Used when this file is sourced standalone without the shared logging library.
if ! declare -f log_warn  &>/dev/null; then
    log_warn()  { printf '\e[33m[WARN]\e[0m  %s\n' "$*" >&2; }
fi
if ! declare -f log_error &>/dev/null; then
    log_error() { printf '\e[31m[ERROR]\e[0m %s\n' "$*" >&2; }
fi

# ── /etc/os-release loader ────────────────────────────────────────────────────
# Parses /etc/os-release once and caches fields in _OSREL_* globals.
# All get_os_* functions call this; subsequent calls are no-ops.
_OSREL_LOADED=0

_load_os_release() {
    [[ "${_OSREL_LOADED}" -eq 1 ]] && return 0

    local osrel="/etc/os-release"
    if [[ ! -r "${osrel}" ]]; then
        log_error "_load_os_release: ${osrel} not found or unreadable"
        return 1
    fi

    # Source into a subshell first to validate, then pull individual fields.
    # Avoids polluting the environment with every key in os-release.
    local key val
    while IFS='=' read -r key val; do
        # Strip surrounding quotes (both single and double).
        val="${val#\"}"  val="${val%\"}"
        val="${val#\'}"  val="${val%\'}"
        # Skip blank lines and comments.
        [[ -z "${key}" || "${key}" == \#* ]] && continue
        case "${key}" in
            ID)             _OSREL_ID="${val}"             ;;
            ID_LIKE)        _OSREL_ID_LIKE="${val}"        ;;
            NAME)           _OSREL_NAME="${val}"           ;;
            VERSION_ID)     _OSREL_VERSION_ID="${val}"     ;;
            VERSION_CODENAME) _OSREL_CODENAME="${val}"     ;;
            UBUNTU_CODENAME)  _OSREL_UBUNTU_CODENAME="${val}" ;;  # present in some Ubuntu derivatives
            PRETTY_NAME)    _OSREL_PRETTY_NAME="${val}"    ;;
        esac
    done < "${osrel}"

    _OSREL_LOADED=1
}

# ── get_os_codename ───────────────────────────────────────────────────────────
# Prints the release codename (e.g. "noble", "bookworm", "jammy").
# Checks VERSION_CODENAME first (universal), then UBUNTU_CODENAME (derivatives
# like Mint that ship their own codename but carry the Ubuntu base codename
# separately), then falls back to lsb_release -cs.
get_os_codename() {
    _load_os_release || return 1

    local codename="${_OSREL_CODENAME:-}"

    # Some Ubuntu derivatives set VERSION_CODENAME to their own name
    # but expose the upstream base via UBUNTU_CODENAME.
    # Prefer UBUNTU_CODENAME when the caller needs it for APT sources.
    # Here we return VERSION_CODENAME (the distro's own codename) — callers
    # that specifically need the Ubuntu base codename should use get_os_ubuntu_codename.
    if [[ -n "${codename}" ]]; then
        printf '%s\n' "${codename}"
        return 0
    fi

    # Fallback: lsb_release (not always installed, but try).
    if command -v lsb_release &>/dev/null; then
        codename="$(lsb_release -cs 2>/dev/null)"
        if [[ -n "${codename}" && "${codename}" != "n/a" ]]; then
            printf '%s\n' "${codename}"
            return 0
        fi
    fi

    log_warn "get_os_codename: could not determine release codename"
    return 1
}

# ── get_os_ubuntu_codename ────────────────────────────────────────────────────
# For Ubuntu derivatives (Mint, Pop!_OS, etc.) that need the upstream Ubuntu
# codename for APT repo URLs. Returns UBUNTU_CODENAME if present, otherwise
# falls back to VERSION_CODENAME (on real Ubuntu these are the same).
get_os_ubuntu_codename() {
    _load_os_release || return 1

    local codename="${_OSREL_UBUNTU_CODENAME:-${_OSREL_CODENAME:-}}"
    if [[ -n "${codename}" ]]; then
        printf '%s\n' "${codename}"
        return 0
    fi

    log_warn "get_os_ubuntu_codename: could not determine Ubuntu base codename"
    return 1
}

# ── get_os_id ─────────────────────────────────────────────────────────────────
# Prints the distro identifier: "ubuntu", "debian", "fedora", "arch", etc.
# Use this to gate package manager calls (apt vs dnf vs pacman).
get_os_id() {
    _load_os_release || return 1

    if [[ -n "${_OSREL_ID:-}" ]]; then
        printf '%s\n' "${_OSREL_ID}"
        return 0
    fi

    log_warn "get_os_id: ID field missing from /etc/os-release"
    return 1
}

# ── get_os_id_like ────────────────────────────────────────────────────────────
# Prints ID_LIKE — the upstream family this distro is based on.
# E.g. Linux Mint returns "ubuntu", Pop!_OS returns "ubuntu debian".
# Useful for capability gating when ID alone is too specific.
# Returns empty string (not an error) if ID_LIKE is absent — not all distros set it.
get_os_id_like() {
    _load_os_release || return 1
    printf '%s\n' "${_OSREL_ID_LIKE:-}"
}

# ── get_os_version ────────────────────────────────────────────────────────────
# Prints VERSION_ID: "24.04", "12", "40", etc.
# Use for numeric version comparisons or release-specific code paths.
get_os_version() {
    _load_os_release || return 1

    if [[ -n "${_OSREL_VERSION_ID:-}" ]]; then
        printf '%s\n' "${_OSREL_VERSION_ID}"
        return 0
    fi

    log_warn "get_os_version: VERSION_ID field missing from /etc/os-release"
    return 1
}

# ── get_os_pretty_name ────────────────────────────────────────────────────────
# Prints the human-readable distro name: "Ubuntu 24.04.1 LTS", etc.
# Useful for log headers and diagnostic output.
get_os_pretty_name() {
    _load_os_release || return 1

    if [[ -n "${_OSREL_PRETTY_NAME:-}" ]]; then
        printf '%s\n' "${_OSREL_PRETTY_NAME}"
        return 0
    fi

    log_warn "get_os_pretty_name: PRETTY_NAME missing from /etc/os-release"
    return 1
}

# ── get_arch ──────────────────────────────────────────────────────────────────
# Prints the dpkg architecture string: "amd64", "arm64", "armhf", etc.
# This is what APT repo URLs and package names use — NOT the kernel's uname -m.
# Falls back to a uname -m → dpkg-arch translation if dpkg is absent.
get_arch() {
    if command -v dpkg &>/dev/null; then
        dpkg --print-architecture
        return 0
    fi

    # Non-Debian systems or minimal containers without dpkg: normalize uname -m.
    local machine
    machine="$(uname -m)"
    case "${machine}" in
        x86_64)          printf 'amd64\n'   ;;
        aarch64|arm64)   printf 'arm64\n'   ;;
        armv7l|armhf)    printf 'armhf\n'   ;;
        armv6l)          printf 'armel\n'   ;;
        i386|i686)       printf 'i386\n'    ;;
        *)
            log_warn "get_arch: unrecognized machine type '${machine}'; returning raw uname -m value"
            printf '%s\n' "${machine}"
            ;;
    esac
}

# ── get_kernel_arch ───────────────────────────────────────────────────────────
# Prints the raw kernel architecture as reported by uname -m.
# Use when you need the kernel's view: "x86_64", "aarch64", "armv7l", etc.
# Distinct from get_arch which normalizes to dpkg naming conventions.
get_kernel_arch() {
    uname -m
}

# ── get_kernel_version ────────────────────────────────────────────────────────
# Prints the full kernel version string: "6.8.0-57-generic", etc.
# Useful for gating kernel-version-dependent behaviour (e.g. OpenVPN DCO,
# vfio-bind availability, nftables feature support).
get_kernel_version() {
    uname -r
}

# ── get_init_system ───────────────────────────────────────────────────────────
# Prints the name of PID 1: "systemd", "init", "openrc-init", etc.
# Scripts that install services should check this before calling systemctl.
get_init_system() {
    local init
    init="$(ps -p 1 -o comm= 2>/dev/null)"
    if [[ -z "${init}" ]]; then
        log_warn "get_init_system: could not read PID 1 comm"
        return 1
    fi
    printf '%s\n' "${init}"
}

# ── get_virt_type ─────────────────────────────────────────────────────────────
# Prints the virtualization/container context via systemd-detect-virt.
# Returns: "none" (bare metal), "kvm", "qemu", "vmware", "lxc", "docker",
#          "podman", "wsl", "openvz", etc.
# Scripts that touch hardware (PCIe passthrough, USB, raw disks) should gate
# on this returning "none" or a known-safe VM type.
get_virt_type() {
    if ! command -v systemd-detect-virt &>/dev/null; then
        log_warn "get_virt_type: systemd-detect-virt not found; install systemd or systemd-detect-virt"
        return 1
    fi
    # systemd-detect-virt exits 0 when virtualized, 1 when bare metal.
    # We capture and print in both cases; the caller decides what to do with it.
    local virt
    virt="$(systemd-detect-virt 2>/dev/null || true)"
    printf '%s\n' "${virt:-none}"
}

# ── get_session_type ──────────────────────────────────────────────────────────
# Prints the display/session type: "wayland", "x11", or "none".
# "none" indicates no active graphical session (server/headless context).
# More useful than a binary desktop/server flag because it tells you *what kind*
# of session you're dealing with, which matters for clipboard, screengrab, etc.
get_session_type() {
    # Prefer loginctl if available — authoritative for systemd sessions.
    if command -v loginctl &>/dev/null; then
        local session_id session_type
        session_id="$(loginctl --no-legend list-sessions 2>/dev/null | awk 'NR==1{print $1}')"
        if [[ -n "${session_id}" ]]; then
            session_type="$(loginctl show-session "${session_id}" -p Type --value 2>/dev/null)"
            case "${session_type}" in
                wayland) printf 'wayland\n'; return 0 ;;
                x11|mir) printf 'x11\n';     return 0 ;;
            esac
        fi
    fi

    # Fallback: environment variable inspection (works inside the current session).
    if [[ -n "${WAYLAND_DISPLAY:-}" ]]; then
        printf 'wayland\n'
        return 0
    fi
    if [[ -n "${DISPLAY:-}" ]]; then
        printf 'x11\n'
        return 0
    fi

    # Final fallback: check if a known display manager service is active.
    if command -v systemctl &>/dev/null; then
        local dm
        for dm in gdm sddm lightdm xdm lxdm; do
            if systemctl is-active --quiet "${dm}" 2>/dev/null; then
                printf 'x11\n'  # Can't determine wayland vs x11 from DM name alone
                return 0
            fi
        done
    fi

    printf 'none\n'
}

# ── sys_detect_summary ────────────────────────────────────────────────────────
# Prints all detected attributes to stdout in KEY=value format.
# Useful for log headers at the top of install scripts.
sys_detect_summary() {
    printf 'DISTRO_ID=%s\n'       "$(get_os_id          2>/dev/null || printf 'unknown')"
    printf 'DISTRO_ID_LIKE=%s\n'  "$(get_os_id_like     2>/dev/null || printf '')"
    printf 'OS_VERSION=%s\n'      "$(get_os_version      2>/dev/null || printf 'unknown')"
    printf 'OS_CODENAME=%s\n'     "$(get_os_codename     2>/dev/null || printf 'unknown')"
    printf 'PRETTY_NAME=%s\n'     "$(get_os_pretty_name  2>/dev/null || printf 'unknown')"
    printf 'PKG_ARCH=%s\n'        "$(get_arch            2>/dev/null || printf 'unknown')"
    printf 'KERNEL_ARCH=%s\n'     "$(get_kernel_arch     2>/dev/null || printf 'unknown')"
    printf 'KERNEL_VERSION=%s\n'  "$(get_kernel_version  2>/dev/null || printf 'unknown')"
    printf 'INIT_SYSTEM=%s\n'     "$(get_init_system     2>/dev/null || printf 'unknown')"
    printf 'VIRT_TYPE=%s\n'       "$(get_virt_type       2>/dev/null || printf 'unknown')"
    printf 'SESSION_TYPE=%s\n'    "$(get_session_type    2>/dev/null || printf 'unknown')"
}
