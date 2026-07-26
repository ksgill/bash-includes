#!/usr/bin/env bash
# net.sh — IPv4 address and subnet arithmetic.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Pure integer arithmetic in bash — no ipcalc, no python, nothing to install.
# Every function returns its result on stdout for $(...) capture.
#
# Depends on: log.sh (check_internet only; the arithmetic needs nothing).

# include: log.sh
# include: log.sh
[[ -n "${_LIB_NET_SOURCED:-}" ]] && return 0
_LIB_NET_SOURCED=1

# ── mask_to_cidr <dotted-quad mask> ───────────────────────────────────────────
# 255.255.0.0 -> 16. Counts set bits, so a non-contiguous mask yields a bit
# count rather than an error; validate upstream if that matters.
mask_to_cidr() {
    local mask="$1" cidr=0 octet
    local -a octets
    IFS='.' read -r -a octets <<< "$mask"
    for octet in "${octets[@]}"; do
        while [[ $octet -gt 0 ]]; do
            cidr=$((cidr + (octet & 1)))
            octet=$((octet >> 1))
        done
    done
    printf '%s\n' "$cidr"
}

# ── derive_network_addr <ip> <cidr> ───────────────────────────────────────────
# Mask an address down to its network address. 10.1.2.3/16 -> 10.1.0.0
#
# The read targets are plain `local`; only computed results use `local -i`.
# Combining `local -i` with `read` trips unbound-variable errors under `set -u`
# in some bash versions.
derive_network_addr() {
    local ip="$1" cidr="$2"
    local o1 o2 o3 o4
    IFS='.' read -r o1 o2 o3 o4 <<< "${ip}"
    local -i ipint=$(( (o1 << 24) | (o2 << 16) | (o3 << 8) | o4 ))
    local -i mask=$(( cidr == 0 ? 0 : (0xFFFFFFFF << (32 - cidr)) & 0xFFFFFFFF ))
    local -i netint=$(( ipint & mask ))
    printf '%d.%d.%d.%d\n' \
        $(( (netint >> 24) & 0xFF )) \
        $(( (netint >> 16) & 0xFF )) \
        $(( (netint >>  8) & 0xFF )) \
        $((  netint        & 0xFF ))
}

# ── ranges_overlap <net_a> <cidr_a> <net_b> <cidr_b> ──────────────────────────
# True (0) when the two CIDR ranges intersect at all.
#
# Masking both networks by the SHORTER of the two prefixes and comparing
# catches every case in one test:
#   identical      10.0.0.0/16 vs 10.0.0.0/16
#   containment    10.0.0.0/16 contains 10.0.0.42/24
#   partial        10.0.0.0/15 and 10.1.0.0/16
ranges_overlap() {
    local net_a="$1" cidr_a="$2" net_b="$3" cidr_b="$4"
    local shorter=$(( cidr_a < cidr_b ? cidr_a : cidr_b ))
    local masked_a masked_b
    masked_a="$(derive_network_addr "${net_a}" "${shorter}")"
    masked_b="$(derive_network_addr "${net_b}" "${shorter}")"
    [[ "${masked_a}" == "${masked_b}" ]]
}

# ── ip_in_range <ip> <net> <cidr> ─────────────────────────────────────────────
# True (0) when <ip> falls inside <net>/<cidr>.
ip_in_range() {
    local ip="$1" net="$2" cidr="$3"
    [[ "$(derive_network_addr "$ip" "$cidr")" == "$(derive_network_addr "$net" "$cidr")" ]]
}


# ── check_internet ────────────────────────────────────────────────────────────
# Verify generic HTTPS internet connectivity. We don't probe the actual repos
# because (a) they're different per distro, (b) repo mirrors have very high
# uptime — if the wider internet is reachable, the mirrors almost certainly
# are too. A failure here cleanly distinguishes "no internet" from "repo
# doesn't support this codename" — both would otherwise show up as apt errors.
check_internet() {
    local test_hosts=(
        "https://www.google.com"
        "https://www.cloudflare.com"
    )

    log_info "Verifying internet connectivity..."

    local host
    for host in "${test_hosts[@]}"; do
        if curl --silent --head --fail --max-time 5 \
                --connect-timeout 3 "$host" >/dev/null 2>&1; then
            log_info "  ✓ Internet reachable (via ${host})"
            return 0
        fi
    done

    log_error "No internet connectivity detected"
    log_error "Tested hosts: ${test_hosts[*]}"
    log_error "Check network connectivity, DNS resolution, and proxy/firewall settings"
    return 1
}
