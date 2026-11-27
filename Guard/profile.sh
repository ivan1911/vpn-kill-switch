# Run scutil in the logged-in user's session to see Network Extension profiles.
profile_scutil() {
    if [ "$(id -u)" = 0 ]; then
        if ! owner=$(stat -f '%u' /dev/console); then
            guard_debug vpn.context console-lookup-failed
            return 1
        fi
        if [ "$owner" -ge 501 ]; then
            guard_debug vpn.context console-user
            /bin/launchctl asuser "$owner" /usr/bin/sudo -n -u "#$owner" /usr/sbin/scutil --nc "$@"
            return
        fi
        guard_debug vpn.context root-direct
    else
        guard_debug vpn.context user-direct
    fi
    /usr/sbin/scutil --nc "$@"
}

vpn_profile() {
    bundle=$(client_bundle "$1") || return 1
    if ! profiles=$(profile_scutil list); then
        guard_debug vpn.list failed
        return 1
    fi
    matches=$(printf '%s\n' "$profiles" | awk -v provider="$bundle" '
        $1=="*" && $4=="VPN" && $5=="(" provider ")" &&
        $NF=="[VPN:" provider "]" &&
        $3 ~ /^[[:xdigit:]]{8}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{4}-[[:xdigit:]]{12}$/ {
            service=$3; count++
        }
        END { if (count==0) print "none"; else if (count>1) print "multiple"; else print service }
    ') || { guard_debug vpn.list parse-failed; return 1; }
    case "$matches" in
        none|multiple) guard_debug vpn.profiles "$matches"; return 1 ;;
    esac
    guard_debug vpn.profiles one
    printf '%s\n' "$matches"
}

vpn_status() {
    service=$(vpn_profile "$1") || return 1
    profile_scutil status "$service" || { guard_debug vpn.status failed; return 1; }
}

vpn_interface() {
    newline='
'
    state=${1%%"$newline"*}
    case "$state" in
        Connected|Connecting|Disconnected|Disconnecting|Invalid) ;;
        *) state=unknown ;;
    esac
    guard_debug vpn.state "$state"
    [ "$state" = Connected ] || return 0
    iface=$(printf '%s\n' "$1" | awk '
        $1=="InterfaceName" && $3 ~ /^utun[0-9]+$/ { seen[$3]=1 }
        END {
            for (name in seen) { count++; iface=name }
            if (count==0) print "missing"; else if (count>1) print "ambiguous"; else print iface
        }
    ') || { guard_debug vpn.interface parse-failed; return 1; }
    case "$iface" in
        missing|ambiguous) guard_debug vpn.interface "$iface" ;;
        *)
            if ifconfig "$iface" >/dev/null 2>&1; then
                guard_debug vpn.interface "$iface"
                printf '%s\n' "$iface"
            else
                guard_debug vpn.interface-candidate "$iface"
                guard_debug vpn.interface not-present
            fi
            ;;
    esac
}
