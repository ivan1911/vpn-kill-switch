# Building and verifying VPN Kill Switch on macOS

Start in the project root on macOS with Xcode Command Line Tools and Python 3. Use a graphical login for the AppKit tests. The user-facing [README](../../README.md) covers setup, CLI commands and offline recovery. Use the [glossary](../../GLOSSARY.md) for names used in the menu.

## Follow a change through the app

| If the change concerns | Edit here | Verify across the boundary |
| --- | --- | --- |
| Client, server or Settings | `SettingsWindow.swift`, `Peer.swift` and `VPNClient.swift` (the shell list is `client_table` in `Guard/config.sh`; `Tests/clients.sh` keeps them equal) | Each client has its own local draft. Apply commits the client and VPN server together. The saved PF anchor also supports older Shadowrocket installs. Check both fresh setup and upgrade. |
| Firewall and service lifecycle | `Guard/guard-install.sh`, `guard.sh`, `guard.plist`, `peer.sh`, `upgrade-service.sh` and the included config, profile and policy scripts in `Guard/` | The root LaunchDaemon reconciles the selected profile with PF. A disconnected client has no allowed tunnel. Removing the service must work offline even after the client app is removed. |
| Menu status and reconnect | `main.swift`, `Admin.swift`, `Status.swift`, `Guard/check.sh` | The menu observes the applied VPN profile. A connection event wakes the authorized monitor. The checker reports the rules actually installed. During reconnect, macOS can report Connected before PF allows the interface. Exercise the retry and a late result from the previous selection. |
| External IPv4 and flag | `ExternalIP.swift`, `GeoIP.swift`, `main.swift`, `SettingsWindow.swift` | Protection fetches the external IPv4 on demand. GeoIP matches that address locally. Check stale replies, missing or invalid data, and retention of the installed database after a failed update. |

The service uses two PF anchors. The base anchor permits loopback, DHCP and the configured server socket before its final block rule. The nested tunnel anchor enforces the direct IPv4 config from `Guard/direct.sh` before it permits the interface of the applied client when connected. An empty tunnel anchor with the base rules active means internet access is blocked. For a status discrepancy, compare the selected profile, allowed tunnel and checker exit code using the [diagnostic commands](../../README.md#commands-and-recovery). For a failed installation, correlate the debug journal with the authorization and installer stages using the [logging guide](../../README.md#diagnose-an-installation-attempt).

The menu never parses the checker's English sentences. `Admin.swift` runs `check.sh --porcelain`, which prints stable `key=value` lines (`protection`, `tunnel`, `client`, `client-name`, `vpn`, `vpn-interface`, `direct`, `direct-waiting`, `problem`) with the same exit codes, and `Status.swift` reads only those keys. Add a new status as a key in `Guard/check.sh` (documented in its header) and in `Tests/Status`; leave Terminal prose free to change.

The Exceptions tab in `ExceptionsView.swift` uses the checker for reads and address validation. `Guard/exceptions.sh` revalidates the list under the shared lock, rejects stale edits, writes root-owned preferences and reconciles the live service. The guard and checker read legacy 1.8.0 entries until the first app save. The guard fixtures exercise migration, offline saves, conflicts, rollback and clearing the last entry.

The app, system service and Terminal commands have separate lifetimes. Quitting or replacing the menu app leaves the installed service running. Building a new installer leaves the copies in `~/.local/bin` as they were. Compare those copies with `Commands/` when diagnosing different behavior from Terminal and the menu.

## Build the app or disk image

- For shell-only work, run `python3 Tools/package-commands.py`. It generates the three standalone Finder commands in `Commands/`. The files in `Scripts/` are relative symlinks to them. Review the generated diff alongside edits to `Guard/`.
- For the app, run `./build.sh`. It regenerates the commands, produces the app-specific peer script with `--app-peer` (including the legacy service upgrade), and embeds the scripts in a temporary `Commands.swift`. Add new production Swift files to the explicit compiler invocation in [build.sh](../../build.sh). The script builds the icon, compiles both architectures for macOS 13+, combines them and ad-hoc signs the bundle.
- Use `./build.sh` for everyday changes. Keep `VERSION` and the numeric bundle build number stable between releases. If a tester needs a disk image, run `./build-dmg.sh`. About, the launch log and the DMG filename share the same identifier. The bundle also stores the full commit in `VPNSourceCommit`. A dirty checkout adds `.dirty` to its HEAD identifier. Commit changes for a reproducible source revision.
- Follow the [release policy](../../AGENTS.md#release-policy). Only prepare and publish a release when the user explicitly requests one. Set `VERSION` on the release branch using MAJOR for incompatible changes, MINOR for compatible features and PATCH for compatible fixes. Increment the numeric `CFBundleVersion` in `build.sh` for the release. [Semantic Versioning](https://semver.org/spec/v2.0.0.html)
- After the release PR merges into `main`, read its resulting full commit SHA from the merged pull request on GitHub. Use a clean worktree at that exact revision and run `./build-dmg.sh --release "$merge_sha"` there. The script checks the supplied SHA against HEAD. Release packages use `VERSION+g<7 hex digits>`. Publish the verified image separately after the merge, then update the download links. Keep the last published download available during development.
- For an isolated development build use a Git worktree. A fresh `git archive` carries its source revision via `.git-revision`. An ordinary source copy without Git metadata displays `+unknown`.

## Run the local regression checks

Run these blocks from the project root. For shell changes, regenerate the standalone commands first. The guard fixtures use a temporary filesystem and fake system operations. The PF syntax checks use Apple's parser in dry-run mode. None of these commands requires turning protection on or off.

```sh
(
    set -eu
    for script in Commands/*.command; do /bin/sh -n "$script"; done
    /bin/sh Tests/build-version.sh
    /bin/sh Tests/peer.sh
    /bin/sh Tests/clients.sh
    /bin/sh Tests/upgrade-service.sh
    /usr/bin/python3 Tests/guard.py
)
```

Each Swift suite has a separate `main.swift`. Compile it with its production dependencies. The Settings suite opens a test window and uses isolated preferences. The GuardConfirmation suite drives native modal alerts with keyboard and button input. The VPNEvents harness runs the real monitor loop against a fixture checker.

```sh
(
    set -eu
    test_dir=$(mktemp -d)
    trap 'rm -rf "$test_dir"' EXIT
    run_suite() {
        suite=$1
        shift
        xcrun swiftc -swift-version 5 "$@" "Tests/$suite/main.swift" -o "$test_dir/$suite"
        "$test_dir/$suite"
    }
    run_suite Status Status.swift
    run_suite ExternalIP Status.swift ExternalIP.swift
    run_suite MenuFeedback StatusMenuFeedback.swift
    run_suite GuardConfirmation Status.swift GuardConfirmation.swift
    run_suite GeoIP GeoIP.swift
    run_suite DebugLog Admin.swift
    run_suite Mutation Admin.swift Status.swift
    run_suite VPNEvents Admin.swift Status.swift
    run_suite Settings Admin.swift VPNClient.swift Peer.swift GeoIP.swift ExceptionsView.swift SettingsWindow.swift
)
```

For a visual change, run the compiled Settings suite with an existing output directory and `light` or `dark` as its arguments. Use separate directories for the two appearances because each run writes the same filenames. Inspect the screenshots of the three panes and About at their normal window widths. The GeoIP suite accepts a real `geoip.dat` path for an additional offline lookup. `Tests/Monitor/main.swift` prints a monitor command for a supplied snapshot path, PID and lease path. Use VPNEvents for the automated monitor check.

## Verify the release artifact

The block below verifies the image whose version matches the built app. It mounts the DMG read-only, checks its Applications link, checks both CPU slices and the signature, and compares its executable with the build. Run it in the same checkout where the image was built.

```sh
(
    set -eu
    app="build/VPN Kill Switch.app"
    version=$(/usr/libexec/PlistBuddy -c 'Print VPNBuildIdentifier' "$app/Contents/Info.plist")
    image="build/VPN Kill Switch-$version.dmg"
    hdiutil verify -quiet "$image"
    mount_dir=$(mktemp -d)
    hdiutil attach -quiet -readonly -nobrowse -mountpoint "$mount_dir" "$image"
    trap 'hdiutil detach "$mount_dir" >/dev/null && rmdir "$mount_dir"' EXIT
    bundle="$mount_dir/VPN Kill Switch.app"
    exe="Contents/MacOS/VPNKillSwitch"
    diff -r Commands "$mount_dir/Commands"
    test "$(readlink "$mount_dir/Applications")" = /Applications
    slices=$(lipo -archs "$bundle/$exe")
    for arch in arm64 x86_64; do
        case " $slices " in *" $arch "*) ;; *) exit 1 ;; esac
    done
    codesign --verify --deep --strict --all-architectures "$bundle"
    cmp "$app/$exe" "$bundle/$exe"
)
```

When asked to install the app, quit the running copy, copy the verified bundle into Applications, open that copy and verify its version and process path. Enabling or removing the system service is a separate live operation. It can interrupt the connection carrying the agent session. For an explicitly requested live firewall test, have the README's local Terminal recovery command available first. Record the selected client, its connection state, the checker's allowed tunnel and an observed traffic result.
