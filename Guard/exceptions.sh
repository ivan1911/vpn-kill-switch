#!/bin/sh
# Embedded in the menu app. Arguments carry the list shown when editing began
# and the proposed list as data. All validation is repeated under the guard lock.
set -eu
export PATH=/usr/bin:/bin:/usr/sbin:/sbin LC_ALL=C
[ "$#" = 2 ] && [ "$(id -u)" = 0 ] || exit 1
umask 077
. "$(dirname "$0")/config.sh"
. "$(dirname "$0")/direct.sh"
label=local.shadowrocket-killswitch
base=/Library/PrivilegedHelperTools/$label
plist=/Library/LaunchDaemons/$label.plist
# @@UPGRADE_SERVICE@@

stage=$(mktemp -d "/Library/Preferences/.vpn-ks-exceptions.XXXXXXXX")
trap 'rm -rf "$stage"' EXIT
shlock -f "$lock" -p "$$" || { echo 'Another firewall operation is in progress. Try again.' >&2; exit 1; }
published=no
installed=no
finish() {
    rc=$?
    trap - EXIT HUP INT TERM
    if [ "$rc" -ne 0 ] && [ "$published" = yes ]; then
        if [ -f "$stage/previous" ]; then mv -f "$stage/previous" "$direct_preferences"
        else rm -f "$direct_preferences"; fi
        if [ "$installed" = yes ]; then
            if "$base/guard" --install-tick; then echo 'Could not apply exceptions. The previous list was restored.' >&2
            else echo 'The service will retry the previous exceptions.' >&2; fi
        fi
    fi
    rm -rf "$stage"; rm -f "$lock"
    exit "$rc"
}
trap finish EXIT
trap 'exit 1' HUP INT TERM
previous=$(direct_list)
[ "$previous" = "$1" ] || { echo 'Exceptions changed elsewhere. Click Reload and edit the latest list.' >&2; exit 1; }
next=$(printf '%s\n' "$2" | direct_parse -)
plutil -create xml1 "$stage/next"
plutil -insert Destinations -string "$next" "$stage/next"
chmod 644 "$stage/next"
if [ -e "$direct_preferences" ]; then cp -p "$direct_preferences" "$stage/previous"; fi
if [ -f "$plist" ] || [ -x "$base/guard" ]; then
    [ -f "$plist" ] && [ -x "$base/guard" ] && launchctl print "system/$label" >/dev/null 2>&1 ||
        { echo 'The installed service is incomplete or stopped. Reinstall it first.' >&2; exit 1; }
    installed=yes
    if ! grep -Fxq '# direct-ipv4-preferences' "$base/guard"; then upgrade_service; fi
fi
published=yes
mv -f "$stage/next" "$direct_preferences"
if [ "$installed" = yes ]; then
    "$base/guard" --install-tick || { echo 'Could not apply exceptions. Restoring the previous list.' >&2; exit 1; }
    echo 'Exceptions applied.'
else
    echo 'Saved. Exceptions will apply when protection is installed.'
fi
