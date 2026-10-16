#!/usr/bin/env bash
# netdev.sh — a network interface's existence, state and wireless phy.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Mechanism only, read from sysfs and `iw`: nothing here changes an
# interface. Every function prints to stdout (or nothing) and logs nothing,
# so it is safe inside $(...). Not named iface.sh: bld resolves an include by
# file name with the consumer's own lib/ first, and wifi-cap-test has a
# lib/iface.sh of its own.
#
# Lifted from sys-tools, wifi-tools, open-wifi-scanner and wifi-cap-test,
# which carried the same sysfs tests and two parses of `iw phy info`
# (FA-fleet-021).
#
# Depends on: nothing (sysfs and iw directly).

[[ -n "${_LIB_NETDEV_SOURCED:-}" ]] && return 0
_LIB_NETDEV_SOURCED=1

# Where the kernel publishes interfaces. A variable so tests can point it at a
# temp tree.
_NETDEV_SYSFS="${_NETDEV_SYSFS:-/sys/class/net}"

# ── iface_exists <iface> ──────────────────────────────────────────────────────
# True when the kernel has an interface of that name. A name with a '/', or
# '.' or '..', is refused rather than looked up as a path (the sysfs directory
# itself would answer yes to both dots).
iface_exists() {
    [[ -n "${1:-}" && "$1" != */* && "$1" != . && "$1" != .. && -d "${_NETDEV_SYSFS}/${1}" ]]
}

# ── iface_is_up <iface> ───────────────────────────────────────────────────────
# True when the interface is administratively up (IFF_UP in its flags). That
# is `ip link set up`, not carrier: a cable-less port and a Wi-Fi interface
# with no association are "up" too. False when it is down, does not exist,
# or its flags cannot be read.
iface_is_up() {
    local flags=""
    iface_exists "${1:-}" || return 1
    # The group so the open error is silenced too (a redirection on `read`
    # alone applies after the file has been opened); `|| -n` keeps a file
    # with no trailing newline, where read returns 1 with the value set.
    { read -r flags < "${_NETDEV_SYSFS}/${1}/flags"; } 2>/dev/null || [[ -n "$flags" ]] || return 1
    [[ "$flags" =~ ^0x[0-9a-fA-F]+$ ]] || return 1
    (( flags & 0x1 ))
}

# ── iface_phy <iface> ─────────────────────────────────────────────────────────
# Print the phy (phy0, phy2) behind a wireless interface; fail and print
# nothing for a wired one. The presence of the phy80211 link is the
# definitive wireless test: `iw dev <iface> info` also works but shells out
# and prints to stderr on failure. readlink -e, not -f: -f canonicalises a
# path whose final component does not exist and still exits 0, so every
# wired interface would report a phy named "phy80211".
iface_phy() {
    local link=""
    iface_exists "${1:-}" || return 1
    link="$(readlink -e "${_NETDEV_SYSFS}/${1}/phy80211" 2>/dev/null)" || return 1
    [[ -n "$link" ]] || return 1
    printf '%s\n' "${link##*/}"
}

# ── phy_modes_parse ───────────────────────────────────────────────────────────
# stdin: the output of `iw phy <phy> info`; stdout: the interface modes under
# "Supported interface modes:" (managed, AP, monitor, mesh point, ...), one
# per line, in iw's order. The block is the lines "\t\t * <mode>" that follow
# the heading; the first line of any other shape ends it.
# awk, not grep: grep does not expand \t in its pattern, so the obvious
# '^\t\t \* monitor$' matches nothing and every adapter looks
# capture-incapable, a trap already hit once.
phy_modes_parse() {
    awk '
        /Supported interface modes:/ { grab = 1; next }
        grab && /^\t\t \* / { sub(/^\t\t \* /, ""); print; next }
        grab { exit }
    '
}

# ── phy_modes <phy> ───────────────────────────────────────────────────────────
# The modes a phy supports, one per line (phy_modes_parse over `iw phy <phy>
# info`). Returns 1 and prints nothing when iw fails (no such phy, no iw).
phy_modes() {
    local info=""
    info="$(iw phy "${1:-}" info 2>/dev/null)" || return 1
    phy_modes_parse <<< "$info"
}

# ── phy_supports_mode <phy> <mode> ────────────────────────────────────────────
# True when the phy lists <mode> (exact, as iw spells it: "monitor", "AP",
# "mesh point"). False when it does not, or iw fails.
phy_supports_mode() {
    local mode=""
    while IFS= read -r mode; do
        [[ "$mode" == "${2:-}" ]] && return 0
    done < <(phy_modes "${1:-}")
    return 1
}
