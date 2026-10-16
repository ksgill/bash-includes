#!/usr/bin/env bash
# nft.sh — jq programs over nft's JSON listings.
# Part of the bash-includes library. Source this file; do not execute it.
#
# Mechanism only: how to read a chain's policy, the other users of a hook,
# the family of a filter table or the handle of a jump rule out of
# `nft -j list ruleset`, `nft -j list chains` or `nft -j [-a] list chain`.
# Which chain a script manages, what policy it wants and what it does about
# the answer are the caller's. Always over the JSON listing, never the text
# one: a rule or chain comment can forge lines in the text (an attacker who
# can add a rule comment can make `grep 'type filter hook forward'` count a
# chain that is not there).
#
# Assignments only, like config.sh: a hook that runs as root under systemd
# includes nothing but log.sh besides this file, and no function is needed to
# carry a program. The $f, $t, $n, $c, $s and $names inside the single quotes
# are jq variables, bound with --arg / --argjson by the caller (SC2016); the
# names are for the files that include this one (SC2034). None of the
# programs contains a single quote, so a generator can still paste one
# inside '...' in a heredoc.
#
# Lifted from openvpn-bld's lib/nft-jq.sh and the same programs in
# wireguard-bld (FA-fleet-020), which had each been fixed twice for the same
# bug. Two of them carry the VPN builders' convention rather than a fact
# about nft: the family detection looks at tables named "filter" and
# prefers inet on a tie, and the policy query treats a chain named
# "forward" specially (a chain named "input" is still picked by name alone;
# a base chain named input on another hook reports that hook's policy). A
# consumer with another layout passes its own table name to the queries
# that take one and does not use the detection.
#
# What a caller has to bring:
# - The exit status of nft and of jq. Every program prints nothing, exit 0,
#   on empty input, and "nothing" is a real answer for several of them (no
#   other forward users, no jump), so a listing that failed must be told
#   apart from an empty one by the status of `nft -j`, and `jq` must be
#   checked too — a consumer that flips a forward policy to drop on an
#   empty _NFT_FWD_OTHERS_JQ result must first know the listing succeeded.
# - Only nft is seen. iptables-legacy chains (Docker with the legacy
#   alternative selected) and plain routing with no filter chain at all
#   read as "no other forward users"; /proc/net/ip_tables_names is where a
#   consumer looks for the former.
# - Names come back as the ruleset has them. Family, table and chain are
#   printed with control characters replaced, nothing else; nft joins its
#   arguments into one command buffer, so a name with a space or ';' could
#   not be passed back to it safely — creating one needs CAP_NET_ADMIN,
#   which is already root, but a consumer that pastes names into an nft
#   command should check them against nft's identifier grammar first.
#
# Depends on: nothing (the caller runs nft and jq).
# shellcheck disable=SC2016,SC2034
[[ -n "${_LIB_NFT_SOURCED:-}" ]] && return 0
_LIB_NFT_SOURCED=1

# _NFT_FWD_OTHERS_JQ, with --arg f <family> --arg t <table>, over `nft -j
# list ruleset` or `nft -j list chains`: "<family> <table>/<chain>" of every
# base chain on the forward hook other than the one the caller manages
# (<family> <table> forward), unique, joined by ", "; empty when there is
# none. That includes other chains in the caller's own table: iptables-nft
# (Docker) puts its FORWARD chain in ip filter. A packet dropped by any base
# chain on a hook is dropped, so a drop policy on the caller's forward chain
# would cut their traffic too. Not counted: ip6 chains when the caller's
# family is ip, whose forward hook IPv6 never passes (bridge chains are
# counted, the conservative choice). Names come from the ruleset: control
# characters print as '?'.
_NFT_FWD_OTHERS_JQ='def c: tostring | gsub("[[:cntrl:]]"; "?");
    [.nftables[] | .chain? // empty | select(.hook? == "forward")
     | select((.family == $f and .table == $t and .name == "forward") | not)
     | select(($f == "ip" and .family == "ip6") | not)
     | "\(.family | c) \(.table | c)/\(.name | c)"] | unique | join(", ")'

# _NFT_POLICY_JQ, with --arg f <family> --arg t <table> --arg n <chain>:
# "missing" when the table has no such chain, otherwise its policy ("accept",
# "drop"), or "none" for a regular (non-base) chain. A chain named forward
# that is a base chain on any hook but forward (input, say) is "none" too:
# it is picked by name, and its policy is not the forward policy, so it must
# never be flipped. (Only for forward: an input chain is name-based.)
_NFT_POLICY_JQ='[.nftables[] | .chain? // empty
     | select(.family == $f and .table == $t and .name == $n)]
    | if length == 0 then "missing"
      elif $n == "forward" and (.[0].hook // "") != "forward" then "none"
      else (.[0].policy // "none") end'

# _NFT_DETECT_FAMILY_JQ, over `nft -j list ruleset`: the family ("inet" or
# "ip") a hook should put its filter chains in. Both filter tables: the one
# with more filter base chains (ip only when it has strictly more); one
# filter table: its family; no filter table: inet when any inet table
# exists, else ip when any ip table does. Empty when there is no table at
# all; the caller then decides by IPv6 (ip when it is disabled).
_NFT_DETECT_FAMILY_JQ='def has_t($fam; $name): any(.nftables[]; (.table? // {}) | .family == $fam and .name == $name);
    def hooks($fam): [.nftables[] | .chain? // empty
        | select(.family == $fam and .table == "filter" and .type? == "filter" and has("hook"))] | length;
    if has_t("inet"; "filter") and has_t("ip"; "filter") then
        (if hooks("ip") > hooks("inet") then "ip" else "inet" end)
    elif has_t("inet"; "filter") then "inet"
    elif has_t("ip"; "filter") then "ip"
    elif any(.nftables[]; (.table? // {}) | .family == "inet") then "inet"
    elif any(.nftables[]; (.table? // {}) | .family == "ip") then "ip"
    else "" end'

# _NFT_FILTER_FAMILY_JQ, with --arg c <chain>: the family ("inet" or "ip") of
# the filter table that holds the caller's chain <c>, once a hook has made
# it; before that, _NFT_DETECT_FAMILY_JQ applied to the listing, so a build
# check and the hook decide alike. Empty when those rules fall through to
# the IPv6 check, which the caller makes. A down action uses it too, so it
# cleans up the table the up action actually used.
_NFT_FILTER_FAMILY_JQ="([.nftables[] | .chain? // empty
      | select(.table == \"filter\" and .name == \$c and (.family == \"inet\" or .family == \"ip\"))
      | .family] | first)
    // (${_NFT_DETECT_FAMILY_JQ})"

# _NFT_JUMP_HANDLES_JQ, with --arg t <chain>, over `nft -j -a list chain
# ...`: the handle of every rule that jumps or goes to <chain>, one per line.
# A jump or goto inside a verdict map is not seen. _NFT_HAS_JUMP_JQ: "true"
# when there is one, else "false". _NFT_EXACT_JUMP_JQ: "true" only when a
# rule's whole expression is that jump — an unconditional one; a jump
# behind a match ("ip saddr x jump <chain>") carries only some packets into
# the chain and is not what a hook adds or verifies. None of the three
# looks at the rule's family, table or chain: run them over `nft -j -a list
# chain <family> <table> <chain>`, not over the whole ruleset. Nor do they
# say where in the chain the jump sits: a rule before it that accepts or
# drops ends evaluation first.
_NFT_JUMP_HANDLES_JQ='.nftables[] | .rule? // empty
    | select([.expr[]? | objects | (.jump.target?, .goto.target?) // empty] | any(. == $t))
    | .handle'
_NFT_HAS_JUMP_JQ='[.nftables[] | .rule? // empty | .expr[]? | objects
    | (.jump.target?, .goto.target?) // empty] | any(. == $t)'
_NFT_EXACT_JUMP_JQ='any(.nftables[] | .rule? // empty; .expr == [{"jump": {"target": $t}}])'

# _NFT_COUNT_JQ, with --arg s <statement>, over `nft -j list chain ...`: how
# many rules carry that statement (counter, masquerade, drop).
_NFT_COUNT_JQ='[.nftables[] | .rule? // empty | select(any(.expr[]?; type == "object" and has($s)))] | length'

# _NFT_CHAINS_NAMED_JQ, with --argjson names '["a","b"]', over `nft -j list
# chains`: "<family> <table> <chain>" for every chain whose name is in the
# list, by exact name, so a chain whose name merely starts with one of them
# is not counted. $names must be a JSON array (--argjson): `any($names[])`
# fails on a string, where a substring test would silently widen the match.
# Family and table come from the ruleset: control characters print as '?'.
_NFT_CHAINS_NAMED_JQ='def c: tostring | gsub("[[:cntrl:]]"; "?");
    .nftables[] | .chain? // empty
    | select(.name as $n | any($names[]; . == $n))
    | "\(.family | c) \(.table | c) \(.name)"'
