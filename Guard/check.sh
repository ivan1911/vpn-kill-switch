#!/bin/sh
# Read-only status check for the VPN guard.
#
# With --porcelain, stdout holds only stable key=value lines for the menu app;
# the human sentences are not part of that contract. Keys:
#   protection=on|off|unknown   tunnel=utunN|none|unrestricted
#   client=<id>  client-name=<display name>  vpn=<state>  vpn-interface=utunN
#   direct=<comma list>  direct-waiting=yes
#   problem=invalid-direct|direct-routes|tunnel
# Exit codes are the same in both forms.
set -u
export LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin
anchor=local.shadowrocket-guard
file=/etc/pf.anchors/$anchor
. "$(dirname "$0")/config.sh"
pending=$token_file.flush-pending
. "$(dirname "$0")/debug.sh"
. "$(dirname "$0")/profile.sh"
. "$(dirname "$0")/direct.sh"
if [ "${1:-}" = --list-direct ]; then direct_list; exit $?; fi
if [ "${1:-}" = --validate-direct ]; then [ "$#" = 2 ] && direct_parse "$2"; exit $?; fi
if [ "${1:-}" = --profile-id ]; then
    [ -r "$file" ] && load_settings "$file" && vpn_profile "$applied_client"
    exit $?
fi

porcelain=
if [ "${1:-}" = --porcelain ]; then porcelain=yes; fi

pf_read() {
    if [ "$(id -u)" = 0 ]; then /sbin/pfctl "$@"; else sudo /sbin/pfctl "$@"; fi
}
unknown() {
    [ -z "$porcelain" ] || echo 'protection=unknown'
    echo 'Protection status unknown.' >&2
    exit 2
}
describe_vpn() {
    if ! [ -r "$file" ] || ! load_settings "$file"; then return; fi
    display=$(client_name "$applied_client")
    vpn=$(vpn_status "$applied_client") || vpn=
    status=$(printf '%s\n' "$vpn" | head -n 1)
    current=$(vpn_interface "$vpn")
}
print_vpn() {
    [ -n "${display:-}" ] || return 0
    if [ -n "$porcelain" ]; then
        case "${status:-}" in
            Connected|Connecting|Disconnected|Disconnecting|Invalid) vpn_key=$status ;;
            *) vpn_key=unknown ;;
        esac
        printf 'client=%s\nclient-name=%s\nvpn=%s\n' "$applied_client" "$display" "$vpn_key"
        if [ -n "${current:-}" ]; then printf 'vpn-interface=%s\n' "$current"; fi
    else
        printf '%s: %s%s\n' "$display" "${status:-unknown}" "${current:+ ($current)}"
    fi
}
# Print a human sentence, or the matching porcelain line.
say() {
    if [ -n "$porcelain" ]; then [ -z "$2" ] || printf '%s\n' "$2"; else printf '%s\n' "$1"; fi
}
stable() {
    # A lock or durable pending marker prevents a snapshot from certifying
    # rules read in the middle of a transaction.
    [ ! -e "$lock" ] && [ ! -e "$pending" ]
}
info=$(pf_read -si) || unknown
case "$info" in
    "Status: Disabled"*)
        describe_vpn
        [ ! -e "$lock" ] || unknown
        say 'Protection: off (pf disabled).' protection=off
        say 'Allowed tunnel: unrestricted (pf disabled).' tunnel=unrestricted
        print_vpn
        exit 1 ;;
    "Status: Enabled"*) ;;
    *) unknown ;;
esac
root_rules=$(pf_read -sr) || unknown
guard_entry='anchor "local.shadowrocket-guard" quick all'
if ! printf '%s\n' "$root_rules" | grep -Fxq "$guard_entry"; then
    describe_vpn
    [ ! -e "$lock" ] || unknown
    say 'Protection: off (guard rule inactive).' protection=off
    say 'Allowed tunnel: unrestricted by this guard.' tunnel=unrestricted
    print_vpn
    exit 1
fi
stable || unknown
describe_vpn
[ -n "${display:-}" ] || unknown
original_settings=$settings

# An earlier filter rule could take priority over the guard.
first=$(printf '%s\n' "$root_rules" | awk '/^(anchor|pass|block|match|antispoof)[[:space:]]/ {print; exit}')
base_rules=$(pf_read -a "$anchor" -sr) || unknown
tunnel_rules=$(pf_read -a "$anchor/tunnel" -sr) || unknown

# Accept only the installed guard's exceptions before its final block.
# Missing exceptions can restrict connectivity further.
# Compare the live rules with the narrow VPN server saved in the root-owned anchor.
peer=$(selected_peer) || unknown
IFS=' ' read -r ip port proto <<EOF
$peer
EOF
base_ok=$(printf '%s\n' "$base_rules" | awk -v ip="$ip" -v port="$port" -v proto="$proto" '
    seen_block { unexpected=1 }
    /^pass quick on lo0 all no state$/ { next }
    /^pass out quick inet proto udp from any port = 68 to 255[.]255[.]255[.]255 port = 67 no state$/ { next }
    /^pass in quick inet proto udp from any port = 67 to any port = 68 no state$/ { next }
    $0 == ("pass out quick inet proto " proto " from any to " ip " port = " port " no state") { out++; next }
    $0 == ("pass in quick inet proto " proto " from " ip " port = " port " to any no state") { inc++; next }
    /^anchor "tunnel" quick all$/ { seen_tunnel=1; next }
    /^block drop quick all$/ { seen_block=1; next }
    { unexpected=1 }
    END { print (seen_block && seen_tunnel && inc==1 && out==1 && !unexpected) ? "yes" : "no" }
')
allowed=$(printf '%s\n' "$tunnel_rules" | awk '/^pass quick on utun[0-9]+ all no state$/ {print $4}')
valid_direct=yes
nets=$(direct_config) || { valid_direct=no; nets=; }
uplink=
if [ -n "$nets" ]; then uplink=$(direct_uplink | awk '{print $1}'); fi
wanted=$(
    direct_rules "$nets" "$uplink"
    if [ -n "$allowed" ]; then printf 'pass quick on %s all no state\n' "$allowed"; fi
)
if [ "$first" != "$guard_entry" ] || [ "$base_ok" != yes ] ||
   [ "$wanted" != "$tunnel_rules" ]; then
    if [ -z "$porcelain" ]; then
        echo 'Rules differ from the saved configuration. Active tunnel rules:'
        printf '%s\n' "${tunnel_rules:-none}"
    fi
    unknown
fi

stable && load_settings "$file" && [ "$settings" = "$original_settings" ] || unknown
final_valid=yes
final_nets=$(direct_config) || { final_valid=no; final_nets=; }
[ "$valid_direct" = "$final_valid" ] && [ "$nets" = "$final_nets" ] || unknown
say 'Protection: on.' protection=on
direct_list_text=$(printf '%s\n' "$nets" | paste -sd, -)
if [ -n "$nets" ]; then say "Direct IPv4 destinations: $direct_list_text" "direct=$direct_list_text"; fi
if [ -n "$nets" ] && [ -z "$uplink" ]; then
    say 'Direct IPv4 destinations are waiting for Wi-Fi or Ethernet.' direct-waiting=yes
fi
if [ -z "$porcelain" ]; then printf 'VPN server: %s:%s/%s\n' "$ip" "$port" "$proto"; fi
say "Allowed tunnel: ${allowed:-none}" "tunnel=${allowed:-none}"
print_vpn
if [ "$valid_direct" = no ]; then
    say 'Invalid direct IPv4 configuration.' problem=invalid-direct
    exit 2
fi
if [ -f "$token_file.direct-error" ]; then
    say 'Direct IPv4 routing is unavailable for one or more destinations.' problem=direct-routes
    exit 2
fi
case "$status" in
    Connected) [ -n "$allowed" ] && [ "$allowed" = "$current" ] && exit 0 ;;
    Disconnected|'') [ -z "$allowed" ] && exit 0 ;;
esac
say 'VPN and tunnel rules differ. Check again in 5 seconds.' problem=tunnel
exit 2
