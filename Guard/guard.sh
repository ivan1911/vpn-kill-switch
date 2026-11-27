#!/bin/sh
# selected-vpn-client
# direct-ipv4-config
# direct-ipv4-preferences
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
umask 077
anchor=local.shadowrocket-guard
saved_file=/etc/pf.anchors/$anchor
file=$saved_file
. "$(dirname "$0")/config.sh"
. "$(dirname "$0")/debug.sh"
. "$(dirname "$0")/profile.sh"
. "$(dirname "$0")/direct.sh"

selected_interface() {
    if load_settings "$1" && vpn=$(vpn_status "$applied_client"); then vpn_interface "$vpn"; fi
}
if [ "${1:-}" = --check ]; then
    iface=$(selected_interface "${2:-$file}")
    echo "${iface:-blocked}"
    exit 0
fi
# Apply can verify a candidate while keeping the previous file installed.
if [ "${1:-}" = --install-tick ] && [ "$#" = 2 ]; then file=$2; fi

# An installer transaction already holds the config.sh lock when it calls --install-tick.
stage=
cleanup() {
    if [ -n "$stage" ]; then rm -rf "$stage"; fi
    if [ "${1:-}" != --install-tick ]; then rm -f "$lock"; fi
}
if [ "${1:-}" != --install-tick ]; then
    shlock -f "$lock" -p "$$" || exit 0
fi
trap 'cleanup "${1:-}"' EXIT
. /Library/PrivilegedHelperTools/local.shadowrocket-killswitch/policy.sh
conf=/etc/pf.conf
pending=$token_file.flush-pending
repair_root() {
    # Rebuild from the current config, preserving other services' rules.
    stage=$(mktemp -d /private/etc/.srguard.XXXXXXXX)
    cp -p "$conf" "$stage/main"
    render_root "$conf" > "$stage/main"
    runtime_config=$stage/main
    replacement=$file
    if [ "${1:-}" = --blocked ]; then
        replacement=$stage/blocked
        printf 'block drop quick all\n' > "$replacement"
    fi
    if [ "$replacement" != "$saved_file" ]; then
        runtime_config=$stage/runtime
        awk -v from="load anchor \"$anchor\" from \"$saved_file\"" \
            -v to="load anchor \"$anchor\" from \"$replacement\"" \
            '$0 == from { $0=to } { print }' "$stage/main" > "$runtime_config"
    fi
    preview=$(pfctl -nvf "$runtime_config")
    printf '%s\n' "$preview" | guard_first
    touch "$pending"
    close_guard "$anchor"
    pfctl -f "$runtime_config"
    rootrules=$(pfctl -sr)
    printf '%s\n' "$rootrules" | guard_first
    if [ "${1:-}" != --blocked ] && ! cmp -s "$stage/main" "$conf"; then mv -f "$stage/main" "$conf"; fi
}
rootrules=$(pfctl -sr)
# Compare with PF's normalized representation of the root-owned peer policy.
if ! load_settings "$file" || ! expected=$(pfctl -a "$anchor" -nvf "$file" 2>/dev/null) ||
   [ "$(printf '%s\n' "$expected" | tail -n 1)" != 'block drop quick all' ]; then
    touch "$pending"
    if ! printf '%s\n' "$rootrules" | guard_first; then repair_root --blocked; fi
    close_guard "$anchor"
    enable_guard "$token_file"
    pfctl -F states
    guard_is_enabled
    echo 'The saved VPN configuration is invalid; the VPN guard is blocking traffic.' >&2
    exit 1
fi
if ! printf '%s\n' "$rootrules" | guard_first; then repair_root; fi
actual=$(pfctl -a "$anchor" -sr)
if [ "$expected" != "$actual" ]; then
    touch "$pending"
fi
if [ "$file" = "$saved_file" ]; then
    enable_guard "$token_file"
else
    guard_is_enabled || { echo 'PF stopped during Apply.' >&2; exit 1; }
fi
if [ -e "$pending" ]; then
    # A failed Apply may have left either version of the base anchor loaded.
    # Revoke its allowances and flush states before restoring the saved policy.
    close_guard "$anchor"
    pfctl -F states
    pfctl -a "$anchor" -f "$file"
    [ "$(pfctl -a "$anchor" -sr)" = "$expected" ]
    rm -f "$pending"
fi
# Read the selected service after locking, close to the tunnel-rule update.
iface=
if vpn=$(vpn_status "$applied_client"); then iface=$(vpn_interface "$vpn"); fi
current=$(pfctl -a "$anchor/tunnel" -sr)
bad_config=no
nets=$(direct_config) || { nets=; bad_config=yes; }
uplink= gateway=
if [ -n "$nets" ]; then
    read -r uplink gateway <<EOF
$(direct_uplink)
EOF
fi
direct=$(direct_rules "$nets" "$uplink")
wanted=$(
    if [ -n "$direct" ]; then printf '%s\n' "$direct"; fi
    if [ -n "$iface" ]; then printf 'pass quick on %s all no state\n' "$iface"; fi
)
# PF states survive a rule replacement. Remember the last direct policy even
# when an external PF reload drops the child anchor before the next tick.
remembered=
if [ -f "$token_file.direct-rules" ]; then remembered=$(cat "$token_file.direct-rules"); fi
old_direct=$(printf '%s\n' "$current" | sed '/^pass quick on utun[0-9][0-9]* all no state$/d')
# Direct pass rules are if-bound, so a state made on a previous uplink cannot
# carry traffic on another one. Only a removed destination needs its states
# dropped. Compare destination sets, not rule text, which embeds the uplink.
removed=$(direct_removed "$remembered
$old_direct" "$direct")
if [ -n "$removed" ]; then
    touch "$pending"
    pfctl -a "$anchor/tunnel" -F rules
    if printf '%s\n' "$removed" | grep -Fxq 0.0.0.0/0; then
        pfctl -F states
    else
        for destination in $removed; do pfctl -k 0.0.0.0/0 -k "$destination"; done
    fi
    current=
    rm -f "$pending"
fi
if [ "$remembered" != "$direct" ]; then
    printf '%s\n' "$direct" > "$token_file.direct-rules.next"
    mv -f "$token_file.direct-rules.next" "$token_file.direct-rules"
fi
if [ "$current" != "$wanted" ]; then
    if [ -n "$wanted" ]; then printf '%s\n' "$wanted" | pfctl -a "$anchor/tunnel" -f -
    else pfctl -a "$anchor/tunnel" -F rules; fi
fi
# Without an uplink the destinations stay blocked and wait for Wi-Fi or Ethernet.
if ! direct_reconcile_routes "$nets" "$uplink" "$gateway"; then
    touch "$token_file.direct-error"
    echo 'Direct IPv4 routing is unavailable for one or more destinations.' >&2
    exit 1
fi
rm -f "$token_file.direct-error"
[ "$bad_config" = no ]
