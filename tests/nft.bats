#!/usr/bin/env bats
# Unit tests for nft.sh — the jq programs over nft's JSON listings.
#
# The programs are run with jq over hand-written listings in the shape
# `nft -j list ruleset` / `nft -j -a list chain` print (nftables 1.1), so no
# nft and no root are needed. Each case is one property the consumers lean
# on: a forged text line cannot fool a JSON read, a chain named forward on
# the wrong hook is never a forward policy, a jump behind a match is not the
# unconditional jump a hook verifies.

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    # shellcheck source=/dev/null
    . "${LIB}/nft.sh"
    command -v jq >/dev/null || skip "jq not installed"

    # Two filter tables (inet filter with input/forward base chains, ip filter
    # with Docker's FORWARD), a nat table, and rules: an unconditional jump
    # to obt-input (handle 11), a conditional one (handle 12), a goto (13),
    # a comment that forges a jump line and a chain line (14), two counters.
    RS='{"nftables":[{"metainfo":{"version":"1.1.3","release_name":"x","json_schema_version":1}},
      {"table":{"family":"inet","name":"filter","handle":1}},
      {"chain":{"family":"inet","table":"filter","name":"input","handle":2,"type":"filter","hook":"input","prio":0,"policy":"accept"}},
      {"chain":{"family":"inet","table":"filter","name":"forward","handle":3,"type":"filter","hook":"forward","prio":0,"policy":"accept"}},
      {"chain":{"family":"inet","table":"filter","name":"obt-input","handle":4}},
      {"chain":{"family":"inet","table":"filter","name":"obt-forward","handle":5}},
      {"chain":{"family":"inet","table":"filter","name":"obt-forward-extra","handle":6}},
      {"table":{"family":"ip","name":"filter","handle":7}},
      {"chain":{"family":"ip","table":"filter","name":"FORWARD","handle":8,"type":"filter","hook":"forward","prio":0,"policy":"accept"}},
      {"table":{"family":"ip","name":"nat","handle":9}},
      {"chain":{"family":"ip","table":"nat","name":"obt-nat","handle":10,"type":"nat","hook":"postrouting","prio":100,"policy":"accept"}},
      {"rule":{"family":"inet","table":"filter","chain":"input","handle":11,"expr":[{"jump":{"target":"obt-input"}}]}},
      {"rule":{"family":"inet","table":"filter","chain":"input","handle":12,"expr":[{"match":{"op":"==","left":{"payload":{"protocol":"ip","field":"saddr"}},"right":"10.0.0.1"}},{"jump":{"target":"obt-input"}}]}},
      {"rule":{"family":"inet","table":"filter","chain":"forward","handle":13,"expr":[{"goto":{"target":"obt-forward"}}]}},
      {"rule":{"family":"inet","table":"filter","chain":"forward","handle":14,"comment":"jump obt-input\nchain forward { type filter hook forward","expr":[{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},
      {"rule":{"family":"ip","table":"nat","chain":"obt-nat","handle":15,"expr":[{"counter":{"packets":0,"bytes":0}},{"masquerade":null}]}}
    ]}'
}

q() { jq -r "$@" <<< "$RS"; }

# ── _NFT_POLICY_JQ ────────────────────────────────────────────────────────────

@test "policy: a base chain reports its policy, a regular chain none, an absent one missing" {
    [ "$(q --arg f inet --arg t filter --arg n forward "$_NFT_POLICY_JQ")" = accept ]
    [ "$(q --arg f inet --arg t filter --arg n obt-input "$_NFT_POLICY_JQ")" = none ]
    [ "$(q --arg f inet --arg t filter --arg n nothing "$_NFT_POLICY_JQ")" = missing ]
    [ "$(q --arg f ip6 --arg t filter --arg n forward "$_NFT_POLICY_JQ")" = missing ]
}

@test "policy: a chain named forward that is a base chain on another hook is none, never its policy" {
    local rs='{"nftables":[{"chain":{"family":"inet","table":"filter","name":"forward","handle":3,"type":"filter","hook":"input","prio":0,"policy":"drop"}}]}'
    [ "$(jq -r --arg f inet --arg t filter --arg n forward "$_NFT_POLICY_JQ" <<< "$rs")" = none ]
    # The same shape for an input chain is name-based: its policy is reported.
    rs='{"nftables":[{"chain":{"family":"inet","table":"filter","name":"input","handle":3,"type":"filter","hook":"prerouting","prio":0,"policy":"drop"}}]}'
    [ "$(jq -r --arg f inet --arg t filter --arg n input "$_NFT_POLICY_JQ" <<< "$rs")" = drop ]
}

@test "policy: a forged chain line in a rule comment is not a chain" {
    [ "$(q --arg f inet --arg t filter --arg n obt-forward-extra "$_NFT_POLICY_JQ")" = none ]
    # The comment on handle 14 claims a chain; the table has no chain by that text.
    [ "$(q --arg f inet --arg t filter --arg n 'forward { type filter hook forward' "$_NFT_POLICY_JQ")" = missing ]
}

# ── _NFT_FWD_OTHERS_JQ ────────────────────────────────────────────────────────

@test "forward others: every forward-hook base chain but ours, in any table, unique and joined" {
    [ "$(q --arg f inet --arg t filter "$_NFT_FWD_OTHERS_JQ")" = "ip filter/FORWARD" ]
    # From the ip family's view, inet filter forward is another user, and so
    # is Docker's FORWARD in ip filter itself: "forward" is matched exactly.
    [ "$(q --arg f ip --arg t filter "$_NFT_FWD_OTHERS_JQ")" = "inet filter/forward, ip filter/FORWARD" ]
}

@test "forward others: ip6 chains do not count against an ip family; bridge chains do" {
    local rs='{"nftables":[
      {"chain":{"family":"ip6","table":"filter","name":"forward","handle":1,"type":"filter","hook":"forward","prio":0,"policy":"drop"}},
      {"chain":{"family":"bridge","table":"filter","name":"forward","handle":2,"type":"filter","hook":"forward","prio":0,"policy":"drop"}}]}'
    [ "$(jq -r --arg f ip --arg t filter "$_NFT_FWD_OTHERS_JQ" <<< "$rs")" = "bridge filter/forward" ]
    [ "$(jq -r --arg f inet --arg t filter "$_NFT_FWD_OTHERS_JQ" <<< "$rs")" = "bridge filter/forward, ip6 filter/forward" ]
}

@test "forward others: empty when there is none; control characters in names print as ?" {
    local rs='{"nftables":[{"chain":{"family":"inet","table":"filter","name":"forward","handle":1,"type":"filter","hook":"forward","prio":0,"policy":"accept"}}]}'
    [ -z "$(jq -r --arg f inet --arg t filter "$_NFT_FWD_OTHERS_JQ" <<< "$rs")" ]
    rs='{"nftables":[{"chain":{"family":"inet","table":"filter","name":"fwd\u001b[31m","handle":1,"type":"filter","hook":"forward","prio":0,"policy":"accept"}}]}'
    [ "$(jq -r --arg f inet --arg t filter "$_NFT_FWD_OTHERS_JQ" <<< "$rs")" = "inet filter/fwd?[31m" ]
}

# ── _NFT_DETECT_FAMILY_JQ / _NFT_FILTER_FAMILY_JQ ─────────────────────────────

@test "detect family: both filter tables — the one with more filter base chains, inet on a tie" {
    # inet filter has 2 base chains (input, forward); ip filter 1 (FORWARD).
    [ "$(q "$_NFT_DETECT_FAMILY_JQ")" = inet ]
    local rs='{"nftables":[
      {"table":{"family":"inet","name":"filter","handle":1}},
      {"chain":{"family":"inet","table":"filter","name":"input","handle":2,"type":"filter","hook":"input","prio":0,"policy":"accept"}},
      {"table":{"family":"ip","name":"filter","handle":3}},
      {"chain":{"family":"ip","table":"filter","name":"INPUT","handle":4,"type":"filter","hook":"input","prio":0,"policy":"accept"}},
      {"chain":{"family":"ip","table":"filter","name":"FORWARD","handle":5,"type":"filter","hook":"forward","prio":0,"policy":"accept"}}]}'
    [ "$(jq -r "$_NFT_DETECT_FAMILY_JQ" <<< "$rs")" = ip ]
    rs='{"nftables":[
      {"table":{"family":"inet","name":"filter","handle":1}},
      {"chain":{"family":"inet","table":"filter","name":"input","handle":2,"type":"filter","hook":"input","prio":0,"policy":"accept"}},
      {"table":{"family":"ip","name":"filter","handle":3}},
      {"chain":{"family":"ip","table":"filter","name":"INPUT","handle":4,"type":"filter","hook":"input","prio":0,"policy":"accept"}}]}'
    [ "$(jq -r "$_NFT_DETECT_FAMILY_JQ" <<< "$rs")" = inet ]
}

@test "detect family: one filter table — its family; none — any inet table, else any ip table, else empty" {
    local rs='{"nftables":[{"table":{"family":"ip","name":"filter","handle":1}}]}'
    [ "$(jq -r "$_NFT_DETECT_FAMILY_JQ" <<< "$rs")" = ip ]
    rs='{"nftables":[{"table":{"family":"ip","name":"nat","handle":1}},{"table":{"family":"inet","name":"mangle","handle":2}}]}'
    [ "$(jq -r "$_NFT_DETECT_FAMILY_JQ" <<< "$rs")" = inet ]
    rs='{"nftables":[{"table":{"family":"ip","name":"nat","handle":1}}]}'
    [ "$(jq -r "$_NFT_DETECT_FAMILY_JQ" <<< "$rs")" = ip ]
    rs='{"nftables":[{"metainfo":{"version":"1.1.3","release_name":"x","json_schema_version":1}}]}'
    [ -z "$(jq -r "$_NFT_DETECT_FAMILY_JQ" <<< "$rs")" ]
}

@test "filter family: the table that holds the caller's chain wins over detection; without it, detection" {
    # obt-input lives in inet filter; ask for a chain that is only in ip.
    [ "$(q --arg c obt-input "$_NFT_FILTER_FAMILY_JQ")" = inet ]
    local rs='{"nftables":[
      {"table":{"family":"inet","name":"filter","handle":1}},
      {"chain":{"family":"inet","table":"filter","name":"input","handle":2,"type":"filter","hook":"input","prio":0,"policy":"accept"}},
      {"table":{"family":"ip","name":"filter","handle":3}},
      {"chain":{"family":"ip","table":"filter","name":"wg-input","handle":4}}]}'
    [ "$(jq -r --arg c wg-input "$_NFT_FILTER_FAMILY_JQ" <<< "$rs")" = ip ]
    [ "$(jq -r --arg c absent "$_NFT_FILTER_FAMILY_JQ" <<< "$rs")" = inet ]
}

# ── jumps ─────────────────────────────────────────────────────────────────────

@test "jump handles: every rule that jumps or goes to the chain, by handle; a comment forging a jump is not one" {
    [ "$(q --arg t obt-input "$_NFT_JUMP_HANDLES_JQ" | paste -sd ' ')" = "11 12" ]
    [ "$(q --arg t obt-forward "$_NFT_JUMP_HANDLES_JQ")" = 13 ]
    [ -z "$(q --arg t obt-nat "$_NFT_JUMP_HANDLES_JQ")" ]
}

@test "has jump / exact jump: a conditional jump counts as a jump but not as the unconditional one" {
    [ "$(q --arg t obt-input "$_NFT_HAS_JUMP_JQ")" = true ]
    [ "$(q --arg t obt-input "$_NFT_EXACT_JUMP_JQ")" = true ]
    [ "$(q --arg t obt-forward "$_NFT_HAS_JUMP_JQ")" = true ]
    # handle 13 is a goto, not a jump: not the exact jump a hook adds.
    [ "$(q --arg t obt-forward "$_NFT_EXACT_JUMP_JQ")" = false ]
    [ "$(q --arg t obt-nat "$_NFT_HAS_JUMP_JQ")" = false ]
    local rs='{"nftables":[{"rule":{"family":"inet","table":"filter","chain":"input","handle":1,"expr":[{"match":{"op":"==","left":{"meta":{"key":"iifname"}},"right":"eth0"}},{"jump":{"target":"c"}}]}}]}'
    [ "$(jq -r --arg t c "$_NFT_HAS_JUMP_JQ" <<< "$rs")" = true ]
    [ "$(jq -r --arg t c "$_NFT_EXACT_JUMP_JQ" <<< "$rs")" = false ]
}

# ── counts and named chains ───────────────────────────────────────────────────

@test "count: rules carrying a statement, from JSON, not from words in comments" {
    [ "$(q --arg s counter "$_NFT_COUNT_JQ")" = 2 ]
    [ "$(q --arg s masquerade "$_NFT_COUNT_JQ")" = 1 ]
    [ "$(q --arg s drop "$_NFT_COUNT_JQ")" = 0 ]
    [ "$(q --arg s jump "$_NFT_COUNT_JQ")" = 2 ]
}

@test "chains named: exact names only, with family and table; a longer name is not a match" {
    run jq -r --argjson names '["obt-input","obt-forward","obt-nat"]' "$_NFT_CHAINS_NAMED_JQ" <<< "$RS"
    [ "$status" -eq 0 ]
    [ "${lines[0]}" = "inet filter obt-input" ]
    [ "${lines[1]}" = "inet filter obt-forward" ]
    [ "${lines[2]}" = "ip nat obt-nat" ]
    [ "${#lines[@]}" -eq 3 ]
    [ -z "$(q --argjson names '["obt"]' "$_NFT_CHAINS_NAMED_JQ")" ]
    # A string instead of an array fails rather than turning into a substring match.
    run jq -r --argjson names '"obt-input obt-forward"' "$_NFT_CHAINS_NAMED_JQ" <<< "$RS"
    [ "$status" -ne 0 ]
    run jq -r --arg names obt-input "$_NFT_CHAINS_NAMED_JQ" <<< "$RS"
    [ "$status" -ne 0 ]
}

@test "the programs carry no single quote, so a generator can paste them inside '...'" {
    local v
    for v in _NFT_FWD_OTHERS_JQ _NFT_POLICY_JQ _NFT_DETECT_FAMILY_JQ _NFT_FILTER_FAMILY_JQ \
             _NFT_JUMP_HANDLES_JQ _NFT_HAS_JUMP_JQ _NFT_EXACT_JUMP_JQ _NFT_COUNT_JQ _NFT_CHAINS_NAMED_JQ; do
        [[ "${!v}" != *"'"* ]] || { echo "$v contains a single quote"; return 1; }
    done
}
