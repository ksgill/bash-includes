#!/usr/bin/env bats
# Unit tests for sshd.sh — the SSH ports from sshd -T, ssh.socket and ss.
#
# sshd, systemctl and ss are shell functions fed by files in a temp tree, and
# sudo runs the command as the caller, so nothing here needs root or an sshd.
# The fixtures are real output: `sshd -T` from OpenSSH 10.2p1, `systemctl
# show -p Listen` and `ss -Htlnp` (iproute2 6.19.0) from an Ubuntu 26.04.1
# host under socket activation.

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    TMP="$(mktemp -d)"
    export TMP

    # shellcheck disable=SC2317
    sudo() { case "${1:-}" in -v|-n) shift ;; esac; [[ $# -eq 0 ]] && return 0; "$@"; }
    # shellcheck disable=SC2317
    sshd() { [[ "${1:-}" == -T ]] || return 2; [[ -f "${TMP}/sshd-T" ]] || { echo "/etc/ssh/sshd_config line 9: Bad configuration option: Prot" >&2; return 255; }; cat "${TMP}/sshd-T"; }
    # shellcheck disable=SC2317
    systemctl() {
        case "$*" in
            "is-active --quiet ssh.socket") [[ -f "${TMP}/socket-active" ]] ;;
            "show ssh.socket -p Listen --value") cat "${TMP}/socket-listen" ;;
            "show -p MainPID --value ssh.service") cat "${TMP}/mainpid" ;;
            *) echo "unexpected systemctl $*" >&2; return 1 ;;
        esac
    }
    # shellcheck disable=SC2317
    ss() { [[ "$*" == "-Htlnp" ]] || return 2; [[ -f "${TMP}/ss" ]] || return 1; cat "${TMP}/ss"; }
    export -f sudo sshd systemctl ss

    printf 'port 22\nlistenaddress [::]:22\nlistenaddress 0.0.0.0:22\n' > "${TMP}/sshd-T"
    printf '0.0.0.0:22 (Stream)\n' > "${TMP}/socket-listen"
    echo 10950 > "${TMP}/mainpid"
    : > "${TMP}/socket-active"
    cat > "${TMP}/ss" <<'EOF'
LISTEN 0      4096      127.0.0.54:53 0.0.0.0:* users:(("systemd-resolve",pid=602,fd=19))
LISTEN 0      4096         0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=10950,fd=3),("systemd",pid=1,fd=78))
LISTEN 0      4096   127.0.0.53%lo:53 0.0.0.0:* users:(("systemd-resolve",pid=602,fd=17))
EOF

    # shellcheck source=/dev/null
    . "${LIB}/sshd.sh"
}

teardown() {
    rm -rf -- "$TMP"
}

# ── sshd_valid_ports / sshd_valid_endpoints ──────────────────────────────────

@test "sshd_valid_ports keeps 1-65535 as plain decimals, sorted and unique, and drops the rest" {
    run sshd_valid_ports <<< $'22\n0022\n65535\n65536\n0\n-5\n2a\n\n22\n 80\n443 x'
    [ "$status" -eq 0 ]
    [ "$output" = $'22\n80\n443\n65535' ]
}

@test "sshd_valid_endpoints keeps address-port pairs with a valid port, the port decimal, sorted once each" {
    run sshd_valid_endpoints <<< $'10.8.0.1 0022\n* 22\n:: 65536\nfe80::1%eth0 2201\n10.8.0.1 22\nbare\na b c\n0.0.0.0 0'
    [ "$status" -eq 0 ]
    [ "$output" = $'* 22\n10.8.0.1 22\nfe80::1%eth0 2201' ]
}

# ── _sshd_split_endpoint ──────────────────────────────────────────────────────

@test "_sshd_split_endpoint: the three tools' forms, scope kept on the address; unbracketed IPv6 and portless lines dropped" {
    run _sshd_split_endpoint <<< $'0.0.0.0:22\n[::]:22\n*:2224\n2225\n[fe80::1%eth0]:2201\n[fe80::1]:2202%eth0\n[fe80::1]%eth0:2203\n127.0.0.53%lo:53\nfe80::1:2204\n[::1]'
    [ "$status" -eq 0 ]
    [ "$output" = $'0.0.0.0 22\n:: 22\n* 2224\n* 2225\nfe80::1%eth0 2201\nfe80::1%eth0 2202\nfe80::1%eth0 2203\n127.0.0.53%lo 53' ]
}

# ── sshd_endpoint_match ───────────────────────────────────────────────────────

@test "sshd_endpoint_match: nothing for *, a family wildcard is port-wide in its own family and nfproto in inet; daddr for an address, iifname for a scope" {
    for fam in inet ip ip6; do
        run sshd_endpoint_match "$fam" '*'
        [ "$status" -eq 0 ]
        [ -z "$output" ]
    done
    [ -z "$(sshd_endpoint_match ip 0.0.0.0)" ]
    [ "$(sshd_endpoint_match inet 0.0.0.0)" = "meta nfproto ipv4 " ]
    [ -z "$(sshd_endpoint_match ip6 ::)" ]
    [ "$(sshd_endpoint_match inet ::)" = "meta nfproto ipv6 " ]
    [ "$(sshd_endpoint_match inet 10.8.0.1)" = "ip daddr 10.8.0.1 " ]
    [ "$(sshd_endpoint_match ip 10.8.0.1)" = "ip daddr 10.8.0.1 " ]
    [ "$(sshd_endpoint_match inet 2001:db8::1)" = "ip6 daddr 2001:db8::1 " ]
    [ "$(sshd_endpoint_match ip6 2001:db8::1)" = "ip6 daddr 2001:db8::1 " ]
    [ "$(sshd_endpoint_match inet fe80::1%eth0)" = 'iifname "eth0" ip6 daddr fe80::1 ' ]
    [ "$(sshd_endpoint_match ip 127.0.0.53%lo)" = 'iifname "lo" ip daddr 127.0.0.53 ' ]
    # An IPv4-mapped address names an IPv4 listener.
    [ "$(sshd_endpoint_match inet ::ffff:10.8.0.1)" = "ip daddr 10.8.0.1 " ]
    [ "$(sshd_endpoint_match ip ::FFFF:10.8.0.1)" = "ip daddr 10.8.0.1 " ]
    # Every spelling of the any-address is a wildcard; with a scope (a
    # socket bound to a device) the interface alone is the match.
    [ "$(sshd_endpoint_match inet 0:0:0:0:0:0:0:0)" = "meta nfproto ipv6 " ]
    [ "$(sshd_endpoint_match inet '0000::')" = "meta nfproto ipv6 " ]
    [ "$(sshd_endpoint_match inet ::ffff:0.0.0.0)" = "meta nfproto ipv4 " ]
    [ -z "$(sshd_endpoint_match ip ::ffff:0.0.0.0)" ]
    [ "$(sshd_endpoint_match inet '0.0.0.0%eth0')" = 'iifname "eth0" meta nfproto ipv4 ' ]
    [ "$(sshd_endpoint_match ip '0.0.0.0%eth0')" = 'iifname "eth0" ' ]
    [ "$(sshd_endpoint_match inet '::%eth0')" = 'iifname "eth0" meta nfproto ipv6 ' ]
    [ "$(sshd_endpoint_match ip6 '*%eth0')" = 'iifname "eth0" ' ]
    # Full and uppercase forms pass as given; the output is one line.
    [ "$(sshd_endpoint_match inet 1:2:3:4:5:6:7:8)" = "ip6 daddr 1:2:3:4:5:6:7:8 " ]
    [ "$(sshd_endpoint_match inet 2001:DB8::ABCD)" = "ip6 daddr 2001:DB8::ABCD " ]
    [ "$(sshd_endpoint_match inet 1:2:3:4:5:6:7::)" = "ip6 daddr 1:2:3:4:5:6:7:: " ]
    [ "$(sshd_endpoint_match inet 10.8.0.1 | wc -l)" -eq 1 ]
}

@test "sshd_endpoint_match: 2 for an address the family cannot reach, 1 for what is not an address, nothing printed either way" {
    run sshd_endpoint_match ip 2001:db8::1
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    run sshd_endpoint_match ip6 10.8.0.1
    [ "$status" -eq 2 ]
    [ -z "$output" ]
    run sshd_endpoint_match ip6 ::ffff:10.8.0.1
    [ "$status" -eq 2 ]
    # A family wildcard is unreachable through the other family's table too.
    for a in 0.0.0.0 '0.0.0.0%eth0' ::ffff:0.0.0.0; do
        run sshd_endpoint_match ip6 "$a"
        [ "$status" -eq 2 ]
        [ -z "$output" ]
    done
    for a in :: 0:0:0:0:0:0:0:0 '::%eth0'; do
        run sshd_endpoint_match ip "$a"
        [ "$status" -eq 2 ]
        [ -z "$output" ]
    done
    for bad in host.example 10.8.0.256 10.8.0 010.8.0.1 1.2.3.04 '10.8.0.1 ' 2001:db8:::1 '2001::db8::1' ':' ':1' '1:' '12345::1' 1:2:3:4:5:6:7:8:9 1:2:3:4:5:6:7::8 1:2:3:4:5:6:7 'fe80::1%' 'fe80::1%.' 'fe80::1%..' 'fe80::1%2' 'fe80::1%eth0;x' 'fe80::1%0123456789abcdef' 'fe80::1%eth0%x' '2001:db8::1 accept' ''; do
        run sshd_endpoint_match inet "$bad"
        [ "$status" -eq 1 ]
        [ -z "$output" ]
    done
    run sshd_endpoint_match bridge 10.8.0.1
    [ "$status" -eq 1 ]
    # Checked under the C locale whatever the caller's: a bracket range in a
    # UTF-8 locale would let a superscript digit through.
    local loc
    loc="$(locale -a 2>/dev/null | grep -ix 'en_US.utf8\|C.utf8' | head -1)" || loc=""
    if [[ -n "$loc" ]]; then
        run env LC_ALL="$loc" bash -c ". '${LIB}/sshd.sh'; sshd_endpoint_match inet 'fe80::²'; echo \"rc=\$?\"; sshd_endpoint_match inet '1.2.3.4%eth²'; echo \"rc=\$?\""
        [ "$output" = $'rc=1\nrc=1' ]
    fi
}

# ── sshd_master_pid ───────────────────────────────────────────────────────────

@test "sshd_master_pid prints MainPID, nothing for 0, 1, empty or garbage" {
    [ "$(sshd_master_pid)" = 10950 ]
    echo 0 > "${TMP}/mainpid";   [ -z "$(sshd_master_pid)" ]
    echo 1 > "${TMP}/mainpid";   [ -z "$(sshd_master_pid)" ]
    : > "${TMP}/mainpid";        [ -z "$(sshd_master_pid)" ]
    echo abc > "${TMP}/mainpid"; [ -z "$(sshd_master_pid)" ]
}

# ── sshd_ports_configured ─────────────────────────────────────────────────────

@test "sshd_ports_configured: the listenaddress ports, bracketed IPv6 included, once each" {
    run sshd_ports_configured
    [ "$status" -eq 0 ]
    [ "$output" = 22 ]
}

@test "sshd_ports_configured: listenaddress wins over port when both are present (sshd binds only the former)" {
    printf 'port 2222\nlistenaddress 0.0.0.0:2200\nlistenaddress [::1]:2201 rdomain x\n' > "${TMP}/sshd-T"
    [ "$(sshd_ports_configured | paste -sd ' ')" = "2200 2201" ]
}

@test "sshd_ports_configured: without listenaddress, every port line counts" {
    printf 'port 22\nport 2222\nport 2222\nport 70000\n' > "${TMP}/sshd-T"
    [ "$(sshd_ports_configured | paste -sd ' ')" = "22 2222" ]
}

@test "sshd_ports_configured: a listenaddress without a port, or an unbracketed IPv6, yields nothing rather than a guess" {
    printf 'port 22\nlistenaddress 10.0.0.1\nlistenaddress ::1\nlistenaddress fe80::1:22\n' > "${TMP}/sshd-T"
    [ -z "$(sshd_ports_configured)" ]
}

@test "sshd_endpoints_configured: the address with the port, brackets off, * for a port line" {
    [ "$(sshd_endpoints_configured | paste -sd '|')" = "0.0.0.0 22|:: 22" ]
    printf 'port 2222\nlistenaddress 10.8.0.1:2200\nlistenaddress [fe80::1%%eth0]:2201 rdomain x\nlistenaddress 0.0.0.0:2200\n' > "${TMP}/sshd-T"
    [ "$(sshd_endpoints_configured | paste -sd '|')" = "0.0.0.0 2200|10.8.0.1 2200|fe80::1%eth0 2201" ]
    [ "$(sshd_ports_configured | paste -sd ' ')" = "2200 2201" ]
    printf 'port 22\nport 2222\n' > "${TMP}/sshd-T"
    [ "$(sshd_endpoints_configured | paste -sd '|')" = "* 22|* 2222" ]
    rm -f "${TMP}/sshd-T"
    run --separate-stderr sshd_endpoints_configured
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "sshd_ports_configured: a failing sshd -T returns 1 and prints nothing on stdout, its stderr passed through" {
    rm -f "${TMP}/sshd-T"
    run --separate-stderr sshd_ports_configured
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    [[ "$stderr" == *"Bad configuration option"* ]]
}

@test "_sshd_root: through sudo when not root" {
    [ "$_SSHD_EUID" = "$EUID" ]
    local calls="${TMP}/calls"
    # shellcheck disable=SC2317
    sudo() { echo "sudo $*" >> "$calls"; "$@"; }
    export -f sudo
    _SSHD_EUID=1000
    [ "$(sshd_ports_configured)" = 22 ]
    sshd_ports_listening 22 >/dev/null
    [ "$(cat "$calls")" = $'sudo sshd -T\nsudo ss -Htlnp' ]
}

@test "_sshd_root: directly when already root, never touching sudo, with the sbin directories on PATH" {
    # shellcheck disable=SC2317
    sudo() { echo SUDO-CALLED >&2; return 99; }
    export -f sudo
    _SSHD_EUID=0
    run --separate-stderr sshd_ports_configured
    [ "$status" -eq 0 ]
    [ "$output" = 22 ]
    [ -z "$stderr" ]
    [ "$(sshd_ports_listening 22)" = 22 ]
    # The root branch's PATH carries the sbin directories (sshd, ss live there).
    # shellcheck disable=SC2317
    sshd() { printf '%s\n' "$PATH"; }
    export -f sshd
    [[ "$(_sshd_root sshd -T)" == *":/usr/sbin:/sbin" ]]
}

# ── sshd_ports_socket ─────────────────────────────────────────────────────────

@test "sshd_ports_socket: the Stream ports of an active ssh.socket, scope suffix stripped; nothing and 1 when inactive" {
    [ "$(sshd_ports_socket)" = 22 ]
    printf '[::]:2222 (Stream)\n[fe80::1]:2223%%eth0 (Stream)\n2224 (Stream)\n0.0.0.0:514 (Datagram)\n/run/x.sock (Stream)\n/run/odd:5 (Stream)\n@abstract:7 (Stream)\n' > "${TMP}/socket-listen"
    [ "$(sshd_ports_socket | paste -sd ' ')" = "2222 2223 2224" ]
    [ "$(sshd_endpoints_socket | paste -sd '|')" = "* 2224|:: 2222|fe80::1%eth0 2223" ]
    rm -f "${TMP}/socket-active"
    run sshd_ports_socket
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run sshd_endpoints_socket
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

@test "_SSHD_EUID: anything but digits from the environment falls back to EUID (it meets -eq, which is arithmetic)" {
    local out
    out="$(_SSHD_EUID='a[$(echo INJECTED >&2)]' bash -c '. "'"${LIB}"'/sshd.sh"; printf %s "$_SSHD_EUID"' 2>&1)"
    [ "$out" = "$EUID" ]
    out="$(_SSHD_EUID='' bash -c '. "'"${LIB}"'/sshd.sh"; printf %s "$_SSHD_EUID"')"
    [ "$out" = "$EUID" ]
    out="$(_SSHD_EUID=0 bash -c '. "'"${LIB}"'/sshd.sh"; printf %s "$_SSHD_EUID"')"
    [ "$out" = 0 ]
}

# ── sshd_ports_listening ──────────────────────────────────────────────────────

@test "sshd_ports_listening: a listener counts when the sshd master holds it, or pid 1 on an ssh.socket port" {
    [ "$(sshd_ports_listening 22)" = 22 ]
    # Without the socket port argument, pid 1's hold does not count, but the master's still does.
    [ "$(sshd_ports_listening)" = 22 ]
    cat > "${TMP}/ss" <<'EOF'
LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("systemd",pid=1,fd=78))
LISTEN 0 4096 0.0.0.0:2222 0.0.0.0:* users:(("sshd",pid=10950,fd=3))
LISTEN 0 4096 [::]:2223 [::]:* users:(("systemd",pid=1,fd=79))
LISTEN 0 4096 *:2224 *:* users:(("systemd",pid=1,fd=80))
EOF
    [ "$(sshd_ports_listening 22 2223 | paste -sd ' ')" = "22 2222 2223" ]
    [ "$(sshd_ports_listening | paste -sd ' ')" = "2222" ]
    [ "$(sshd_endpoints_listening 22 2223 | paste -sd '|')" = "0.0.0.0 22|0.0.0.0 2222|:: 2223" ]
    [ "$(sshd_endpoints_listening 22 2223 2224 | paste -sd '|')" = "* 2224|0.0.0.0 22|0.0.0.0 2222|:: 2223" ]
    [ "$(sshd_endpoints_listening | paste -sd '|')" = "0.0.0.0 2222" ]
    # The socket ports are joined with a space whatever the caller's IFS.
    [ "$(IFS=$'\n'; sshd_ports_listening 22 2223 | paste -sd ' ')" = "22 2222 2223" ]
}

@test "sshd_ports_listening: matched by pid, never by name — a process named sshd, or a forged pid in a name, does not count" {
    cat > "${TMP}/ss" <<'EOF'
LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=10950,fd=3))
LISTEN 0 4096 0.0.0.0:6010 0.0.0.0:* users:(("sshd",pid=20000,fd=9))
LISTEN 0 4096 0.0.0.0:4444 0.0.0.0:* users:(("evil,pid=10950,fd=3",pid=30000,fd=4))
LISTEN 0 4096 0.0.0.0:4445 0.0.0.0:* users:(("x",pid=1,fd=5))
EOF
    [ "$(sshd_ports_listening 22 | paste -sd ' ')" = "22" ]
    [ "$(sshd_endpoints_listening 22 | paste -sd '|')" = "0.0.0.0 22" ]
    # ss's scoped and device-bound forms come through with the scope on the address.
    printf 'LISTEN 0 4096 [fe80::1]%%eth0:2222 [::]:* users:(("sshd",pid=10950,fd=3))\nLISTEN 0 4096 0.0.0.0%%eth1:2223 0.0.0.0:* users:(("sshd",pid=10950,fd=4))\n' > "${TMP}/ss"
    [ "$(sshd_endpoints_listening | paste -sd '|')" = "0.0.0.0%eth1 2223|fe80::1%eth0 2222" ]
    [ "$(sshd_ports_listening | paste -sd ' ')" = "2222 2223" ]
    printf 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=10950,fd=3))\nLISTEN 0 4096 0.0.0.0:4445 0.0.0.0:* users:(("x",pid=1,fd=5))\n' > "${TMP}/ss"
    # A newline in a process name splits ss's line. The fragment can carry
    # anything the namer wrote except ')' (ss stops reading the name there),
    # so a forged ",pid=<master>,fd=3" in it is never followed by the ')'
    # the match needs, and the real pid on the line is the namer's.
    printf 'LISTEN 0 4096 0.0.0.0:22 0.0.0.0:* users:(("sshd",pid=10950,fd=3))\nLISTEN 0 4096 0.0.0.0:4446 0.0.0.0:* users:(("y\nA B C :4447 users:(("sshd",pid=10950,fd=3",pid=40000,fd=6))\n' > "${TMP}/ss"
    [ "$(sshd_ports_listening 22 | paste -sd ' ')" = "22" ]
}

@test "sshd_ports_listening: no master (service inactive) counts only pid 1 on socket ports; a failing ss prints nothing" {
    echo 0 > "${TMP}/mainpid"
    [ "$(sshd_ports_listening 22)" = 22 ]
    [ -z "$(sshd_ports_listening)" ]
    rm -f "${TMP}/ss"
    run sshd_ports_listening 22
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}
