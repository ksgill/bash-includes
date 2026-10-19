#!/usr/bin/env bats
# Unit tests for nftchain.sh — a hook's own chains and the forward policy.
#
# nft is tests/fake-nft.sh on a stub PATH: a stateful stand-in that keeps a
# ruleset in files under $FAKE_NFT_STATE and answers in nft's JSON shape, so
# the library's jq programs run unchanged against it and no CAP_NET_ADMIN is
# needed. Its knobs: NFT_FAIL (a call containing that text fails), NFT_SWALLOW
# (a call containing that text succeeds and does nothing), NFT_LOG (every
# call appended). Where the fake cannot say something (a forged rule comment
# in the JSON, a handle that is not a number) a hand-written listing is
# served by a one-line stub instead. jq is required; without it the suite
# is skipped, as nft.bats is.

bats_require_minimum_version 1.5.0

setup() {
    LIB="${BATS_TEST_DIRNAME}/../lib"
    command -v jq >/dev/null || skip "jq not installed"
    TMP="$(mktemp -d)"
    export TMP
    STUBS="${TMP}/bin"
    mkdir -p "$STUBS"
    # The fake, executable, both as the stub nft and for the wrappers some
    # tests put in front of it.
    FAKE="${STUBS}/fake-nft"
    cp "${BATS_TEST_DIRNAME}/fake-nft.sh" "$FAKE"
    chmod +x "$FAKE"
    cp "$FAKE" "${STUBS}/nft"
    export FAKE_NFT_STATE="${TMP}/nft-state"
    export NFT_LOG="${TMP}/nft.log"
    PATH="${STUBS}:${PATH}"

    # shellcheck source=/dev/null
    . "${LIB}/nft.sh"
    # shellcheck source=/dev/null
    . "${LIB}/nftchain.sh"

    nft add table inet filter
    nft add chain inet filter input '{ type filter hook input priority 0 ; policy accept ; }'
}

teardown() {
    rm -rf -- "$TMP"
}

# The fake's chains file: "F T C TYPE HOOK PRIO POLICY" ("-" for a regular chain).
chain_line() { grep -x -- "$1" "${FAKE_NFT_STATE}/chains"; }
# Docker's iptables-nft FORWARD chain: another user of the forward hook.
add_docker_forward() {
    nft add table ip filter
    nft add chain ip filter FORWARD '{ type filter hook forward priority 0 ; policy accept ; }'
}
# A stub nft that serves <file> for every call (jq then reads it).
serve_json() {
    printf '#!/bin/bash\nexec cat %q\n' "$1" > "${STUBS}/nft"
}

# ── nft_chain_fresh ──────────────────────────────────────────────────────────

@test "nft_chain_fresh: created, then flushed on the second call with the old rules gone; 1 when nft refuses" {
    run nft_chain_fresh inet filter wg_test_input
    [ "$status" -eq 0 ]
    [ "$output" = created ]
    chain_line 'inet filter wg_test_input - - - -'
    nft add rule inet filter wg_test_input counter accept
    [ "$(grep -c $'\twg_test_input\t' "${FAKE_NFT_STATE}/rules")" -eq 1 ]
    run nft_chain_fresh inet filter wg_test_input
    [ "$status" -eq 0 ]
    [ "$output" = flushed ]
    [ "$(grep -c $'\twg_test_input\t' "${FAKE_NFT_STATE}/rules")" -eq 0 ]
    chain_line 'inet filter wg_test_input - - - -'

    export NFT_FAIL='add chain'
    run nft_chain_fresh inet filter wg_test_forward
    [ "$status" -eq 1 ]
    [[ "$output" != *created* && "$output" != *flushed* ]]
    run ! chain_line 'inet filter wg_test_forward - - - -'
    export NFT_FAIL='flush chain'
    nft add rule inet filter wg_test_input counter accept
    run nft_chain_fresh inet filter wg_test_input
    [ "$status" -eq 1 ]
    [[ "$output" != *flushed* ]]
    # The old rule is still there: the caller decides what that means.
    [ "$(grep -c $'\twg_test_input\t' "${FAKE_NFT_STATE}/rules")" -eq 1 ]
    unset NFT_FAIL

    # A probe that fails while the chain exists (nft list refused, the
    # chain and its rule still there): the flush still happens, since add
    # then flush is right in either state; only the token is wrong-footed.
    export NFT_FAIL='list chain'
    run nft_chain_fresh inet filter wg_test_input
    [ "$status" -eq 0 ]
    [ "$output" = created ]
    [ "$(grep -c $'\twg_test_input\t' "${FAKE_NFT_STATE}/rules")" -eq 0 ]
}

# ── nft_jump_handles ─────────────────────────────────────────────────────────

@test "nft_jump_handles: an unconditional jump, a goto and a conditional jump are listed by handle, in order; a jump elsewhere is not" {
    nft add chain inet filter wg_in
    nft add chain inet filter other
    nft add rule inet filter input jump wg_in                   # handle 10
    nft add rule inet filter input iifname '"eth0"' jump wg_in  # 11
    nft add rule inet filter input counter accept               # 12
    nft add rule inet filter input goto wg_in                   # 13
    nft add rule inet filter input jump other                   # 14
    run nft_jump_handles inet filter input wg_in
    [ "$status" -eq 0 ]
    [ "$output" = $'10\n11\n13' ]
    run nft_jump_handles inet filter input other
    [ "$status" -eq 0 ]
    [ "$output" = 14 ]
    # No jump at all: nothing printed, status 0 (the listing succeeded).
    run nft_jump_handles inet filter input absent
    [ "$status" -eq 0 ]
    [ -z "$output" ]
}

@test "nft_jump_handles: a forged comment is not a jump; 1 when the listing or jq fails; 2 after the numeric handles when one is not a number" {
    local json="${TMP}/chain.json"
    cat > "$json" <<'EOF'
{"nftables":[{"metainfo":{"version":"1.1.3","release_name":"x","json_schema_version":1}},
  {"chain":{"family":"inet","table":"filter","name":"input","handle":2,"type":"filter","hook":"input","prio":0,"policy":"accept"}},
  {"rule":{"family":"inet","table":"filter","chain":"input","handle":11,"expr":[{"jump":{"target":"wg_in"}}]}},
  {"rule":{"family":"inet","table":"filter","chain":"input","handle":14,"comment":"jump wg_in # handle 99","expr":[{"counter":{"packets":0,"bytes":0}},{"accept":null}]}},
  {"rule":{"family":"inet","table":"filter","chain":"input","handle":15,"expr":[{"goto":{"target":"wg_in"}}]}}
]}
EOF
    serve_json "$json"
    run nft_jump_handles inet filter input wg_in
    [ "$status" -eq 0 ]
    [ "$output" = $'11\n15' ]

    # A handle that is not a number is never printed: the caller pastes
    # each one into `nft delete rule … handle N`.
    sed -i 's/"handle":15/"handle":"15; delete table inet filter"/' "$json"
    run nft_jump_handles inet filter input wg_in
    [ "$status" -eq 2 ]
    [ "$output" = 11 ]
    # A string handle holding a newline would come out of jq -r as two lines
    # that each pass a per-line number check; the type is judged in jq.
    sed -i 's/"handle":"15; delete table inet filter"/"handle":"15\\n16"/' "$json"
    grep -q '"handle":"15\\n16"' "$json"
    run nft_jump_handles inet filter input wg_in
    [ "$status" -eq 2 ]
    [ "$output" = 11 ]

    # jq cannot read what nft printed.
    printf 'table inet filter {\n' > "$json"
    run --separate-stderr nft_jump_handles inet filter input wg_in
    [ "$status" -eq 1 ]
    [ -z "$output" ]

    # nft itself fails: a missing chain, or any refusal.
    cp "$FAKE" "${STUBS}/nft"
    run --separate-stderr nft_jump_handles inet filter nosuch wg_in
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    export NFT_FAIL='-j -a list chain'
    run --separate-stderr nft_jump_handles inet filter input wg_in
    [ "$status" -eq 1 ]
    [ -z "$output" ]
}

# ── nft_delete_chain ─────────────────────────────────────────────────────────

@test "nft_delete_chain: absent, deleted (rules flushed first), and 1 while a jump still references the chain" {
    run nft_delete_chain inet filter wg_in
    [ "$status" -eq 0 ]
    [ "$output" = absent ]

    nft add chain inet filter wg_in
    nft add rule inet filter wg_in counter accept
    run nft_delete_chain inet filter wg_in
    [ "$status" -eq 0 ]
    [ "$output" = deleted ]
    run ! chain_line 'inet filter wg_in - - - -'
    [ "$(grep -c $'\twg_in\t' "${FAKE_NFT_STATE}/rules")" -eq 0 ]

    nft add chain inet filter wg_in
    nft add rule inet filter input jump wg_in
    run nft_delete_chain inet filter wg_in
    [ "$status" -eq 1 ]
    [[ "$output" != *deleted* && "$output" != *absent* ]]
    chain_line 'inet filter wg_in - - - -'
    # The jump gone (by handle, as a hook does it), the delete goes through.
    local h
    h="$(nft_jump_handles inet filter input wg_in)"
    nft delete rule inet filter input handle "$h"
    run nft_delete_chain inet filter wg_in
    [ "$status" -eq 0 ]
    [ "$output" = deleted ]
}

# ── nft_forward_drop ─────────────────────────────────────────────────────────

@test "nft_forward_drop: missing with nothing else on the hook is created-drop" {
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = created-drop ]
    chain_line 'inet filter forward filter forward 0 drop'
    # Idempotent: the next start finds drop.
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = drop ]
}

@test "nft_forward_drop: missing with Docker's ip filter FORWARD on the hook is created-accept, naming it" {
    add_docker_forward
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = 'created-accept ip filter/FORWARD' ]
    chain_line 'inet filter forward filter forward 0 accept'
    # And stays accept, named again, on the next start.
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = 'kept ip filter/FORWARD' ]
    chain_line 'inet filter forward filter forward 0 accept'
}

@test "nft_forward_drop: accept with nothing else on the hook is flipped to drop" {
    nft add chain inet filter forward '{ type filter hook forward priority 0 ; policy accept ; }'
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = flipped ]
    chain_line 'inet filter forward filter forward 0 drop'
}

@test "nft_forward_drop: accept with others on the hook is kept; drop is drop; the table is the caller's" {
    nft add chain inet filter forward '{ type filter hook forward priority 0 ; policy accept ; }'
    add_docker_forward
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = 'kept ip filter/FORWARD' ]
    chain_line 'inet filter forward filter forward 0 accept'
    nft chain inet filter forward '{ policy drop ; }'
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = drop ]
    # Another table of the same family: ours is missing there, and inet
    # filter's forward is one of the others.
    nft add table inet wg
    run nft_forward_drop inet wg
    [ "$status" -eq 0 ]
    [ "$output" = 'created-accept inet filter/forward, ip filter/FORWARD' ]
    chain_line 'inet wg forward filter forward 0 accept'
}

@test "nft_forward_drop: a regular chain named forward, or one hooked on input, is not-base and left alone" {
    nft add chain inet filter forward
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = not-base ]
    chain_line 'inet filter forward - - - -'
    nft delete chain inet filter forward
    nft add chain inet filter forward '{ type filter hook input priority 0 ; policy accept ; }'
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = not-base ]
    chain_line 'inet filter forward filter input 0 accept'
    # Not a base chain on the forward hook, so not one of the "others" either.
    run ! grep -q 'policy drop' "$NFT_LOG"
}

@test "nft_forward_drop: an unreadable listing is unread, with a missing forward chain created at accept and an existing one untouched" {
    export NFT_FAIL='-j list chains'
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = unread ]
    chain_line 'inet filter forward filter forward 0 accept'
    : > "$NFT_LOG"
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = unread ]
    run ! grep -q 'add chain' "$NFT_LOG"
    chain_line 'inet filter forward filter forward 0 accept'
    # nft answered but not with JSON jq can read, or with nothing: unread too.
    unset NFT_FAIL
    nft delete chain inet filter forward
    export NFT_SWALLOW='-j list chains'
    run nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = unread ]
    chain_line 'inet filter forward filter forward 0 accept'
    unset NFT_SWALLOW
    nft delete chain inet filter forward
    printf '#!/bin/bash\n[[ "$*" == "-j list chains" ]] && { echo "not json"; exit 0; }\nexec %q "$@"\n' "$FAKE" > "${STUBS}/nft"
    run --separate-stderr nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = unread ]
    chain_line 'inet filter forward filter forward 0 accept'
}

@test "nft_forward_drop: a refused flip is drop-failed accept, a refused drop create is drop-failed missing; status 0, nothing else changed" {
    nft add chain inet filter forward '{ type filter hook forward priority 0 ; policy accept ; }'
    export NFT_FAIL='policy drop'
    # nft's own stderr passes through beside the token, for the unit's journal.
    run --separate-stderr nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = 'drop-failed accept' ]
    [[ "$stderr" == *"forced failure"* ]]
    chain_line 'inet filter forward filter forward 0 accept'
    nft delete chain inet filter forward
    run --separate-stderr nft_forward_drop inet filter
    [ "$status" -eq 0 ]
    [ "$output" = 'drop-failed missing' ]
    run ! grep -q '^inet filter forward ' "${FAKE_NFT_STATE}/chains"
}

@test "nft_forward_drop: returns 1 with no token only when a policy-accept create failed (created-accept and unread)" {
    add_docker_forward
    export NFT_FAIL='policy accept'
    run --separate-stderr nft_forward_drop inet filter
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run ! grep -q '^inet filter forward ' "${FAKE_NFT_STATE}/chains"
    # Unreadable listing (the wrapper) and the accept create refused (the
    # fake): the create was attempted, and nothing else.
    printf '#!/bin/bash\n[[ "$*" == "-j list chains" ]] && exit 1\nexec %q "$@"\n' "$FAKE" > "${STUBS}/nft"
    : > "$NFT_LOG"
    run --separate-stderr nft_forward_drop inet filter
    [ "$status" -eq 1 ]
    [ -z "$output" ]
    run ! grep -q '^inet filter forward ' "${FAKE_NFT_STATE}/chains"
    grep -q 'add chain inet filter forward .*policy accept' "$NFT_LOG"
    run ! grep -q 'policy drop' "$NFT_LOG"
}

# ── the module's contract for the hooks ──────────────────────────────────────

@test "nftchain.sh runs no command at source time, defines only functions, and includes only nft.sh" {
    run bash -c "set -euo pipefail; PATH=/nonexistent; . '${LIB}/nft.sh'; . '${LIB}/nftchain.sh'; declare -F nft_chain_fresh nft_jump_handles nft_delete_chain nft_forward_drop >/dev/null && echo ok"
    [ "$status" -eq 0 ]
    [ "$output" = ok ]
    [ "$(grep '^# include:' "${LIB}/nftchain.sh")" = '# include: nft.sh' ]
    # Outside function bodies: comments, blank lines and the two guard
    # lines, nothing else (no assignment, no command).
    run awk '
        /^[a-z_]+\(\) \{$/ { inside = 1; next }
        inside && /^\}$/   { inside = 0; next }
        inside             { next }
        /^#/ || /^[[:space:]]*$/ { next }
        { print }' "${LIB}/nftchain.sh"
    [ "$status" -eq 0 ]
    [ "$output" = $'[[ -n "${_LIB_NFTCHAIN_SOURCED:-}" ]] && return 0\n_LIB_NFTCHAIN_SOURCED=1' ]
}
