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

# ── _sshd_valid_ports ─────────────────────────────────────────────────────────

@test "_sshd_valid_ports keeps 1-65535 as plain decimals, sorted and unique, and drops the rest" {
    run _sshd_valid_ports <<< $'22\n0022\n65535\n65536\n0\n-5\n2a\n\n22\n 80\n443 x'
    [ "$status" -eq 0 ]
    [ "$output" = $'22\n80\n443\n65535' ]
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
    printf '[::]:2222 (Stream)\n[fe80::1%%eth0]:2223 (Stream)\n2224 (Stream)\n0.0.0.0:514 (Datagram)\n/run/x.sock (Stream)\n/run/odd:5 (Stream)\n@abstract:7 (Stream)\n' > "${TMP}/socket-listen"
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
