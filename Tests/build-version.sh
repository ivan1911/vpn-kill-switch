#!/bin/sh
set -eu
project=$(cd "$(dirname "$0")/.." && pwd)
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
git init -q -b main "$tmp/repo"
cd "$tmp/repo"
git config user.name Fixture
git config user.email fixture@example.test
git config commit.gpgsign false
cp "$project/VERSION" "$project/.gitattributes" "$project/.git-revision" .
git add . && git commit -qm initial
git checkout -qb release/fixture
echo change > feature
git add feature && git commit -qm feature
source_sha=$(git rev-parse HEAD)
version=$(cat VERSION)
identity() {
    python3 "$project/Tools/build_version.py" "$@" > "$tmp/info.plist" || return 1
    /usr/libexec/PlistBuddy -c 'Print VPNBuildIdentifier' "$tmp/info.plist"
}
short=$(git rev-parse --short=7 HEAD)
test "$(identity)" = "$version-dev+g$short"
touch untracked
test "$(identity)" = "$version-dev+g$short.dirty"
rm untracked
if identity "$source_sha"; then exit 1; fi
git checkout -q main
git merge -q --no-ff release/fixture -m merge
merge_sha=$(git rev-parse HEAD)
short=$(git rev-parse --short=7 HEAD)
test "$(identity "$merge_sha")" = "$version+g$short"
test "$(/usr/libexec/PlistBuddy -c 'Print VPNSourceCommit' "$tmp/info.plist")" = "$merge_sha"
if identity "$source_sha"; then exit 1; fi
echo modified > feature
if identity "$merge_sha"; then exit 1; fi
git archive -o "$tmp/source.tar" HEAD
mkdir "$tmp/export"
cd "$tmp/export"
tar xf "$tmp/source.tar"
test "$(identity)" = "$version-dev+g$short"
echo "Development, dirty, archive and merged release build identities passed."
