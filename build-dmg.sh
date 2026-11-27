#!/bin/sh
set -eu
cd "$(dirname "$0")"
app="build/VPN Kill Switch.app"
if [ "$#" -ne 0 ] && { [ "$#" -ne 2 ] || [ "$1" != "--release" ]; }; then
    echo "Usage: ./build-dmg.sh [--release MERGE_SHA]" >&2
    exit 2
fi
./build.sh "$@" "$app"
version=$(/usr/libexec/PlistBuddy -c 'Print VPNBuildIdentifier' "$app/Contents/Info.plist")
suffix=""
if [ "${VPN_BUILD_ARCH:-universal}" = arm64 ]; then suffix="-arm64"; fi
dest="build/VPN Kill Switch-$version$suffix.dmg"
./Tools/package-dmg.sh "$app" "$dest"
echo "$dest"
