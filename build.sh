#!/bin/sh
set -eu
cd "$(dirname "$0")"
release_sha=
if [ "${1-}" = "--release" ]; then
    [ "$#" -ge 2 ] && [ -n "$2" ] || { echo "Expected the full release PR merge SHA" >&2; exit 2; }
    release_sha=$2
    shift 2
fi
[ "$#" -le 1 ] || { echo "Usage: ./build.sh [--release MERGE_SHA] [destination.app]" >&2; exit 2; }
dest=${1:-build/VPN Kill Switch.app}
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
/usr/bin/python3 Tools/package-commands.py
/usr/bin/python3 Tools/build_version.py ${release_sha:+"$release_sha"} > "$tmp/version.plist"
/usr/bin/python3 Tools/package-commands.py --app-peer > "$tmp/peer.sh"
/usr/bin/python3 Tools/package-commands.py --app-exceptions > "$tmp/exceptions.sh"
mkdir -p "$dest/Contents/MacOS" "$dest/Contents/Resources"
iconset="$tmp/AppIcon.iconset"
mkdir "$iconset"
for points in 16 32 128 256 512; do
    for scale in 1 2; do
        suffix=''
        if [ "$scale" = 2 ]; then suffix='@2x'; fi
        pixels=$((points * scale))
        /usr/bin/sips -z "$pixels" "$pixels" Assets/AppIcon.png \
            --out "$iconset/icon_${points}x${points}${suffix}.png" >/dev/null
    done
done
/usr/bin/iconutil -c icns "$iconset" -o "$dest/Contents/Resources/AppIcon.icns"
/usr/bin/python3 - "$tmp/Commands.swift" "$dest/Contents/Info.plist" "$tmp/peer.sh" "$tmp/exceptions.sh" "$tmp/version.plist" <<'PY'
import base64
import pathlib
import plistlib
import sys
parts = ['import Foundation', 'enum Commands {']
sources = {action: pathlib.Path('Scripts', action + '.sh') for action in ('check', 'install', 'remove')}
sources.update(exceptions=pathlib.Path(sys.argv[4]), peer=pathlib.Path(sys.argv[3]), baseRules=pathlib.Path('Guard/guard.pf'))
for action, path in sources.items():
    script = path.read_bytes()
    data = base64.b64encode(script).decode()
    parts.append(f'    static let {action} = String(decoding: Data(base64Encoded: "{data}")!, as: UTF8.self)')
parts.append('}')
pathlib.Path(sys.argv[1]).write_text('\n'.join(parts))
info = dict(CFBundleIdentifier='io.github.ivan1911.vpn-kill-switch',
            CFBundleName='VPN Kill Switch', CFBundleDisplayName='VPN Kill Switch',
            CFBundleExecutable='VPNKillSwitch', CFBundlePackageType='APPL',
            CFBundleVersion='38', CFBundleDevelopmentRegion='en', CFBundleIconFile='AppIcon.icns',
            LSMinimumSystemVersion='13.0', LSUIElement=True,
            NSHighResolutionCapable=True, VPNKillSwitchDebugDefault=True)
info.update(plistlib.loads(pathlib.Path(sys.argv[5]).read_bytes()))
pathlib.Path(sys.argv[2]).write_bytes(plistlib.dumps(info))
PY
for arch in arm64 x86_64; do
    /usr/bin/xcrun swiftc -swift-version 5 -O -target "$arch-apple-macosx13.0" \
        -framework AppKit ExceptionsView.swift SettingsWindow.swift VPNClient.swift Peer.swift MenuGlyph.swift Status.swift GuardConfirmation.swift StatusMenuFeedback.swift ExternalIP.swift GeoIP.swift Admin.swift main.swift "$tmp/Commands.swift" \
        -o "$tmp/VPNKillSwitch-$arch"
done
/usr/bin/lipo -create "$tmp/VPNKillSwitch-arm64" "$tmp/VPNKillSwitch-x86_64" -output "$dest/Contents/MacOS/VPNKillSwitch"
/usr/bin/codesign --force --sign - "$dest"
/usr/bin/codesign --verify --strict "$dest"
