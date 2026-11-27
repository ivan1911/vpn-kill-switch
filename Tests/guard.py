"""Exercise the packaged shell commands on a temporary filesystem without root or network."""
import json
import os
import subprocess
import tempfile
from pathlib import Path

project = Path(__file__).resolve().parents[1]
name = "local.shadowrocket-guard"
label = "local.shadowrocket-killswitch"

with tempfile.TemporaryDirectory() as location:
    root = Path(location)
    tools = root / "bin"
    helpers = root / "Library/PrivilegedHelperTools" / label
    plist = root / "Library/LaunchDaemons" / (label + ".plist")
    anchor = root / "etc/pf.anchors" / name
    conf = root / "etc/pf.conf"
    token = root / "var/run" / (name + ".token")
    pending = token.with_suffix(".token.flush-pending")
    for directory in (tools, plist.parent, anchor.parent, token.parent, helpers.parent, root / "Library/Preferences"):
        directory.mkdir(parents=True)

    def stub(name, script):
        path = tools / name
        path.write_text("#!/bin/sh\nset -eu\n" + script)
        path.chmod(0o755)

    stub("id", 'echo "${KS_TEST_UID:-0}"')
    stub("osascript", '''
case "$4" in
    com.liguangming.Shadowrocket) test -f "$KS_TEST/app-present" ;;
    su.ffg.happ.plus) test -f "$KS_TEST/happ-present" ;;
    *) exit 1 ;;
esac
''')
    stub("stat", 'case "$*" in *%u:%Lp*) echo "${KS_CONFIG_MODE:-0:644}" ;; *) echo 501 ;; esac')
    for name_of_tool in ("route", "netstat"):
        stub(name_of_tool, f'exec /usr/bin/python3 "{project}/Tests/direct-route.py" {name_of_tool} "$@"')
    stub("sudo", 'touch "$KS_TEST/sudo-requested"; exit 1')  # Never prompt for or use real privileges.
    stub("ifconfig", 'test ! -f "$KS_TEST/interface-absent"')
    stub("scutil", """
case "$2" in
  list)
    test ! -f "$KS_TEST/error-vpn-list"
    echo '* (Connected) 11111111-2222-3333-4444-555555555555 VPN (com.liguangming.Shadowrocket) "Shadowrocket" [VPN:com.liguangming.Shadowrocket]'
    if [ ! -e "$KS_TEST/no-happ-profile" ]; then
        echo '* (Disconnected) aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee VPN (su.ffg.happ.plus) "Happ Plus" [VPN:su.ffg.happ.plus]'
        echo '  (Connected) bbbbbbbb-cccc-dddd-eeee-ffffffffffff VPN (su.ffg.happ.plus) "Disabled" [VPN:su.ffg.happ.plus]'
    fi
    if [ -e "$KS_TEST/ambiguous-happ" ]; then
        echo '* (Disconnected) ffffffff-eeee-dddd-cccc-bbbbbbbbbbbb VPN (su.ffg.happ.plus) "Duplicate" [VPN:su.ffg.happ.plus]'
    fi ;;
  status)
    case "$3" in
        11111111-2222-3333-4444-555555555555) printf 'Connected\\nInterfaceName : utun4\\n' ;;
        aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee)
            test ! -f "$KS_TEST/error-vpn-status"
            if [ -e "$KS_TEST/happ-state" ]; then
                cat "$KS_TEST/happ-state"
            elif [ -e "$KS_TEST/happ-interface" ]; then
                printf 'Connected\\nInterfaceName : %s\\n' "$(cat "$KS_TEST/happ-interface")"
            else echo Disconnected; fi ;;
        *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
""")
    stub("sleep", 'exit 0')
    stub("launchctl", '''
case "$1" in
    print) test -f "$KS_TEST/loaded" ;;
    bootout) rm -f "$KS_TEST/loaded" ;;
    enable) exit 0 ;;
    bootstrap) touch "$KS_TEST/loaded" ;;
    kickstart) test -f "$KS_TEST/loaded" ;;
    asuser) case "$*" in *osascript*)
                while [ "${1##*/}" != osascript ]; do shift; done
                exec "$@" ;;
            esac
            test ! -f "$KS_TEST/error-asuser"
            while [ "$1" != --nc ]; do shift; done; scutil "$@" ;;
    *) exit 2 ;;
esac
''')
    stub("install", '''
if [ "$1" = -d ]; then mkdir -p "$8"; exit; fi
if [ "$1" = -m ]; then mode=$2; else mode=$6; fi
case "$8" in */new.conf) test ! -e "$KS_TEST/fail-saveconf" ;; esac
/usr/bin/install -m "$mode" "$7" "$8"
''')
    stub("curl", '''
case "$*" in *api.openai.com*) exit 99 ;; esac
if [ -e "$KS_TEST/fail-probe" ] && [ -e "$KS_TEST/applied" ]; then exit 1; fi
''')
    stub("pfctl", '''
runtime=$KS_TEST/runtime
mkdir -p "$runtime"
rules="$runtime/root"
if [ "$1" = -a ]; then
    case "$2" in */tunnel) rules="$runtime/tunnel" ;; *) rules="$runtime/base" ;; esac
    shift 2
fi
case "$1" in
    -nf|-nvf)
        test ! -f "$KS_TEST/error-pf-preview"
        exec /sbin/pfctl "$@" ;; # Apple's parser, dry-run only
    -sr)
        if [ "$rules" = "$runtime/tunnel" ] && grep -qF '203.0.113.91' "$runtime/base"; then
            if [ -e "$KS_TEST/fail-final-tick" ]; then exit 1; fi
            if [ -e "$KS_TEST/disable-on-final-tick" ]; then rm -f "$runtime/enabled"; fi
        fi
        if [ -f "$rules" ]; then cat "$rules"; fi ;;
    -s|-si) if [ -f "$runtime/enabled" ]; then echo 'Status: Enabled'; else echo 'Status: Disabled'; fi ;;
    -E) touch "$runtime/enabled"; echo 'Token : 123'; echo acquired >> "$runtime/references" ;;
    -X) rm -f "$runtime/enabled" ;;
    -k) # Killing states is a transaction step: the durable marker must be present.
        test -e "$KS_TEST/var/run/local.shadowrocket-guard.token.flush-pending"
        if [ -e "$KS_TEST/fail-kill" ]; then exit 1; fi
        echo "$*" >> "$runtime/kills" ;;
    -F) if [ "$2" = states ]; then
            if [ -e "$KS_TEST/test-handover" ]; then
                test "$(cat "$runtime/base")" = 'block drop quick all'
                test ! -s "$runtime/tunnel"
                echo 'flushed while blocked' >> "$KS_TEST/handover"
            fi
            if [ -e "$KS_TEST/fail-flush" ]; then exit 1; fi
            echo flushed >> "$runtime/flushes"
        else : > "$rules"; fi ;;
    -f) if [ -e "$KS_TEST/fail-remove-load" ] && [ "$rules" = "$runtime/root" ]; then exit 1; fi
        if [ "$2" = - ]; then cat > "$rules"; else
            if [ "$rules" = "$runtime/base" ] && [ -e "$KS_TEST/test-handover" ]; then
                test -s "$KS_TEST/handover"
                if [ -e "$KS_TEST/fail-base-load" ]; then exit 1; fi
                test ! -s "$runtime/tunnel"
                # A launchd tick scheduled during Apply must not run old policy.
                "$KS_TEST/Library/PrivilegedHelperTools/local.shadowrocket-killswitch/guard"
                test ! -s "$runtime/tunnel"
                test "$(cat "$runtime/base")" = 'block drop quick all'
            fi
            /sbin/pfctl -nvf "$2" > "$rules"
            touch "$KS_TEST/applied"
        fi ;;
    *) exit 2 ;;
esac
''')
    def redirect(script):
        # Redirect generated commands AND the service code they install.
        script = script.replace('/private/etc/', '/etc/')
        for prefix in ('/etc/', '/var/run/', '/Library/'):
            script = script.replace(prefix, location + prefix)
        script = script.replace('PATH=/usr/bin:', 'PATH=' + str(tools) + ':/usr/bin:')
        for cmd in ('/usr/bin/sudo', '/usr/bin/curl', '/bin/launchctl', '/usr/sbin/scutil', '/usr/bin/osascript', '/sbin/pfctl'):
            script = script.replace(cmd, str(tools / Path(cmd).name))
        return script

    installer = root / "installer"
    installer.write_text(redirect((project / "Commands/install-shadowrocket-killswitch.command").read_text()))
    checker = root / "checker"
    checker.write_text(redirect((project / "Commands/check-shadowrocket-killswitch.command").read_text()))
    peer = root / "peer"
    packaged_peer = subprocess.check_output(["python3", "Tools/package-commands.py", "--app-peer"], cwd=project, text=True)
    peer.write_text(redirect(packaged_peer))
    exceptions = root / "exceptions"
    exceptions.write_text(redirect(subprocess.check_output(
        ["python3", "Tools/package-commands.py", "--app-exceptions"], cwd=project, text=True)))
    template = (project / "Guard/guard.pf").read_text()
    env = dict(os.environ, KS_TEST=location)

    def run(command, success=True, args=(), stdin=None):
        result = subprocess.run(["/bin/sh", str(command), *args], cwd=project, env=env,
                                capture_output=True, text=True, input=stdin)
        assert (result.returncode == 0) == success, result.stdout + result.stderr
        return result

    def porcelain(success=True):
        """Run the checker's machine form: key=value lines only, same exit codes."""
        result = run(checker, success=success, args=("--porcelain",))
        lines = result.stdout.splitlines()
        assert all("=" in line and ": " not in line for line in lines), lines
        return result.returncode, dict(line.split("=", 1) for line in lines)

    # A failed first install restores the prior unprotected configuration.
    original = 'pass quick on lo0 all\n'
    conf.write_text(original)
    # Even with a stale connected profile and explicit VPN server, a missing app
    # stops both an interactive install and a privileged install before PF.
    for uid in ("501", "0"):
        env["KS_TEST_UID"] = uid
        error = run(installer, success=False, args=("203.0.113.22", "443", "tcp"))
        assert "Shadowrocket is required" in error.stderr
        assert "before installing the kill switch." in error.stderr
        assert not any(p.exists() for p in (root / "sudo-requested", root / "runtime", plist, helpers, anchor, token))
        assert conf.read_text() == original
    (root / "app-present").touch()
    run(installer, args=("--check-shadowrocket",))
    run(installer, success=False)
    assert not anchor.exists() and not (root / "applied").exists()
    (root / "fail-probe").touch()
    run(installer, success=False, args=("203.0.113.22", "443", "tcp"))
    assert conf.read_text() == original and not plist.exists() and not token.exists()
    (root / "fail-probe").unlink()
    run(installer, args=("203.0.113.22", "443", "tcp"))
    runtime = root / "runtime"
    assert (runtime / "root").read_text().splitlines()[0] == f'anchor "{name}" quick all'
    assert (runtime / "tunnel").read_text().strip() == 'pass quick on utun4 all no state'

    # A legacy file resolves Shadowrocket even if both apps are installed.
    guard = helpers / "guard"
    (root / "happ-present").touch()
    run(installer, args=("--check-client", "happ-plus"))
    anchor.write_text("\n".join(line for line in anchor.read_text().splitlines()
                               if not line.startswith(("# client:", "# endpoint "))) + "\n")
    assert run(checker, args=("--profile-id",)).stdout.strip() == "11111111-2222-3333-4444-555555555555"
    assert "Shadowrocket: Connected (utun4)" in run(checker).stdout
    assert porcelain() == (0, {"protection": "on", "tunnel": "utun4", "client": "shadowrocket",
                               "client-name": "Shadowrocket", "vpn": "Connected", "vpn-interface": "utun4"})

    # Reinstallation failure must preserve the prior helper and a nondefault peer.
    guard.write_text(guard.read_text() + "\n# previous version\n")
    anchor.write_text(anchor.read_text().replace("203.0.113.22", "198.51.100.8"))
    run(guard)
    saved = {path: path.read_bytes() for path in (plist, anchor, guard, conf, helpers / "remove")}
    (root / "applied").unlink()
    (root / "fail-probe").touch()
    run(installer, success=False)
    assert all(path.read_bytes() == contents for path, contents in saved.items())
    assert (root / "loaded").exists() and (runtime / "enabled").exists()
    (root / "fail-probe").unlink()

    # Normal maintenance after a system config replacement, with interrupted cleanup.
    conf.write_text(original)
    (runtime / "root").write_text(original)
    (runtime / "base").write_text("")
    (root / "fail-flush").touch()
    references = (runtime / "references").read_bytes()
    run(guard, success=False)
    assert pending.exists() and conf.read_bytes() == saved[conf]
    assert (runtime / "base").read_text().splitlines()[-1] == "block drop quick all"
    (root / "fail-flush").unlink()
    run(guard)
    assert not pending.exists() and (runtime / "references").read_bytes() == references
    flushes = (runtime / "flushes").read_bytes()
    run(guard)
    assert (runtime / "flushes").read_bytes() == flushes
    (runtime / "base").write_text("")
    run(guard)
    assert "198.51.100.8" in (runtime / "base").read_text()
    assert (runtime / "flushes").read_bytes() != flushes

    # A failed flush during first acquisition reuses the same PF reference on retry.
    token.unlink()
    (runtime / "enabled").unlink()
    (root / "fail-flush").touch()
    run(guard, success=False)
    acquired = (runtime / "references").read_bytes()
    assert pending.exists() and token.exists() and acquired == references + b"acquired\n"
    (root / "fail-flush").unlink()
    run(guard)
    assert not pending.exists() and (runtime / "references").read_bytes() == acquired

    # Invalid or missing saved settings at startup must still install effective
    # blocking rules without modifying the user's saved file.
    saved_anchor = anchor.read_bytes()
    for malformed in (b"# client: invalid\nthis is not valid PF\n", None):
        if malformed is None:
            anchor.unlink()
        else:
            anchor.write_bytes(malformed)
        (runtime / "root").write_text(original)
        (runtime / "enabled").unlink()
        run(guard, success=False)
        assert (runtime / "enabled").exists()
        assert (runtime / "root").read_text().splitlines()[0] == f'anchor "{name}" quick all'
        assert (runtime / "base").read_text().strip() == "block drop quick all"
        assert not (runtime / "tunnel").read_text()
        assert (anchor.read_bytes() if anchor.exists() else None) == malformed
        anchor.write_bytes(saved_anchor)
        run(guard)
        assert "Shadowrocket: Connected (utun4)" in run(checker).stdout

    # The old exception and tunnel are revoked before the new base is loaded.
    # A failed live load preserves the saved Shadowrocket VPN server.
    (root / "test-handover").touch()
    (root / "fail-base-load").touch()
    args = ("--apply", "203.0.113.91", "8443", "udp", "happ-plus")
    before = anchor.read_bytes()
    run(peer, success=False, args=args, stdin=template)
    assert anchor.read_bytes() == before and pending.exists()
    assert (runtime / "base").read_text().strip() == "block drop quick all"
    assert not (runtime / "tunnel").read_text()
    (root / "fail-base-load").unlink()
    (root / "test-handover").unlink()
    run(guard)
    assert not pending.exists() and "198.51.100.8" in (runtime / "base").read_text()
    assert (runtime / "tunnel").read_text().strip() == "pass quick on utun4 all no state"

    # Neither a failed final tick nor PF losing its enable reference may publish
    # the candidate. The scheduled service can recover the earlier selection.
    for fault in ("fail-final-tick", "disable-on-final-tick"):
        (root / fault).touch()
        error = run(peer, success=False, args=args, stdin=template)
        assert "not applied" in error.stderr
        assert anchor.read_bytes() == before and pending.exists()
        assert (runtime / "base").read_text().strip() == "block drop quick all"
        assert not (runtime / "tunnel").read_text()
        (root / fault).unlink()
        run(guard)
        assert not pending.exists() and "198.51.100.8" in (runtime / "base").read_text()
        assert (runtime / "tunnel").read_text().strip() == "pass quick on utun4 all no state"

    (root / "loaded").unlink()
    run(peer, success=False, args=args, stdin=template)
    assert anchor.read_bytes() == before and "198.51.100.8" in (runtime / "base").read_text()
    (root / "loaded").touch()

    # A live Apply from a legacy installed service upgrades it without requiring
    # the destination to connect. Its next tick reads the applied client.
    guard.write_text(guard.read_text().replace("# direct-ipv4-preferences\n", ""))
    (root / "test-handover").touch()
    (root / "handover").unlink()
    run(peer, args=args, stdin=template)
    (root / "test-handover").unlink()
    assert "# direct-ipv4-preferences" in guard.read_text() and (root / "loaded").exists()
    assert "# endpoint shadowrocket: 198.51.100.8 443 tcp" in anchor.read_text()
    assert "203.0.113.91" in (runtime / "base").read_text()
    assert "198.51.100.8" not in (runtime / "base").read_text()
    assert not (runtime / "tunnel").read_text()
    assert run(checker, args=("--profile-id",)).stdout.strip() == "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    disconnected = run(checker).stdout
    assert "Happ Plus: Disconnected" in disconnected and "Allowed tunnel: none" in disconnected
    assert porcelain() == (0, {"protection": "on", "tunnel": "none", "client": "happ-plus",
                               "client-name": "Happ Plus", "vpn": "Disconnected"})

    # Public/LAN exceptions survive disconnect and coexist with the selected tunnel.
    config = root / "etc/vpn-ks-direct.conf"
    config.write_text("localhost\n::1\n127.0.0.1\n192.168.*  # LAN\n203.0.113.0/24\n8.8.8.8\n")
    canonical = run(checker, args=("--validate-direct", str(config))).stdout.splitlines()
    assert canonical == ["192.168.0.0/16", "203.0.113.0/24", "8.8.8.8/32"]
    run(guard)
    child = (runtime / "tunnel").read_text()
    normalized = subprocess.run(["/sbin/pfctl", "-nvf", "-"], text=True, input=child,
                                capture_output=True, check=True).stdout
    assert normalized == child and "on utun" not in child
    assert child.count("pass out quick on en0") == 3 and child.count("block drop out quick") == 3
    assert "Direct IPv4 destinations:" in run(checker).stdout
    def managed():
        return json.loads((root / "route-table").read_text())
    assert set(managed()) == {"192.168.0.0/16", "203.0.113.0/25", "203.0.113.128/25", "8.8.8.8/32"}
    (root / "happ-interface").write_text("utun8")
    run(guard)
    assert (runtime / "tunnel").read_text() == child + "pass quick on utun8 all no state\n"
    def states():
        """Every PF state flush and targeted kill the fake pfctl has recorded."""
        kills = runtime / "kills"
        return ((runtime / "flushes").read_bytes(), kills.read_text().splitlines() if kills.exists() else [])
    (root / "uplink").write_text("en1")
    before_states = states()
    run(guard)
    assert all(dev == "en1" for dev, gw in managed().values())
    # The uplink switch replaces the rules but drops no state, VPN sessions included.
    assert "on en1" in (runtime / "tunnel").read_text() and "on en0" not in (runtime / "tunnel").read_text()
    assert states() == before_states and not pending.exists()
    # Without Wi-Fi or Ethernet the destinations stay blocked and simply wait.
    (root / "offline").touch()
    run(guard)
    assert states() == before_states
    waiting = run(checker).stdout
    assert not managed() and "pass out quick" not in (runtime / "tunnel").read_text()
    assert (runtime / "tunnel").read_text().count("block drop out quick") == 3
    assert "Direct IPv4 destinations are waiting for Wi-Fi or Ethernet." in waiting
    code, keys = porcelain()
    assert code == 0 and keys["direct"] == "192.168.0.0/16,203.0.113.0/24,8.8.8.8/32" and keys["direct-waiting"] == "yes"
    assert "problem" not in keys and "tunnel" in keys
    assert "unavailable" not in waiting and not (token.parent / (name + ".token.direct-error")).exists()
    (root / "offline").unlink()
    assert "waiting" not in run(checker, success=False).stdout
    run(guard)
    assert states() == before_states
    assert managed() and (runtime / "tunnel").read_text().count("pass out quick on en1") == 3
    assert "waiting" not in run(checker).stdout
    assert "direct-waiting" not in porcelain()[1]
    # A route failure with an uplink present is still an error.
    # A new uplink makes the guard add its routes again, and the add fails.
    (root / "route-conflict").touch()
    (root / "uplink").write_text("en0")
    run(guard, success=False)
    assert "Direct IPv4 routing is unavailable" in run(checker, success=False).stdout
    code, keys = porcelain(success=False)
    assert code == 2 and keys["problem"] == "direct-routes" and keys["protection"] == "on"
    (root / "route-conflict").unlink()
    run(guard)
    assert managed() and "Allowed tunnel: utun8" in run(checker).stdout
    before_states = states()
    # Adding a destination flushes and kills nothing.
    config.write_text("192.168.*\n203.0.113.0/24\n8.8.8.8\n1.1.1.1\n")
    run(guard)
    assert states() == before_states and "to 1.1.1.1" in (runtime / "tunnel").read_text()
    # Removing one destination kills only its states.
    config.write_text("192.168.*\n203.0.113.0/24\n8.8.8.8\n")
    run(guard)
    assert not pending.exists() and "1.1.1.1" not in (runtime / "tunnel").read_text()
    assert states() == (before_states[0], before_states[1] + ["-k 0.0.0.0/0 -k 1.1.1.1"])
    # A failed kill keeps the durable marker, so the checker stays unsure. The
    # next tick finds the marker and recovers conservatively with a full flush.
    config.write_text("192.168.*\n203.0.113.0/24\n8.8.8.8\n1.1.1.1\n")
    run(guard)
    before_states = states()
    config.write_text("192.168.*\n203.0.113.0/24\n8.8.8.8\n")
    (root / "fail-kill").touch()
    run(guard, success=False)
    assert pending.exists() and states() == before_states
    assert run(checker, success=False).returncode == 2
    assert porcelain(success=False) == (2, {"protection": "unknown"})
    (root / "fail-kill").unlink()
    run(guard)
    assert not pending.exists() and "1.1.1.1" not in (runtime / "tunnel").read_text()
    assert states()[0] != before_states[0]
    # Removing 0.0.0.0/0 still flushes every state.
    config.write_text("0.0.0.0/0\n192.168.*\n203.0.113.0/24\n8.8.8.8\n")
    before_states = states()
    run(guard)
    assert states() == before_states and "block drop out quick inet all" in (runtime / "tunnel").read_text()
    config.write_text("192.168.*\n203.0.113.0/24\n8.8.8.8\n")
    run(guard)
    assert states()[1] == before_states[1] and states()[0] != before_states[0]
    before_states = states()
    config.write_text("8.8.8.8\n192.168.1.8/24\n")
    run(checker, success=False, args=("--validate-direct", str(config)))
    run(guard, success=False)
    assert not managed() and (runtime / "tunnel").read_text() == "pass quick on utun8 all no state\n"
    # An invalid list removes every destination: kill each one, flush nothing.
    assert states()[0] == before_states[0]
    assert sorted(states()[1][len(before_states[1]):]) == sorted(
        f"-k 0.0.0.0/0 -k {dest}" for dest in ("192.168.0.0/16", "203.0.113.0/24", "8.8.8.8"))
    assert "Invalid direct IPv4 configuration." in run(checker, success=False).stdout
    code, keys = porcelain(success=False)
    assert code == 2 and keys["problem"] == "invalid-direct" and "direct" not in keys
    config.write_text("192.168.*\n")
    for mode in ("501:644", "0:664"):
        env["KS_CONFIG_MODE"] = mode
        run(guard, success=False)
        assert not managed() and "pass out quick" not in (runtime / "tunnel").read_text()
    del env["KS_CONFIG_MODE"]
    config.unlink()
    run(guard)
    (root / "happ-interface").write_text("utun8")
    run(guard)
    assert "Happ Plus: Connected (utun8)" in run(checker).stdout
    (root / "ambiguous-happ").touch()
    run(guard)
    assert not (runtime / "tunnel").read_text()
    run(checker, success=False, args=("--profile-id",))
    assert "Happ Plus: unknown" in run(checker).stdout
    assert porcelain()[1]["vpn"] == "unknown" and porcelain()[1]["client"] == "happ-plus"
    (root / "ambiguous-happ").unlink()
    (root / "no-happ-profile").touch()
    run(guard)
    assert not (runtime / "tunnel").read_text()
    (root / "no-happ-profile").unlink()
    (root / "happ-interface").write_text("utun12")
    # Connected before the guard has opened the tunnel: the checker asks for a retry.
    code, keys = porcelain(success=False)
    assert code == 2 and keys["problem"] == "tunnel" and keys["vpn"] == "Connected"
    assert "VPN and tunnel rules differ" in run(checker, success=False).stdout
    run(guard)
    assert "Allowed tunnel: utun12" in run(checker).stdout
    assert porcelain()[1]["tunnel"] == "utun12"

    run(peer, args=("--apply", "198.51.100.8", "443", "tcp", "shadowrocket"), stdin=template)
    assert "# endpoint happ-plus: 203.0.113.91 8443 udp" in anchor.read_text()
    restored = run(checker).stdout
    assert "VPN server: 198.51.100.8:443/tcp" in restored
    assert "Shadowrocket: Connected (utun4)" in restored

    (root / "app-present").unlink()
    run(installer, success=False)
    assert (root / "loaded").exists() and token.exists()
    config.write_text("8.8.8.8\n")
    run(guard)
    assert managed()
    saved_profile = anchor.read_bytes()
    # A failure after the service is unloaded restores the service and pf.conf.
    for fault in ("fail-remove-load", "fail-saveconf"):
        before = {path: path.read_bytes() for path in (conf, anchor, plist, token, helpers / "guard")}
        (root / fault).touch()
        failed = run(helpers / "remove", success=False)
        (root / fault).unlink()
        assert "Retry removal" in failed.stderr and (root / "loaded").exists()
        assert before == {path: path.read_bytes() for path in before}
        assert 'anchor "local.shadowrocket-guard" quick' in conf.read_text()
        run(guard)
        assert managed()
    run(helpers / "remove")
    assert not managed()
    assert not list((root / "var/run").glob(name + ".*"))
    config.unlink()
    assert anchor.read_bytes() == saved_profile
    assert not any(p.exists() for p in (plist, token, root / "loaded"))
    assert conf.read_text() == original
    (runtime / "tunnel").unlink()

    # The app saves settings with protection off. Old lists remain readable
    # until the first successful save, including an intentionally empty list.
    config.write_text("192.168.*\n")
    prefs = root / "Library/Preferences/io.github.ivan1911.vpn-kill-switch.exceptions.plist"
    list_args = ("--list-direct",)
    old = run(checker, args=list_args).stdout.strip()
    assert old == "192.168.0.0/16"
    prefs.symlink_to(config)
    rejected = run(checker, success=False, args=list_args)
    assert rejected.returncode == 1 and "symbolic link" in rejected.stderr
    prefs.unlink()
    prefs.write_text("invalid plist")
    rejected = run(checker, success=False, args=list_args)
    assert rejected.returncode == 1 and "malformed" in rejected.stderr
    env["KS_CONFIG_MODE"] = "0:666"
    rejected = run(checker, success=False, args=list_args)
    assert rejected.returncode == 1 and "unsafe permissions" in rejected.stderr
    env.pop("KS_CONFIG_MODE")
    if os.geteuid() != 0:
        prefs.chmod(0)
        unreadable = run(checker, success=False, args=list_args)
        assert unreadable.returncode == 77 and "Administrator access" in unreadable.stderr
    prefs.unlink()

    run(exceptions, success=False, args=(old, "1.2.3.999"))
    assert not prefs.exists()
    run(exceptions, args=(old, "203.0.113.23"))
    new = run(checker, args=list_args).stdout.strip()
    assert new == "203.0.113.23/32" and not token.exists()
    run(exceptions, success=False, args=(old, ""))
    assert run(checker, args=list_args).stdout.strip() == new
    run(exceptions, args=(new, ""))
    assert run(checker, args=list_args).stdout.strip() == ""
    # Save a Happ Plus configuration with protection off and install it with
    # Shadowrocket unavailable. Removal remains available offline.
    run(peer, args=args, stdin=template)
    off = run(checker, success=False).stdout
    assert "Protection: off" in off and "Happ Plus: Connected (utun12)" in off
    assert porcelain(success=False) == (1, {"protection": "off", "tunnel": "unrestricted", "client": "happ-plus",
                                            "client-name": "Happ Plus", "vpn": "Connected", "vpn-interface": "utun12"})
    # Exercise installer preflight and profile parsing without privileges or network.
    marker = "test-debug-marker"
    disabled = run(installer, success=False, args=("invalid-host", "443", "tcp"))
    assert "install.stage" not in disabled.stderr and "vpn.context" not in disabled.stderr
    env["VPN_KS_DEBUG_MARKER"] = marker
    env["KS_TEST_UID"] = "501"
    (root / "error-vpn-list").touch()
    user_lookup = run(checker, success=False, args=("--profile-id",))
    assert f"{marker} vpn.context user-direct" in user_lookup.stderr
    assert f"{marker} vpn.list failed" in user_lookup.stderr
    (root / "error-vpn-list").unlink()
    env["KS_TEST_UID"] = "0"
    cases = {
        "error-pf-preview": ("", "install.stage validate-anchor"),
        "error-asuser": ("", "vpn.list failed"),
        "error-vpn-list": ("", "vpn.list failed"),
        "no-happ-profile": ("", "vpn.profiles none"),
        "ambiguous-happ": ("", "vpn.profiles multiple"),
        "error-vpn-status": ("", "vpn.status failed"),
        "interface-absent": ("", "vpn.interface not-present"),
    }
    for fault, (contents, expected) in cases.items():
        (root / fault).write_text(contents)
        result = run(installer, success=False)
        events = [line.removeprefix(marker + " ") for line in result.stderr.splitlines()
                  if line.startswith(marker + " ")]
        assert expected in events, result.stderr
        assert all("203.0.113." not in line and "aaaaaaaa-bbbb" not in line for line in events)
        assert not plist.exists() and not token.exists()
        (root / fault).unlink()
    for status, expected in (
        ("Disconnecting\n", "vpn.state Disconnecting"),
        ("sensitive fixture value https://secret.invalid\n", "vpn.state unknown"),
        ("Connected\nInterfaceName : en0\n", "vpn.interface missing"),
        ("Connected\nInterfaceName : utun6\nInterfaceName : utun8\n", "vpn.interface ambiguous"),
    ):
        (root / "happ-state").write_text(status)
        result = run(installer, success=False)
        assert f"{marker} {expected}" in result.stderr, result.stderr
        assert "Connect Happ Plus" in result.stderr and "secret.invalid" not in result.stderr
        assert not plist.exists() and not token.exists()
        (root / "happ-state").unlink()
    connected = run(installer)
    assert f"{marker} vpn.context console-user" in connected.stderr
    assert f"{marker} vpn.interface utun12" in connected.stderr
    assert f"{marker} install.stage complete" in connected.stderr
    del env["VPN_KS_DEBUG_MARKER"]
    run(installer)
    assert "Allowed tunnel: utun12" in run(checker).stdout
    # A GUI-only upgrade from the previous service and a failed route change
    # both leave a working verified guard. No reinstall or reconnect is needed.
    guard.write_text(guard.read_text().replace("# direct-ipv4-preferences\n", ""))
    run(exceptions, args=("", "8.8.8.8"))
    assert "# direct-ipv4-preferences" in guard.read_text() and "8.8.8.8/32" in managed()
    # Saving with no uplink succeeds and applies once Wi-Fi or Ethernet returns.
    (root / "offline").touch()
    run(exceptions, args=("8.8.8.8/32", "8.8.8.8\n1.1.1.1"))
    assert not managed()
    assert run(checker, args=list_args).stdout.split() == ["8.8.8.8/32", "1.1.1.1/32"]
    assert "waiting for Wi-Fi or Ethernet" in run(checker).stdout
    (root / "offline").unlink()
    run(guard)
    assert set(managed()) == {"8.8.8.8/32", "1.1.1.1/32"}
    run(exceptions, args=("8.8.8.8/32\n1.1.1.1/32", "8.8.8.8"))
    assert set(managed()) == {"8.8.8.8/32"}
    (root / "route-conflict").touch()
    run(exceptions, success=False, args=("8.8.8.8/32", "8.8.8.8\n1.1.1.1"))
    assert run(checker, args=list_args).stdout.strip() == "8.8.8.8/32"
    (root / "route-conflict").unlink()
    run(exceptions, args=("8.8.8.8/32", ""))
    assert not managed()
    (root / "happ-present").unlink()
    error = run(installer, success=False)
    assert "Happ Plus is required" in error.stderr
    saved_profile = anchor.read_bytes()
    run(helpers / "remove")
    assert anchor.read_bytes() == saved_profile
    assert not any(p.exists() for p in (plist, token, root / "loaded"))

    # A fresh installer process follows the same no-argument path as the menu.
    assert conf.read_text() == original
    assert "Protection: off" in run(checker, success=False).stdout
    (root / "happ-present").touch()
    run(installer)
    reinstalled = run(checker).stdout
    assert "Happ Plus: Connected (utun12)" in reinstalled
    assert "VPN server: 203.0.113.91:8443/udp" in reinstalled
    assert anchor.read_bytes() == saved_profile

print("Passed recovery, client switching, IPv4 exceptions, uplink changes, route conflicts and offline removal.")
