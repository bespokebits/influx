#!/usr/bin/env python3
"""Fail when Swift package pins drift apart, stop satisfying Package.swift, or are younger than N days (default 14).

Three rules:

1. Every copy of Package.resolved (--copy, repeatable) matches the package's
   own Package.resolved. The project keeps a copy at the
   project root because Xcode Cloud will not resolve packages itself; if the
   copies differ, TestFlight ships a dependency the tests never ran against.
2. Every remote dependency in Package.swift is pinned at a tagged version its
   requirement admits. A branch or revision pin has no release age.
3. The 14-day release-age floor covers Swift pins. A pin's age is the
   `published_at` of the GitHub release for its tag. A pin whose age cannot be
   determined, including a tag with no GitHub release, fails (fail closed).

A package with no remote dependencies may have no Package.resolved; that passes.
--offline checks rules 1 and 2 with no network; `scripts/verify.sh` runs it that
way. With --base REF, only pins added or changed since REF (git) are aged; CI
passes --base HEAD^1. GITHUB_TOKEN, when set, authenticates the API lookups.

Standard library only.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timedelta, timezone

MANIFEST = "Package.swift"
RESOLVED = "Package.resolved"
API = "https://api.github.com"
VERSION = re.compile(r"^(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$")
GITHUB_URL = re.compile(r"^https://github\.com/([^/\s]+)/([^/\s]+?)(?:\.git)?/?$", re.I)


def parse_version(text: str) -> tuple:
    """A comparable key: a pre-release sorts before its release (semver)."""
    match = VERSION.match(text)
    if not match:
        raise ValueError(f"not a semantic version: {text!r}")
    major, minor, patch, pre = match.groups()
    identifiers = tuple((0, int(part)) if part.isdigit() else (1, part)
                        for part in pre.split(".")) if pre else ()
    return (int(major), int(minor), int(patch), 0 if pre else 1, identifiers)


def normalized(url: str) -> str:
    url = url.strip().lower().rstrip("/")
    return url[:-4] if url.endswith(".git") else url


def package_calls(manifest: str) -> list[str]:
    """The argument text of every `.package(...)` call, parentheses balanced."""
    calls, start = [], 0
    while (start := manifest.find(".package(", start)) != -1:
        opened = start + len(".package")
        depth = 0
        for end in range(opened, len(manifest)):
            depth += {"(": 1, ")": -1}.get(manifest[end], 0)
            if depth == 0:
                break
        else:
            raise ValueError("unbalanced parentheses in a .package(...) call")
        calls.append(manifest[opened + 1:end])
        start = end
    return calls


def requirements(manifest: str) -> dict[str, tuple[tuple, tuple | None, bool]]:
    """url -> (lower bound, upper bound or None for exact, upper bound inclusive).

    Admits the forms this manifest can reasonably use; anything else (branch:,
    revision:, a form this does not know) raises, so a new form fails loudly
    rather than passing unchecked. Local `path:` packages have no pin.
    """
    found = {}
    for call in package_calls(manifest):
        url = re.search(r'url:\s*"([^"]+)"', call)
        if not url:
            if re.search(r"\bpath:", call):
                continue
            raise ValueError(f"unrecognised .package(...) call: {call.strip()!r}")
        rest = call[url.end():].strip().removeprefix(",").strip()
        if m := re.fullmatch(r'\.upToNextMinor\(\s*from:\s*"([^"]+)"\s*\)', rest):
            low = parse_version(m[1])
            found[normalized(url[1])] = (low, (low[0], low[1] + 1, 0, 0, ()), False)
        elif m := re.fullmatch(r'from:\s*"([^"]+)"', rest):
            low = parse_version(m[1])
            found[normalized(url[1])] = (low, (low[0] + 1, 0, 0, 0, ()), False)
        elif m := re.fullmatch(r'\.upToNextMajor\(\s*from:\s*"([^"]+)"\s*\)', rest):
            low = parse_version(m[1])
            found[normalized(url[1])] = (low, (low[0] + 1, 0, 0, 0, ()), False)
        elif m := re.fullmatch(r'exact:\s*"([^"]+)"|\.exact\(\s*"([^"]+)"\s*\)', rest):
            found[normalized(url[1])] = (parse_version(m[1] or m[2]), None, True)
        elif m := re.fullmatch(r'"([^"]+)"\s*(\.\.<|\.\.\.)\s*"([^"]+)"', rest):
            found[normalized(url[1])] = (parse_version(m[1]), parse_version(m[3]), m[2] == "...")
        else:
            raise ValueError(f"{url[1]}: requirement is not a version range this check understands "
                             f"(branch and revision pins have no release age): {rest.strip(' ,')!r}")
    return found


def admits(requirement: tuple[tuple, tuple | None, bool], version: tuple) -> bool:
    low, high, inclusive = requirement
    if high is None:
        return version == low
    return low <= version and (version <= high if inclusive else version < high)


def pins(text: str) -> dict[str, dict]:
    """location -> {identity, location, version, revision} for Package.resolved v2/v3."""
    document = json.loads(text)
    if document.get("version") not in (2, 3):
        raise ValueError(f"unsupported Package.resolved version {document.get('version')!r}")
    found = {}
    for pin in document.get("pins", []):
        state = pin.get("state", {})
        found[normalized(pin["location"])] = {
            "identity": pin.get("identity", ""), "location": pin["location"], "kind": pin.get("kind"),
            "version": state.get("version"), "revision": state.get("revision"),
        }
    return found


def consistency_errors(manifest: str, resolved: str, copies: dict[str, str | None]) -> list[str]:
    errors = []
    for path, text in sorted(copies.items()):
        if text != resolved:
            errors.append(f"{path} differs from {RESOLVED}; Xcode Cloud would build other pins than "
                          f"the tests ran against. Copy it: cp {RESOLVED} {path}")
    pinned = pins(resolved)
    for location, pin in sorted(pinned.items()):
        if pin["kind"] != "remoteSourceControl":
            errors.append(f"{pin['identity']}: pin kind {pin['kind']!r} is not a remote source-control pin")
        elif not pin["version"]:
            errors.append(f"{pin['identity']}: pinned to a revision or branch, not a tagged version")
    for url, requirement in sorted(requirements(manifest).items()):
        pin = pinned.get(url)
        if pin is None:
            errors.append(f"{url} is in {MANIFEST} but not pinned in {RESOLVED}; resolve the package")
        elif pin["version"] and not admits(requirement, parse_version(pin["version"])):
            errors.append(f"{pin['identity']} is pinned at {pin['version']}, which {MANIFEST} does not admit; "
                          f"resolve the package again")
    return errors


def github_json(path: str) -> dict | None:
    """GET a GitHub REST path; None on 404, raises on any other failure."""
    headers = {"Accept": "application/vnd.github+json", "User-Agent": "influx-swift-pins-check",
               "X-GitHub-Api-Version": "2022-11-28"}
    if os.environ.get("GITHUB_TOKEN"):
        headers["Authorization"] = f"Bearer {os.environ['GITHUB_TOKEN']}"
    request = urllib.request.Request(API + path, headers=headers)
    try:
        with urllib.request.urlopen(request, timeout=60) as response:  # noqa: S310 (fixed host)
            return json.loads(response.read())
    except urllib.error.HTTPError as error:
        if error.code == 404:
            return None
        raise


def release_pin(location: str, version: str) -> tuple[datetime, str] | None:
    """Publication time and commit of the same release tag (`X` or `vX`)."""
    match = GITHUB_URL.match(location.strip())
    if not match:
        raise ValueError("not a github.com package; its release age cannot be looked up")
    owner, repo = (urllib.parse.quote(part, safe="") for part in match.groups())
    for tag in (version, f"v{version}"):
        release = github_json(f"/repos/{owner}/{repo}/releases/tags/{urllib.parse.quote(tag, safe='')}")
        if release and not release.get("draft") and release.get("published_at"):
            ref = github_json(f"/repos/{owner}/{repo}/git/ref/tags/{urllib.parse.quote(tag, safe='')}")
            obj = (ref or {}).get("object", {})
            # Annotated tags may point at another tag; dereference a bounded
            # chain and fail closed unless it ends at a commit.
            for _ in range(5):
                if obj.get("type") != "tag":
                    break
                annotated = github_json(f"/repos/{owner}/{repo}/git/tags/{obj['sha']}")
                obj = (annotated or {}).get("object", {})
            if obj.get("type") != "commit" or not obj.get("sha"):
                raise ValueError(f"release tag {tag} does not resolve to a commit")
            return (datetime.fromisoformat(release["published_at"].replace("Z", "+00:00")), obj["sha"])
    return None


def read(path: str, ref: str | None = None) -> str | None:
    if ref is None:
        try:
            with open(path, encoding="utf-8", newline="") as fh:
                return fh.read()
        except FileNotFoundError:
            return None
    shown = subprocess.run(["git", "show", f"{ref}:{path}"], capture_output=True, text=True)
    return shown.stdout if shown.returncode == 0 else None


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("--days", type=int, default=14)
    ap.add_argument("--base", help="git ref; age only pins added or changed since it")
    ap.add_argument("--at", help="ISO-8601 time to age pins at (default: now)")
    ap.add_argument("--offline", action="store_true", help="rules 1 and 2 only; no network")
    ap.add_argument("--list", action="store_true", help="print every aged pin with its age")
    ap.add_argument("--package", default=".", help="directory holding Package.swift (default: .)")
    ap.add_argument("--copy", action="append", default=[],
                    help="path of a Package.resolved copy that must match the package's (repeatable)")
    args = ap.parse_args()

    global MANIFEST, RESOLVED
    MANIFEST = os.path.normpath(os.path.join(args.package, "Package.swift"))
    RESOLVED = os.path.normpath(os.path.join(args.package, "Package.resolved"))
    manifest = read(MANIFEST)
    if manifest is None:
        print(f"::error file={MANIFEST}::{MANIFEST} not found")
        return 1
    resolved = read(RESOLVED)
    if resolved is None:
        if requirements(manifest):
            print(f"::error file={MANIFEST}::{MANIFEST} has remote dependencies but {RESOLVED} is missing; "
                  f"resolve the package")
            return 1
        resolved = '{"pins": [], "version": 3}'
        if any(read(path) is not None for path in args.copy):
            print(f"::error::{RESOLVED} is missing but a copy exists; remove the copy or resolve the package")
            return 1
        print(f"swift-pins: {MANIFEST} has no remote dependencies; nothing to pin")
        return 0
    try:
        errors = consistency_errors(manifest, resolved, {path: read(path) for path in args.copy})
    except (ValueError, KeyError, json.JSONDecodeError) as exc:
        errors = [f"cannot read the Swift package files: {exc}"]
    for error in errors:
        print(f"::error file={RESOLVED}::{error}")
    if errors:
        return 1
    head = pins(resolved)
    copies = f"{', '.join(args.copy)} match" if args.copy else "no copies to compare"
    print(f"swift-pins: {len(head)} pins; {copies}; every {MANIFEST} requirement is met")
    if args.offline:
        return 0

    base: dict[str, dict] = {}
    if args.base:
        before = read(RESOLVED, args.base)
        if before is None:
            print(f"{RESOLVED} not found at {args.base}; aging every pin")
        else:
            base = pins(before)
    candidates = sorted((pin for location, pin in head.items() if base.get(location) != pin),
                        key=lambda pin: pin["identity"])
    now = datetime.fromisoformat(args.at.replace("Z", "+00:00")) if args.at else datetime.now(timezone.utc)
    if now.tzinfo is None:
        raise SystemExit("--at needs a timezone, e.g. 2026-09-24T17:00:00Z")
    cutoff = now - timedelta(days=args.days)
    young, unknown = [], []
    for pin in candidates:
        try:
            release = release_pin(pin["location"], pin["version"])
        except Exception as exc:  # network, API or URL failure: fail closed
            unknown.append((pin, f"release lookup failed: {exc}"))
            continue
        if release is None:
            unknown.append((pin, "GitHub has no published release for its tag"))
            continue
        released, revision = release
        if pin["revision"] != revision:
            unknown.append((pin, f"pinned revision {pin['revision']} does not match release tag commit {revision}"))
            continue
        if args.list:
            age = now - released
            print(f"  {pin['identity']} {pin['version']} released {released:%Y-%m-%dT%H:%MZ}, "
                  f"{age.days} days {age.seconds // 3600} h old at {now:%Y-%m-%dT%H:%MZ}")
        if released > cutoff:
            young.append((pin, released))

    scope = f"changed since {args.base}" if args.base else f"in {RESOLVED}"
    print(f"swift-pins: aged {len(candidates)} pins {scope}; floor {args.days} days "
          f"(cutoff {cutoff:%Y-%m-%dT%H:%MZ})")
    for pin, released in young:
        print(f"::error file={RESOLVED}::{pin['identity']} {pin['version']} released {released:%Y-%m-%d} "
              f"({(now - released).days} days ago) is younger than {args.days} days")
    for pin, why in unknown:
        print(f"::error file={RESOLVED}::{pin['identity']} {pin['version']}: release age unknown ({why})")
    if young or unknown:
        print("Pin an older version, or wait until it is old enough; a younger fix needs a human decision.")
        return 1
    print("swift-pins: ok")
    return 0


if __name__ == "__main__":
    sys.exit(main())
