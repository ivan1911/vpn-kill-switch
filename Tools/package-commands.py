"""Assemble the standalone Finder commands from the PF and launchd sources."""
import sys
from pathlib import Path

project = Path(__file__).resolve().parents[1]
guard = project / "Guard"
commands = project / "Commands"


def source(name):
    return (guard / name).read_text()


def inline(name, *includes):
    script = source(name)
    for filename in includes:
        directive = f'. "$(dirname "$0")/{filename}"'
        assert script.count(directive) == 1
        script = script.replace(directive, source(filename).rstrip())
    return script


def heredoc(path, marker, body):
    assert marker not in body.splitlines()
    return f'cat > "{path}" <<\'{marker}\'\n{body.rstrip()}\n{marker}'


guard_script = inline("guard.sh", "config.sh", "debug.sh", "profile.sh", "direct.sh")
template = source("guard-install.sh")
header, install = template.replace("# @@DIRECT_CLEANUP@@", source("direct.sh").rstrip()).split("@@FILES@@")
marker = 'if [ "${1:-}" = --remove ]; then'
assert header.count(marker) == 1 and header.endswith("fi\n")
remove = header.replace("@@INSTALL_CHECK@@\n", source("config.sh")).replace(marker, "{")[:-3] + "}\n"
upgrade = source("upgrade-service.sh").replace(
    "# @@UPGRADED_GUARD@@", heredoc("$stage/guard.next", "UPGRADED_GUARD", guard_script)
).replace(
    "# @@UPGRADED_POLICY@@", heredoc("$stage/policy.next", "UPGRADED_POLICY", source("policy.sh"))
).replace(
    "# @@UPGRADED_REMOVE@@", heredoc("$stage/remove.next", "UPGRADED_REMOVE", remove)
)
if sys.argv[1:] == ["--app-exceptions"]:
    print(inline("exceptions.sh", "config.sh", "direct.sh").replace("# @@UPGRADE_SERVICE@@", upgrade.rstrip()), end="")
    sys.exit(0)

peer = inline("peer.sh", "config.sh", "policy.sh")
if sys.argv[1:] == ["--app-peer"]:
    print(peer.replace("# @@UPGRADE_SERVICE@@", upgrade.rstrip()), end="")
    sys.exit(0)

header = header.replace("@@INSTALL_CHECK@@",
                        source("config.sh") + source("debug.sh") + source("require-client.sh").rstrip())

files = {
    "peer": peer,
    "policy.sh": source("policy.sh"),
    "guard": guard_script,
    "anchor": source("guard.pf"),
    "remove": remove,
    "daemon.plist": source("guard.plist"),
}
blocks = [heredoc(f"$stage/{name}", "EMBEDDED_FILE", body) for name, body in files.items()]
for action, body in {
    "check": inline("check.sh", "config.sh", "debug.sh", "profile.sh", "direct.sh"),
    "install": header + "\n".join(blocks) + install,
    "remove": remove
}.items():
    path = commands / f"{action}-shadowrocket-killswitch.command"
    path.write_text(body)
    path.chmod(0o755)
