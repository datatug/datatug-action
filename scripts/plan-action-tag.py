#!/usr/bin/env python3
"""Plan an immutable Action tag; read-only, with no network or publication."""

import json
import re
import subprocess
import sys


RUNTIME_PATHS = ("action.yml", "action.yaml", "scripts/datatug-cli.sh")
VERSION = re.compile(r"v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\Z")
BREAKING = re.compile(r"^[a-z]+(?:\([^\n)]+\))?!:|^BREAKING[ -]CHANGE:", re.MULTILINE)
FEATURE = re.compile(r"^feat(?:\([^\n)]+\))?:", re.MULTILINE)


def git(*args):
    return subprocess.check_output(["git", *args], text=True).strip()


def plan(sha):
    if not re.fullmatch(r"[0-9a-f]{40}", sha):
        raise ValueError("expected an exact tested commit SHA")
    if git("rev-parse", f"{sha}^{{commit}}") != sha:
        raise ValueError("candidate is not the exact tested commit")
    versions = []
    for tag in git("tag", "--list").splitlines():
        match = VERSION.fullmatch(tag)
        if match:
            versions.append((tuple(map(int, match.groups())), tag))
    if not versions:
        return {"tag": None, "reason": "initial tag requires explicit reviewed bootstrap"}
    version, baseline = max(versions)
    previous = git("rev-parse", f"{baseline}^{{commit}}")
    if previous == sha:
        return {"tag": None, "reason": "commit already has the latest version", "baseline": baseline}
    ancestor = subprocess.run(
        ["git", "merge-base", "--is-ancestor", previous, sha], check=False
    ).returncode
    if ancestor == 1:
        return {"tag": None, "reason": "stale or divergent candidate", "baseline": baseline}
    if ancestor != 0:
        raise RuntimeError("could not establish baseline ancestry")
    changed = git("diff", "--name-only", "--no-renames", baseline, sha, "--", *RUNTIME_PATHS)
    if not changed:
        return {"tag": None, "reason": "no Action runtime change", "baseline": baseline}
    messages = git("log", "--format=%B", f"{baseline}..{sha}", "--", *RUNTIME_PATHS)
    if BREAKING.search(messages):
        raise ValueError("declared breaking change requires an explicit release decision")
    major, minor, patch = version
    if FEATURE.search(messages):
        minor, patch = minor + 1, 0
    else:
        patch += 1
    return {
        "tag": f"v{major}.{minor}.{patch}",
        "sha": sha,
        "baseline": baseline,
        "reason": "tested Action runtime change",
        "changed": changed.splitlines(),
    }


if __name__ == "__main__":
    if len(sys.argv) != 2:
        raise SystemExit("usage: plan-action-tag.py <exact-tested-sha>")
    print(json.dumps(plan(sys.argv[1]), sort_keys=True))
