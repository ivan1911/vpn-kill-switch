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
