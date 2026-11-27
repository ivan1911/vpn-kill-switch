#!/bin/sh
# --get reads the active VPN server from an existing anchor, including legacy anchors.
# --render and --apply take a trusted base template on stdin.
set -eu
export LC_ALL=C PATH=/usr/bin:/bin:/usr/sbin:/sbin
anchor=local.shadowrocket-guard
file=/etc/pf.anchors/$anchor
label=local.shadowrocket-killswitch
base=/Library/PrivilegedHelperTools/$label
plist=/Library/LaunchDaemons/$label.plist
. "$(dirname "$0")/config.sh"
pending=$token_file.flush-pending
. "$(dirname "$0")/policy.sh"
# @@UPGRADE_SERVICE@@

render() {
    if [ -n "${5:-}" ] && [ -e "$5" ]; then
        load_settings "$5" || { echo 'Could not read the saved VPN configuration.' >&2; return 1; }
    else
        applied_client=shadowrocket
        shadow_peer=
        happ_peer=
    fi
    target=${4:-$applied_client}
    case "$target" in
        shadowrocket) shadow_peer="$1 $2 $3" ;;
        happ-plus) happ_peer="$1 $2 $3" ;;
        *) echo 'Unsupported VPN client.' >&2; return 2 ;;
    esac
    awk -v ip="$1" -v port="$2" -v proto="$3" -v client="$target" -v shadow="$shadow_peer" -v happ="$happ_peer" '
        $0=="# VPN endpoint rules" {
            print "# client:",client
            if (shadow!="") print "# endpoint shadowrocket:",shadow
            if (happ!="") print "# endpoint happ-plus:",happ
            print "pass out quick inet proto",proto,"from any to",ip,"port",port,(proto=="tcp"?"flags any no state":"no state")
            print "pass in quick inet proto",proto,"from",ip,"port",port,"to any",(proto=="tcp"?"flags any no state":"no state")
            markers++; next
        }
        {print}
        END {if (markers!=1) exit 1}'
}

mode=${1:-}
case "$mode" in
    --get)
        [ "$#" = 2 ] && load_settings "$2" && selected_peer
        exit $? ;;
    --render|--apply) shift ;;
    *) exit 2 ;;
esac
if [ "$#" -lt 3 ] || [ "$#" -gt 5 ] || ! validate_peer "$1" "$2" "$3"; then
    echo 'Invalid IPv4 address, port, or transport.' >&2
    exit 2
fi
if [ "$mode" = --render ]; then render "$@"; exit; fi
[ "$#" -le 4 ] && [ "$(id -u)" = 0 ] || exit 1

umask 077
stage=$(mktemp -d /private/etc/.srpeer.XXXXXXXX)
trap 'rm -rf "$stage"' EXIT
shlock -f "$lock" -p "$$" || { echo 'Another firewall operation is in progress.' >&2; exit 1; }
changed=no
restore_protection() {
    touch "$pending" || return 1
    close_guard "$anchor" || return 1
    rules=$(pfctl -sr) || return 1
    if printf '%s\n' "$rules" | guard_first; then
        enable_guard "$token_file" && pfctl -F states && guard_is_enabled
    else
        # A concurrent system rules reload may have removed the guard hook.
        "$base/guard" --install-tick
    fi
}
finish() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$rc" -ne 0 ] && [ "$changed" = yes ]; then
        restore_protection || echo 'The VPN guard could not verify recovery.' >&2
        echo 'The VPN configuration was not applied. The guard will retry the previous configuration.' >&2
    fi
    rm -rf "$stage"
    rm -f "$lock"
    exit "$rc"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
render "$1" "$2" "$3" "${4:-}" "$file" > "$stage/candidate"
expected=$(pfctl -a "$anchor" -nvf "$stage/candidate")
[ "$(printf '%s\n' "$expected" | tail -n 1)" = 'block drop quick all' ] || {
    echo 'The VPN configuration does not have a final blocking rule.' >&2
    exit 1
}
chmod 644 "$stage/candidate"

rules=$(pfctl -sr)
live=no
if printf '%s\n' "$rules" | guard_first; then
    live=yes
elif [ -f "$plist" ] || printf '%s\n' "$rules" | grep -Fxq 'anchor "local.shadowrocket-guard" quick all'; then
    echo 'The installed guard is recovering. Check protection and retry Apply.' >&2
    exit 1
fi

if [ "$live" = yes ]; then
    if ! [ -x "$base/guard" ] || ! [ -f "$plist" ]; then
        echo 'The installed VPN service is incomplete. Reinstall the kill switch before applying settings.' >&2
        exit 1
    fi
    if ! grep -Fxq '# direct-ipv4-preferences' "$base/guard"; then upgrade_service; fi
    launchctl print "system/$label" >/dev/null 2>&1 || {
        echo 'The installed VPN service is inactive. Reinstall the kill switch before applying settings.' >&2
        exit 1
    }
    guard_is_enabled || { echo 'PF is inactive. Check protection and retry Apply.' >&2; exit 1; }
    # Keep the saved file unchanged until the new ruleset is verified.
    touch "$pending"
    changed=yes
    close_guard "$anchor"
    pfctl -F states
    pfctl -a "$anchor" -f "$stage/candidate"
    [ "$(pfctl -a "$anchor" -sr)" = "$expected" ]
    rm -f "$pending"
    "$base/guard" --install-tick "$stage/candidate"
    rules=$(pfctl -sr)
    printf '%s\n' "$rules" | guard_first
    [ "$(pfctl -a "$anchor" -sr)" = "$expected" ]
    launchctl print "system/$label" >/dev/null 2>&1
    guard_is_enabled || { echo 'PF stopped during Apply.' >&2; exit 1; }
fi
# Closing the admin prompt before execution leaves policy untouched. Once the
# live rules have been verified, finish the atomic commit despite a signal.
trap '' HUP INT TERM
mv -f "$stage/candidate" "$file"
changed=no
