#!/usr/bin/env python3
"""Read-only release version planning after the caller synchronizes remote tags."""

import argparse
import json
import plistlib
import re
import subprocess
import sys
from pathlib import Path


VERSION = re.compile(r"(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)")


def parse_version(value):
    if not isinstance(value, str) or not VERSION.fullmatch(value):
        raise ValueError(f"Invalid version: {value!r}; expected MAJOR.MINOR.PATCH")
    return tuple(map(int, value.split(".")))


def build_number(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]*", value):
        raise ValueError(f"Invalid CFBundleVersion: {value!r}; expected a positive integer")
    return int(value)


def git(repo, *args):
    return subprocess.check_output(["git", "-C", str(repo), *args], stderr=subprocess.PIPE)


def plan(repo, bump=None, explicit_version=None):
    root = Path(git(repo, "rev-parse", "--show-toplevel").decode().strip())
    current_plist = plistlib.loads((root / "Info.plist").read_bytes())
    current = parse_version(current_plist["CFBundleShortVersionString"])
    current_build = build_number(current_plist["CFBundleVersion"])
    all_tags = git(root, "tag", "--list").decode().splitlines()
    stable = sorted(
        (parse_version(tag[1:]), tag)
        for tag in all_tags
        if tag.startswith("v") and VERSION.fullmatch(tag[1:])
    )
    latest, latest_tag = stable[-1] if stable else (None, None)
    builds = []
    for version, tag in stable:
        tagged_plist = plistlib.loads(git(root, "show", f"{tag}:Info.plist"))
        if parse_version(tagged_plist["CFBundleShortVersionString"]) != version:
            raise ValueError(f"Tag {tag} does not match its committed Info.plist")
        builds.append(build_number(tagged_plist["CFBundleVersion"]))
    if latest is not None:
        git(root, "merge-base", "--is-ancestor", f"{latest_tag}^{{commit}}", "HEAD")
        if current < latest:
            raise ValueError("Working version is older than the latest tag; synchronize the branch")

    if explicit_version is not None:
        target = parse_version(explicit_version)
        if target < current:
            raise ValueError("Explicit version is lower than the prepared working version")
    elif latest is None:
        target = current
    else:
        major, minor, patch = latest
        if bump == "major":
            minimum = (major + 1, 0, 0)
        elif bump == "minor":
            minimum = (major, minor + 1, 0)
        else:
            minimum = (major, minor, patch + 1)
        target = max(current, minimum)

    if latest is not None and target <= latest:
        raise ValueError("Release version must be greater than every existing stable tag")
    target_version = ".".join(map(str, target))
    target_tag = "v" + target_version
    if target_tag in all_tags:
        raise ValueError(f"Tag already exists: {target_tag}")
    return {
        "repository": str(root),
        "stable_tags": [tag for _, tag in stable],
        "other_tags": sorted(set(all_tags) - {tag for _, tag in stable}),
        "latest_tag": latest_tag,
        "latest_commit": git(root, "rev-parse", f"{latest_tag}^{{commit}}").decode().strip()
        if latest_tag else None,
        "current_version": current_plist["CFBundleShortVersionString"],
        "current_build": current_build,
        "bump": bump,
        "version": target_version,
        "build": max(current_build, max(builds, default=0) + 1),
        "tag": target_tag,
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repo", type=Path, default=Path.cwd())
    choice = parser.add_mutually_exclusive_group(required=True)
    choice.add_argument("--bump", choices=("patch", "minor", "major"))
    choice.add_argument("--version", help="Explicit version without the v prefix")
    args = parser.parse_args()
    try:
        result = plan(args.repo, args.bump, args.version)
    except (ValueError, KeyError, OSError, plistlib.InvalidFileException, subprocess.CalledProcessError) as error:
        if isinstance(error, subprocess.CalledProcessError):
            detail = error.stderr.decode(errors="replace").strip()
            message = detail or "Latest stable tag is not an ancestor of HEAD"
        else:
            message = str(error)
        print(f"Release planning failed: {message}", file=sys.stderr)
        return 1
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0


if __name__ == "__main__":
    sys.exit(main())
