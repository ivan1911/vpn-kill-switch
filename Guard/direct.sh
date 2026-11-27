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
