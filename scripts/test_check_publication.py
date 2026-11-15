#!/usr/bin/env python3
"""Tests for scripts/check-publication.py: python3 scripts/test_check_publication.py

This file is scanned by the check too, so every sample that should match is
built from pieces at run time and never appears whole in the source.
"""
from __future__ import annotations

import importlib.util
import os
import re
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

HERE = Path(__file__).resolve().parent
SCRIPT = HERE / "check-publication.py"

spec = importlib.util.spec_from_file_location("check_publication", SCRIPT)
cp = importlib.util.module_from_spec(spec)
sys.modules["check_publication"] = cp
spec.loader.exec_module(cp)

AT = "@"
DOT = "."
# A personal term for the tests; the real list is never read (HOME is moved).
TERM = "Zed" + "quist"


def hits(text: str) -> list[str]:
    return [name for name, regex in cp.PATTERNS if regex.search(text)]


class PatternTests(unittest.TestCase):
    def test_matches(self) -> None:
        cases = {
            "private-network-name": [
                "ssh build" + DOT + "tail1234" + DOT + "ts" + DOT + "net",
                "the " + "tail" + "net",
                "http://printer" + DOT + "local/",
                "nas" + DOT + "home" + DOT + "arpa",
                "db" + DOT + "internal:5432",
            ],
            "home-directory-path": [
                "/" + "Users/alex/code",
                "cd /" + "Users/alex",
                "HOME=/" + "home/alex\n",
                "/" + "home/alex/.ssh",
                "see " + "~" + "alex/notes",
            ],
            "private-ipv4": ["10" + ".1.2.3", "192" + ".168.0.10", "172" + ".20.0.1", "100" + ".100.1.1"],
            "ipv6-ula": ["fd" + "12:3456:789a::1"],
            "secret-store-reference": [
                "op" + ":/" + "/Private/Item/field",
                "1Pass" + "word item",
                "tool " + "--" + "item \"Thing\"",
                "vault" + " > Some Item",
                "private" + " > Signing Key",
            ],
            "email-address": ["alex" + AT + "gmail" + DOT + "com", "a.b+c" + AT + "corp" + DOT + "io"],
            "sammy-host": ["https://staging" + DOT + "heysammy" + DOT + "app/v1"],
            "device-identifier": ["0000" + "8130-001A2B3C4D5E6F70"],
            "ask-code": ["per " + "K" + "339"],
        }
        for name, samples in cases.items():
            for sample in samples:
                with self.subTest(name=name, sample=sample):
                    self.assertIn(name, hits(sample))

    def test_leaves_alone(self) -> None:
        for sample in [
            "Configs/Debug" + DOT + "local" + DOT + "xcconfig",
            ".cache" + DOT + "local",
            "let ch = (e & f) ^ (~e & g)",
            "b" + DOT + "internal}",
            "~/" + ".config/influx/devices.conf",
            "/" + "Users/runner/work",
            "/" + "Users/Shared/x",
            "/" + "Users/runner",
            "10.15.7",
            "v1." + "10" + ".0.1.2",
            "8.8.8.8",
            "alex" + AT + "example" + DOT + "com",
            "me" + AT + "example" + DOT + "social",
            "12+bot" + AT + "users.noreply.github" + DOT + "com",
            "noreply" + AT + "github" + DOT + "com",
            "git" + AT + "github" + DOT + "com:org/repo",
            "icon" + AT + "2x" + DOT + "png",
            "System Settings > Privacy & Security > Files & Folders > bash > Network Volumes",
            "if count > limit { return }",
            "4K video at 60fps",
            "https://api" + DOT + "heysammy" + DOT + "app",
            "A1B2C3D4-0000-1111-2222-333344445555",
        ]:
            with self.subTest(sample=sample):
                self.assertEqual(hits(sample), [])

    def test_terms_whole_word_and_edges(self) -> None:
        terms = cp.Terms([("t1", "alpha"), ("t2", "beta#")])
        self.assertEqual(terms.search("ALPHA-host"), ["t1"])
        self.assertEqual(terms.search("alphabet"), [])
        self.assertEqual(terms.search("see beta#12"), ["t2"])


class RepoTests(unittest.TestCase):
    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name) / "repo"
        self.home = Path(self.tmp.name) / "home"
        self.root.mkdir()
        self.home.mkdir()
        self.git("init", "-q", "-b", "main")
        (self.root / "README.md").write_text("hello\n")
        self.commit("first")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t" + AT + "example.com",
             "-c", "commit.gpgsign=false", *args],
            cwd=self.root, check=True, capture_output=True, text=True,
        ).stdout

    def commit(self, message: str) -> None:
        self.git("add", "-A")
        self.git("commit", "-q", "-m", message)

    def child_env(self, terms: str | None = TERM) -> dict[str, str]:
        """The check's environment: a moved HOME, and only the test's terms."""
        env = {k: v for k, v in os.environ.items() if not k.startswith("INFLUX_PUBLICATION")}
        env["HOME"] = str(self.home)
        if terms is not None:
            env["INFLUX_PUBLICATION_TERMS"] = terms
        return env

    def run_check(self, *args: str, terms: str | None = TERM) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(SCRIPT), "--root", str(self.root), *args],
            capture_output=True, text=True, env=self.child_env(terms),
        )

    def test_clean_tree_passes(self) -> None:
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("layers 1 and 2", result.stdout)

    def test_no_list_says_so_once_and_runs_layer_one(self) -> None:
        result = self.run_check(terms=None)
        self.assertEqual(result.returncode, 0)
        self.assertEqual(result.stderr.count("no personal list"), 1)
        self.assertIn("(layer 1)", result.stdout)

    def test_personal_term_fails_without_printing_it(self) -> None:
        (self.root / "notes.md").write_text("one\nask " + TERM.lower() + " later\n")
        self.git("add", "notes.md")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("notes.md:2: layer 2 personal-term:env1", result.stdout)
        self.assertNotIn(TERM.lower(), (result.stdout + result.stderr).lower())

    def test_term_file_line_number(self) -> None:
        (self.home / ".config" / "influx").mkdir(parents=True)
        (self.home / ".config" / "influx" / "publication-terms").write_text("# comment\n\n" + TERM + "\n")
        (self.root / "a.txt").write_text(TERM + "\n")
        self.git("add", "a.txt")
        result = self.run_check(terms=None)
        self.assertEqual(result.returncode, 1)
        self.assertIn("a.txt:1: layer 2 personal-term:3", result.stdout)

    def test_layer_one_names_pattern_not_text(self) -> None:
        address = "192" + ".168.4.4"
        (self.root / "cfg.txt").write_text("host " + address + "\n")
        self.git("add", "cfg.txt")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertIn("cfg.txt:1: layer 1 private-ipv4", result.stdout)
        self.assertNotIn(address, result.stdout + result.stderr)

    def test_allowlist_is_exact_and_unused_entries_are_noted(self) -> None:
        address = "10" + ".0.0.1"
        (self.root / "t.swift").write_text('let a = "' + address + '"\nlet b = "10' + '.0.0.2"\n')
        (self.root / "scripts").mkdir()
        allow = self.root / cp.ALLOWLIST
        # The defanged form, as the committed list writes it.
        allow.write_text("t.swift | private-ipv4 | " + address.replace(".", "[.]") + "\n")
        self.git("add", "-A")
        result = self.run_check()
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("t.swift:1:", result.stdout)
        self.assertIn("t.swift:2: layer 1 private-ipv4", result.stdout)

        (self.root / "t.swift").write_text("let a = 1\n")
        fanged = address.replace(".", "[.]")
        allow.write_text(
            "t.swift | private-ipv4 | " + fanged + "\n"
            # A file this copy does not track is not stale.
            "gone.swift | private-ipv4 | " + fanged + "\n"
        )
        result = self.run_check()
        # Unused: noted, not failed, so an exception can land before its code.
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("note: " + cp.ALLOWLIST + ":1: allows nothing", result.stderr)
        self.assertNotIn(":2: allows nothing", result.stderr)

    def test_allowlist_file_is_scanned_like_any_other(self) -> None:
        (self.root / "scripts").mkdir()
        allow = self.root / cp.ALLOWLIST
        # Written plainly, an entry's text is itself a finding.
        allow.write_text("README.md | private-ipv4 | 10" + ".0.0.9\n")
        self.git("add", "-A")
        result = self.run_check()
        self.assertIn(cp.ALLOWLIST + ":1: layer 1 private-ipv4", result.stdout)
        allow.write_text("README.md | ipv6-ula | fd00[:][:]1\n")
        result = self.run_check()
        self.assertNotIn("layer 1", result.stdout)

    def test_every_pattern_can_be_allowed_without_tripping_the_list(self) -> None:
        samples = {
            "ask-code": "K" + "339",
            "device-identifier": "0000" + "8130-001A2B3C4D5E6F70",
            "home-directory-path": "/" + "Users/alex",
            "secret-store-reference": "op" + ":/" + "/x",
        }
        (self.root / "scripts").mkdir()
        (self.root / "x.txt").write_text("\n".join(samples.values()) + "\n")
        patterns = dict(cp.PATTERNS)
        lines = []
        for name, sample in samples.items():
            text = patterns[name].search(sample).group(0)
            # Bracket the second character: enough to break each pattern.
            lines.append(f"x.txt | {name} | {text[0]}[{text[1]}]{text[2:]}")
        (self.root / cp.ALLOWLIST).write_text("\n".join(lines) + "\n")
        self.git("add", "-A")
        result = self.run_check()
        self.assertEqual(result.returncode, 0, result.stdout)

    def test_external_allowlist_replaces_the_scanned_trees_own(self) -> None:
        address = "192" + ".168.7.7"
        (self.root / "scripts").mkdir()
        (self.root / "f.txt").write_text(address + "\n")
        # The scanned tree's own list would allow it; an external list wins.
        (self.root / cp.ALLOWLIST).write_text("f.txt | private-ipv4 | " + address.replace(".", "[.]") + "\n")
        self.git("add", "-A")
        self.assertEqual(self.run_check().returncode, 0)
        main_list = Path(self.tmp.name) / "main-allowlist.txt"
        main_list.write_text("README.md | private-ipv4 | 10[.]1[.]1[.]1\n")
        result = self.run_check("--allowlist", str(main_list))
        self.assertEqual(result.returncode, 1)
        self.assertIn("f.txt:1: layer 1 private-ipv4", result.stdout)
        # An entry the tree no longer needs is a note, not a failure.
        (self.root / "f.txt").write_text("fine\n")
        result = self.run_check("--allowlist", str(main_list))
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertIn("note: " + cp.ALLOWLIST + ":1: allows nothing", result.stderr)

    def test_layer1_only_ignores_any_list_and_says_why_once(self) -> None:
        (self.root / "n.md").write_text(TERM + "\n")
        self.git("add", "-A")
        result = self.run_check("--layer1-only=a fork's pull request gets no secrets")
        self.assertEqual(result.returncode, 0, result.stdout)
        self.assertEqual(result.stderr.strip().splitlines(), [
            "check-publication: layer 1 only: a fork's pull request gets no secrets"])

    def test_allowlist_rejects_globs(self) -> None:
        (self.root / "scripts").mkdir()
        (self.root / cp.ALLOWLIST).write_text("Tests/* | private-ipv4 | x\n")
        result = self.run_check()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("a path, not a glob", result.stderr)

    def test_messages_title_and_body(self) -> None:
        base = self.git("rev-parse", "HEAD").strip()
        (self.root / "b.txt").write_text("x\n")
        self.commit("Fix it\n\nThanks " + TERM)
        # A body that starts with a list item: CI passes --pr-body=TEXT.
        result = self.run_check("--messages", base + "..HEAD", "--pr-title=fine",
                                "--pr-body=- line\nmail " + "a" + AT + "gmail" + DOT + "com")
        self.assertEqual(result.returncode, 1)
        self.assertRegex(result.stdout, r"commit [0-9a-f]{10} message line:3: layer 2 personal-term:env1")
        self.assertIn("pull request body line:2: layer 1 email-address", result.stdout)
        self.assertNotIn("title", result.stdout)

    def test_staged_reads_the_index(self) -> None:
        (self.root / "README.md").write_text("hello " + TERM + "\n")
        self.assertEqual(self.run_check("--staged").returncode, 0)
        self.git("add", "README.md")
        result = self.run_check("--staged")
        self.assertEqual(result.returncode, 1)
        self.assertIn("README.md:1: layer 2", result.stdout)

    def test_binary_and_path(self) -> None:
        (self.root / "img.bin").write_bytes(b"\x89PNG\0\0" + TERM.encode() + b"\0")
        (self.root / (TERM + "-notes.md")).write_text("ok\n")
        self.git("add", "-A")
        result = self.run_check()
        self.assertIn("img.bin (binary): layer 2 personal-term:env1", result.stdout)
        self.assertIn("(path): layer 2 personal-term:env1", result.stdout)

    def test_hook_installer(self) -> None:
        scripts = self.root / "scripts"
        scripts.mkdir()
        for name in ("check-publication.py", "install-publication-hook.sh"):
            (scripts / name).write_bytes((HERE / name).read_bytes())
            (scripts / name).chmod(0o755)
        self.commit("scripts")
        install = [str(scripts / "install-publication-hook.sh")]
        config_before = self.git("config", "--list", "--local")
        self.assertEqual(subprocess.run(install, capture_output=True).returncode, 0)
        self.assertEqual(subprocess.run(install, capture_output=True).returncode, 0)  # again: same hook
        self.assertEqual(self.git("config", "--list", "--local"), config_before)

        (self.root / "c.txt").write_text(TERM + "\n")
        self.git("add", "c.txt")
        blocked = subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t" + AT + "example.com", "-c", "commit.gpgsign=false",
             "commit", "-q", "-m", "c"],
            cwd=self.root, env=self.child_env(), capture_output=True, text=True,
        )
        self.assertNotEqual(blocked.returncode, 0)
        self.assertIn("c.txt:1: layer 2", blocked.stdout + blocked.stderr)  # git sends hook output to stderr

        hook = Path(self.git("rev-parse", "--git-path", "hooks").strip())
        if not hook.is_absolute():
            hook = self.root / hook
        (hook / "pre-commit").write_text("#!/bin/sh\nexit 0\n")
        refused = subprocess.run(install, capture_output=True, text=True)
        self.assertEqual(refused.returncode, 1)
        self.assertIn("already exists", refused.stderr)

    def test_history_finds_removed_content_and_rewrites_nothing(self) -> None:
        (self.root / "old.md").write_text(TERM + "\n")
        self.commit("add")
        (self.root / "old.md").unlink()
        self.commit("remove")
        head = self.git("rev-parse", "HEAD").strip()
        self.assertEqual(self.run_check().returncode, 0)
        result = self.run_check("--history")
        self.assertEqual(result.returncode, 1)
        self.assertIn("old.md (history): layer 2 personal-term:env1", result.stdout)
        self.assertEqual(self.git("rev-parse", "HEAD").strip(), head)

        # A term only in a file's old name, before a rename.
        (self.root / (TERM + ".md")).write_text("plain\n")
        self.commit("named")
        self.git("mv", TERM + ".md", "renamed.md")
        self.commit("renamed")
        result = self.run_check("--history")
        self.assertIn(TERM + ".md (history path): layer 2 personal-term:env1", result.stdout)


WORKFLOW = HERE.parent / ".github" / "workflows" / "publication.yml"
SCAN_STEP = "      - name: Nothing private in what would be published"


def scan_step_script() -> str:
    """The scan step's run: block, as the runner's bash gets it."""
    lines = WORKFLOW.read_text().splitlines()
    start = lines.index(SCAN_STEP)
    run = next(i for i in range(start, len(lines)) if lines[i].strip() == "run: |")
    body = []
    for line in lines[run + 1:]:
        if line.strip() and not line.startswith(" " * 10):
            break
        body.append(line[10:])
    return "\n".join(body) + "\n"


@unittest.skipUnless(WORKFLOW.is_file(), "no publication workflow in this copy")
class WorkflowShapeTests(unittest.TestCase):
    """publication.yml keeps the personal list away from pull-request code."""

    def setUp(self) -> None:
        self.text = WORKFLOW.read_text()

    def test_runs_the_default_branchs_file_on_pull_requests(self) -> None:
        self.assertIn("\n  pull_request_target:\n", self.text)
        self.assertNotRegex(self.text, r"\n  pull_request:")

    def test_least_permissions(self) -> None:
        self.assertIn("\npermissions: {}\n", self.text)
        self.assertIn("    permissions:\n      contents: read\n    steps:", self.text)
        self.assertNotIn("write", self.text.split("jobs:", 1)[1].replace("written", ""))

    def test_checkouts_keep_no_token_and_the_checker_comes_from_main(self) -> None:
        self.assertEqual(self.text.count("uses: actions/checkout@"), 2)
        self.assertEqual(self.text.count("persist-credentials: false"), 2)
        base = self.text.split("- name: The checker, from the default branch", 1)[1].split("- name:", 1)[0]
        self.assertIn("github.event.repository.default_branch", base)
        self.assertIn("path: base", base)
        pr = self.text.split("- name: The pull request, as data only", 1)[1].split("- name:", 1)[0]
        self.assertIn("path: pr", pr)

    def test_the_secret_reaches_only_the_scan_step_and_never_a_fork(self) -> None:
        uses = [l for l in self.text.splitlines() if re.search(r"\bsecrets\.\w", l)]
        self.assertEqual(len(uses), 1, uses)
        line = uses[0]
        self.assertIn("github.event.pull_request.head.repo.full_name == github.repository", line)
        self.assertLess(self.text.index(SCAN_STEP), self.text.index(line))

    def test_nothing_from_the_pull_request_is_run(self) -> None:
        script = scan_step_script()
        self.assertIn("check=(python3 -I base/scripts/check-publication.py)", script)
        for line in script.splitlines():
            with self.subTest(line=line):
                # pr appears only as --root's data, never as a path to run.
                self.assertNotRegex(line, r"(?<![\w-])pr/")
                self.assertNotRegex(line.strip(), r"^(?:\.|source|bash|sh|node|python3?)\s+(?!-I base/)")


@unittest.skipUnless(WORKFLOW.is_file(), "no publication workflow in this copy")
class WorkflowScanTests(unittest.TestCase):
    """The scan step's own script, over a stand-in main checkout and pull request."""

    def setUp(self) -> None:
        self.tmp = tempfile.TemporaryDirectory()
        self.work = Path(self.tmp.name)
        base = self.work / "base" / "scripts"
        base.mkdir(parents=True)
        for name in ("check-publication.py", "publication-allowlist.txt"):
            (base / name).write_bytes((HERE / name).read_bytes())
        self.pr = self.work / "pr"
        self.pr.mkdir()
        self.git("init", "-q", "-b", "main")
        (self.pr / "README.md").write_text("hello\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "base")
        self.base_sha = self.git("rev-parse", "HEAD").strip()
        # The pull request: a planted term and address, a checker that always
        # passes, and an allowlist entry for its own finding.
        self.address = "10" + ".9.9.9"
        (self.pr / "leak.md").write_text("ask " + TERM + "\n" + self.address + "\n")
        (self.pr / "scripts").mkdir()
        (self.pr / "scripts" / "check-publication.py").write_text("import sys\nsys.exit(0)\n")
        (self.pr / "scripts" / "publication-allowlist.txt").write_text(
            "leak.md | private-ipv4 | " + self.address.replace(".", "[.]") + "\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "Change things")

    def tearDown(self) -> None:
        self.tmp.cleanup()

    def git(self, *args: str) -> str:
        return subprocess.run(
            ["git", "-c", "user.name=t", "-c", "user.email=t" + AT + "example.com",
             "-c", "commit.gpgsign=false", *args],
            cwd=self.pr, check=True, capture_output=True, text=True,
        ).stdout

    def run_step(self, **env: str) -> subprocess.CompletedProcess[str]:
        full = {k: v for k, v in os.environ.items() if not k.startswith("INFLUX_PUBLICATION")}
        full.update(HOME=str(self.work), EVENT="pull_request_target", SAME_REPO="true",
                    BASE_SHA=self.base_sha, PR_TITLE="A title", PR_BODY="- a body",
                    BEFORE="", AFTER="", INFLUX_PUBLICATION_TERMS=TERM)
        full.update(env)
        return subprocess.run(["bash", "-c", scan_step_script()], cwd=self.work,
                              env=full, capture_output=True, text=True)

    def test_mains_checker_and_allowlist_judge_the_pull_request(self) -> None:
        result = self.run_step()
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("leak.md:1: layer 2 personal-term:env1", result.stdout)
        self.assertIn("leak.md:2: layer 1 private-ipv4", result.stdout)
        self.assertNotIn(TERM, result.stdout + result.stderr)
        self.assertNotIn(self.address, result.stdout + result.stderr)

    def test_messages_title_and_body_are_scanned(self) -> None:
        (self.pr / "leak.md").write_text("clean\n")
        self.git("add", "-A")
        self.git("commit", "-q", "-m", "Thanks " + TERM)
        result = self.run_step(PR_BODY="- mail " + "a" + AT + "gmail" + DOT + "com")
        self.assertEqual(result.returncode, 1)
        self.assertRegex(result.stdout, r"commit [0-9a-f]{10} message line:1: layer 2 personal-term:env1")
        self.assertIn("pull request body line:1: layer 1 email-address", result.stdout)

    def test_a_fork_runs_layer_one_and_says_so_once(self) -> None:
        # Even if a list were in the environment, a fork's scan ignores it.
        result = self.run_step(SAME_REPO="false")
        self.assertEqual(result.returncode, 1)
        self.assertNotIn("layer 2", result.stdout)
        self.assertIn("leak.md:2: layer 1 private-ipv4", result.stdout)
        notes = [l for l in result.stderr.splitlines() if "layer 1 only" in l or "personal list" in l]
        self.assertEqual(notes, ["check-publication: layer 1 only: a fork's pull request gets no secrets"])


if __name__ == "__main__":
    unittest.main(verbosity=1)
