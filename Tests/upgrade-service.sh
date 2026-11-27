#!/bin/sh
# Exercise the old launchd job handoff with an isolated filesystem and fake launchctl.
set -eu
cd "$(dirname "$0")/.."
testdir=$(mktemp -d)
trap 'rm -rf "$testdir"' EXIT
export testdir
base=$testdir/helpers stage=$testdir/stage label=vpn-test
mkdir -p "$base" "$stage" "$testdir/bin"
printf '#!/bin/sh\n# old guard\n' > "$base/guard"
chmod 755 "$base/guard"
printf '# old policy\n' > "$base/policy.sh"
touch "$testdir/$label.plist" "$testdir/loaded"
cat > "$testdir/bin/launchctl" <<'LAUNCHCTL'
#!/bin/sh
set -eu
case "$1" in
    print) test -f "$testdir/loaded" ;;
    kickstart)
        test -f "$testdir/loaded" && test "$2" = -k || exit 1
        if [ -f "$testdir/fail-restart" ]; then exit 1; fi ;;
    bootstrap)
        if [ -e "$testdir/fail-first-bootstrap" ]; then
            rm "$testdir/fail-first-bootstrap"
            exit 1
        fi
        touch "$testdir/loaded" ;;
    *) exit 2 ;;
esac
LAUNCHCTL
chmod +x "$testdir/bin/launchctl"
PATH=$testdir/bin:$PATH
sed -e 's|/Library/LaunchDaemons/|$testdir/|' \
    -e 's|# @@UPGRADED_GUARD@@|echo "# new guard" > "$stage/guard.next"|' \
    -e 's|# @@UPGRADED_REMOVE@@|echo "# new remover" > "$stage/remove.next"|' \
    -e 's|# @@UPGRADED_POLICY@@|echo "# new policy" > "$stage/policy.next"|' \
    Guard/upgrade-service.sh > "$testdir/upgrade"
. "$testdir/upgrade"
touch "$testdir/fail-restart"
if upgrade_service; then exit 1; fi
test -e "$testdir/loaded"
grep -qx '# old guard' "$base/guard"
grep -qx '# old policy' "$base/policy.sh"
rm "$testdir/fail-restart"
rm "$testdir/loaded"
touch "$testdir/fail-first-bootstrap"
if upgrade_service; then exit 1; fi
grep -qx '# old guard' "$base/guard"
upgrade_service
test -e "$testdir/loaded"
test -x "$base/guard"
grep -qx '# new guard' "$base/guard"
grep -qx '# new policy' "$base/policy.sh"
echo 'Legacy service upgrade, failed restart and bootstrap, rollback and retry passed.'
