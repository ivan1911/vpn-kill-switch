#!/bin/bash
# Run from the clean checkout of the release commit.
set -euo pipefail
if [[ $# != 2 ]]; then
    echo "Usage: build-release-dmgs.sh MERGE_SHA OUTPUT_DIRECTORY" >&2
    exit 2
fi
sha=$1
out=$2
tools_dir=$(cd "$(dirname "$0")" && pwd)
version=$(cat VERSION)
identifier="$version+g${sha:0:7}"
stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT
mkdir -p "$out"
executable=Contents/MacOS/VPNKillSwitch
universal="$stage/universal.app"
VPN_BUILD_ARCH=universal ./build.sh --release "$sha" "$universal"

verify_image() (
    image=$1
    app=$2
    variant=$3
    mount_dir=$(mktemp -d "$stage/mount.XXXXXX")
    hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_dir" "$image"
    trap 'hdiutil detach -quiet "$mount_dir"' EXIT
    bundle="$mount_dir/VPN Kill Switch.app"
    slices=$(lipo -archs "$bundle/$executable")
    case "$variant:$slices" in
        "arm64:arm64"|"x86_64:x86_64"|"universal:x86_64 arm64"|"universal:arm64 x86_64") ;;
        *) echo "Unexpected architectures in $image: $slices" >&2; exit 1 ;;
    esac
    test "$(/usr/libexec/PlistBuddy -c 'Print VPNSourceCommit' "$bundle/Contents/Info.plist")" = "$sha"
    test "$(/usr/libexec/PlistBuddy -c 'Print VPNBuildIdentifier' "$bundle/Contents/Info.plist")" = "$identifier"
    codesign --verify --deep --strict --all-architectures "$bundle"
    cmp "$bundle/$executable" "$app/$executable"
    diff -r Commands "$mount_dir/Commands"
    test "$(readlink "$mount_dir/Applications")" = /Applications
)

for variant in universal arm64 x86_64; do
    app="$universal"
    if [[ $variant != universal ]]; then
        app="$stage/$variant.app"
        ditto "$universal" "$app"
        lipo "$universal/$executable" -thin "$variant" -output "$stage/thin"
        chmod 755 "$stage/thin"
        mv "$stage/thin" "$app/$executable"
        codesign --force --sign - "$app"
    fi
    image="VPN-Kill-Switch-v$version-$variant.dmg"
    "$tools_dir/package-dmg.sh" "$app" "$stage/$image"
    verify_image "$stage/$image" "$app" "$variant"
    mv "$stage/$image" "$out/$image"
done
