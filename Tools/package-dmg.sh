#!/bin/sh
# Run from the source checkout with the app bundle and destination DMG paths.
set -eu
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir "$stage/image"
ditto "$1" "$stage/image/VPN Kill Switch.app"
ditto Commands "$stage/image/Commands"
ln -s /Applications "$stage/image/Applications"
hdiutil create -quiet -fs HFS+ -format UDZO -volname "VPN Kill Switch" -srcfolder "$stage/image" "$stage/installer.dmg"
hdiutil verify -quiet "$stage/installer.dmg"
mv -f "$stage/installer.dmg" "$2"
