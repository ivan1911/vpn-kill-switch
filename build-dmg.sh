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
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/image"
ditto "$app" "$stage/image/VPN Kill Switch.app"
ditto Commands "$stage/image/Commands"
ln -s /Applications "$stage/image/Applications"
hdiutil create -quiet -fs HFS+ -format UDZO -volname "VPN Kill Switch" -srcfolder "$stage/image" "$stage/installer.dmg"
hdiutil verify -quiet "$stage/installer.dmg"
dest="build/VPN Kill Switch-$version.dmg"
mv -f "$stage/installer.dmg" "$dest"
echo "$dest"
