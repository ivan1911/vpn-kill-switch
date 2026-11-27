"""Build identity for the app bundle. Run from the project root."""
import plistlib
import re
import subprocess
import sys
from pathlib import Path


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def metadata(release_sha=None):
    version = Path("VERSION").read_text().strip()
    if not re.fullmatch(r"(?:0|[1-9][0-9]*)(?:\.(?:0|[1-9][0-9]*)){2}", version):
        raise ValueError("VERSION must contain MAJOR.MINOR.PATCH")

    checkout = Path(".git").exists()
    if checkout:
        commit = git("rev-parse", "HEAD")
        dirty = bool(git("status", "--porcelain", "--untracked-files=normal"))
    else:
        # git archive expands this marker. A plain source copy has no revision.
        revision = Path(".git-revision").read_text().strip()
        commit = revision if re.fullmatch(r"[0-9a-f]{40}|[0-9a-f]{64}", revision) else ""
        dirty = False

    if release_sha is not None:
        if not checkout or dirty or not release_sha or release_sha != commit:
            raise ValueError("Build the release from a clean checkout of the full merge SHA reported by the release PR")
        has_origin_main = subprocess.run(["git", "show-ref", "--verify", "--quiet", "refs/remotes/origin/main"]).returncode == 0
        main_ref = "refs/remotes/origin/main" if has_origin_main else "refs/heads/main"
        if commit not in git("rev-list", "--first-parent", main_ref).splitlines():
            raise ValueError("The supplied release PR result must be on main. Refresh the local main reference and retry.")
        label = version
    else:
        label = version + "-dev"

    label += "+g" + commit[:7] if commit else "+unknown"
    if dirty:
        label += ".dirty"
    return dict(CFBundleShortVersionString=version, VPNBuildIdentifier=label,
                VPNSourceCommit=commit)


if __name__ == "__main__":
    try:
        plistlib.dump(metadata(*sys.argv[1:]), sys.stdout.buffer)
    except ValueError as error:
        sys.exit(str(error))
