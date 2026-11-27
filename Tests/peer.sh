#!/bin/sh
set -eu
cd "$(dirname "$0")/.."
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
for proto in tcp udp; do
    sh Guard/peer.sh --render 203.0.113.9 443 "$proto" < Guard/guard.pf > "$dir/rules"
    [ "$(sh Guard/peer.sh --get "$dir/rules")" = "203.0.113.9 443 $proto" ]
    /sbin/pfctl -a local.shadowrocket-test -R -nf "$dir/rules" >/dev/null 2>&1
    grep -Fxq 'block drop quick all' "$dir/rules"
    grep -Fxq 'anchor "tunnel" quick' "$dir/rules"
    if grep -qF '# VPN endpoint rules' "$dir/rules"; then exit 1; fi
done
for triple in '0.0.0.0 443 tcp' '127.0.0.1 443 tcp' '224.0.0.1 5 tcp' '10.0.0.256 1 tcp' 'example.org 80 tcp' '203.0.113.1 0 tcp' '203.0.113.1 65536 tcp' '203.0.113.1 443 all'; do
    set -- $triple
    if sh Guard/peer.sh --render "$@" < Guard/guard.pf >/dev/null 2>&1; then exit 1; fi
done
if sh Guard/peer.sh --get Guard/guard.pf; then exit 1; fi
sh Guard/peer.sh --render 198.51.100.7 443 tcp < Guard/guard.pf > "$dir/legacy"
sed '/^# client:/d; /^# endpoint /d' "$dir/legacy" > "$dir/old"
sh Guard/peer.sh --render 203.0.113.9 8443 udp happ-plus "$dir/old" < Guard/guard.pf > "$dir/happ"
grep -Fxq '# client: happ-plus' "$dir/happ"
grep -Fxq '# endpoint shadowrocket: 198.51.100.7 443 tcp' "$dir/happ"
grep -Fxq '# endpoint happ-plus: 203.0.113.9 8443 udp' "$dir/happ"
[ "$(sh Guard/peer.sh --get "$dir/happ")" = '203.0.113.9 8443 udp' ]
cat "$dir/happ" "$dir/happ" > "$dir/duplicate"
if sh Guard/peer.sh --get "$dir/duplicate"; then exit 1; fi
sed 's/# endpoint happ-plus: 203.0.113.9/# endpoint happ-plus: 203.0.113.10/' "$dir/happ" > "$dir/mismatch"
if sh Guard/peer.sh --get "$dir/mismatch"; then exit 1; fi
echo 'Peer validation, legacy import, TCP/UDP rendering and pf syntax OK'
