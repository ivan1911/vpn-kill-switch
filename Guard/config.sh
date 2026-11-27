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
