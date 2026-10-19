#!/usr/bin/env bash
# nftchain.sh — a hook's own nft chains: fresh at start, found and removed at
# stop, and the forward base chain's policy.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Mechanism only, for the root-run firewall hooks the VPN builders install
# (CONVENTIONS §9): the four nft sequences both hooks carried, each with its
# own messages, its own choice of warn or die, and in one of them a fix the
# other never got (FA-fleet-024). Every function here runs nft, prints a
# status token (or handles) on stdout and returns a status; it logs nothing,
# names no chain of its own and decides nothing about what a failure means.
# What a `flushed` chain or a refused flip is worth — a WARN, a fatal start,
# an entry in a list reported at the end — stays in the hook, in a `case`
# on the token.
#
# Contract for the hooks that include it:
#   - This file includes nft.sh (for the jq programs) and nothing else: no
#     log.sh, so no logging and no die, and no umask. A hook that includes
#     only log.sh and nft.sh today can include this too.
#   - Nothing runs at source time. The file defines functions and nothing
#     else, so a hook that pins PATH as "the first command after the
#     library" (wg-firewall.sh) keeps that property with this file inlined.
#   - Names reach nft as the caller gives them; the hooks' names are their
#     own (the settings header), never read from the ruleset. The one thing
#     read from the ruleset that is printed back — the other users of the
#     forward hook — comes out of the jq program with control characters
#     already replaced.
#   - nft's stderr passes through for the commands that change something
#     (add, flush, delete, policy), so the unit's journal shows nft's own
#     reason beside the hook's message; the probes (`nft list chain`,
#     `nft -j list chains`) are silenced, since their failure is the
#     answer. The one exception is the flush inside nft_delete_chain,
#     silenced because the delete that follows reports the same cause.
#   - A missing jq is one of the ways a listing fails (status 1, no word of
#     its own): a hook that wants to name it keeps its own `command -v jq`
#     check before calling.
#
#   nft_chain_fresh <family> <table> <chain>
#     The hook's own regular chain, empty: added and then flushed whatever
#     its state, since `nft add chain` on an existing chain succeeds and the
#     rules then added would sit behind the old ones. A chain that existed
#     at start was left by a stop whose down action could not delete it;
#     `flushed` is printed so the hook can say so, `created` otherwise. 1
#     when nft refused the add or the flush.
#
#   nft_jump_handles <family> <table> <base> <target>
#     The handle of every rule in <base> that jumps or goes to <target>,
#     numeric, one per line, from the JSON listing (`nft -j -a list chain`
#     and _NFT_JUMP_HANDLES_JQ): the text listing can be forged by a rule
#     comment. Only a number is ever printed, because the caller pastes
#     each handle into `nft delete rule … handle N`. 1 when the listing or
#     jq failed (the up action dies on that; the down action takes it for
#     nothing to delete); 2, after the numeric handles, when any handle was
#     not a number — the offending value is not reported, only that there
#     was one. Status 2 comes with handles on stdout, so a caller reads
#     `handles="$(nft_jump_handles …)"; rc=$?` and acts on both; the
#     `|| handles=""` form would throw the valid ones away. A jump inside a
#     verdict map is not seen.
#
#   nft_delete_chain <family> <table> <chain>
#     Flush and delete the chain; `deleted` when the delete went through,
#     `absent` when it was refused and the chain is not there, 1 when it is
#     still there (a rule still jumps to it: the jumps go first, by handle;
#     or nft cannot say). A refused flush is not reported on its own: the
#     delete then fails and says so.
#
#   nft_forward_drop <family> <table>
#     The forward base chain of the hook's filter table, and its policy.
#     Forwarding is on for a VPN, so a forward chain at policy accept makes
#     the host a router for anything on the LAN; the hook wants drop, and
#     gets it unless any other base chain is on the forward hook (another
#     table: LXD, libvirt; or the same one: iptables-nft's FORWARD for
#     Docker), since a packet dropped by any base chain on a hook is
#     dropped and the hook's drop would cut their traffic too. Read from
#     `nft -j list chains` with _NFT_FWD_OTHERS_JQ and _NFT_POLICY_JQ, never
#     the text listing. A missing chain is created `type filter hook
#     forward priority 0`. One line on stdout says what happened:
#
#       unread                  the listing could not be read as JSON (nft,
#                               jq, or an answer that is none of the four
#                               below); nothing was checked or changed, and
#                               a missing forward chain was created at
#                               policy accept
#       created-drop            the chain was missing, nothing else is on
#                               the hook: created with policy drop
#       created-accept <others> the chain was missing, <others> are on the
#                               hook: created with policy accept
#       drop-failed missing     the drop create was refused; the chain is
#                               still missing
#       flipped                 the policy was accept, nothing else on the
#                               hook: set to drop
#       drop-failed accept      that flip was refused; it is still accept
#       kept <others>           left at accept because of <others>
#       drop                    already drop; nothing done
#       not-base                a chain named forward exists but is not a
#                               base chain on the forward hook (a regular
#                               chain, or one hooked on input): its policy
#                               is not the forward policy and was not
#                               touched; whether the start goes on is the
#                               hook's call
#
#     Returns 1, with no token, only when a policy-accept create failed (in
#     the unread and the created-accept case), which both hooks treat as
#     fatal. Every other outcome returns 0 with its token; a refused drop is
#     a token, not a failure, since forward is then no more open than it
#     was.
#
# Depends on: nft.sh (the caller runs nft and jq).

# include: nft.sh
[[ -n "${_LIB_NFTCHAIN_SOURCED:-}" ]] && return 0
_LIB_NFTCHAIN_SOURCED=1

# ── nft_chain_fresh <family> <table> <chain> ──────────────────────────────────
nft_chain_fresh() {
    local family="$1" table="$2" chain="$3" token=created
    # The probe only picks the token. Add then flush is right in either
    # state (add succeeds on an existing chain, flush on an empty one), so
    # a probe that fails while the chain exists cannot leave the old rules
    # ahead of the new ones.
    if nft list chain "$family" "$table" "$chain" &>/dev/null; then
        token=flushed
    fi
    nft add chain "$family" "$table" "$chain" || return 1
    nft flush chain "$family" "$table" "$chain" || return 1
    printf '%s\n' "$token"
}

# ── nft_jump_handles <family> <table> <base> <target> ─────────────────────────
nft_jump_handles() {
    local family="$1" table="$2" base="$3" target="$4" listing handles handle rc=0
    listing="$(nft -j -a list chain "$family" "$table" "$base" 2>/dev/null)" || return 1
    # jq hands a non-number on as a fixed word, so a string handle holding a
    # newline cannot come out as two lines that each look like a number.
    handles="$(jq -r --arg t "$target" \
        "${_NFT_JUMP_HANDLES_JQ} | if type == \"number\" then . else \"not-a-number\" end" \
        <<< "$listing")" || return 1
    while IFS= read -r handle; do
        [[ -n "$handle" ]] || continue
        if [[ "$handle" =~ ^[0-9]+$ ]]; then
            printf '%s\n' "$handle"
        else
            rc=2
        fi
    done <<< "$handles"
    return "$rc"
}

# ── nft_delete_chain <family> <table> <chain> ─────────────────────────────────
nft_delete_chain() {
    local family="$1" table="$2" chain="$3" err
    nft flush chain "$family" "$table" "$chain" 2>/dev/null || true
    if err="$(nft delete chain "$family" "$table" "$chain" 2>&1)"; then
        printf 'deleted\n'
        return 0
    fi
    # Refused, or there was none: the probe tells which, after the fact, so
    # a chain that can neither be deleted nor listed is reported as refused
    # (with nft's reason), never as absent.
    if nft list chain "$family" "$table" "$chain" &>/dev/null; then
        [[ -z "$err" ]] || printf '%s\n' "$err" >&2
        return 1
    fi
    printf 'absent\n'
}

# ── nft_forward_drop <family> <table> ─────────────────────────────────────────
nft_forward_drop() {
    local family="$1" table="$2" chains_json others="" policy="" checked=0
    local spec_drop='{ type filter hook forward priority 0 ; policy drop ; }'
    local spec_accept='{ type filter hook forward priority 0 ; policy accept ; }'
    if chains_json="$(nft -j list chains 2>/dev/null)" \
       && others="$(jq -r --arg f "$family" --arg t "$table" "$_NFT_FWD_OTHERS_JQ" <<< "$chains_json" 2>/dev/null)" \
       && policy="$(jq -r --arg f "$family" --arg t "$table" --arg n forward "$_NFT_POLICY_JQ" <<< "$chains_json" 2>/dev/null)"; then
        case "$policy" in missing|accept|drop|none) checked=1 ;; esac
    fi

    if (( ! checked )); then
        if ! nft list chain "$family" "$table" forward &>/dev/null; then
            nft add chain "$family" "$table" forward "$spec_accept" || return 1
        fi
        printf 'unread\n'
        return 0
    fi
    case "$policy" in
        missing)
            if [[ -z "$others" ]]; then
                if nft add chain "$family" "$table" forward "$spec_drop"; then
                    printf 'created-drop\n'
                else
                    printf 'drop-failed missing\n'
                fi
            else
                nft add chain "$family" "$table" forward "$spec_accept" || return 1
                printf 'created-accept %s\n' "$others"
            fi ;;
        accept)
            if [[ -z "$others" ]]; then
                if nft chain "$family" "$table" forward '{ policy drop ; }'; then
                    printf 'flipped\n'
                else
                    printf 'drop-failed accept\n'
                fi
            else
                printf 'kept %s\n' "$others"
            fi ;;
        drop) printf 'drop\n' ;;
        none) printf 'not-base\n' ;;
    esac
    return 0
}
