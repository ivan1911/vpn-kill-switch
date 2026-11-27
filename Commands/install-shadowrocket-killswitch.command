#!/bin/sh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
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
# Stream diagnostics back to the process performing a one-shot mutation.
guard_debug() {
    [ -n "${VPN_KS_DEBUG_MARKER:-}" ] || return 0
    printf '%s %s %s\n' "$VPN_KS_DEBUG_MARKER" "$1" "$2" >&2 || :
}
# VPNClient.isInstalled in the app makes the same check with AppKit. This shell copy exists because
# the root installer has no AppKit, so it asks Launch Services in the desktop user's session.
# Query Launch Services in the desktop user's session without opening the app.
client_installed() {
    id=$(client_bundle "$1") || return 1
    set -- /usr/bin/osascript -l JavaScript
    if [ "$(id -u)" = 0 ]; then
        owner=$(stat -f '%u' /dev/console) || return 1
        [ "$owner" -ne 0 ] || return 1
        set -- /bin/launchctl asuser "$owner" /usr/bin/sudo -n -H -u "#$owner" "$@"
    fi
    "$@" - "$id" >/dev/null 2>&1 <<'JXA'
ObjC.import('AppKit')
function run(argv) {
    const id = argv[0]
    const urls = $.NSWorkspace.sharedWorkspace.URLsForApplicationsWithBundleIdentifier(id)
    for (let i = 0; i < urls.count; i++) {
        const url = urls.objectAtIndex(i).URLByResolvingSymlinksInPath
        const path = ObjC.unwrap(url.path)
        if (/(^|\/)(\.Trash|\.Trashes|AppTranslocation)(\/|$)/.test(path)) continue
        const readOnly = Ref()
        if (!url.getResourceValueForKeyError(readOnly, $.NSURLVolumeIsReadOnlyKey, null) ||
            ObjC.unwrap(readOnly[0])) continue
        const bundle = $.NSBundle.bundleWithURL(url)
        if (ObjC.unwrap(bundle.bundleIdentifier) === id &&
            ObjC.unwrap(bundle.executablePath) &&
            $.NSFileManager.defaultManager.isExecutableFileAtPath(bundle.executablePath)) return
    }
    throw Error('VPN app unavailable')
}
JXA
}
require_client() {
    client_installed "$1" || {
        name=$(client_name "$1") || return 1
        echo "$name is required. Install it in Applications and connect before installing the kill switch." >&2
        return 1
    }
}

case "${1:-}" in
    --check-shadowrocket) require_client shadowrocket; exit $? ;;
    --check-client) [ "$#" = 2 ] && client_installed "$2"; exit $? ;;
esac
if [ "${1:-}" != --remove ]; then
    guard_debug install.stage precheck
    configured=/etc/pf.anchors/local.shadowrocket-guard
    applied_client=shadowrocket
    if [ -e "$configured" ]; then
        load_settings "$configured" || { echo 'Set a valid VPN server in Settings first.' >&2; exit 1; }
    fi
    require_client "$applied_client"
    guard_debug install.stage precheck-passed
fi
if [ "$(id -u)" != 0 ]; then exec /usr/bin/sudo /bin/sh "$0" "$@"; fi
umask 077
label=local.shadowrocket-killswitch
base=/Library/PrivilegedHelperTools/$label
plist=/Library/LaunchDaemons/$label.plist
anchor=/etc/pf.anchors/local.shadowrocket-guard
conf=/etc/pf.conf
stage=$(mktemp -d /private/etc/.srguard.XXXXXXXX)
trap 'rm -rf "$stage"' EXIT
shlock -f "$lock" -p "$$" || { echo 'Another firewall operation is in progress.' >&2; exit 1; }
trap 'rm -rf "$stage"; rm -f "$lock"' EXIT
# Only remove our own two configuration lines. Preserve edits by other services.
awk '$0 != "anchor \"local.shadowrocket-guard\" quick" && $0 != "load anchor \"local.shadowrocket-guard\" from \"/etc/pf.anchors/local.shadowrocket-guard\""' "$conf" > "$stage/clean"
saveconf() {
    install -o root -g wheel -m 644 "$1" "$stage/new.conf" || return 1
    mv -f "$stage/new.conf" "$conf"
}
unload() {
    if launchctl print "system/$label" >/dev/null 2>&1; then launchctl bootout "system/$label"; fi
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
if [ "${1:-}" = --remove ]; then
    pfctl -nf "$stage/clean"
    cp -p "$conf" "$stage/original.conf"
    unload
    if ! direct_reconcile_routes "" "" ""; then
        if [ -f "$plist" ]; then launchctl bootstrap system "$plist"; fi
        echo 'Could not remove direct routes. Retry removal.' >&2
        exit 1
    fi
    rm -f "$token_file.direct-rules" "$token_file.direct-error"
    replaced=no
    if ! { saveconf "$stage/clean" && replaced=yes && pfctl -f "$conf"; }; then
        # Leave the system as it was before removal started.
        if [ "$replaced" = yes ]; then saveconf "$stage/original.conf" || echo 'Could not restore pf.conf.' >&2; fi
        if [ -f "$plist" ]; then launchctl bootstrap system "$plist"; fi
        echo 'Could not remove the firewall configuration. Retry removal.' >&2
        exit 1
    fi
    if [ -s "$token_file" ]; then pfctl -X "$(cat "$token_file")" || true; fi
    # The detached anchor stores the applied VPN profile for the next install.
    rm -f "$token_file" "$token_file.flush-pending" "$base/policy.sh" "$plist" "$base/guard" "$base/on-connect" "$base/killswitch" "$base/remove"
    rmdir "$base" 2>/dev/null || true
    rm -rf "$direct_journal"
    echo 'VPN protection removed.'
    exit 0
fi
cat > "$stage/peer" <<'EMBEDDED_FILE'
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
# Shared by the standalone installer and the root service.
render_root() {
    awk '
        function hook() {
            print "anchor \"local.shadowrocket-guard\" quick"
            print "load anchor \"local.shadowrocket-guard\" from \"/etc/pf.anchors/local.shadowrocket-guard\""
            added=1
        }
        $0 == "anchor \"local.shadowrocket-guard\" quick" { next }
        $0 == "load anchor \"local.shadowrocket-guard\" from \"/etc/pf.anchors/local.shadowrocket-guard\"" { next }
        !added && /^[[:space:]]*(anchor|pass|block|match|antispoof)[[:space:]]/ { hook() }
        { print }
        END { if (!added) hook() }
    ' "$1"
}

guard_first() {
    awk '/^(anchor|pass|block|match|antispoof)[[:space:]]/ {
        first=$0; exit
    } END { exit first != "anchor \"local.shadowrocket-guard\" quick all" }'
}

close_guard() {
    # Replace the base anchor without referencing its tunnel child. Drain its
    # stale rules before a subsequent base anchor can reference it again.
    printf 'block drop quick all\n' | pfctl -a "$1" -f - || return 1
    [ "$(pfctl -a "$1" -sr)" = 'block drop quick all' ] || return 1
    pfctl -a "$1/tunnel" -F rules
}

guard_is_enabled() {
    info=$(pfctl -s info) || return 1
    case "$info" in "Status: Enabled"*) return 0 ;; *) return 1 ;; esac
}

enable_guard() {
    info=$(pfctl -s info) || return 1
    case "$info" in
        "Status: Enabled"*) if [ -s "$1" ]; then return 0; fi ;;
    esac
    touch "$1.flush-pending" || return 1
    msg=$(pfctl -E 2>&1) || { echo "$msg" >&2; return 1; }
    ref=$(printf '%s\n' "$msg" | awk '/Token[[:space:]]*:/ {print $NF}')
    case "$ref" in ''|*[!0-9]*) echo "$msg" >&2; return 1 ;; esac
    echo "$ref" > "$1"
}
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
EMBEDDED_FILE
cat > "$stage/policy.sh" <<'EMBEDDED_FILE'
# Shared by the standalone installer and the root service.
render_root() {
    awk '
        function hook() {
            print "anchor \"local.shadowrocket-guard\" quick"
            print "load anchor \"local.shadowrocket-guard\" from \"/etc/pf.anchors/local.shadowrocket-guard\""
            added=1
        }
        $0 == "anchor \"local.shadowrocket-guard\" quick" { next }
        $0 == "load anchor \"local.shadowrocket-guard\" from \"/etc/pf.anchors/local.shadowrocket-guard\"" { next }
        !added && /^[[:space:]]*(anchor|pass|block|match|antispoof)[[:space:]]/ { hook() }
        { print }
        END { if (!added) hook() }
    ' "$1"
}

guard_first() {
    awk '/^(anchor|pass|block|match|antispoof)[[:space:]]/ {
        first=$0; exit
    } END { exit first != "anchor \"local.shadowrocket-guard\" quick all" }'
}

close_guard() {
    # Replace the base anchor without referencing its tunnel child. Drain its
    # stale rules before a subsequent base anchor can reference it again.
    printf 'block drop quick all\n' | pfctl -a "$1" -f - || return 1
    [ "$(pfctl -a "$1" -sr)" = 'block drop quick all' ] || return 1
    pfctl -a "$1/tunnel" -F rules
}

guard_is_enabled() {
    info=$(pfctl -s info) || return 1
    case "$info" in "Status: Enabled"*) return 0 ;; *) return 1 ;; esac
}

enable_guard() {
    info=$(pfctl -s info) || return 1
    case "$info" in
        "Status: Enabled"*) if [ -s "$1" ]; then return 0; fi ;;
    esac
    touch "$1.flush-pending" || return 1
    msg=$(pfctl -E 2>&1) || { echo "$msg" >&2; return 1; }
    ref=$(printf '%s\n' "$msg" | awk '/Token[[:space:]]*:/ {print $NF}')
    case "$ref" in ''|*[!0-9]*) echo "$msg" >&2; return 1 ;; esac
    echo "$ref" > "$1"
}
EMBEDDED_FILE
cat > "$stage/guard" <<'EMBEDDED_FILE'
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
EMBEDDED_FILE
cat > "$stage/anchor" <<'EMBEDDED_FILE'
pass quick on lo0 all no state
pass out quick inet proto udp from any port 68 to 255.255.255.255 port 67 no state
pass in quick inet proto udp from any port 67 to any port 68 no state
# VPN endpoint rules
anchor "tunnel" quick
block drop quick all
EMBEDDED_FILE
cat > "$stage/remove" <<'EMBEDDED_FILE'
#!/bin/sh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
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
if [ "$(id -u)" != 0 ]; then exec /usr/bin/sudo /bin/sh "$0" "$@"; fi
umask 077
label=local.shadowrocket-killswitch
base=/Library/PrivilegedHelperTools/$label
plist=/Library/LaunchDaemons/$label.plist
anchor=/etc/pf.anchors/local.shadowrocket-guard
conf=/etc/pf.conf
stage=$(mktemp -d /private/etc/.srguard.XXXXXXXX)
trap 'rm -rf "$stage"' EXIT
shlock -f "$lock" -p "$$" || { echo 'Another firewall operation is in progress.' >&2; exit 1; }
trap 'rm -rf "$stage"; rm -f "$lock"' EXIT
# Only remove our own two configuration lines. Preserve edits by other services.
awk '$0 != "anchor \"local.shadowrocket-guard\" quick" && $0 != "load anchor \"local.shadowrocket-guard\" from \"/etc/pf.anchors/local.shadowrocket-guard\""' "$conf" > "$stage/clean"
saveconf() {
    install -o root -g wheel -m 644 "$1" "$stage/new.conf" || return 1
    mv -f "$stage/new.conf" "$conf"
}
unload() {
    if launchctl print "system/$label" >/dev/null 2>&1; then launchctl bootout "system/$label"; fi
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
{
    pfctl -nf "$stage/clean"
    cp -p "$conf" "$stage/original.conf"
    unload
    if ! direct_reconcile_routes "" "" ""; then
        if [ -f "$plist" ]; then launchctl bootstrap system "$plist"; fi
        echo 'Could not remove direct routes. Retry removal.' >&2
        exit 1
    fi
    rm -f "$token_file.direct-rules" "$token_file.direct-error"
    replaced=no
    if ! { saveconf "$stage/clean" && replaced=yes && pfctl -f "$conf"; }; then
        # Leave the system as it was before removal started.
        if [ "$replaced" = yes ]; then saveconf "$stage/original.conf" || echo 'Could not restore pf.conf.' >&2; fi
        if [ -f "$plist" ]; then launchctl bootstrap system "$plist"; fi
        echo 'Could not remove the firewall configuration. Retry removal.' >&2
        exit 1
    fi
    if [ -s "$token_file" ]; then pfctl -X "$(cat "$token_file")" || true; fi
    # The detached anchor stores the applied VPN profile for the next install.
    rm -f "$token_file" "$token_file.flush-pending" "$base/policy.sh" "$plist" "$base/guard" "$base/on-connect" "$base/killswitch" "$base/remove"
    rmdir "$base" 2>/dev/null || true
    rm -rf "$direct_journal"
    echo 'VPN protection removed.'
    exit 0
}
EMBEDDED_FILE
cat > "$stage/daemon.plist" <<'EMBEDDED_FILE'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
	<key>Label</key>
	<string>local.shadowrocket-killswitch</string>
	<key>ProgramArguments</key>
	<array>
		<string>/Library/PrivilegedHelperTools/local.shadowrocket-killswitch/guard</string>
	</array>
	<key>RunAtLoad</key>
	<true/>
	<key>StartInterval</key>
	<integer>5</integer>
	<key>ThrottleInterval</key>
	<integer>5</integer>
</dict>
</plist>
EMBEDDED_FILE
checked_client=$applied_client
guard_debug install.stage settings
if [ -e "$anchor" ]; then
    load_settings "$anchor" || { echo 'Set a valid VPN server in Settings first.' >&2; exit 1; }
else
    applied_client=shadowrocket
fi
if [ "$checked_client" != "$applied_client" ]; then require_client "$applied_client"; fi
if [ "$#" = 3 ]; then
    address=$1 port=$2 transport=$3
elif [ "$#" = 0 ] && [ -f "$anchor" ]; then
    values=$(/bin/sh "$stage/peer" --get "$anchor") || { echo 'Set a valid VPN server in Settings first.' >&2; exit 1; }
    IFS=' ' read -r address port transport <<EOF
$values
EOF
else
    echo 'Set the VPN server in the app first, or run this installer with IPV4 PORT tcp|udp.' >&2
    exit 1
fi
/bin/sh "$stage/peer" --render "$address" "$port" "$transport" "$applied_client" "$anchor" < "$stage/anchor" > "$stage/configured"
mv "$stage/configured" "$stage/anchor"
guard_debug install.stage validate-anchor
pfctl -a local.shadowrocket-guard -nf "$stage/anchor"
guard_debug install.stage validate-service
plutil -lint "$stage/daemon.plist"
/bin/sh -n "$stage/guard"
. "$stage/policy.sh"
guard_debug install.stage validate-pf-config
render_root "$conf" > "$stage/main"
sed "s|/etc/pf.anchors/local.shadowrocket-guard|$stage/anchor|" "$stage/main" > "$stage/preview"
preview=$(pfctl -nvf "$stage/preview")
printf '%s\n' "$preview" | guard_first || { echo 'Could not place the guard first in the pf ruleset.' >&2; exit 1; }
guard_debug install.stage vpn-precheck
# If a live VPN session exists, test the same HTTPS request before and after activation.
# This one-time transaction also runs to completion if the chat loses connectivity.
probe() {
    /usr/bin/curl -q -4 --noproxy '*' --interface "$1" -fsS --max-time 5 \
        --output /dev/null https://www.apple.com/library/test/success.html
}
initial=$(/bin/sh "$stage/guard" --check "$stage/anchor")
if [ "$initial" = blocked ]; then
    echo "Connect $(client_name "$applied_client") and run the installer again." >&2
    exit 1
else
    guard_debug install.stage https-precheck
    probe "$initial" || { echo 'VPN HTTPS check failed before installation. Rules were not activated.' >&2; exit 1; }
fi
# Back up every file we replace, including a peer saved before first install.
mkdir "$stage/old"
cp -p "$conf" "$stage/old/pf.conf"
for path in "$base/guard" "$base/remove" "$base/policy.sh" "$plist" "$anchor"; do
    if [ -f "$path" ]; then cp -p "$path" "$stage/old/"; fi
done
loaded=no
if launchctl print "system/$label" >/dev/null 2>&1; then loaded=yes; fi
had_token=no
if [ -s "$token_file" ]; then had_token=yes; fi
had_pending=no
if [ -e "$token_file.flush-pending" ]; then had_pending=yes; fi
live_changed=no
restore_file() {
    if [ -f "$stage/old/${1##*/}" ]; then cp -p "$stage/old/${1##*/}" "$1"; else rm -f "$1"; fi
}
recover() {
    unload || return 1
    if [ "$live_changed" = yes ]; then
        # Retire states created by candidate exceptions before restoring an older service.
        if [ -s "$token_file.direct-rules" ]; then
            touch "$token_file.flush-pending" || return 1
            close_guard local.shadowrocket-guard || return 1
            pfctl -F states || return 1
        fi
        direct_reconcile_routes "" "" "" || return 1
        rm -f "$token_file.direct-rules" "$token_file.direct-error"
    fi
    for path in "$base/guard" "$base/remove" "$base/policy.sh" "$plist" "$anchor"; do
        restore_file "$path" || return 1
    done
    saveconf "$stage/old/pf.conf" || return 1
    if [ "$live_changed" = yes ]; then
        pfctl -f "$conf" || return 1
    fi
    if [ "$loaded" = yes ]; then
        # Restore the tunnel before launchd's next scheduled tick.
        if [ "$live_changed" = yes ] && [ -x "$base/guard" ]; then
            "$base/guard" --install-tick || echo 'The service will retry recovery on its next run.' >&2
        fi
        launchctl bootstrap system "$plist" || return 1
    elif [ "$had_token" = no ] && [ -s "$token_file" ]; then
        pfctl -X "$(cat "$token_file")" || return 1
        rm -f "$token_file"
    fi
    if [ "$had_pending" = no ] && [ "$loaded" = no ] && [ "$had_token" = no ]; then
        rm -f "$token_file.flush-pending"
    fi
}
finish() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$rc" -ne 0 ]; then
        guard_debug install.stage rollback
        if ! recover; then
            echo "Rollback failed. Backups are in $stage/old." >&2
            rm -f "$lock"
            exit 1
        fi
        echo 'Installation stopped. Previous configuration restored.' >&2
    fi
    rm -rf "$stage"
    rm -f "$lock"
    exit "$rc"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
guard_debug install.stage activate
unload
install -d -m 755 -o root -g wheel "$base"
install -m 755 -o root -g wheel "$stage/remove" "$base/remove"
install -m 755 -o root -g wheel "$stage/guard" "$base/guard"
install -m 644 -o root -g wheel "$stage/policy.sh" "$base/policy.sh"
install -m 644 -o root -g wheel "$stage/anchor" "$anchor"
install -m 644 -o root -g wheel "$stage/daemon.plist" "$plist"
saveconf "$stage/main"
live_changed=yes
# Existing states must be cleared if the previous hook was absent or misplaced.
oldrules=$(pfctl -sr)
previous_base=$(pfctl -a local.shadowrocket-guard -sr)
expected_base=$(pfctl -a local.shadowrocket-guard -nvf "$anchor")
if ! printf '%s\n' "$oldrules" | guard_first || [ "$previous_base" != "$expected_base" ]; then
    touch "$token_file.flush-pending"
fi
pfctl -f "$conf"
"$base/guard" --install-tick
launchctl enable "system/$label"
launchctl bootstrap system "$plist"
if [ "$initial" != blocked ]; then
    guard_debug install.stage https-verify
    verified=no
    for delay in 1 3 5; do
        sleep "$delay"
        live=$("$base/guard" --check) || live=blocked
        if [ "$live" != blocked ] && probe "$live"; then verified=yes; break; fi
    done
    [ "$verified" = yes ] || exit 1
fi
guard_debug install.stage complete
echo 'Protection enabled. To remove it, run sudo /Library/PrivilegedHelperTools/local.shadowrocket-killswitch/remove'
