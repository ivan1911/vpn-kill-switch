#!/bin/sh
# The shell client table (Guard/config.sh) and VPNClient.allCases must list the
# same ids, display names and bundle identifiers in the same order.
set -eu
cd "$(dirname "$0")/.."
dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
xcrun swiftc -swift-version 5 VPNClient.swift Tests/Clients/main.swift -o "$dir/clients"
"$dir/clients" > "$dir/swift"
(. Guard/config.sh; client_table) > "$dir/shell"
diff -u "$dir/shell" "$dir/swift" || { echo 'Guard/config.sh client_table and VPNClient disagree' >&2; exit 1; }
# Every field also reads back through the shell accessors.
(
    . Guard/config.sh
    while IFS='|' read -r id name bundle; do
        [ "$(client_name "$id")" = "$name" ] && [ "$(client_bundle "$id")" = "$bundle" ]
    done < "$dir/swift"
    if client_name unknown >/dev/null; then exit 1; fi
)
# The comparison must notice a mismatch.
sed 's/Happ Plus/Happ/' "$dir/swift" > "$dir/mismatch"
if diff -q "$dir/shell" "$dir/mismatch" >/dev/null; then echo 'The consistency check cannot fail' >&2; exit 1; fi
echo 'Shell client table matches VPNClient'
