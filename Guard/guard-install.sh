#!/bin/sh
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
@@INSTALL_CHECK@@
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
# @@DIRECT_CLEANUP@@
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
@@FILES@@
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
