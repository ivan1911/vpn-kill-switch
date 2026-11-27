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
# The persisted base anchor records the selection and each client's saved VPN server.
# One line per supported client: id|display name|bundle identifier. Keep it equal
# to VPNClient in VPNClient.swift. Tests/clients.sh fails when the two disagree.
client_table() {
    cat <<'CLIENT_TABLE'
shadowrocket|Shadowrocket|com.liguangming.Shadowrocket
happ-plus|Happ Plus|su.ffg.happ.plus
CLIENT_TABLE
}

client_field() {
    client_table | awk -F'|' -v id="$1" -v column="$2" '$1==id {print $column; found=1} END {exit !found}'
}
client_name() { client_field "$1" 2; }
client_bundle() { client_field "$1" 3; }
client_ids() { client_table | awk -F'|' '{print $1}'; }

# The PF enable token. Other runtime state (.flush-pending, .direct-rules,
# .direct-error) keeps this file name as its prefix so installed services upgrade cleanly.
token_file=/var/run/local.shadowrocket-guard.token

# The privileged scripts serialise every firewall change through this lock.
lock=/private/etc/.local.shadowrocket-guard.lock

validate_peer() {
    # Validate raw text before passing it to awk, which interprets backslashes in -v values.
    case "$1" in ''|*[!0-9.]*) return 1 ;; esac
    case "$2" in ''|*[!0-9]*) return 1 ;; esac
    case "$3" in tcp|udp) ;; *) return 1 ;; esac
    awk -v ip="$1" -v port="$2" 'BEGIN {
        if (split(ip, a, "[.]") != 4 || port !~ /^[1-9][0-9]*$/ || length(port)>5 || port+0>65535) exit 1
        for (i=1; i<=4; i++)
            if (a[i] !~ /^(0|[1-9][0-9]?[0-9]?)$/ || a[i]+0>255) exit 1
        if (a[1]+0==0 || a[1]+0==127 || a[1]+0>=224) exit 1
    }'
}

load_settings() {
    settings=$(awk -v ids="$(client_ids | tr '\n' ' ')" '
        BEGIN { n = split(ids, list, " "); for (i = 1; i <= n; i++) known[list[i]] = 1 }
        /^#[[:space:]]+client([:[:space:]]|$)/ {
            if (++clients != 1 || NF != 3 || $2 != "client:" || !($3 in known)) bad=1
            selected=$3
        }
        /^#[[:space:]]+endpoint([:[:space:]]|$)/ {
            if (NF != 6 || $2 != "endpoint" || $3 !~ /:$/ || !(substr($3, 1, length($3) - 1) in known) || ++seen[$3] != 1) bad=1
            saved[$3]=$4 " " $5 " " $6
            endpoints++
        }
        $1=="pass" && $2=="out" && $3=="quick" && $4=="inet" && $5=="proto" &&
        $7=="from" && $8=="any" && $9=="to" && $11=="port" {
            active=$10 " " $12 " " $6; rules++
        }
        END {
            if (bad || rules != 1) exit 1
            if (!clients && !endpoints) { selected="shadowrocket"; saved["shadowrocket:"]=active }
            if (saved[selected ":"] != active) exit 1
            print selected "|" saved["shadowrocket:"] "|" saved["happ-plus:"]
        }' "$1") || return 1
    IFS='|' read -r applied_client shadow_peer happ_peer <<EOF
$settings
EOF
    validate_saved_peer "$shadow_peer" && validate_saved_peer "$happ_peer"
}

# An empty saved VPN server is allowed; a saved one must be a valid "address port transport".
validate_saved_peer() {
    [ -z "$1" ] && return 0
    IFS=' ' read -r config_ip config_port config_transport <<EOF
$1
EOF
    validate_peer "$config_ip" "$config_port" "$config_transport"
}

selected_peer() {
    case "$applied_client" in
        shadowrocket) printf '%s\n' "$shadow_peer" ;;
        happ-plus) printf '%s\n' "$happ_peer" ;;
        *) return 1 ;;
    esac
}
pending=$token_file.flush-pending
# Stream diagnostics back to the process performing a one-shot mutation.
guard_debug() {
    [ -n "${VPN_KS_DEBUG_MARKER:-}" ] || return 0
    printf '%s %s %s\n' "$VPN_KS_DEBUG_MARKER" "$1" "$2" >&2 || :
}
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
# Sourced by the packaged guard, checker and uninstaller.
direct_file=/etc/vpn-ks-direct.conf
direct_preferences=/Library/Preferences/io.github.ivan1911.vpn-kill-switch.exceptions.plist
direct_journal=/var/run/local.shadowrocket-guard.routes

# IPv4 helpers shared by the awk programs below, which prepend this text.
direct_awk_lib='
    function dotted(v) { return sprintf("%d.%d.%d.%d",int(v/16777216),int(v/65536)%256,int(v/256)%256,v%256) }
    function cidr(v,b) { return dotted(v) "/" b }
    function to_int(ip, a,n,i,v) {
        n=split(ip,a,"."); v=0
        for (i=1;i<=4;i++) v=v*256+(i<=n?a[i]:0)
        return v
    }
'

# Canonical prefixes, one per line. Loopback is already handled by the base anchor.
direct_parse() {
    awk "$direct_awk_lib"'
    function number(s,max) { return s ~ /^(0|[1-9][0-9]*)$/ && length(s)<=3 && s+0<=max }
    function bad() { print "Invalid direct IPv4 entry at line " NR > "/dev/stderr"; exit 1 }
    {
        sub(/#.*/, ""); gsub(/^[[:space:]]+|[[:space:]]+$/, "")
        if ($0=="" || $0=="localhost" || $0=="::1") next
        n=split($0, parts, "/")
        if (n>2 || (n==2 && !number(parts[2],32))) bad()
        count=split(parts[1],oct,"[.]"); wildcard=oct[count]=="*"
        if (wildcard) { if (n!=1 || count<2 || count>4) bad(); bits=(count-1)*8; count-- }
        else { if (count!=4) bad(); bits=n==1 ? 32 : parts[2]+0 }
        ip=0
        for (i=1;i<=4;i++) {
            if (i<=count && !number(oct[i],255)) bad()
            ip=ip*256+(i<=count ? oct[i]+0 : 0)
        }
        step=2^(32-bits); if (ip%step!=0) bad()
        if (oct[1]==127 && bits>=8) next
        key=cidr(ip,bits)
        if (!(key in seen)) { seen[key]=1; print key }
    }' "$1"
}

# Old installations used a text file. Once the app saves its preferences,
# even an empty list takes precedence over the legacy values.
direct_read() {
    path=$direct_preferences
    if [ ! -e "$path" ] && [ ! -L "$path" ]; then path=$direct_file; fi
    [ ! -L "$path" ] || { echo 'The saved exceptions file is a symbolic link.' >&2; return 1; }
    [ -e "$path" ] || return 0
    [ -f "$path" ] || { echo 'The saved exceptions are not in a regular file.' >&2; return 1; }
    mode=$(stat -f '%u:%Lp' "$path") || return 1
    case "$mode" in 0:[0-7][0145][0145]) ;; *) echo 'Exception settings have unsafe permissions.' >&2; return 1 ;; esac
    # --list-direct uses EX_NOPERM only after the file itself passes safety checks.
    [ -r "$path" ] || { echo 'Administrator access is needed to read exceptions.' >&2; return 77; }
    if [ "$path" = "$direct_preferences" ]; then
        plutil -extract Destinations raw -expect string "$path" ||
            { echo 'The exception preferences are malformed.' >&2; return 1; }
    else cat "$path"; fi
}

direct_config() {
    direct_input=$(direct_read) || return 1
    printf '%s\n' "$direct_input" | direct_parse -
}

# Expose invalid legacy entries too so they can be removed in Settings.
direct_list() {
    input=$(direct_read) || return $?
    if normalized=$(printf '%s\n' "$input" | direct_parse - 2>/dev/null); then
        printf '%s' "$normalized"
    else
        printf '%s\n' "$input" | awk '{sub(/#.*/,""); gsub(/^[[:space:]]+|[[:space:]]+$/,""); if (length) print}'
    fi
}

# VPN defaults can be listed before the physical default. Only Ethernet/Wi-Fi
# interfaces with a numeric gateway qualify. Resolve anew on every service tick.
direct_uplink() {
    netstat -rn -f inet | awk '$1=="default" && $2 ~ /^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$/ && $4 ~ /^en[0-9]+$/ { print $4, $2; exit }'
}

direct_rules() {
    # Output PF's normalised spellings so comparing with -sr is deterministic.
    for prefix in $1; do
        host=${prefix%/32}
        [ "$prefix" != "0.0.0.0/0" ] || host=any
        if [ -n "$2" ]; then
            printf 'pass out quick on %s inet from (%s) to %s flags S/SA keep state (if-bound)\n' "$2" "$2" "$host"
        fi
        if [ "$host" = any ]; then echo 'block drop out quick inet all'
        else printf 'block drop out quick inet from any to %s\n' "$host"; fi
    done
}

# Destinations blocked by a direct rule set, one per line.
direct_destinations() {
    printf '%s\n' "$1" | sed -n -e 's|^block drop out quick inet from any to ||p' \
        -e 's|^block drop out quick inet all$|0.0.0.0/0|p'
}

# Destinations present in the previous rules ($1) and absent from the new ones ($2).
direct_removed() {
    { direct_destinations "$2"; echo --; direct_destinations "$1"; } | awk '
        $0 == "--" { old=1; next }
        !old { keep[$0]=1; next }
        !($0 in keep) && !($0 in done) { done[$0]=1; print }'
}

# route get can return a covering route. Require the precise destination/mask,
# the gateway and our protocol flag before deleting anything from the journal.
direct_route() (
    action=$1; prefix=$2; shift 2
    case "$prefix" in
        */32) route -n "$action" -host "${prefix%/32}" "$@" ;;
        *) route -n "$action" -net "$prefix" "$@" ;;
    esac
)

direct_owned() {
    direct_route get "$1" 2>/dev/null | awk -v prefix="$1" -v iface="$2" -v gw="$3" "$direct_awk_lib"'
        /destination:/ { dst=$2 }
        /mask:/ { mask=$2 }
        /gateway:/ { gateway=$2 }
        /interface:/ { dev=$2 }
        /flags:/ { flags=$2 }
        END {
            split(prefix,p,"/"); m=4294967296-2^(32-p[2])
            wanted=dotted(m)
            exit !(dst==p[1] && (p[2]==32 ? flags ~ /[<,]HOST[,>]/ : mask==wanted) &&
                   dev==iface && gateway==gw && flags ~ /[<,]PROTO1[,>]/ && flags !~ /[<,]IFSCOPE[,>]/)
        }'
}

direct_reconcile_routes() (
    desired=$1; iface=$2; gw=$3
    forget_route() {
        read -r net old_if old_gw < "$1" || return 1
        if direct_owned "$net" "$old_if" "$old_gw"; then
            direct_route delete "$net" "$old_gw" >/dev/null || return 1
        fi
        rm -f "$1"
    }
    # Retire old-uplink routes first so the planner sees the new network.
    for record in "$direct_journal"/*; do
        [ -f "$record" ] || continue
        read -r net old_if old_gw < "$record" || return 1
        if [ -z "$desired" ] || [ "$iface $gw" != "$old_if $old_gw" ]; then
            forget_route "$record" || return 1
        fi
    done
    if [ -n "$desired" ] && [ -n "$iface" ]; then
        desired=$(direct_plan "$desired" "$iface") || return 1
    fi
    for record in "$direct_journal"/*; do
        [ -f "$record" ] || continue
        read -r net old_if old_gw < "$record" || return 1
        if ! printf '%s\n' "$desired" | grep -Fxq "$net"; then
            forget_route "$record" || return 1
        elif ! direct_owned "$net" "$old_if" "$old_gw"; then
            rm -f "$record"
        fi
    done
    [ -n "$iface" ] && [ -n "$desired" ] || return 0
    mkdir -p "$direct_journal" || return 1
    failed=0
    for net in $desired; do
        record="$direct_journal/${net%/*}-${net#*/}"
        [ ! -f "$record" ] || continue
        printf '%s %s %s\n' "$net" "$iface" "$gw" > "$direct_journal/.next" && mv -f "$direct_journal/.next" "$record" || return 1
        # Darwin link_addr needs the trailing colon to encode an interface name.
        if ! direct_route add "$net" "$gw" -ifp "${iface}:" -proto1 >/dev/null; then
            rm -f "$record"; failed=1
        elif ! direct_owned "$net" "$iface" "$gw"; then
            failed=1
        fi
    done
    return "$failed"
)

# A VPN can install routes more specific than an excluded network. Cover its
# subnets too. When an exact route belongs to the VPN, use two narrower routes
# instead of replacing it. A conflicting /32 has no narrower route.
direct_plan() {
    direct_table=$(netstat -rn -f inet) || return 1
    printf '%s\n' "$direct_table" | awk -v targets="$(printf '%s' "$1" | tr '\n' ' ')" -v uplink="$2" "$direct_awk_lib"'
        # The nearest covering unscoped route determines the effective interface.
        # Owned routes remain desired until their prefix is removed from the config.
        function plan(v,b, k,j,size,parent) {
            k=cidr(v,b); if (planned[k]++) return
            if (k=="0.0.0.0/0") {plan(0,1);plan(2147483648,1);return}
            if (k in devices) {
                if (devices[k]==uplink || devices[k]=="lo0") {
                    if (owned[k]) print k
                    return
                }
                if (b<32) {plan(v,b+1);plan(v+2^(31-b),b+1);return}
            }
            for (j=b-1;j>=0;j--) {
                size=2^(32-j);parent=cidr(int(v/size)*size,j)
                if (parent in devices) break
            }
            if (k in devices || !(parent in devices) || devices[parent]!=uplink || owned[parent]) print k
        }
        $4!="" && $3 ~ /U/ && $3 !~ /I/ {
            if ($1=="default") k="0.0.0.0/0"
            else {
                if ($1 !~ /^[0-9.\/]+$/) next
                n=split($1,p,"/"); octets=split(p[1],a,".")
                bits=n==2?p[2]+0:($3 ~ /H/?32:octets*8)
                k=cidr(to_int(p[1]),bits)
            }
            devices[k]=$4
            owned[k]=($3 ~ /1/)
        }
        END {
            count=split(targets,t,/[[:space:]]+/)
            for (i=1;i<=count;i++) {
                split(t[i],p,"/"); v=to_int(p[1]); bits=p[2]+0; span=2^(32-bits)
                plan(v,bits)
                for (k in devices) {
                    split(k,p,"/"); w=to_int(p[1])
                    if (p[2]+0>bits && w>=v && w<v+span && (devices[k]!=uplink || owned[k])) plan(w,p[2]+0)
                }
            }
        }'
}
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
