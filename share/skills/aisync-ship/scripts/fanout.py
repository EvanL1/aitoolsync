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


def copy_file(src: Path, dst: Path, log: list, dry_run: bool, label: str) -> None:
    log.append(f"  {label}: {src} -> {dst}")
    if dry_run:
        return
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copy2(src, dst)


def copy_root_md(src_root: Path, dest_dir: Path, target_name: Optional[str],
                 log: list, dry_run: bool) -> int:
    if not target_name:
        return 0
    src_md = src_root / "CLAUDE.md"
    if not src_md.exists():
        return 0
    copy_file(src_md, dest_dir / target_name, log, dry_run, "root-md")
    return 1


def replace_subtree(target_dir: Path, log: list, dry_run: bool, label: str) -> None:
    """Owned-subtree replace: clear target_dir before populating it.
    Used by A-mode (this file's direct copy) so deletion-propagation
    matches what C-mode (install-remote.sh) does. Only called when the
    source has at least one entry (evidence-based ownership)."""
    if dry_run:
        log.append(f"  {label}-replace: would clear {target_dir} before copy")
        return
    if target_dir.exists():
        log.append(f"  {label}-replace: clearing {target_dir}")
        shutil.rmtree(target_dir)


def copy_rules(src_root: Path, dest_dir: Path, rules_subdir: Optional[str],
               ext: str, log: list, dry_run: bool) -> int:
    if not rules_subdir:
        return 0
    rules_src = src_root / "rules"
    if not rules_src.is_dir():
        return 0
    files = sorted(rules_src.glob("*.md"))
    if not files:
        return 0
    target_root = dest_dir / rules_subdir
    replace_subtree(target_root, log, dry_run, "rules")
    for f in files:
        copy_file(f, target_root / f"{f.stem}.{ext}", log, dry_run, "rule")
    return len(files)


def copy_skills(src_root: Path, dest_dir: Path, skills_subdir: Optional[str],
                as_dir: bool, log: list, dry_run: bool) -> int:
    if not skills_subdir:
        return 0
    skills_src = src_root / "skills"
    if not skills_src.is_dir():
        return 0
    target_root = dest_dir / skills_subdir
    n = 0
    if as_dir:
        skill_dirs = [sd for sd in sorted(skills_src.iterdir())
                      if sd.is_dir() and (sd / "SKILL.md").exists()]
        if not skill_dirs:
            return 0
        replace_subtree(target_root, log, dry_run, "skills")
        for sd in skill_dirs:
            target_dir = target_root / sd.name
            log.append(f"  skill-dir: {sd} -> {target_dir}")
            if not dry_run:
                target_dir.parent.mkdir(parents=True, exist_ok=True)
                # symlinks=True: a symlink inside ~/.claude/skills/<name>
                # (e.g. -> /tmp/secret) must NOT be dereferenced during
                # fan-out — preserve it as a symlink so we don't materialize
                # arbitrary local paths into other tools' user dirs.
                shutil.copytree(sd, target_dir, symlinks=True)
            n += 1
    else:
        skill_files = sorted(skills_src.rglob("SKILL.md"))
        if not skill_files:
            return 0
        replace_subtree(target_root, log, dry_run, "skills")
        for sm in skill_files:
            target = target_root / f"{sm.parent.name}.md"
            copy_file(sm, target, log, dry_run, "skill-flat")
            n += 1
    return n


def copy_agents(src_root: Path, dest_dir: Path, agents_subdir: Optional[str],
                log: list, dry_run: bool) -> int:
    if not agents_subdir:
        return 0
    agents_src = src_root / "agents"
    if not agents_src.is_dir():
        return 0
    files = sorted(agents_src.glob("*.md"))
    if not files:
        return 0
    target_root = dest_dir / agents_subdir
    replace_subtree(target_root, log, dry_run, "agents")
    for f in files:
        copy_file(f, target_root / f.name, log, dry_run, "agent")
    return len(files)


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
        if counts["total"] > 0:
            # Fan-out targets use merge mode + owned-subtree replace.
            #
            # "merge" alone (cp -aR staged/. dest/) preserves the target tool's
            # auth.json/config.toml/sessions but never deletes anything in dest
            # — so removing a rule or skill at the source side leaves a stale
            # copy in the fan-out target forever (config drift).
            #
            # The 4th column lists subtrees we own outright: install-remote.sh
            # rm -rf's them in dest before merging so deletions propagate, but
            # only within those subtrees. Everything else in dest is preserved.
            #
            # CRITICAL: ownership is EVIDENCE-BASED, not declarative. We list
            # only subtrees we actually wrote to stage this run (counts > 0).
            # If we declared ownership of `rules` whenever the platform has a
            # rules_dir — even when source has no rules — install-remote would
            # rm dest/rules without rewriting it, deleting the user's existing
            # rules that have nothing to do with this fan-out invocation.
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
