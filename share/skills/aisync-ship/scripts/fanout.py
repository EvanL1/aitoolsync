#!/usr/bin/env python3
"""fanout.py — fan out a Claude Code user-level config tree to the
user-level config dirs of other agent CLIs (Codex, Gemini, Cursor, Windsurf,
Cline). Mirrors what `aisync user` does for project-level `.agents/`, but
takes `~/.claude/` (or any Claude-shaped tree) as the source of truth.

Two deployment modes:
  A) Same-machine fan-out:  --out-base <home>      writes into real ~/.<tool>
  B) Stage-for-ship mode:   --out-base <stage_dir> writes into <stage_dir>/<subdir>
                            (used by ship.sh --also <list>)

Platform map mirrors src/platforms.rs (kept here in Python for Phase 1's
"do not modify Rust src/" constraint; Phase 3 will collapse them).
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from pathlib import Path
from typing import Optional

# (NOTE) Mirror of src/platforms.rs PLATFORMS user-dir fields.
# `user_dir_subpath` is the path under $HOME (no leading ~/).
PLATFORMS: dict = {
    "claude":   {"user_dir_subpath": ".claude",          "user_root_md": "CLAUDE.md",
                 "rules_dir": "rules", "rules_ext": "md",
                 "skills_dir": "skills", "skills_as_dir": True,
                 "agents_dir": "agents"},
    "codex":    {"user_dir_subpath": ".codex",           "user_root_md": "AGENTS.md",
                 "rules_dir": "rules", "rules_ext": "md",
                 "skills_dir": "skills", "skills_as_dir": True,
                 "agents_dir": None},
    "gemini":   {"user_dir_subpath": ".gemini",          "user_root_md": "GEMINI.md",
                 "rules_dir": None,    "rules_ext": "md",
                 "skills_dir": "skills", "skills_as_dir": True,
                 "agents_dir": None},
    "cursor":   {"user_dir_subpath": ".cursor",          "user_root_md": None,
                 "rules_dir": "rules", "rules_ext": "mdc",
                 "skills_dir": None, "skills_as_dir": False,
                 "agents_dir": None},
    "windsurf": {"user_dir_subpath": ".codeium/windsurf", "user_root_md": None,
                 "rules_dir": "rules", "rules_ext": "md",
                 "skills_dir": None, "skills_as_dir": False,
                 "agents_dir": None},
    "cline":    {"user_dir_subpath": ".cline",           "user_root_md": None,
                 "rules_dir": None,    "rules_ext": "md",
                 "skills_dir": None, "skills_as_dir": False,
                 "agents_dir": None},
}

# Names that fanout NEVER touches — these are Claude-specific, other tools
# have their own (incompatible) format.
NOT_FANNED_OUT = {
    "settings.json", "settings.local.json", ".mcp.json",
    "hooks", "scripts", "lib", "statusline-command.sh", "commands",
    ".credentials.json",
}


def detect_present_platforms(home: Path) -> list[str]:
    """Return platform names whose user_dir already exists under HOME."""
    out = []
    for name, p in PLATFORMS.items():
        if name == "claude":
            continue
        if (home / p["user_dir_subpath"]).is_dir():
            out.append(name)
    return out


def copy_file(src: Path, dst: Path, log: list, dry_run: bool, label: str) -> bool:
    """Copy a single file. Returns True iff actually copied (not skipped).
    Symlinks are SKIPPED with a warning — we never dereference + materialize
    a symlink target (could be a secret, cache, or external dir the user
    did not intend to share via fan-out)."""
    if src.is_symlink():
        try:
            tgt = os.readlink(src)
        except OSError:
            tgt = "<unreadable>"
        log.append(f"  WARN ({label}): SKIPPED symlink {src} -> {tgt} "
                   f"(refusing to dereference; copy the target into source if intended)")
        return False
    log.append(f"  {label}: {src} -> {dst}")
    if dry_run:
        return True
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst, follow_symlinks=False)  # belt+suspenders
    return True


def copy_root_md(src_root: Path, dest_dir: Path, target_name: Optional[str],
                 log: list, dry_run: bool) -> int:
    if not target_name:
        return 0
    src_md = src_root / "CLAUDE.md"
    if not src_md.exists():
        return 0
    return 1 if copy_file(src_md, dest_dir / target_name, log, dry_run, "root-md") else 0


def container_is_unsafe(container: Path, label: str, log: list) -> bool:
    """A container dir (rules/, skills/, agents/) inside the source root
    is "unsafe" if it's itself a symlink. is_dir() follows symlinks, so
    glob/iterdir would happily list and copy contents from a symlink
    target outside the source — silently leaking external data into
    fan-out destinations. Refuse and warn."""
    if container.is_symlink():
        try:
            tgt = os.readlink(container)
        except OSError:
            tgt = "<unreadable>"
        log.append(f"  WARN ({label}): SKIPPED symlinked container {container} -> {tgt} "
                   f"(refusing to dereference; move contents into source if intended)")
        return True
    return False


def copy_rules(src_root: Path, dest_dir: Path, rules_subdir: Optional[str],
               ext: str, log: list, dry_run: bool) -> int:
    if not rules_subdir:
        return 0
    rules_src = src_root / "rules"
    if container_is_unsafe(rules_src, "rules", log):
        return 0
    if not rules_src.is_dir():
        return 0
    files = sorted(rules_src.glob("*.md"))
    if not files:
        return 0
    target_root = dest_dir / rules_subdir
    n = 0
    for f in files:
        if copy_file(f, target_root / f"{f.stem}.{ext}", log, dry_run, "rule"):
            n += 1
    return n


def copy_skills(src_root: Path, dest_dir: Path, skills_subdir: Optional[str],
                as_dir: bool, log: list, dry_run: bool) -> int:
    if not skills_subdir:
        return 0
    skills_src = src_root / "skills"
    if container_is_unsafe(skills_src, "skills", log):
        return 0
    if not skills_src.is_dir():
        return 0
    target_root = dest_dir / skills_subdir
    n = 0
    if as_dir:
        # Walk skill candidates; reject symlinked skill DIRS at the top level
        # because copytree(src, dst, symlinks=True) would still dereference
        # src itself if src is a symlink (symlinks=True only preserves
        # symlinks INSIDE src). A symlinked top-level skill dir could point
        # at /etc or any external tree.
        skill_dirs = []
        for sd in sorted(skills_src.iterdir()):
            if sd.is_symlink():
                try:
                    tgt = os.readlink(sd)
                except OSError:
                    tgt = "<unreadable>"
                log.append(f"  WARN (skill): SKIPPED symlinked skill dir {sd} -> {tgt} "
                           f"(refusing to dereference)")
                continue
            if sd.is_dir() and (sd / "SKILL.md").exists():
                skill_dirs.append(sd)
        if not skill_dirs:
            return 0
        for sd in skill_dirs:
            target_dir = target_root / sd.name
            log.append(f"  skill-dir: {sd} -> {target_dir}")
            if not dry_run:
                target_dir.parent.mkdir(parents=True, exist_ok=True)
                # If a previous version of this same-named skill is in the
                # target, remove it before copytree (which refuses an
                # existing dst). This is the per-skill replace and is safe:
                # the target_dir path is scoped to one named skill.
                if target_dir.exists():
                    shutil.rmtree(target_dir)
                # symlinks=True: symlinks INSIDE ~/.claude/skills/<name>/
                # are preserved as symlinks (not dereferenced). The top-level
                # sd is guaranteed to be a real dir by the symlink-check above.
                shutil.copytree(sd, target_dir, symlinks=True)
            n += 1
    else:
        skill_files = sorted(skills_src.rglob("SKILL.md"))
        if not skill_files:
            return 0
        for sm in skill_files:
            target = target_root / f"{sm.parent.name}.md"
            if copy_file(sm, target, log, dry_run, "skill-flat"):
                n += 1
    return n


def copy_agents(src_root: Path, dest_dir: Path, agents_subdir: Optional[str],
                log: list, dry_run: bool) -> int:
    if not agents_subdir:
        return 0
    agents_src = src_root / "agents"
    if container_is_unsafe(agents_src, "agents", log):
        return 0
    if not agents_src.is_dir():
        return 0
    files = sorted(agents_src.glob("*.md"))
    if not files:
        return 0
    target_root = dest_dir / agents_subdir
    n = 0
    for f in files:
        if copy_file(f, target_root / f.name, log, dry_run, "agent"):
            n += 1
    return n


MARKER_FILENAME = ".aisync-ship-managed"


def _plan_skill_paths(skills_src: Path, p: dict) -> list[str]:
    """Helper for plan_managed_paths — list dest-rel paths we'd write for
    every non-symlinked skill under skills_src."""
    paths: list[str] = []
    sub = p["skills_dir"]
    if p["skills_as_dir"]:
        for sd in sorted(skills_src.iterdir()):
            if sd.is_symlink() or not sd.is_dir() or not (sd / "SKILL.md").exists():
                continue
            for f in sd.rglob("*"):
                if f.is_symlink() or f.is_file():
                    rel = f.relative_to(sd)
                    paths.append(f"{sub}/{sd.name}/{rel.as_posix()}")
    else:
        for sm in sorted(skills_src.rglob("SKILL.md")):
            if not sm.is_symlink():
                paths.append(f"{sub}/{sm.parent.name}.md")
    return paths


def plan_managed_paths(src_root: Path, p: dict) -> list[str]:
    """Predict the dest-relative paths fanout WILL install for this source
    + platform combination. Mirrors copy_root_md/copy_rules/copy_skills/
    copy_agents (symlinks skipped, container symlinks skipped). Used to
    write the marker file BEFORE we'd accidentally include user-authored
    files in dest (which a post-cp dest walk would).
    """
    paths: list[str] = []
    if p["user_root_md"]:
        src_md = src_root / "CLAUDE.md"
        if src_md.is_file() and not src_md.is_symlink():
            paths.append(p["user_root_md"])
    if p["rules_dir"]:
        rules_src = src_root / "rules"
        if rules_src.is_dir() and not rules_src.is_symlink():
            for f in sorted(rules_src.glob("*.md")):
                if not f.is_symlink():
                    paths.append(f"{p['rules_dir']}/{f.stem}.{p['rules_ext']}")
    if p["skills_dir"]:
        skills_src = src_root / "skills"
        if skills_src.is_dir() and not skills_src.is_symlink():
            paths.extend(_plan_skill_paths(skills_src, p))
    if p["agents_dir"]:
        agents_src = src_root / "agents"
        if agents_src.is_dir() and not agents_src.is_symlink():
            for f in sorted(agents_src.glob("*.md")):
                if not f.is_symlink():
                    paths.append(f"{p['agents_dir']}/{f.name}")
    return sorted(set(paths))


def write_marker(dest_dir: Path, platform: str, paths: list[str], log: list) -> None:
    """Plain-text marker (one rel-path per line) so install-remote.sh can
    parse it with POSIX sh + grep, no JSON/jq dependency."""
    marker = dest_dir / MARKER_FILENAME
    body = (f"# aisync-ship managed manifest v1\n"
            f"# platform: {platform}\n"
            + "\n".join(paths) + ("\n" if paths else ""))
    marker.write_text(body, encoding="utf-8")
    log.append(f"  marker: wrote {len(paths)} paths to {marker}")


def read_marker(dest_dir: Path) -> list[str]:
    """Read prior managed-paths list. Empty list if no marker (first run)."""
    marker = dest_dir / MARKER_FILENAME
    if not marker.is_file():
        return []
    paths = []
    for line in marker.read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        paths.append(line)
    return paths


def is_safe_rel(rel: str) -> bool:
    """Reject marker entries that could escape dest via path traversal,
    absolute paths, or backslash injection. Any single bad entry could
    let `dest / rel` resolve OUTSIDE dest_dir and our rm/rmtree would
    happily delete unrelated user data. Be paranoid — markers can come
    from a tampered source/dest disk."""
    if not rel or rel != rel.strip():
        return False
    if rel.startswith("/") or "\\" in rel or "\x00" in rel:
        return False
    parts = rel.split("/")
    return all(p and p != "." and p != ".." for p in parts)


def apply_marker_deletions(dest_dir: Path, old_managed: list[str],
                           new_managed: list[str], log: list) -> int:
    """Delete files in dest that we previously installed (in old marker) but
    no longer install (not in new managed set). Files NOT in old marker —
    e.g. user-authored ~/.codex/rules/manual.md — are never touched.
    Prunes empty ancestor dirs after each delete so a fully-removed skill
    dir like skills/active/ doesn't leave a hollow shell."""
    to_delete = sorted(set(old_managed) - set(new_managed))
    n = 0
    for rel in to_delete:
        if not is_safe_rel(rel):
            log.append(f"  marker-delete REJECTED unsafe path: {rel!r} "
                       f"(absolute, traversal, or null byte)")
            continue
        target = dest_dir / rel
        if not target.exists() and not target.is_symlink():
            continue
        if target.is_file() or target.is_symlink():
            target.unlink()
        elif target.is_dir():
            shutil.rmtree(target)
        log.append(f"  marker-delete: {target}")
        n += 1
        # Prune now-empty ancestor dirs, walking up but bounded to dest_dir
        parent = target.parent
        while parent != dest_dir and parent.is_relative_to(dest_dir):
            try:
                parent.rmdir()  # raises if non-empty → safe stop signal
            except OSError:
                break
            parent = parent.parent
    return n


def fanout_one(src_root: Path, platform: str, dest_dir: Path,
               log: list, dry_run: bool) -> dict:
    p = PLATFORMS[platform]
    counts = {
        "root_md": copy_root_md(src_root, dest_dir, p["user_root_md"], log, dry_run),
        "rules":   copy_rules(src_root, dest_dir, p["rules_dir"], p["rules_ext"], log, dry_run),
        "skills":  copy_skills(src_root, dest_dir, p["skills_dir"], p["skills_as_dir"], log, dry_run),
        "agents":  copy_agents(src_root, dest_dir, p["agents_dir"], log, dry_run),
    }
    counts["total"] = sum(counts.values())
    if not dry_run:
        # Marker-based delete propagation:
        #   - OLD marker = what WE installed last time (user-authored never recorded)
        #   - NEW managed set = what we just installed THIS run, computed from
        #     source (NOT from walking dest, which would include round-1
        #     leftovers + user-authored files and break the diff).
        #   - Delete (old - new): previous installs that are no longer in source.
        # IMPORTANT: do NOT gate on counts["total"] > 0. If source goes
        # totally empty for this platform but dest has an old marker, we
        # must still propagate the deletion — otherwise stale entries
        # accumulate forever once source drops everything for a platform.
        old_managed = read_marker(dest_dir) if dest_dir.exists() else []
        new_managed = plan_managed_paths(src_root, p)
        if old_managed or new_managed:
            if not dest_dir.exists():
                dest_dir.mkdir(parents=True)
            deleted = apply_marker_deletions(dest_dir, old_managed, new_managed, log)
            if deleted:
                log.append(f"  marker-delete: removed {deleted} stale entries")
            if new_managed:
                write_marker(dest_dir, platform, new_managed, log)
            elif old_managed:
                # Everything we previously installed is gone; remove marker
                # too so dest_dir is back to a clean slate from our POV.
                marker = dest_dir / MARKER_FILENAME
                if marker.exists():
                    marker.unlink()
                    log.append(f"  marker-delete: removed marker {marker}")
    return counts


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Fan out ~/.claude/ to other agent user dirs")
    p.add_argument("--from", dest="src", default="~/.claude",
                   help="Source Claude-shaped tree (default: ~/.claude)")
    p.add_argument("--out-base", default="~",
                   help="Output base. Use ~ for same-machine A-mode (default), "
                        "or a stage dir for C-mode (ship --also). Targets become "
                        "<out-base>/<platform_subpath>.")
    p.add_argument("--to-platforms", default="",
                   help="Comma-separated platform names. Empty = auto-detect "
                        "platforms whose user_dir already exists under HOME.")
    p.add_argument("--all-platforms", action="store_true",
                   help="Fan out to every platform with a user_dir (overrides --to-platforms).")
    p.add_argument("--dry-run", action="store_true",
                   help="List intended actions only; do not write any files.")
    p.add_argument("--manifest", default="",
                   help="If set, write a TSV manifest mapping <stage_subpath>\\t<home_subpath>"
                        " for each platform actually touched. Used by ship's install-remote.sh.")
    p.add_argument("--log", default="-",
                   help="Path for human-readable log (default: stderr)")
    return p.parse_args()


def resolve_targets(opts: argparse.Namespace, home: Path) -> list[str]:
    if opts.all_platforms:
        return [n for n in PLATFORMS if n != "claude"]
    if opts.to_platforms:
        names = [n.strip() for n in opts.to_platforms.split(",") if n.strip()]
        bad = [n for n in names if n not in PLATFORMS or n == "claude"]
        if bad:
            sys.exit(f"fanout: unknown or non-target platform(s): {bad}")
        return names
    return detect_present_platforms(home)


def emit_log(lines: list, dest: str) -> None:
    text = "\n".join(lines) + "\n" if lines else ""
    if dest == "-":
        sys.stderr.write(text)
    else:
        Path(dest).write_text(text, encoding="utf-8")


def main() -> int:
    opts = parse_args()
    src = Path(opts.src).expanduser().resolve()
    out_base = Path(opts.out_base).expanduser().resolve()
    home = Path.home()
    if not src.is_dir():
        sys.exit(f"fanout: source dir not found: {src}")
    targets = resolve_targets(opts, home)
    if not targets:
        sys.stderr.write("fanout: no target platforms (none auto-detected; pass --to-platforms or --all-platforms)\n")
        return 0
    log = [f"# fanout.py log (src={src} out_base={out_base} dry_run={opts.dry_run})"]
    summary: dict = {}
    manifest_lines: list = []
    for plat in targets:
        sub = PLATFORMS[plat]["user_dir_subpath"]
        dest_dir = out_base / sub
        log.append(f"[{plat}] dest={dest_dir}")
        counts = fanout_one(src, plat, dest_dir, log, opts.dry_run)
        summary[plat] = counts
        if not opts.manifest:
            # A-mode (no manifest): fanout_one already wrote marker + did
            # delete propagation directly against the real dest. Nothing
            # else to do per platform.
            continue
        # C-mode (manifest-driven, used by ship.sh):
        # Always emit a manifest line + ensure stage_dir + a marker file
        # exist for THIS platform — even if source produced no content.
        # Without this, going from "had content" to "empty source" wouldn't
        # reach install-remote.sh: no manifest line ⇒ no remote stage_sub
        # ⇒ no chance to run marker-based delete propagation against the
        # remote dest, and stale entries persist on the remote forever.
        if not opts.dry_run:
            new_managed = plan_managed_paths(src, PLATFORMS[plat])
            if not dest_dir.exists():
                dest_dir.mkdir(parents=True)
            if not (dest_dir / MARKER_FILENAME).exists():
                write_marker(dest_dir, plat, new_managed, log)
        # owned_csv stays evidence-based (Phase 1 fallback for old
        # install-remote.sh that doesn't know about markers). New
        # install-remote.sh sees the marker and ignores owned_csv.
        p = PLATFORMS[plat]
        owned = []
        if p["rules_dir"] and counts["rules"] > 0:
            owned.append(p["rules_dir"])
        if p["skills_dir"] and counts["skills"] > 0:
            owned.append(p["skills_dir"])
        if p["agents_dir"] and counts["agents"] > 0:
            owned.append(p["agents_dir"])
        owned_csv = ",".join(owned)
        manifest_lines.append(f"{sub}\t{sub}\tmerge\t{owned_csv}")
    log.append(f"# summary: {json.dumps(summary)}")
    emit_log(log, opts.log)
    if opts.manifest:
        Path(opts.manifest).write_text(
            "\n".join(manifest_lines) + ("\n" if manifest_lines else ""),
            encoding="utf-8",
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
