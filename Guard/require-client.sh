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
