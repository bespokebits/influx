#!/usr/bin/env python3
"""Fail when something private would be published.

AGENTS.md says nothing here may name a person, a device, a home directory, a
private host, a secret-store item or an internal process code. This check
makes that rule fail instead of relying on review. It has two layers:

1. Generic patterns, committed below (PATTERNS). They know nothing private:
   private network names, home-directory paths, private and carrier-grade NAT
   IPv4 literals, IPv6 unique local addresses, secret-store references,
   email addresses other than the example and no-reply forms, Sammy hosts
   other than api.heysammy.app, Apple device identifiers and ask codes. A
   reviewed occurrence that must stay (a test
   fixture of the address guard, say) is listed exactly in
   scripts/publication-allowlist.txt: one file, one pattern, one matched
   text per line. An entry that allows nothing is noted, not failed: a new
   exception lands before the code it covers (see the list's header).
2. A personal list that is never committed: one term per line in
   ~/.config/influx/publication-terms (INFLUX_PUBLICATION_TERMS_FILE names
   another file), and also each line of the INFLUX_PUBLICATION_TERMS
   environment variable, for CI. Blank lines and lines starting with # are
   skipped. A term matches literally, ignoring case, as a whole word: not
   inside a longer run of letters and digits. Nothing allows a personal
   term. With no list the check says so in one line and runs layer 1 only.

Output names the file, the line, the layer and the pattern; a personal term
is named by its line number in the list, never by its text, so CI logs stay
clean. Matched text is never printed.

What it scans:
  (default)            every tracked file in the working tree, and its path
  --staged             every tracked file as staged in the index (the
                       pre-commit hook; scripts/install-publication-hook.sh)
  --messages RANGE     also the commit messages of a git range (a..b)
  --pr-title=TEXT      also a pull request's title (a squash merge writes
  --pr-body=TEXT       the title and body into main); use the = form, since
                       a body often starts with "-"
  --root DIR           scan another checkout, read only as data; with
  --allowlist FILE     apply this allowlist instead of DIR's own. The
                       pull-request scan runs main's copy of this script
                       over the pull request's checkout with main's
                       allowlist, so a pull request cannot loosen either
                       (.github/workflows/publication.yml says why).
  --layer1-only=WHY    skip the personal list, saying why in one line (a
                       fork's pull request, which gets no secrets)
  --history            every blob, path, commit message, author and committer
                       of every commit reachable from any ref, instead of the
                       tree; reports each finding once per path. It reads
                       history and rewrites nothing.

Binary files are scanned for personal terms only. Exit status: 0 clean,
1 findings, 2 usage or setup error. Standard library only.
"""
from __future__ import annotations

import argparse
import os
import re
import subprocess
import sys
from collections import defaultdict
from dataclasses import dataclass
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ALLOWLIST = "scripts/publication-allowlist.txt"
DEFAULT_TERMS = Path.home() / ".config" / "influx" / "publication-terms"
# History only: a larger blob is left out of the report. The tree and the
# index are read whatever the size, so a large file cannot hide a term.
HISTORY_MAX_BYTES = 8 * 1024 * 1024

# Octets 0-255, for the address patterns.
_O = r"(?:25[0-5]|2[0-4]\d|1\d\d|[1-9]?\d)"
# Not part of a longer dotted number (a version string, another address).
_NB = r"(?<![\d.])"
_NA = r"(?![\d]|\.\d)"

# Layer 1. Each name is what the output prints; keep names stable, the
# allowlist refers to them.
PATTERNS: list[tuple[str, re.Pattern[str]]] = [
    (
        "private-network-name",
        re.compile(
            r"\btailnet\b"
            # A dotfile's name (.env.local) is not a host.
            # Two characters or more first, so a one-letter property in code
            # is not a host.
            r"|(?<![\w.-])[a-z0-9][a-z0-9-]+(?:\.[a-z0-9-]+)*"
            r"\.(?:ts\.net|home\.arpa|local|lan|internal|localdomain|intranet|corp)"
            r"(?![\w-]|\.\w)",
            re.IGNORECASE,
        ),
    ),
    (
        "home-directory-path",
        re.compile(
            # Placeholder and CI-runner names are not anyone's home.
            # The home itself counts too, with or without a slash after it.
            r"/Users/(?!(?:Shared|runner|you|username|user|name|me|example)(?![\w.-]))[A-Za-z0-9._-]+"
            r"|/home/(?!(?:runner|user|ubuntu|you|username|name|example)(?![\w.-]))[a-z_][a-z0-9._-]*"
            # A tilde, a name and a slash: a bare tilde before a letter is
            # bitwise not in code.
            r"|(?<![\w~/])~[a-z_][a-z0-9._-]*/"
        ),
    ),
    (
        "private-ipv4",
        re.compile(
            _NB
            + r"(?:10\.%(o)s|172\.(?:1[6-9]|2\d|3[01])|192\.168|100\.(?:6[4-9]|[7-9]\d|1[01]\d|12[0-7]))"
            % {"o": _O}
            + r"\.%(o)s\.%(o)s" % {"o": _O}
            + _NA
        ),
    ),
    (
        "ipv6-ula",
        re.compile(r"(?<![\w:])f[cd][0-9a-f]{2}:(?:[0-9a-f]{0,4}:){1,6}[0-9a-f]{0,4}(?![\w:])", re.IGNORECASE),
    ),
    (
        "secret-store-reference",
        re.compile(
            r"\bop:/{2}"
            r"|\b1Password\b\s*(?::|>|\bitems?\b|\bvaults?\b)"
            r"|--(?:source-)?item\s+[\"'A-Za-z]"
            # A lower-case vault, " > ", then a title-case item of two or
            # more words. A settings path starts upper-case and chains more
            # steps, and code never compares a value with two capitalised
            # words.
            r"|(?<![\w.])(?<!> )(?-i:[a-z][\w-]*) > (?-i:[A-Z][\w.()-]*(?: [A-Z\d][\w.()-]*)+)"
            r"|\bvault\s*>\s*\w",
            re.IGNORECASE,
        ),
    ),
    (
        "email-address",
        re.compile(
            r"(?<![\w.+-])"
            # Example, reserved and no-reply forms are fine.
            r"(?!(?:no-?reply|git)@)"
            r"(?![\w.+-]*\+[\w.-]*@users\.noreply\.github\.com)"
            r"[A-Za-z0-9._%+-]+@"
            r"(?!(?:[\w-]+\.)*(?:example\.[a-z]+|example|invalid|test|localhost)\b)"
            r"(?!users\.noreply\.github\.com\b)"
            r"(?!\d+x\.)"
            r"[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,}\b",
            re.IGNORECASE,
        ),
    ),
    (
        "sammy-host",
        # AGENTS.md: api.heysammy.app is the one Sammy host the repo may name.
        re.compile(r"(?<![\w.-])(?!api\.heysammy\.app\b)(?:[\w-]+\.)+heysammy\.app\b", re.IGNORECASE),
    ),
    (
        "device-identifier",
        # An Apple device's UDID (iPhone XS and later). Simulator and other
        # UUIDs are not covered: they are everywhere and name nothing.
        re.compile(r"\b0000[0-9]{4}-[0-9A-F]{16}\b"),
    ),
    (
        "ask-code",
        re.compile(r"\bK\d{1,4}\b"),
    ),
]


@dataclass(frozen=True)
class Finding:
    where: str  # "path:line", "path", "commit abc1234 message line 3", ...
    layer: int
    pattern: str  # layer-1 name, or "personal-term:N"

    def __str__(self) -> str:
        return f"{self.where}: layer {self.layer} {self.pattern}"


class Terms:
    """The personal list: literal, case-insensitive, whole-word."""

    def __init__(self, entries: list[tuple[str, str]]):
        self.entries = entries  # (label, term)
        self.regexes = [(label, self.compile(term)) for label, term in entries]

    @staticmethod
    def compile(term: str) -> re.Pattern[str]:
        # A word edge only where the term itself starts or ends with a letter
        # or digit: a term "repo#" must still match "repo#12".
        before = r"(?<![A-Za-z0-9])" if term[0].isalnum() else ""
        after = r"(?![A-Za-z0-9])" if term[-1].isalnum() else ""
        return re.compile(before + re.escape(term) + after, re.IGNORECASE)

    @classmethod
    def load(cls, env: dict[str, str]) -> tuple["Terms", str | None]:
        entries: list[tuple[str, str]] = []
        notes: list[str] = []
        path = Path(env["INFLUX_PUBLICATION_TERMS_FILE"]) if env.get("INFLUX_PUBLICATION_TERMS_FILE") else DEFAULT_TERMS
        if path.is_file():
            for number, line in enumerate(path.read_text(encoding="utf-8").splitlines(), 1):
                term = line.strip()
                if term and not term.startswith("#"):
                    entries.append((f"personal-term:{number}", term))
        elif env.get("INFLUX_PUBLICATION_TERMS_FILE"):
            raise SystemExit(f"check-publication: no personal list at {path}")
        for number, line in enumerate(env.get("INFLUX_PUBLICATION_TERMS", "").splitlines(), 1):
            term = line.strip()
            if term and not term.startswith("#"):
                entries.append((f"personal-term:env{number}", term))
        if not entries:
            notes.append(f"no personal list ({_tilde(path)} or INFLUX_PUBLICATION_TERMS); layer 1 only")
        return cls(entries), (notes[0] if notes else None)

    def search(self, text: str) -> list[str]:
        return [label for label, regex in self.regexes if regex.search(text)]


def _tilde(path: Path) -> str:
    home = str(Path.home())
    text = str(path)
    return "~" + text[len(home):] if text.startswith(home + os.sep) else text


@dataclass
class AllowEntry:
    number: int
    path: str
    pattern: str
    text: str
    used: bool = False


def load_allowlist(file: Path) -> list[AllowEntry]:
    if not file.is_file():
        return []
    names = {name for name, _ in PATTERNS}
    entries = []
    for number, raw in enumerate(file.read_text(encoding="utf-8").splitlines(), 1):
        if not raw.strip() or raw.lstrip().startswith("#"):
            continue
        parts = raw.split(" | ", 2)
        if len(parts) != 3 or not all(parts):
            raise SystemExit(f"{ALLOWLIST}:{number}: expected 'path | pattern | exact matched text'")
        path, pattern, text = parts
        if pattern not in names:
            raise SystemExit(f"{ALLOWLIST}:{number}: unknown pattern {pattern!r}")
        if any(ch in path for ch in "*?["):
            raise SystemExit(f"{ALLOWLIST}:{number}: a path, not a glob")
        # Any one character may be written in brackets ([.], [@], [:],
        # K[3]39, a literal bracket as [[]), so an entry matches neither its
        # own pattern (the list is scanned like any other file) nor other
        # scanners (the org's publish-safety gate).
        text = re.sub(r"\[(.)\]", r"\1", text)
        entries.append(AllowEntry(number, path, pattern, text))
    return entries


class Scanner:
    def __init__(self, terms: Terms, allow: list[AllowEntry]):
        self.terms = terms
        self.allow = allow
        self.findings: list[Finding] = []

    def _allowed(self, path: str | None, pattern: str, matched: str) -> bool:
        if path is None:
            return False
        hit = False
        for entry in self.allow:
            if entry.path == path and entry.pattern == pattern and entry.text == matched:
                entry.used = True
                hit = True
        return hit

    def line(self, text: str, where: str, path: str | None, layer1: bool = True) -> None:
        if layer1:
            for name, regex in PATTERNS:
                for match in regex.finditer(text):
                    if not self._allowed(path, name, match.group(0)):
                        self.findings.append(Finding(where, 1, name))
                        break
        for label in self.terms.search(text):
            self.findings.append(Finding(where, 2, label))

    def text(self, text: str, where: str, path: str | None, layer1: bool = True) -> None:
        for number, line in enumerate(text.splitlines(), 1):
            self.line(line, f"{where}:{number}" if where else str(number), path, layer1)

    def blob(self, data: bytes, path: str, where: str | None = None) -> None:
        """A file's content, and its path."""
        where = where or path
        self.line(path, f"{where} (path)", path)
        if b"\0" in data[:8192]:
            # Binary: personal terms only, as raw bytes.
            for label in self.terms.search(data.decode("latin-1")):
                self.findings.append(Finding(f"{where} (binary)", 2, label))
            return
        self.text(data.decode("utf-8", errors="replace"), where, path)


def git(root: Path, *args: str, input: bytes | None = None) -> bytes:
    result = subprocess.run(["git", *args], cwd=root, input=input, capture_output=True)
    if result.returncode != 0:
        raise SystemExit(f"git {' '.join(args)} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def tracked(root: Path) -> list[str]:
    return [p for p in git(root, "ls-files", "-z").decode().split("\0") if p]


def scan_tree(scanner: Scanner, root: Path, staged: bool) -> None:
    if staged:
        entries = git(root, "ls-files", "-s", "-z").decode().split("\0")
        objects = []
        for entry in entries:
            if not entry:
                continue
            meta, path = entry.split("\t", 1)
            mode, sha, _stage = meta.split()
            if mode != "160000":  # submodules have no blob
                objects.append((sha, path))
        for (sha, path), data in zip(objects, cat_blobs(root, [sha for sha, _ in objects])):
            if data is not None:
                scanner.blob(data, path)
        return
    for path in tracked(root):
        file = root / path
        if file.is_symlink():
            scanner.blob(os.readlink(file).encode(), path)
        elif file.is_file():
            scanner.blob(file.read_bytes(), path)


def cat_blobs(root: Path, shas: list[str], limit: int | None = None):
    """Yield each blob's bytes (None when over limit), in order, from one git process."""
    if not shas:
        return
    proc = subprocess.Popen(
        ["git", "cat-file", "--batch"], cwd=root, stdin=subprocess.PIPE, stdout=subprocess.PIPE
    )
    assert proc.stdin and proc.stdout
    import threading

    def feed() -> None:
        try:
            for sha in shas:
                proc.stdin.write(sha.encode() + b"\n")
            proc.stdin.close()
        except BrokenPipeError:
            pass

    writer = threading.Thread(target=feed, daemon=True)
    writer.start()
    for _ in shas:
        header = proc.stdout.readline().split()
        if len(header) < 3:
            yield None
            continue
        size = int(header[2])
        data = proc.stdout.read(size)
        proc.stdout.read(1)
        yield None if limit is not None and size > limit else data
    writer.join()
    proc.wait()


def scan_messages(scanner: Scanner, root: Path, revs: list[str]) -> None:
    out = git(root, "log", "--format=%H%x00%B%x00", *revs, "--")
    parts = out.decode("utf-8", errors="replace").split("\0")
    for sha, body in zip(parts[0::2], parts[1::2]):
        sha = sha.strip()
        if sha:
            scanner.text(body, f"commit {sha[:10]} message line", None)


def scan_history(scanner: Scanner, root: Path) -> None:
    # Every blob of every commit, once, with every path it appeared under.
    paths: dict[str, set[str]] = defaultdict(set)
    for line in git(root, "rev-list", "--all", "--objects").decode("utf-8", errors="replace").splitlines():
        sha, _, path = line.partition(" ")
        if path:
            paths[sha].add(path)
    kinds = git(root, "cat-file", "--batch-check", input="\n".join(paths).encode() + b"\n").decode().splitlines()
    blobs = []
    for line in kinds:
        bits = line.split()
        if len(bits) >= 2 and bits[1] == "blob":
            blobs.append(bits[0])
    seen: set[tuple[str, int, str]] = set()
    for sha, data in zip(blobs, cat_blobs(root, blobs, HISTORY_MAX_BYTES)):
        if data is None:
            continue
        for path in sorted(paths[sha]):
            local = Scanner(scanner.terms, scanner.allow)
            local.blob(data, path)
            for finding in local.findings:
                key = (path, finding.layer, finding.pattern)
                if key not in seen:
                    seen.add(key)
                    scanner.findings.append(Finding(f"{path} (history)", finding.layer, finding.pattern))
    # Every path any commit added, under every name: a blob is listed above
    # under one path only, so an old name of a renamed file is read here.
    names = git(root, "log", "--all", "--no-renames", "--format=", "--name-only", "-z").decode(
        "utf-8", errors="replace"
    )
    for path in sorted({p.strip() for p in names.split("\0") if p.strip()}):
        local = Scanner(scanner.terms, scanner.allow)
        local.line(path, "", path)
        for finding in local.findings:
            key = (path, finding.layer, finding.pattern)
            if key not in seen:
                seen.add(key)
                scanner.findings.append(Finding(f"{path} (history path)", finding.layer, finding.pattern))
    # Commit messages and identities, once per pattern.
    out = git(root, "log", "--all", "--format=%H%x00%an <%ae>%x00%cn <%ce>%x00%B%x00").decode(
        "utf-8", errors="replace"
    )
    parts = out.split("\0")
    counts: dict[tuple[str, int, str], int] = defaultdict(int)
    for i in range(0, len(parts) - 4, 4):
        author, committer, body = parts[i + 1], parts[i + 2], parts[i + 3]
        for kind, text in (("commit identity", author + "\n" + committer), ("commit message", body)):
            local = Scanner(scanner.terms, [])
            local.text(text, "", None)
            for finding in {(f.layer, f.pattern) for f in local.findings}:
                counts[(kind, *finding)] += 1
    for line in git(root, "for-each-ref", "--format=%(refname)").decode().splitlines():
        local = Scanner(scanner.terms, [])
        local.line(line, "", None)
        for f in {(f.layer, f.pattern) for f in local.findings}:
            counts[("ref name", *f)] += 1
    for (kind, layer, pattern), count in sorted(counts.items()):
        scanner.findings.append(Finding(f"{kind} ({count} commits)" if kind != "ref name" else f"{kind} ({count})", layer, pattern))


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--staged", action="store_true", help="scan the index instead of the working tree")
    parser.add_argument("--messages", metavar="RANGE", help="also scan the commit messages of RANGE")
    parser.add_argument("--pr-title", metavar="TEXT", help="also scan a pull request's title")
    parser.add_argument("--pr-body", metavar="TEXT", help="also scan a pull request's body")
    parser.add_argument("--history", action="store_true", help="scan all of history instead of the tree")
    parser.add_argument("--root", type=Path, default=ROOT,
                        help="the checkout to scan, read only as data (default: this script's own)")
    parser.add_argument("--layer1-only", metavar="REASON",
                        help="skip the personal list, and say why in the one note line")
    parser.add_argument("--allowlist", type=Path, metavar="FILE",
                        help=f"the reviewed allowlist to apply, in place of ROOT's own {ALLOWLIST}")
    args = parser.parse_args(argv)
    if args.history and args.staged:
        parser.error("--history and --staged do not combine")

    if args.layer1_only is not None:
        # The personal list is not read at all, even if one is around.
        terms, note = Terms([]), f"layer 1 only: {args.layer1_only}"
    else:
        terms, note = Terms.load(dict(os.environ))
    if note:
        print(f"check-publication: {note}", file=sys.stderr)
    # --allowlist: the pull-request scan applies main's list over the PR's tree.
    allow = load_allowlist(args.allowlist or args.root / ALLOWLIST)
    scanner = Scanner(terms, allow)

    if args.history:
        scan_history(scanner, args.root)
    else:
        scan_tree(scanner, args.root, args.staged)
    if args.messages:
        scan_messages(scanner, args.root, [args.messages])
    if args.pr_title is not None:
        scanner.text(args.pr_title, "pull request title line", None)
    if args.pr_body is not None:
        scanner.text(args.pr_body, "pull request body line", None)

    problems = [str(f) for f in scanner.findings]
    if not args.history:
        present = set(tracked(args.root))
        for entry in allow:
            # An entry for a file the public copy leaves out is not stale.
            if not entry.used and entry.path in present:
                # A note, never a failure: a new exception lands in a pull
                # request of its own, before the code it covers (the
                # pull-request scan applies main's list), so for a while it
                # allows nothing on main.
                print(f"check-publication: note: {ALLOWLIST}:{entry.number}: allows nothing;"
                      " remove it if the code it covered is gone", file=sys.stderr)
    for problem in problems:
        print(problem)
    if problems:
        if args.history:
            advice = "History is only reported: a history rewrite removes them, this check changes nothing."
        else:
            advice = f"Reword them (AGENTS.md, publication rule); a reviewed layer-1 exception goes in {ALLOWLIST}."
        print(f"check-publication: {len(problems)} finding(s). {advice}", file=sys.stderr)
        return 1
    layers = "layers 1 and 2" if terms.entries else "layer 1"
    print(f"check-publication: ok ({layers})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
