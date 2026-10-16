#!/usr/bin/env bash
# sshd.sh — the TCP ports SSH is configured for and listening on.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Mechanism only: how to read the ports out of `sshd -T`, out of ssh.socket's
# Listen= and out of `ss -tlnp`, each with its traps. What to do with them —
# open them in a firewall, compare the configured and the listening set,
# leave 22 out, treat a missing sshd as "nothing to open" or as an error — is
# the caller's. Each function prints ports one per line, numeric, sorted and
# unique, and prints nothing for a source that fails; the two that can tell
# "nothing configured" from "could not read" return non-zero for the latter.
# stderr is left alone (sshd -T names the line it rejects): a caller that
# wants silence redirects it.
#
# Two rules for a caller that turns these into firewall rules:
#
# 1. The configured set alone must never drive a drop policy. `sshd -T`
#    reports what the file says, which can name a port sshd does not bind
#    (a ListenAddress whose address is not on the host; a Port changed and
#    sshd not yet restarted; under socket activation sshd binds nothing
#    itself) and can miss one it does (`SSHD_OPTS="-p 2222"` in
#    /etc/default/ssh, or -f/-o in a unit override). Take the union of the
#    configured and the listening set and treat a disagreement as "do not
#    drop yet", which is what the VPN builders do.
#
# 2. A port is not an endpoint. A listener bound to one address
#    (`ListenAddress 10.8.0.1:2222`) must not become `tcp dport 2222
#    accept` for every address: any local user can bind 10.0.0.5:2222
#    alongside it (only the wildcard bind conflicts) and is then reachable
#    from outside on a port the operator thinks is SSH. For ports below 1024
#    that needs root; above, nothing. The *_endpoints_* functions give the
#    address with the port so the rule can carry `ip daddr <a>` / `ip6 daddr
#    <a>` when the address is not a wildcard (0.0.0.0, ::, or *).
#
# Lifted from openvpn-bld, wireguard-bld and sys-bld, which carried three
# readers of the same output (FA-fleet-020).
#
# Depends on: nothing (sudo, sshd, systemctl, ss and awk directly).

[[ -n "${_LIB_SSHD_SOURCED:-}" ]] && return 0
_LIB_SSHD_SOURCED=1

# Whose privileges the commands run with. A variable so tests can take the
# root path without being root (EUID itself is read-only), as mac.sh does.
# Anything but digits falls back to EUID: the value meets `-eq`, which
# evaluates arithmetic, so an environment string like `a[$(cmd)]` would run.
[[ "${_SSHD_EUID:-}" =~ ^[0-9]+$ ]] || _SSHD_EUID="$EUID"

# ── _sshd_root <command...> ───────────────────────────────────────────────────
# Run as root: directly when already root, otherwise through sudo (a script
# that runs whole as root may have no sudo binary at all). The root branch
# adds the sbin directories, where sshd and ss live, because a root shell's
# PATH may lack them while sudo's secure_path always has them.
_sshd_root() {
    if [[ "$_SSHD_EUID" -eq 0 ]]; then
        PATH="${PATH}:/usr/sbin:/sbin" "$@"
    else
        sudo "$@"
    fi
}

# ── _sshd_valid_ports ─────────────────────────────────────────────────────────
# stdin: candidate ports, one per line, anything; stdout: the ones that are a
# whole number from 1 to 65535, as plain decimals, sorted and unique.
_sshd_valid_ports() {
    awk '$1 ~ /^[0-9]+$/ && $1 + 0 >= 1 && $1 + 0 <= 65535 { print $1 + 0 }' | sort -nu
}

# ── _sshd_valid_endpoints ─────────────────────────────────────────────────────
# stdin: "<address> <port>" lines; stdout: those whose port is valid, the port
# as a plain decimal, sorted and unique.
_sshd_valid_endpoints() {
    awk 'NF == 2 && $2 ~ /^[0-9]+$/ && $2 + 0 >= 1 && $2 + 0 <= 65535 { print $1, $2 + 0 }' | LC_ALL=C sort -u
}

# ── _sshd_split_endpoint <address:port form> ──────────────────────────────────
# stdin: one "<addr>:<port>" per line as sshd -T and systemd print them —
# "0.0.0.0:22", "[::]:22", "[fe80::1%eth0]:22", or a bare "22" (systemd's
# ListenStream=22) — stdout: "<address> <port>", brackets removed, "*" for a
# bare port. An unbracketed IPv6 or a portless address prints nothing: the
# port cannot be told from the address, and neither tool prints those forms.
_sshd_split_endpoint() {
    awk '
        /^[0-9]+$/ { print "*", $0; next }
        /^\[/ { if (match($0, /\]:[0-9]+$/)) print substr($0, 2, RSTART - 2), substr($0, RSTART + 2); next }
        { if (split($0, f, ":") == 2) print f[1], f[2] }'
}

# ── sshd_master_pid ───────────────────────────────────────────────────────────
# The pid of the sshd master process: ssh.service's MainPID. Prints nothing
# when the service is not running (systemd reports 0; under socket activation
# ssh.service may be inactive until the first connection) or the value is not
# a pid above 1.
sshd_master_pid() {
    local pid=""
    pid="$(systemctl show -p MainPID --value ssh.service 2>/dev/null)" || pid=""
    if [[ "${pid}" =~ ^[0-9]+$ ]] && (( pid > 1 )); then
        printf '%s\n' "${pid}"
    fi
}

# ── sshd_ports_configured ─────────────────────────────────────────────────────
# The ports sshd's configuration names, from `sshd -T`: sshd's own resolution
# of Include, accumulating Port lines and ListenAddress, which is where a
# re-implementation goes wrong. The ports come from the listenaddress lines
# when there are any, and only then from the port lines: -T prints every
# "listenaddress <addr>:<port>" with the port resolved (a portless
# ListenAddress becomes one line per Port; one with its own port keeps only
# that port) and still prints the global "port N", which sshd then does not
# bind (OpenSSH 10.2p1: `ListenAddress 0.0.0.0:2200` with `Port 2222` reports
# both and binds 2200). IPv6 is bracketed, "[::]:22"; an IPv4 or host form
# carries exactly one ':'; a trailing "rdomain <x>" sits in a later field.
# Returns 1 and prints nothing when sshd -T fails (no sshd, a broken
# config): the caller decides whether that is "nothing to open" or an error.
sshd_ports_configured() {
    local out=""
    out="$(sshd_endpoints_configured)" || return 1
    awk '{ print $2 }' <<< "${out}" | _sshd_valid_ports
}

# ── sshd_endpoints_configured ─────────────────────────────────────────────────
# sshd_ports_configured with the address: "<address> <port>" per line, the
# address as sshd -T prints it without brackets ("0.0.0.0", "::",
# "10.8.0.1", "fe80::1%eth0"), or "*" for a port that comes from a "port"
# line (no listenaddress at all: sshd binds it on every address). Same
# precedence and the same return of 1 when sshd -T fails.
sshd_endpoints_configured() {
    local out=""
    out="$(_sshd_root sshd -T)" || return 1
    awk '
        $1 == "port" { ports[++np] = $2 }
        $1 == "listenaddress" { la = 1; print $2 }
        END { if (!la) for (i = 1; i <= np; i++) print ports[i] }' <<< "${out}" \
        | _sshd_split_endpoint | _sshd_valid_endpoints
}

# ── sshd_ports_socket ─────────────────────────────────────────────────────────
# Returns 1 and prints nothing when ssh.socket is not active. Otherwise the
# ports in its Listen=, one per line: `systemctl show -p Listen` prints one
# "<address> (<type>)" per line, "0.0.0.0:22 (Stream)", "[::]:22 (Stream)",
# "[fe80::1%eth0]:22 (Stream)" for a scoped IPv6 address, or a bare "22".
# The port is the digits after the last ':' (or the whole field when it is
# only digits). Only "(Stream)" (TCP) lines count, so a ListenDatagram
# cannot add a port; a unix socket path ("/run/x.sock", or "@name" for an
# abstract one) is skipped by its first character, since a path may end in
# ":<digits>" too.
# Socket activation is the Ubuntu 24.04+ default; Ubuntu's
# sshd-socket-generator rewrites the socket's Listen= from sshd_config at
# every daemon-reload, so after a port change the two sources agree only once
# that has run.
sshd_ports_socket() {
    local out=""
    out="$(sshd_endpoints_socket)" || return 1
    awk '{ print $2 }' <<< "${out}" | _sshd_valid_ports
}

# ── sshd_endpoints_socket ─────────────────────────────────────────────────────
# sshd_ports_socket with the address: "<address> <port>" per line, brackets
# removed, "*" for a bare port (ListenStream=22 shows as "[::]:22" once
# systemd has normalised it, so "*" is rare). Returns 1 when ssh.socket is
# not active.
sshd_endpoints_socket() {
    local listen=""
    systemctl is-active --quiet ssh.socket 2>/dev/null || return 1
    listen="$(systemctl show ssh.socket -p Listen --value 2>/dev/null)" || listen=""
    awk '$NF == "(Stream)" && $1 !~ /^[\/@]/ { print $1 }' <<< "${listen}" \
        | _sshd_split_endpoint | _sshd_valid_endpoints
}

# ── sshd_ports_listening [<ssh.socket port>...] ───────────────────────────────
# The TCP ports actually listened on for SSH, from `ss -Htlnp`: a listener
# counts only when the sshd master (sshd_master_pid) holds it, or when pid 1
# holds it on one of the ssh.socket ports given as arguments (pid 1 holds the
# listeners of every socket unit, not just ssh.socket's). Matched by pid,
# never by process name: any local user can name a process "sshd"
# (PR_SET_NAME) and listen on a high port, and before OpenSSH 9.8 every
# per-session process is named sshd too, so its X11 and 'ssh -R' forwarding
# listeners would count.
# Each ss line is "State Recv-Q Send-Q Local Peer Process", Local as
# addr:port ("0.0.0.0:22", "[::]:22", "*:22"), Process as
# users:(("<name>",pid=<N>,fd=<M>),...). ss prints <name> unescaped, so a
# name can carry a forged ',pid=<N>,fd=<M>'; a pid counts only when ',fd=<M>'
# is followed by ')', and a name cannot contain ')' (ss reads it from
# /proc/<pid>/stat and stops at the first ')'; iproute2 6.19.0).
# A failing ss prints nothing (and so disagrees with any configured port).
sshd_ports_listening() {
    # IFS is local so "$*" joins the socket ports with a space whatever the
    # caller set it to; the awk index() below depends on that.
    local master="" ss_out="" IFS=' '
    master="$(sshd_master_pid)"
    ss_out="$(_sshd_root ss -Htlnp)" || ss_out=""
    awk -v sock=" $* " -v master="${master}" '
        function held_by(pid) { return pid != "" && $0 ~ (",pid=" pid ",fd=[0-9]+\\)") }
        { a = $4; sub(/.*:/, "", a)
          if (a !~ /^[0-9]+$/ || a + 0 < 1 || a + 0 > 65535) next
          p = a + 0
          if (held_by(master)) print p
          else if (held_by(1) && index(sock, " " p " ")) print p }' <<< "${ss_out}" \
        | _sshd_valid_ports
}
