#!/usr/bin/env python3
"""Unit tests for share/skills/aisync-ship/scripts/fanout.py.

Run: python3 -m unittest tests.test_fanout
Or:  ./tests/test_fanout.py

These cover the pure-functional helpers (is_safe_rel, plan_managed_paths,
apply_marker_deletions, container_is_unsafe, read/write marker) since they
are the ones whose edge cases drove most of Phase 2's stop-hook fixes.
fanout_one's full integration (cp + symlink handling) is exercised by
the test_install_remote.sh integration suite.
"""

from __future__ import annotations

import importlib.util
import os
import shutil
import sys
import tempfile
import unittest
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SCRIPTS = REPO / "share" / "skills" / "aisync-ship" / "scripts"


def _load_module(name: str, filename: str):
    spec = importlib.util.spec_from_file_location(name, SCRIPTS / filename)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"could not load {filename}")
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


fanout = _load_module("fanout", "fanout.py")


class IsSafeRelTests(unittest.TestCase):
    """Path-traversal / absolute-path validation for marker entries."""

    def test_normal_relative_paths(self):
        self.assertTrue(fanout.is_safe_rel("AGENTS.md"))
        self.assertTrue(fanout.is_safe_rel("rules/coding-style.md"))
        self.assertTrue(fanout.is_safe_rel("skills/foo/SKILL.md"))
        self.assertTrue(fanout.is_safe_rel("a/b/c/d.md"))

    def test_empty_or_whitespace(self):
        self.assertFalse(fanout.is_safe_rel(""))
        self.assertFalse(fanout.is_safe_rel("  "))
        self.assertFalse(fanout.is_safe_rel("\t"))

    def test_absolute_path_rejected(self):
        self.assertFalse(fanout.is_safe_rel("/etc/passwd"))
        self.assertFalse(fanout.is_safe_rel("/Users/evan/.ssh/id_rsa"))

    def test_dot_dot_traversal_rejected(self):
        self.assertFalse(fanout.is_safe_rel(".."))
        self.assertFalse(fanout.is_safe_rel("../"))
        self.assertFalse(fanout.is_safe_rel("../../escape"))
        self.assertFalse(fanout.is_safe_rel("rules/../escape"))
        self.assertFalse(fanout.is_safe_rel("a/b/../c"))

    def test_single_dot_segment_rejected(self):
        self.assertFalse(fanout.is_safe_rel("./foo"))
        self.assertFalse(fanout.is_safe_rel("a/./b"))
        self.assertFalse(fanout.is_safe_rel("."))

    def test_backslash_rejected(self):
        # Backslash could be interpreted as path separator on some
        # filesystems and confuse rm — reject preemptively.
        self.assertFalse(fanout.is_safe_rel("foo\\bar"))
        self.assertFalse(fanout.is_safe_rel("a\\..\\escape"))

    def test_null_byte_rejected(self):
        self.assertFalse(fanout.is_safe_rel("foo\x00bar"))


class MarkerRoundtripTests(unittest.TestCase):
    """write_marker → read_marker should round-trip the path list."""

    def test_roundtrip_preserves_paths(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            paths = ["AGENTS.md", "rules/a.md", "skills/foo/SKILL.md"]
            fanout.write_marker(d, "codex", paths, log=[])
            read = fanout.read_marker(d)
            self.assertEqual(read, paths)

    def test_read_skips_comments_and_blanks(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            (d / fanout.MARKER_FILENAME).write_text(
                "# header\n# version: 1\n\nAGENTS.md\n\nrules/a.md\n", encoding="utf-8"
            )
            self.assertEqual(fanout.read_marker(d), ["AGENTS.md", "rules/a.md"])

    def test_missing_marker_returns_empty(self):
        with tempfile.TemporaryDirectory() as tmp:
            self.assertEqual(fanout.read_marker(Path(tmp)), [])

    def test_empty_path_list_roundtrips(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp)
            fanout.write_marker(d, "codex", [], log=[])
            self.assertEqual(fanout.read_marker(d), [])


class ApplyMarkerDeletionsTests(unittest.TestCase):
    """The core delete-propagation engine, including its safety guards."""

    def _setup_dest(self, tmp: Path, files: list[str]) -> Path:
        dest = tmp / "dest"
        dest.mkdir()
        for f in files:
            target = dest / f
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text("content")
        return dest

    def test_no_diff_no_deletions(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = self._setup_dest(Path(tmp), ["a.md", "b.md"])
            log: list = []
            n = fanout.apply_marker_deletions(dest, ["a.md", "b.md"], ["a.md", "b.md"], log)
            self.assertEqual(n, 0)
            self.assertTrue((dest / "a.md").exists())
            self.assertTrue((dest / "b.md").exists())

    def test_drops_files_in_old_not_in_new(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = self._setup_dest(Path(tmp), ["a.md", "b.md", "c.md"])
            log: list = []
            n = fanout.apply_marker_deletions(dest, ["a.md", "b.md", "c.md"], ["a.md"], log)
            self.assertEqual(n, 2)
            self.assertTrue((dest / "a.md").exists())
            self.assertFalse((dest / "b.md").exists())
            self.assertFalse((dest / "c.md").exists())

    def test_files_not_in_old_marker_preserved(self):
        # User-authored file (never recorded in marker) must NOT be deleted.
        with tempfile.TemporaryDirectory() as tmp:
            dest = self._setup_dest(Path(tmp), ["a.md", "user-manual.md"])
            log: list = []
            fanout.apply_marker_deletions(dest, ["a.md"], [], log)
            self.assertFalse((dest / "a.md").exists())
            self.assertTrue((dest / "user-manual.md").exists(), "user-authored file deleted (BUG)")

    def test_path_escape_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_p = Path(tmp)
            dest = tmp_p / "dest"
            dest.mkdir()
            victim = tmp_p / "innocent" / "data.txt"
            victim.parent.mkdir()
            victim.write_text("VICTIM")
            log: list = []
            old = ["AGENTS.md", "../../innocent/data.txt", "/etc/passwd", "..", "./bad"]
            n = fanout.apply_marker_deletions(dest, old, [], log)
            # AGENTS.md not in dest, so 0 actual deletes; the unsafe entries
            # all rejected (no NEAR-misses where rejection slipped through).
            self.assertEqual(n, 0)
            self.assertTrue(victim.exists(), "VICTIM data deleted via path traversal (BUG)")
            # 4 REJECTED log entries (one per unsafe path)
            rejected = [line for line in log if "REJECTED" in line]
            self.assertEqual(len(rejected), 4)

    def test_directory_entry_removed_recursively(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = self._setup_dest(Path(tmp), ["skills/foo/SKILL.md", "skills/foo/extra.md"])
            log: list = []
            # Marker recorded both files; new run drops both → expect dir gone via empty-prune
            n = fanout.apply_marker_deletions(
                dest, ["skills/foo/SKILL.md", "skills/foo/extra.md"], [], log
            )
            self.assertEqual(n, 2)
            self.assertFalse((dest / "skills" / "foo").exists(),
                             "empty skills/foo not pruned")
            self.assertFalse((dest / "skills").exists(), "empty skills/ not pruned")

    def test_empty_dir_prune_does_not_cross_dest_boundary(self):
        with tempfile.TemporaryDirectory() as tmp:
            dest = self._setup_dest(Path(tmp), ["a.md"])
            log: list = []
            fanout.apply_marker_deletions(dest, ["a.md"], [], log)
            # dest itself must NOT be removed even though it's empty after
            self.assertTrue(dest.exists(), "dest_dir was pruned (BUG — must stop at boundary)")


class PlanManagedPathsTests(unittest.TestCase):
    """plan_managed_paths must mirror copy_* logic exactly so the marker
    written reflects what was actually installed (not what's in dest)."""

    def _make_source(self, tmp: Path, layout: dict) -> Path:
        """layout: {'CLAUDE.md': str, 'rules': {fname: content}, 'skills': {name: {fname: content}}, 'agents': {fname: content}}"""
        src = tmp / "src"
        src.mkdir()
        if "CLAUDE.md" in layout:
            (src / "CLAUDE.md").write_text(layout["CLAUDE.md"])
        for sub in ("rules", "agents"):
            if sub in layout:
                d = src / sub
                d.mkdir()
                for f, c in layout[sub].items():
                    (d / f).write_text(c)
        if "skills" in layout:
            d = src / "skills"
            d.mkdir()
            for name, files in layout["skills"].items():
                sd = d / name
                sd.mkdir()
                for f, c in files.items():
                    (sd / f).write_text(c)
        return src

    def test_codex_full_layout(self):
        codex = fanout.PLATFORMS["codex"]
        with tempfile.TemporaryDirectory() as tmp:
            src = self._make_source(Path(tmp), {
                "CLAUDE.md": "x",
                "rules": {"a.md": "x", "b.md": "x"},
                "skills": {"foo": {"SKILL.md": "x", "extra.md": "x"}},
            })
            paths = fanout.plan_managed_paths(src, codex)
            self.assertIn("AGENTS.md", paths)
            self.assertIn("rules/a.md", paths)
            self.assertIn("rules/b.md", paths)
            self.assertIn("skills/foo/SKILL.md", paths)
            self.assertIn("skills/foo/extra.md", paths)

    def test_gemini_skips_rules(self):
        # gemini has skills_dir but no rules_dir → rules omitted from plan
        gemini = fanout.PLATFORMS["gemini"]
        with tempfile.TemporaryDirectory() as tmp:
            src = self._make_source(Path(tmp), {
                "CLAUDE.md": "x",
                "rules": {"a.md": "x"},
                "skills": {"foo": {"SKILL.md": "x"}},
            })
            paths = fanout.plan_managed_paths(src, gemini)
            self.assertIn("GEMINI.md", paths)
            self.assertIn("skills/foo/SKILL.md", paths)
            self.assertFalse(any(p.startswith("rules/") for p in paths),
                             "gemini should not claim rules/ (no rules_dir)")

    def test_empty_source_yields_empty_plan(self):
        codex = fanout.PLATFORMS["codex"]
        with tempfile.TemporaryDirectory() as tmp:
            src = self._make_source(Path(tmp), {})
            self.assertEqual(fanout.plan_managed_paths(src, codex), [])

    def test_symlink_file_skipped(self):
        codex = fanout.PLATFORMS["codex"]
        with tempfile.TemporaryDirectory() as tmp:
            tmp_p = Path(tmp)
            src = self._make_source(tmp_p, {"CLAUDE.md": "x", "rules": {}})
            external = tmp_p / "external.md"
            external.write_text("EXTERNAL")
            (src / "rules" / "leaky.md").symlink_to(external)
            paths = fanout.plan_managed_paths(src, codex)
            self.assertNotIn("rules/leaky.md", paths,
                             "symlink in rules should be skipped from plan (and from copy)")
            self.assertIn("AGENTS.md", paths)

    def test_container_symlink_skipped(self):
        codex = fanout.PLATFORMS["codex"]
        with tempfile.TemporaryDirectory() as tmp:
            tmp_p = Path(tmp)
            src = self._make_source(tmp_p, {"CLAUDE.md": "x"})
            external_rules = tmp_p / "external_rules"
            external_rules.mkdir()
            (external_rules / "leak.md").write_text("LEAK")
            (src / "rules").symlink_to(external_rules)
            paths = fanout.plan_managed_paths(src, codex)
            self.assertFalse(any(p.startswith("rules/") for p in paths),
                             "symlinked rules/ container must contribute no plan paths")


class ContainerIsUnsafeTests(unittest.TestCase):
    def test_real_dir_is_safe(self):
        with tempfile.TemporaryDirectory() as tmp:
            d = Path(tmp) / "real_rules"
            d.mkdir()
            self.assertFalse(fanout.container_is_unsafe(d, "rules", []))

    def test_symlink_dir_is_unsafe(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_p = Path(tmp)
            target = tmp_p / "elsewhere"
            target.mkdir()
            link = tmp_p / "linked_rules"
            link.symlink_to(target)
            log: list = []
            self.assertTrue(fanout.container_is_unsafe(link, "rules", log))
            self.assertTrue(any("WARN" in line for line in log))

    def test_missing_dir_is_safe_returns_false(self):
        # We only check is_symlink — a missing dir is NOT unsafe; caller's
        # is_dir() check handles it.
        with tempfile.TemporaryDirectory() as tmp:
            self.assertFalse(fanout.container_is_unsafe(Path(tmp) / "missing", "rules", []))


class PlatformsMapTests(unittest.TestCase):
    """Sanity check that PLATFORMS dict has expected shape — catches typos."""

    REQUIRED_KEYS = {"user_dir_subpath", "user_root_md", "rules_dir",
                     "rules_ext", "skills_dir", "skills_as_dir", "agents_dir"}

    def test_all_platforms_have_required_fields(self):
        for name, p in fanout.PLATFORMS.items():
            self.assertEqual(set(p.keys()), self.REQUIRED_KEYS,
                             f"platform {name} has wrong fields: {set(p.keys())}")

    def test_known_platforms_present(self):
        for required in ("claude", "codex", "gemini", "cursor", "windsurf", "cline"):
            self.assertIn(required, fanout.PLATFORMS)


class StrictModeTests(unittest.TestCase):
    """transform-settings.py --strict: upgrade LIKELY_LOCAL warnings to strips."""

    def setUp(self):
        # Load transform-settings module the same way as fanout
        global transform
        spec = importlib.util.spec_from_file_location(
            "transform_settings", SCRIPTS / "transform-settings.py"
        )
        transform = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(transform)

    def test_default_does_not_strip_likely_local(self):
        # /Users/evan/Documents/foo is LIKELY_LOCAL but not a known-bad pattern.
        # Default mode should NOT strip the hook.
        self.assertFalse(transform.is_local_command(
            "/Users/evan/Documents/foo.sh", strict=False))

    def test_strict_strips_likely_local(self):
        self.assertTrue(transform.is_local_command(
            "/Users/evan/Documents/foo.sh", strict=True))

    def test_known_bad_stripped_in_both_modes(self):
        # sweatshop and macOS-only roots are always stripped
        for cmd in ("/Users/evan/dev/sweatshop/bin/x", "/opt/homebrew/bin/y",
                    "/Library/Foo", "/Applications/X.app/bin"):
            self.assertTrue(transform.is_local_command(cmd, strict=False), cmd)
            self.assertTrue(transform.is_local_command(cmd, strict=True), cmd)

    def test_portable_paths_never_stripped(self):
        # $HOME-based paths and our known-portable subpaths should pass through
        for cmd in ("$HOME/.claude/hooks/foo.py",
                    "/Users/evan/.claude/scripts/foo.sh",  # whitelisted prefix
                    "/usr/local/bin/uvx"):  # /usr/local is normal
            self.assertFalse(transform.is_local_command(cmd, strict=False), cmd)
            # In strict mode whitelisted .claude/ paths still pass; /usr/local
            # not in LIKELY_LOCAL_RE so passes too
            if "/Users/" not in cmd or "/.claude/" in cmd or "/.local/" in cmd:
                self.assertFalse(transform.is_local_command(cmd, strict=True), cmd)


if __name__ == "__main__":
    unittest.main()
