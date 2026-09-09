#!/usr/bin/env bash
# Report, for every local IPv4 address, which interface a reply from that address
# would leave through — and flag the ones that would leave through a foreign one.
#
# An address whose replies exit via a different interface than the one holding it
# is asymmetrically routed: inbound connections to it from outside its own subnet
# will hang, while connections from within that subnet keep working.
#
#   ./check-return-path.sh              # check every address on the host
#   ./check-return-path.sh 192.168.1.224   # check one address
#   ./check-return-path.sh -t 1.1.1.1      # probe toward a different destination

set -euo pipefail

PROBE=8.8.8.8

usage() {
    echo "usage: $0 [-t probe-destination] [address ...]" >&2
    exit 2
}

while getopts ":t:h" opt; do
    case $opt in
        t) PROBE=$OPTARG ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

command -v ip >/dev/null || { echo "this script needs iproute2" >&2; exit 1; }

# address -> owning interface, skipping loopback and virtual overlay devices
declare -a ADDRS IFACES
if [ $# -gt 0 ]; then
    for a in "$@"; do
        owner=$(ip -4 -o addr show | awk -v a="$a" '$4 ~ "^"a"/" {print $2; exit}')
        ADDRS+=("$a"); IFACES+=("${owner:-?}")
    done
else
    while read -r iface cidr; do
        ADDRS+=("${cidr%%/*}"); IFACES+=("$iface")
    # Overlay, tunnel and container devices are excluded: their traffic is
    # encapsulated and leaves through a physical interface by design, which is
    # not the asymmetry this script looks for.
    done < <(ip -4 -o addr show scope global |
        awk '$2 !~ /^(lo|docker|veth|cali|flannel|cni|kube|br-|virbr|vxlan|tunl|wg|tail|ppp|zt)/ {print $2, $4}')
fi

[ ${#ADDRS[@]} -gt 0 ] || { echo "no global IPv4 addresses found"; exit 0; }

printf '%-12s %-18s %-28s %s\n' IFACE ADDRESS "REPLY LEAVES VIA" STATUS
problems=0

for i in "${!ADDRS[@]}"; do
    addr=${ADDRS[$i]}
    owner=${IFACES[$i]}

    if ! route=$(ip route get "$PROBE" from "$addr" 2>/dev/null); then
        printf '%-12s %-18s %-28s %s\n' "$owner" "$addr" "-" "NO ROUTE"
        problems=$((problems + 1))
        continue
    fi

    exit_if=$(sed -n 's/.*dev \([^ ]*\).*/\1/p' <<<"$route" | head -1)
    via=$(sed -n 's/.*via \([^ ]*\).*/\1/p' <<<"$route" | head -1)
    table=$(sed -n 's/.*table \([^ ]*\).*/\1/p' <<<"$route" | head -1)

    path="$exit_if${via:+ via $via}${table:+ (table $table)}"

    if [ "$owner" != "?" ] && [ "$exit_if" != "$owner" ]; then
        status="ASYMMETRIC"
        problems=$((problems + 1))
    else
        status="ok"
    fi

    printf '%-12s %-18s %-28s %s\n' "$owner" "$addr" "$path" "$status"
done

echo
echo "default routes:"
ip route show default | sed 's/^/  /'

rules=$(ip rule show | grep -v '^\(0\|32766\|32767\):' || true)
echo "source routing rules:"
if [ -n "$rules" ]; then
    sed 's/^/  /' <<<"$rules"
else
    echo "  none — every reply follows the lowest-metric default route"
fi

rp=$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null || echo "?")
case $rp in
    1) echo "rp_filter: 1 (strict) — inbound packets on asymmetric paths are dropped" ;;
    2) echo "rp_filter: 2 (loose) — asymmetric returns are accepted" ;;
    0) echo "rp_filter: 0 (off)" ;;
    *) echo "rp_filter: unknown" ;;
esac

if [ "$problems" -gt 0 ]; then
    echo
    echo "$problems address(es) would reply through a foreign interface."
    echo "Fix with a routing table per interface — see README.md."
    exit 1
fi
