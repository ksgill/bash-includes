#!/usr/bin/env bash
# fake-nft.sh — a stateful stand-in for nft, for tests/nftchain.bats.
#
# The real nft needs CAP_NET_ADMIN, which CI runners and hardened hosts
# refuse. This fake keeps a ruleset in files under $FAKE_NFT_STATE and
# answers the subset of the nft command line the VPN builders' firewall
# hooks use, in nft's JSON shape where the hooks read JSON (the library's
# nft.sh jq programs run unchanged against it), so the chain and policy
# logic in nftchain.sh — creation, flushing, jumps by handle, idempotence,
# failure handling — runs anywhere. It is not nft: no packet semantics, and
# no syntax checking beyond what the hooks build. Installed on the test's
# stub PATH as `nft` by the suite's setup. Knobs: NFT_LOG (every call
# appended), NFT_FAIL (a call containing that text fails), NFT_SWALLOW (a
# call containing that text succeeds without doing anything, as a lost
# command would). A copy of openvpn-bld's tests/fake-nft.sh, which keeps its
# own for its hook tests: a fixture under a library's tests/ is not a
# contract the library offers.
set -euo pipefail

S="${FAKE_NFT_STATE:?}"
mkdir -p "$S"
touch "$S/tables" "$S/chains" "$S/sets" "$S/elements" "$S/rules"
[[ -s "$S/handle" ]] || echo 10 > "$S/handle"

echo "nft $*" >> "${NFT_LOG:-/dev/null}"
if [[ -n "${NFT_FAIL:-}" && "$*" == *"${NFT_FAIL}"* ]]; then
    echo "fake nft: forced failure: $*" >&2
    exit 1
fi
if [[ -n "${NFT_SWALLOW:-}" && "$*" == *"${NFT_SWALLOW}"* ]]; then
    exit 0
fi

JSON=false
while [[ $# -gt 0 ]]; do
    case "$1" in
        -j) JSON=true; shift ;;
        -a) shift ;;
        *) break ;;
    esac
done

die() { echo "fake nft: $*" >&2; exit 1; }

# State files: tables "F T"; chains "F T C TYPE HOOK PRIO POLICY" ("-" when
# not a base chain); sets "F T S"; elements "F T S <elements>"; rules
# "N<tab>F<tab>T<tab>C<tab><expr JSON><tab><text>".
has_table() { grep -qx -- "$1 $2" "$S/tables"; }
has_chain() { awk -v f="$1" -v t="$2" -v c="$3" '$1 == f && $2 == t && $3 == c { found = 1 } END { exit !found }' "$S/chains"; }
has_set()   { grep -qx -- "$1 $2 $3" "$S/sets"; }

# keep <file> <FS> <awk condition> — keep only the lines matching it.
keep() {
    local f="$1" fs="$2" cond="$3"
    awk -F "$fs" "$cond" "$f" > "$f.new" && mv -- "$f.new" "$f"
}

json_table() { printf '{"table":{"family":"%s","name":"%s","handle":1}}' "$1" "$2"; }
# json_chain F T C TYPE HOOK PRIO POLICY
json_chain() {
    if [[ "$4" == - ]]; then
        printf '{"chain":{"family":"%s","table":"%s","name":"%s","handle":2}}' "$1" "$2" "$3"
    else
        printf '{"chain":{"family":"%s","table":"%s","name":"%s","handle":2,"type":"%s","hook":"%s","prio":%s,"policy":"%s"}}' \
            "$1" "$2" "$3" "$4" "$5" "$6" "$7"
    fi
}
json_set() { printf '{"set":{"family":"%s","name":"%s","table":"%s","type":"ipv4_addr","handle":3,"flags":["interval"]}}' "$1" "$3" "$2"; }
# json_rule N F T C EXPR
json_rule() { printf '{"rule":{"family":"%s","table":"%s","chain":"%s","handle":%s,"expr":%s}}' "$2" "$3" "$4" "$1" "$5"; }

# emit_json <objects...> — one nftables JSON document.
emit_json() {
    local IFS=,
    printf '{"nftables":[{"metainfo":{"version":"fake","release_name":"fake","json_schema_version":1}}%s]}\n' "${*:+,$*}"
}

all_tables() { local f t; while read -r f t; do json_table "$f" "$t"; echo; done < "$S/tables"; }
all_chains() {
    local f t c ty h p pol
    while read -r f t c ty h p pol; do json_chain "$f" "$t" "$c" "$ty" "$h" "$p" "$pol"; echo; done < "$S/chains"
}
all_sets() { local f t s; while read -r f t s; do json_set "$f" "$t" "$s"; echo; done < "$S/sets"; }
# rules_of F T C — the chain's rules, JSON, one per line.
rules_of() {
    local n f t c e _
    while IFS=$'\t' read -r n f t c e _; do
        if [[ "$f" == "$1" && "$t" == "$2" && "$c" == "$3" ]]; then
            json_rule "$n" "$f" "$t" "$c" "$e"
            echo
        fi
    done < "$S/rules"
}
all_rules() { local n f t c e _; while IFS=$'\t' read -r n f t c e _; do json_rule "$n" "$f" "$t" "$c" "$e"; echo; done < "$S/rules"; }

# rule_expr <rule words...> — the expression list, in nft's JSON shape, for
# the words the hook uses: a match takes two (iifname/oifname) or three
# (ip/ct/udp/tcp/meta) words, a statement one, a verdict with a target two.
rule_expr() {
    local -a parts=()
    local right
    while [[ $# -gt 0 ]]; do
        case "$1" in
            jump|goto)   parts+=("{\"$1\":{\"target\":\"$2\"}}"); shift 2 ;;
            counter)     parts+=('{"counter":{"packets":0,"bytes":0}}'); shift ;;
            masquerade)  parts+=('{"masquerade":null}'); shift ;;
            accept|drop|return) parts+=("{\"$1\":null}"); shift ;;
            comment)     shift 2 ;;
            iifname|oifname)
                right="${2//\"/}"
                parts+=("{\"match\":{\"op\":\"==\",\"left\":{\"meta\":{\"key\":\"$1\"}},\"right\":\"${right}\"}}")
                shift 2 ;;
            ip|ct|udp|tcp|meta)
                parts+=("{\"match\":{\"op\":\"==\",\"left\":{\"payload\":{\"protocol\":\"$1\",\"field\":\"$2\"}},\"right\":\"$3\"}}")
                shift 3 ;;
            *) die "cannot parse rule word '$1' in: $*" ;;
        esac
    done
    local IFS=,
    printf '[%s]' "${parts[*]}"
}

cmd="${1:-}"
case "$cmd" in
    list)
        case "${2:-}" in
            ruleset)
                mapfile -t objs < <(all_tables; all_chains; all_sets; all_rules)
                emit_json "${objs[@]}" ;;
            chains)
                mapfile -t objs < <(all_chains)
                emit_json "${objs[@]}" ;;
            tables)
                mapfile -t objs < <(all_tables)
                emit_json "${objs[@]}" ;;
            table)
                has_table "$3" "$4" || die "No such table: $3 $4" ;;
            chain)
                has_chain "$3" "$4" "$5" || die "No such chain: $3 $4 $5"
                if [[ "$JSON" == true ]]; then
                    mapfile -t objs < <(awk -v f="$3" -v t="$4" -v c="$5" '$1 == f && $2 == t && $3 == c' "$S/chains" \
                        | { read -r f t c ty h p pol; json_chain "$f" "$t" "$c" "$ty" "$h" "$p" "$pol"; echo; }; rules_of "$3" "$4" "$5")
                    emit_json "${objs[@]}"
                else
                    printf 'table %s %s {\n\tchain %s {\n' "$3" "$4" "$5"
                    awk -F '\t' -v f="$3" -v t="$4" -v c="$5" '$2 == f && $3 == t && $4 == c { print "\t\t" $6 }' "$S/rules"
                    printf '\t}\n}\n'
                fi ;;
            set)
                has_set "$3" "$4" "$5" || die "No such set: $3 $4 $5" ;;
            *) die "unsupported: $*" ;;
        esac ;;
    add)
        case "${2:-}" in
            table)
                has_table "$3" "$4" || echo "$3 $4" >> "$S/tables" ;;
            chain)
                has_table "$3" "$4" || die "No such table: $3 $4"
                if ! has_chain "$3" "$4" "$5"; then
                    spec="${6:-}"
                    ty=-; hook=-; prio=-; pol=-
                    if [[ "$spec" =~ type\ ([a-z]+)\ hook\ ([a-z]+)\ priority\ (-?[0-9]+) ]]; then
                        ty="${BASH_REMATCH[1]}"; hook="${BASH_REMATCH[2]}"; prio="${BASH_REMATCH[3]}"; pol=accept
                        if [[ "$spec" =~ policy\ ([a-z]+) ]]; then pol="${BASH_REMATCH[1]}"; fi
                    fi
                    echo "$3 $4 $5 $ty $hook $prio $pol" >> "$S/chains"
                fi ;;
            set)
                has_table "$3" "$4" || die "No such table: $3 $4"
                has_set "$3" "$4" "$5" || echo "$3 $4 $5" >> "$S/sets" ;;
            element)
                has_set "$3" "$4" "$5" || die "No such set: $3 $4 $5"
                echo "$3 $4 $5 ${6:-}" >> "$S/elements" ;;
            rule)
                has_chain "$3" "$4" "$5" || die "No such chain: $3 $4 $5"
                f="$3"; t="$4"; c="$5"; shift 5
                expr="$(rule_expr "$@")"
                n="$(cat "$S/handle")"
                echo $((n + 1)) > "$S/handle"
                printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$n" "$f" "$t" "$c" "$expr" "$*" >> "$S/rules" ;;
            *) die "unsupported: $*" ;;
        esac ;;
    flush)
        case "${2:-}" in
            chain)
                has_chain "$3" "$4" "$5" || die "No such chain: $3 $4 $5"
                keep "$S/rules" '\t' "!(\$2 == \"$3\" && \$3 == \"$4\" && \$4 == \"$5\")" ;;
            set)
                has_set "$3" "$4" "$5" || die "No such set: $3 $4 $5"
                keep "$S/elements" ' ' "!(\$1 == \"$3\" && \$2 == \"$4\" && \$3 == \"$5\")" ;;
            *) die "unsupported: $*" ;;
        esac ;;
    delete)
        case "${2:-}" in
            chain)
                has_chain "$3" "$4" "$5" || die "No such chain: $3 $4 $5"
                if awk -F '\t' -v f="$3" -v t="$4" -v c="$5" '$2 == f && $3 == t && $4 == c { found = 1 } END { exit !found }' "$S/rules"; then
                    die "Device or resource busy: $3 $4 $5 still has rules"
                fi
                if awk -F '\t' -v f="$3" -v t="$4" -v c="$5" '$2 == f && $3 == t && index($5, "\"target\":\"" c "\"") { found = 1 } END { exit !found }' "$S/rules"; then
                    die "Device or resource busy: a rule still jumps to $3 $4 $5"
                fi
                keep "$S/chains" ' ' "!(\$1 == \"$3\" && \$2 == \"$4\" && \$3 == \"$5\")" ;;
            set)
                has_set "$3" "$4" "$5" || die "No such set: $3 $4 $5"
                if awk -F '\t' -v f="$3" -v t="$4" -v s="@$5" '$2 == f && $3 == t && index($6, s) { found = 1 } END { exit !found }' "$S/rules"; then
                    die "Device or resource busy: a rule still references @$5"
                fi
                keep "$S/sets" ' ' "!(\$1 == \"$3\" && \$2 == \"$4\" && \$3 == \"$5\")"
                keep "$S/elements" ' ' "!(\$1 == \"$3\" && \$2 == \"$4\" && \$3 == \"$5\")" ;;
            rule)
                [[ "${6:-}" == handle && "${7:-}" =~ ^[0-9]+$ ]] || die "unsupported: $*"
                has_chain "$3" "$4" "$5" || die "No such chain: $3 $4 $5"
                keep "$S/rules" '\t' "!(\$1 == \"$7\" && \$2 == \"$3\" && \$3 == \"$4\" && \$4 == \"$5\")" ;;
            *) die "unsupported: $*" ;;
        esac ;;
    chain)
        # nft chain F T C '{ policy drop ; }' — set a base chain's policy.
        has_chain "$2" "$3" "$4" || die "No such chain: $2 $3 $4"
        [[ "${5:-}" =~ policy\ ([a-z]+) ]] || die "unsupported: $*"
        pol="${BASH_REMATCH[1]}"
        awk -v f="$2" -v t="$3" -v c="$4" -v p="$pol" \
            '$1 == f && $2 == t && $3 == c { if ($4 == "-") { print "fake nft: " c " is not a base chain" > "/dev/stderr"; exit 1 } $7 = p } { print }' \
            "$S/chains" > "$S/chains.new" && mv -- "$S/chains.new" "$S/chains" ;;
    *) die "unsupported: $*" ;;
esac
