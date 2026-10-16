#!/usr/bin/env bats
# Unit tests for netdev.sh — interface existence, state and wireless phy.
#
# sysfs is a temp tree (_NETDEV_SYSFS) laid out as a Raspberry Pi 4 with its
# onboard radio and two USB adapters publishes it; iw is a shell function
# printing a captured `iw phy info` (brcmfmac, iw 6.x). No hardware needed.

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    TMP="$(mktemp -d)"
    export TMP
    export _NETDEV_SYSFS="${TMP}/sys/class/net"
    local dev="${TMP}/sys/devices"
    mkdir -p "${_NETDEV_SYSFS}"/{eth0,lo,wlan0,wlx9cefd5f7593b} \
             "${dev}/mmc/ieee80211/phy0" "${dev}/usb/ieee80211/phy2"
    echo 0x1003 > "${_NETDEV_SYSFS}/eth0/flags"
    echo 0x9    > "${_NETDEV_SYSFS}/lo/flags"
    echo 0x1003 > "${_NETDEV_SYSFS}/wlan0/flags"
    echo 0x322  > "${_NETDEV_SYSFS}/wlx9cefd5f7593b/flags"   # IFF_UP clear
    ln -s "${dev}/mmc/ieee80211/phy0" "${_NETDEV_SYSFS}/wlan0/phy80211"
    ln -s "${dev}/usb/ieee80211/phy2" "${_NETDEV_SYSFS}/wlx9cefd5f7593b/phy80211"
    # A dangling link, the shape readlink -f would have canonicalised to a phy named phy80211.
    ln -s "${dev}/gone/ieee80211/phy9" "${_NETDEV_SYSFS}/eth0/phy80211"

    # shellcheck disable=SC2317
    iw() {
        [[ "$1" == phy && "$3" == info ]] || return 2
        case "$2" in
            phy0) printf 'Wiphy phy0\n\twiphy index: 0\n\tSupported interface modes:\n\t\t * IBSS\n\t\t * managed\n\t\t * AP\n\t\t * P2P-client\n\t\t * P2P-GO\n\t\t * P2P-device\n\tBand 1:\n\t\tCapabilities: 0x1062\n' ;;
            phy2) printf 'Wiphy phy2\n\tSupported interface modes:\n\t\t * managed\n\t\t * AP\n\t\t * monitor\n\t\t * mesh point\n\tsoftware interface modes (can always be added):\n\t\t * monitor\n\tvalid interface combinations:\n' ;;
            *) echo "command failed: No such device (-19)" >&2; return 255 ;;
        esac
    }
    export -f iw

    # shellcheck source=/dev/null
    . "${LIB}/netdev.sh"
}

teardown() {
    rm -rf -- "$TMP"
}

# Negatives are `run !`: a bare `! cmd` that is not a test's last line never
# fails it (errexit ignores an inverted command).

@test "iface_exists: a sysfs entry, not a path, not a dot, not empty" {
    iface_exists eth0
    iface_exists lo
    run ! iface_exists eth9
    run ! iface_exists ""
    run ! iface_exists "../net/eth0"
    run ! iface_exists "eth0/"
    run ! iface_exists .
    run ! iface_exists ..
}

@test "iface_is_up: IFF_UP from the flags, false when down, absent or unreadable, silent on stderr" {
    iface_is_up eth0
    iface_is_up lo
    iface_is_up wlan0
    run ! iface_is_up wlx9cefd5f7593b
    run ! iface_is_up eth9
    run ! iface_is_up .
    echo garbage > "${_NETDEV_SYSFS}/eth0/flags"
    run ! iface_is_up eth0
    : > "${_NETDEV_SYSFS}/eth0/flags"
    run ! iface_is_up eth0
    # No trailing newline: read returns 1 with the value set.
    printf 0x1003 > "${_NETDEV_SYSFS}/eth0/flags"
    iface_is_up eth0
    printf 0x1002 > "${_NETDEV_SYSFS}/eth0/flags"
    run ! iface_is_up eth0
    # An unreadable flags file (a 0000 file is still readable by root, so a
    # directory in its place) is "not up", with nothing on stderr.
    rm -f "${_NETDEV_SYSFS}/eth0/flags"; mkdir "${_NETDEV_SYSFS}/eth0/flags"
    run --separate-stderr iface_is_up eth0
    [ "$status" -eq 1 ]
    [ -z "$stderr" ]
}

@test "iface_phy: the phy behind a wireless interface; nothing for wired, dangling or absent" {
    [ "$(iface_phy wlan0)" = phy0 ]
    [ "$(iface_phy wlx9cefd5f7593b)" = phy2 ]
    run iface_phy lo
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    # eth0's phy80211 link dangles: readlink -f would print "phy80211" here.
    run iface_phy eth0
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run iface_phy eth9
    [ "$status" -eq 1 ]
}

@test "phy_modes_parse: the modes under the heading, one per line, in iw's order, ending at the next section" {
    run phy_modes_parse <<< "$(iw phy phy0 info)"
    [ "$status" -eq 0 ]
    [ "$output" = $'IBSS\nmanaged\nAP\nP2P-client\nP2P-GO\nP2P-device' ]
    # The software-modes block that follows on mt76 is not read into the list.
    run phy_modes_parse <<< "$(iw phy phy2 info)"
    [ "$output" = $'managed\nAP\nmonitor\nmesh point' ]
    [ -z "$(phy_modes_parse <<< $'Wiphy phy5\n\tBand 1:\n')" ]
}

@test "phy_modes: runs iw for the phy; 1 and nothing when iw fails" {
    [ "$(phy_modes phy2 | paste -sd ' ')" = "managed AP monitor mesh point" ]
    run phy_modes phy7
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "phy_supports_mode: exact mode names, including the two-word one; false on a missing phy" {
    phy_supports_mode phy2 monitor
    phy_supports_mode phy2 "mesh point"
    phy_supports_mode phy0 AP
    run ! phy_supports_mode phy0 monitor
    run ! phy_supports_mode phy2 mesh
    run ! phy_supports_mode phy2 ap
    run ! phy_supports_mode phy7 monitor
}

@test "the brcmfmac onboard radio has no monitor mode, the mt76 adapter does (the platform fact the tools decide on)" {
    phy_supports_mode "$(iface_phy wlx9cefd5f7593b)" monitor
    run ! phy_supports_mode "$(iface_phy wlan0)" monitor
}
