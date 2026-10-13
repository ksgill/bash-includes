#!/usr/bin/env bash
# mac.sh — read and set an interface's MAC address.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Only the mechanism. Where the original address is kept so it can be put back
# is the caller's: a tool that changes it for one run holds it in a variable, a
# tool that changes it until told otherwise writes it to a state file.
#
# Depends on: nothing (uses sudo and ip directly).

[[ -n "${_LIB_MAC_SOURCED:-}" ]] && return 0
_LIB_MAC_SOURCED=1

# Where the kernel publishes interfaces. A variable so tests can point it at a
# temp tree.
_MAC_SYSFS="${_MAC_SYSFS:-/sys/class/net}"

# ── mac_get <iface> ───────────────────────────────────────────────────────────
# Print the interface's current address, lower case, or fail and print nothing.
mac_get() {
    local iface="${1:-}" mac=""
    [[ -n "$iface" && "$iface" != */* && -r "${_MAC_SYSFS}/${iface}/address" ]] || return 1
    read -r mac < "${_MAC_SYSFS}/${iface}/address" || [[ -n "$mac" ]] || return 1
    [[ -n "$mac" ]] || return 1
    printf '%s\n' "${mac,,}"
}

# ── mac_set <iface> <mac> ─────────────────────────────────────────────────────
# Take the link down, set the address, and read it back. The link is left
# DOWN: bringing it up is the caller's, since what "up" needs differs (rfkill,
# a monitor sibling, a network manager told to keep off).
#
# The read-back is the check that matters. A driver can accept the netlink
# request and keep its old address, and the next frame then goes out with the
# address the caller was trying to hide.
#
# Status, with nothing logged, so the caller words the failure:
#   0  the interface now has <mac>
#   1  <mac> is not six colon-separated hex octets
#   2  the link could not be brought down
#   3  the kernel rejected the address
#   4  it was accepted but the interface reports a different address
mac_set() {
    local iface="${1:-}" mac="${2:-}" now
    [[ "$mac" =~ ^[0-9A-Fa-f]{2}(:[0-9A-Fa-f]{2}){5}$ ]] || return 1
    sudo ip link set dev "$iface" down || return 2
    sudo ip link set dev "$iface" address "$mac" || return 3
    now="$(mac_get "$iface")" || return 4
    [[ "$now" == "${mac,,}" ]] || return 4
    return 0
}
