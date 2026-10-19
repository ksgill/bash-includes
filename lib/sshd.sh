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
#    address with the port, and sshd_endpoint_match turns the address into
#    the `ip daddr <a>` / `ip6 daddr <a>` match the rule carries when the
#    address is not a wildcard (0.0.0.0, ::, or *).
#
# And one question a caller that writes such rules has to ask before it
# applies a drop policy: does the SSH session it is running in keep an
# accept rule? sshd_session_covered answers it for a server address and
# port against the endpoints the readers print (the rule the two VPN
# builders each carried as session_covered, FA-fleet-024).
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

# ── sshd_valid_ports ──────────────────────────────────────────────────────────
# stdin: candidate ports, one per line, anything; stdout: the ones that are a
# whole number from 1 to 65535, as plain decimals, sorted and unique. The
# filter every function here ends in; public because a caller that unions
# two sources needs the same one (the VPN builders do; FA-bash-includes-017).
sshd_valid_ports() {
    awk '$1 ~ /^[0-9]+$/ && $1 + 0 >= 1 && $1 + 0 <= 65535 { print $1 + 0 }' | sort -nu
}

# ── sshd_valid_endpoints ──────────────────────────────────────────────────────
# stdin: "<address> <port>" lines; stdout: those whose port is valid, the port
# as a plain decimal, sorted and unique (C collation, so the order is the
# same on every host). The endpoint counterpart of sshd_valid_ports.
sshd_valid_endpoints() {
    awk 'NF == 2 && $2 ~ /^[0-9]+$/ && $2 + 0 >= 1 && $2 + 0 <= 65535 { print $1, $2 + 0 }' | LC_ALL=C sort -u
}

# ── _sshd_split_endpoint <address:port form> ──────────────────────────────────
# stdin: one "<addr>:<port>" per line as sshd -T, systemd and ss print them —
# "0.0.0.0:22", "[::]:22", "*:22" (ss, for an IPv6 any-address socket that
# takes IPv4 too), a bare "22" (systemd's ListenStream=22), and a scoped
# link-local address in each tool's form: sshd -T puts the scope inside the
# brackets, "[fe80::1%eth0]:22"; systemd puts it after the port,
# "[fe80::1]:22%eth0" (systemd.socket(5): "[x]:y%dev"; systemd 259 rejects
# the other form); ss puts it between the bracket and the port,
# "[fe80::1]%eth0:22" (iproute2 ss.c, inet_addr_print: "%s%%%s" after the
# bracketed address, then the ":" delimiter) — stdout: "<address> <port>",
# brackets removed, the scope on the address whichever way it came
# ("fe80::1%eth0 22"), "*" for a bare port. An unbracketed IPv6 or a
# portless address prints nothing: the port cannot be told from the address,
# and none of the tools prints those forms.
_sshd_split_endpoint() {
    awk '
        /^[0-9]+$/ { print "*", $0; next }
        /^\[/ {
            if (match($0, /\]:[0-9]+(%[^ \]]+)?$/)) {
                addr = substr($0, 2, RSTART - 2); port = substr($0, RSTART + 2)
                if ((i = index(port, "%")) > 0) { addr = addr substr(port, i); port = substr(port, 1, i - 1) }
                print addr, port
            } else if (match($0, /\]%[^ :\]]+:[0-9]+$/)) {
                addr = substr($0, 2, RSTART - 2); rest = substr($0, RSTART + 1)
                i = index(rest, ":"); print addr substr(rest, 1, i - 1), substr(rest, i + 1)
            }
            next
        }
        { if (split($0, f, ":") == 2) print f[1], f[2] }'
}

# ── sshd_endpoint_match <family> <address> ────────────────────────────────────
# The nftables match that confines an accept rule to one listener's address:
# rule 2 above, in one place for every consumer that writes `tcp dport`
# rules from an *_endpoints_* reader. <family> is the family of the table the
# rule goes in (inet, ip or ip6); <address> is one as the readers print it.
# Prints the match to put before `tcp dport <port>`, with a trailing space,
# or nothing for a wildcard; the status says whether a rule is due at all:
#
#   0  print what came out, before `tcp dport <port>`:
#      - "" for "*": the listener takes every address of both families
#        (ss prints an IPv6 any-address socket without IPV6_V6ONLY as "*";
#        a bare systemd ListenStream=<port> is one), so the rule is
#        port-wide.
#      - "meta nfproto ipv4 " for 0.0.0.0 in an inet table, "" in an ip
#        one; "meta nfproto ipv6 " for :: (and its spellings
#        0:0:0:0:0:0:0:0, ::ffff:0.0.0.0 is 0.0.0.0) in inet, "" in ip6.
#        An any-address listener of one family is still a wildcard for
#        that family only: a port-wide inet rule for sshd's 0.0.0.0:2222
#        would let a local user's own [::]:2222 (IPV6_V6ONLY, which the
#        kernel allows beside it) be reached from outside, rule 2 again.
#        Every "::" these readers see is IPv6-only: sshd sets IPV6_V6ONLY
#        on its sockets (which is why `sshd -T` prints 0.0.0.0 beside ::),
#        Ubuntu's ssh.socket carries BindIPv6Only=ipv6-only, and ss prints
#        a dual-stack any socket as "*". A socket unit set to
#        BindIPv6Only=both shows "[::]" in Listen= and "*" in ss, and the
#        union of rule 1 carries the "*".
#      - "ip daddr 10.8.0.1 " for an IPv4 address, "ip6 daddr 2001:db8::1 "
#        for an IPv6 one, and for a scoped address the interface in front,
#        'iifname "eth0" ip6 daddr fe80::1 ', since a link-local address is
#        one per link and nft has no scope match. A wildcard with a scope
#        (ss prints a socket bound to a device with SO_BINDTODEVICE as
#        "0.0.0.0%eth0:22" or "[::]%eth0:22") gets the same iifname in
#        front of its family match: that listener takes connections on that
#        link only. (For a VRF master the input hook may see the enslaved
#        port as iifname; the unscoped wildcard that sshd -T and Listen=
#        report for the same listener keeps the port open through the
#        union.) An IPv4-mapped IPv6 address (::ffff:10.8.0.1, how an IPv6
#        socket that takes IPv4 names an IPv4 listener) is matched as the
#        IPv4 address.
#   2  the address, or the family wildcard, cannot be reached through a
#      table of that family (an IPv6 address or :: and family ip; IPv4 or
#      0.0.0.0 and ip6): the caller writes no rule for it there. That is
#      safe: a table of one family never sees the other's packets, so a
#      rule left out of it cannot lock anyone out.
#   1  not an address this function understands (a hostname, a malformed
#      literal, a scope that is not an interface name — an all-digit scope
#      is an interface index, which nft cannot take, and a name with a
#      character outside the class below): nothing printed, and the text
#      must not be pasted into a rule. The fail-safe reading for the caller
#      is a port-wide rule for that port, or no drop policy at all (rule
#      1): dropping the listener would be the lockout direction.
#
# The output is pasted into an nft command by the caller, so the address and
# the interface name are checked against the grammar first, under the C
# locale (a bracket range in another locale matches more than ASCII): dotted
# decimal with four canonical octets 0-255 (no leading zero: glibc rejects
# it and nft would read it another way); eight hexadecimal groups of 1-4
# digits, or fewer with exactly one "::"; an interface name of 1-15
# characters from [A-Za-z0-9_.-] that is not "." or ".." and not all
# digits. Case is kept as given; nft accepts either. Two spellings of one
# address (case, a mapped form beside the plain one) give two rules; a
# caller that minds runs its rule lines through `sort -u`.
sshd_endpoint_match() {
    local LC_ALL=C family="${1:-}" addr="${2:-}" scope="" prefix="" o parts=0
    local h='[0-9A-Fa-f]{1,4}'
    case "${family}" in inet|ip|ip6) ;; *) return 1 ;; esac
    if [[ "${addr}" == *%* ]]; then
        scope="${addr#*%}"; addr="${addr%%%*}"
        [[ "${scope}" =~ ^[A-Za-z0-9_.-]{1,15}$ && "${scope}" != . && "${scope}" != .. ]] || return 1
        [[ ! "${scope}" =~ ^[0-9]+$ ]] || return 1
        prefix="iifname \"${scope}\" "
    fi
    if [[ "${addr}" == '*' ]]; then
        printf '%s\n' "${prefix}"
        return 0
    fi
    # The family wildcards, after the grammar checks below: "" in a table
    # of their own family, a protocol match in inet, 2 in the other family.
    local v4_any='' v6_any=''
    case "${family}" in inet) v4_any='meta nfproto ipv4 '; v6_any='meta nfproto ipv6 ' ;; esac
    # An IPv4-mapped address names an IPv4 listener.
    if [[ "${addr}" =~ ^::[Ff][Ff][Ff][Ff]:([0-9.]+)$ ]]; then
        addr="${BASH_REMATCH[1]}"
    fi
    if [[ "${addr}" =~ ^([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})\.([0-9]{1,3})$ ]]; then
        for o in "${BASH_REMATCH[@]:1:4}"; do
            [[ "${o}" =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( o <= 255 )) || return 1
        done
        [[ "${family}" != ip6 ]] || return 2
        if [[ "${addr}" == 0.0.0.0 ]]; then
            printf '%s%s\n' "${prefix}" "${v4_any}"
            return 0
        fi
        printf '%sip daddr %s \n' "${prefix}" "${addr}"
        return 0
    fi
    if [[ "${addr}" == *::* ]]; then
        [[ "${addr}" =~ ^(${h}(:${h})*)?::(${h}(:${h})*)?$ ]] || return 1
        # Groups present: the "::" stands for at least one, so at most 7.
        o="${addr//::/:}"; o="${o#:}"; o="${o%:}"; parts="${o//:/}"
        [[ -z "${o}" ]] && parts=0 || parts=$(( ${#o} - ${#parts} + 1 ))
        (( parts <= 7 )) || return 1
    else
        [[ "${addr}" =~ ^${h}(:${h}){7}$ ]] || return 1
    fi
    [[ "${family}" != ip ]] || return 2
    if [[ "${addr}" =~ ^[0:]+$ ]]; then
        printf '%s%s\n' "${prefix}" "${v6_any}"
        return 0
    fi
    printf '%sip6 daddr %s \n' "${prefix}" "${addr}"
    return 0
}

# ── _sshd_addr_key <address> ──────────────────────────────────────────────────
# The form two addresses are compared in: a "%scope" removed, an IPv4-mapped
# IPv6 address (::ffff:a.b.c.d) unmapped, hexadecimal digits in lower case.
# SSH_CONNECTION's server address and the readers' listener addresses can
# each carry a scope or the mapped form (sshd prints a dual-stack socket's
# IPv4 peer mapped). Two spellings of one IPv6 address (2001:db8::1 and
# 2001:db8:0:0::1) still compare unequal. Private: sshd_session_covered is
# its caller.
_sshd_addr_key() {
    local LC_ALL=C a="${1%%%*}"
    a="${a,,}"
    if [[ "${a}" =~ ^::ffff:([0-9.]+)$ ]]; then
        a="${BASH_REMATCH[1]}"
    fi
    printf '%s\n' "${a}"
}

# ── sshd_session_covered <server address> <port> <endpoint>... ────────────────
# Whether the SSH session that reached <server address>:<port> keeps an
# accept rule once per-listener rules are written for <endpoint>... (each
# "<address> <port>" as the *_endpoints_* readers print it): 0 when some
# endpoint has that port and an address that covers the server address, 1
# otherwise; nothing is printed. An address covers the session when it is
# the same address (_sshd_addr_key on both), the family wildcard of the
# session's family (0.0.0.0 for IPv4; :: in any spelling for IPv6 — an IPv4
# session is NOT covered by "::", which sshd_endpoint_match treats as
# IPv6-only), "*" (both families), or an address sshd_endpoint_match does
# not understand (a name: its rule is written port-wide). A scoped or
# device-bound listener (fe80::1%eth0, 0.0.0.0%eth0, *%eth0 — its rule
# carries iifname) covers only a session whose own server address carries
# the same %scope, and an unscoped session address never: which interface a
# session came in on is not knowable from its address (the interface
# holding an address is not its ingress), so it is not guessed. A port
# match alone is not enough: with `ListenAddress 10.8.0.1:22` and a session
# on 192.168.1.5:22 (a second server on that port, not sshd's), the only
# rule is `ip daddr 10.8.0.1 tcp dport 22` and the drop would end the
# session. The same test holds one endpoint set against another (a caller's
# address-level agreement check): there <server address> may itself be a
# wildcard, and "*" is covered by "*" or by either family's wildcard (sshd
# binds what the host has; with IPv6 off, "*" shows as 0.0.0.0 alone).
#
# The order: port, then status 1 from sshd_endpoint_match, then the scope
# gate, then "*", the same address, the family wildcard. The family asked of
# sshd_endpoint_match is fixed at inet: only status 1 (not an address) is
# used, and for any valid family that answer is the same; with an empty or
# wrong family every endpoint would read as port-wide and every session as
# covered, which is the lockout direction. An empty server address or a
# port that is not a number is answered 1 (not covered) for the same reason.
sshd_session_covered() {
    local saddr="$1" sport="$2" skey sscope="" v6=false endpoint addr port key rc
    shift 2
    # No answer for no question: an empty address or a port that is not a
    # number would otherwise match an endpoint with no port field, or read
    # as IPv4, and 0 here is the lockout direction.
    [[ -n "${saddr}" && "${sport}" =~ ^[0-9]+$ ]] || return 1
    skey="$(_sshd_addr_key "${saddr}")"
    [[ "${saddr}" != *%* ]] || sscope="${saddr#*%}"
    [[ "${skey}" != *:* ]] || v6=true
    for endpoint in "$@"; do
        read -r addr port <<< "${endpoint}"
        [[ "${port}" == "${sport}" ]] || continue
        # Not an address (a name, a digit scope): its rule is port-wide,
        # which covers whatever address the session came in on.
        rc=0
        sshd_endpoint_match inet "${addr}" > /dev/null || rc=$?
        (( rc != 1 )) || return 0
        key="$(_sshd_addr_key "${addr}")"
        if [[ "${addr}" == *%* ]]; then
            [[ -n "${sscope}" && "${sscope}" == "${addr#*%}" ]] || continue
        fi
        # After the scope: "*%eth0" covers a session on eth0.
        [[ "${key}" != '*' ]] || return 0
        if [[ "${skey}" == '*' ]]; then
            if [[ "${key}" == 0.0.0.0 ]] || [[ "${key}" == *:* && "${key}" =~ ^[0:]+$ ]]; then
                return 0
            fi
            continue
        fi
        [[ "${key}" != "${skey}" ]] || return 0
        if [[ "${v6}" == true ]]; then
            [[ "${key}" != *:* || ! "${key}" =~ ^[0:]+$ ]] || return 0
        else
            [[ "${key}" != 0.0.0.0 ]] || return 0
        fi
        # Left: a scoped rule that is not this address, or an address of
        # the other family (no rule for this session either way).
    done
    return 1
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
    awk '{ print $2 }' <<< "${out}" | sshd_valid_ports
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
        | _sshd_split_endpoint | sshd_valid_endpoints
}

# ── sshd_ports_socket ─────────────────────────────────────────────────────────
# Returns 1 and prints nothing when ssh.socket is not active. Otherwise the
# ports in its Listen=, one per line: `systemctl show -p Listen` prints one
# "<address> (<type>)" per line, "0.0.0.0:22 (Stream)", "[::]:22 (Stream)",
# "[fe80::1]:22%eth0 (Stream)" for a scoped IPv6 address (the scope after
# the port, unlike sshd -T), or a bare "22". The port is the digits after
# the last ':' up to any '%' (or the whole field when it is only digits).
# Only "(Stream)" (TCP) lines count, so a ListenDatagram
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
    awk '{ print $2 }' <<< "${out}" | sshd_valid_ports
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
        | _sshd_split_endpoint | sshd_valid_endpoints
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
# addr:port ("0.0.0.0:22", "[::]:22", "*:22", "[fe80::1]%eth0:22"), Process
# as users:(("<name>",pid=<N>,fd=<M>),...). ss prints <name> unescaped, so a
# name can carry a forged ',pid=<N>,fd=<M>'; a pid counts only when ',fd=<M>'
# is followed by ')', and a name cannot contain ')' (ss reads it from
# /proc/<pid>/stat and stops at the first ')'; iproute2 6.19.0).
# A failing ss prints nothing (and so disagrees with any configured port).
sshd_ports_listening() {
    _sshd_listening_locals "$@" | _sshd_split_endpoint | awk '{ print $2 }' | sshd_valid_ports
}

# ── sshd_endpoints_listening [<ssh.socket port>...] ───────────────────────────
# sshd_ports_listening with the address: "<address> <port>" per line as the
# other *_endpoints_* functions print it, "*" for ss's any-address form. The
# same listeners count, by the same pids.
sshd_endpoints_listening() {
    _sshd_listening_locals "$@" | _sshd_split_endpoint | sshd_valid_endpoints
}

# ── _sshd_listening_locals [<ssh.socket port>...] ─────────────────────────────
# The Local field of every `ss -Htlnp` line that counts as an SSH listener
# (the rule in sshd_ports_listening), one per line, as ss printed it. The
# port is read off the end of the field here only to decide whether pid 1's
# hold is on a socket port; the callers parse the field properly, through
# _sshd_split_endpoint, so a Local form that function does not read drops
# the listener from both the port and the endpoint set: keep the two in
# step (every form ss prints is listed there).
_sshd_listening_locals() {
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
          if (held_by(master)) print $4
          else if (held_by(1) && index(sock, " " p " ")) print $4 }' <<< "${ss_out}"
}
