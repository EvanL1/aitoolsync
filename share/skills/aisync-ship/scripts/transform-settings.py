#!/usr/bin/env python3
"""transform-settings.py — JSON-aware Claude Code settings.json transformer.

Reads ~/.claude/settings.json (or path from --in), applies the four
structural rules below, and writes the result to stdout (or --out path).

Rules (each can be disabled with --no-<rule>):
  1. strip-local-hooks    Remove hook entries whose `command` references a
                          non-portable absolute path (default: any path
                          under /Users/.../sweatshop/).
  2. strip-localhost-http Remove hooks of type=http whose url targets
                          127.0.0.1 or localhost.
  3. strip-local-mcp      Remove mcpServers entries whose `args` contain
                          a non-portable absolute path.
  4. path-rewrite         Rewrite all string values: /Users/<src-user>
                          → /home/<dst-user>.

Designed to round-trip safely (idempotent on already-transformed input).
"""

import argparse
import json
import re
import sys
from typing import Any


SWEATSHOP_RE = re.compile(r"/Users/[^/]+/dev/sweatshop(/|\b)")
LOCALHOST_RE = re.compile(r"://(127\.0\.0\.1|localhost)(:|/|$)")

# Absolute paths that exist on macOS but not on Linux. Anything containing
# these is a hard signal the entry will not work on the remote.
MACOS_ONLY_PATH_RES = [
    re.compile(r"/opt/homebrew(/|\b)"),
    re.compile(r"/Applications/"),
    re.compile(r"/Library/"),
    re.compile(r"/System/"),
    re.compile(r"/usr/local/Cellar(/|\b)"),  # legacy Intel brew
]

# Absolute paths under /Users/<u>/... that are NOT inside the user's HOME-shaped
# subset we expect to also exist on the remote. Used to scan for "likely broken
# after path-rewrite" — we WARN (do not strip) so the user can decide.
LIKELY_LOCAL_RE = re.compile(r"/Users/[^/]+/(?!\.claude/|\.codex/|\.gemini/|\.cursor/|\.codeium/|\.cline/|\.local/)")


def is_sweatshop_path(s: str) -> bool:
    """Strict-strip pattern: known-bad sweatshop bridge."""
    return bool(SWEATSHOP_RE.search(s or ""))


def is_macos_only_path(s: str) -> bool:
    """Strict-strip pattern: paths that cannot exist on a Linux remote."""
    return any(r.search(s or "") for r in MACOS_ONLY_PATH_RES)


def is_local_command(cmd: str) -> bool:
    """Should this hook command be DROPPED entirely?"""
    return is_sweatshop_path(cmd) or is_macos_only_path(cmd)


def is_localhost_url(url: str) -> bool:
    return bool(LOCALHOST_RE.search(url or ""))


def scan_likely_local(value: str, where: str, log: list) -> None:
    """Walk a string value, warn (not strip) on absolute paths that look
    machine-specific and that path-rewrite would *not* fix correctly."""
    if not isinstance(value, str):
        return
    if is_sweatshop_path(value) or is_macos_only_path(value):
        # already handled by drop logic — no warn needed
        return
    if LIKELY_LOCAL_RE.search(value):
        log.append(f"  WARN ({where}): possibly machine-specific path: {value[:120]}")


def hook_should_drop(h: dict, opts: argparse.Namespace) -> tuple[bool, str]:
    htype = h.get("type")
    if htype == "command" and opts.strip_local_hooks:
        cmd = h.get("command", "")
        if is_local_command(cmd):
            return True, f"local-bound command: {cmd[:80]}"
    if htype == "http" and opts.strip_localhost_http:
        url = h.get("url", "")
        if is_localhost_url(url):
            return True, f"localhost http: {url}"
    return False, ""


def filter_hook_groups(groups: list, opts: argparse.Namespace, log: list) -> list:
    out = []
    for group in groups:
        matcher = group.get("matcher", "?")
        kept = []
        for h in group.get("hooks", []):
            drop, reason = hook_should_drop(h, opts)
            if drop:
                log.append(f"    drop hook (matcher={matcher}): {reason}")
                continue
            # Warn-only scan: kept hooks may still reference machine-specific paths.
            if h.get("type") == "command":
                scan_likely_local(h.get("command", ""), f"hook(matcher={matcher})", log)
            kept.append(h)
        if kept:
            new_group = dict(group)
            new_group["hooks"] = kept
            out.append(new_group)
        else:
            log.append(f"    drop empty group (matcher={matcher})")
    return out


def transform_hooks(data: dict, opts: argparse.Namespace, log: list) -> None:
    hooks = data.get("hooks")
    if not isinstance(hooks, dict):
        return
    log.append("[hooks]")
    for event in list(hooks.keys()):
        log.append(f"  event={event}")
        kept = filter_hook_groups(hooks[event], opts, log)
        if kept:
            hooks[event] = kept
        else:
            del hooks[event]
            log.append(f"  drop empty event {event}")


def _mcp_bad_strings(cfg: dict) -> list[str]:
    """Collect strings under command/cwd/args/env-values that match a
    known-bad pattern (sweatshop or macOS-only). Strict-strip targets only."""
    bad: list[str] = []
    for key in ("command", "cwd"):
        v = cfg.get(key)
        if isinstance(v, str) and is_local_command(v):
            bad.append(f"{key}={v}")
    for a in cfg.get("args", []) or []:
        if isinstance(a, str) and is_local_command(a):
            bad.append(f"args={a}")
    env = cfg.get("env") or {}
    if isinstance(env, dict):
        for ek, ev in env.items():
            if isinstance(ev, str) and is_local_command(ev):
                bad.append(f"env.{ek}={ev}")
    return bad


def _mcp_warn_strings(cfg: dict, server_name: str, log: list) -> None:
    """Warn-only scan: surface machine-specific paths in MCP config so the
    user can decide whether to keep, edit, or remove the server entry."""
    for key in ("command", "cwd"):
        scan_likely_local(cfg.get(key, ""), f"mcpServers.{server_name}.{key}", log)
    for i, a in enumerate(cfg.get("args", []) or []):
        scan_likely_local(a, f"mcpServers.{server_name}.args[{i}]", log)
    env = cfg.get("env") or {}
    if isinstance(env, dict):
        for ek, ev in env.items():
            scan_likely_local(ev, f"mcpServers.{server_name}.env.{ek}", log)


def transform_mcp(data: dict, opts: argparse.Namespace, log: list) -> None:
    if not opts.strip_local_mcp:
        return
    servers = data.get("mcpServers")
    if not isinstance(servers, dict):
        return
    log.append("[mcpServers]")
    for name in list(servers.keys()):
        cfg = servers[name] or {}
        bad = _mcp_bad_strings(cfg)
        if bad:
            log.append(f"  drop server '{name}': {bad[0][:120]}")
            del servers[name]
            continue
        # Warn-only on machine-specific but not strictly-bad paths
        _mcp_warn_strings(cfg, name, log)


def rewrite_paths(obj: Any, src_user: str, dst_user: str) -> Any:
    if isinstance(obj, dict):
        return {k: rewrite_paths(v, src_user, dst_user) for k, v in obj.items()}
    if isinstance(obj, list):
        return [rewrite_paths(v, src_user, dst_user) for v in obj]
    if isinstance(obj, str):
        return obj.replace(f"/Users/{src_user}/", f"/home/{dst_user}/").replace(
            f"/Users/{src_user}", f"/home/{dst_user}"
        )
    return obj


def parse_args() -> argparse.Namespace:
    p = argparse.ArgumentParser(description="Transform Claude Code settings.json")
    p.add_argument("--in", dest="inp", default="-", help="input path or '-' for stdin")
    p.add_argument("--out", dest="out", default="-", help="output path or '-' for stdout")
    p.add_argument("--src-user", required=True, help="source POSIX user (e.g. evan)")
    p.add_argument("--dst-user", required=True, help="destination POSIX user (e.g. evan)")
    p.add_argument("--no-strip-local-hooks", dest="strip_local_hooks",
                   action="store_false", default=True)
    p.add_argument("--no-strip-localhost-http", dest="strip_localhost_http",
                   action="store_false", default=True)
    p.add_argument("--no-strip-local-mcp", dest="strip_local_mcp",
                   action="store_false", default=True)
    p.add_argument("--no-path-rewrite", dest="path_rewrite",
                   action="store_false", default=True)
    p.add_argument("--log", dest="log", default="-",
                   help="path for human-readable transformation log (default stderr)")
    return p.parse_args()


def load_json(path: str) -> dict:
    if path == "-":
        return json.load(sys.stdin)
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


def write_json(path: str, data: dict) -> None:
    text = json.dumps(data, indent=2, ensure_ascii=False) + "\n"
    if path == "-":
        sys.stdout.write(text)
    else:
        with open(path, "w", encoding="utf-8") as f:
            f.write(text)


def emit_log(lines: list, dest: str) -> None:
    text = "\n".join(lines) + "\n" if lines else ""
    if dest == "-":
        sys.stderr.write(text)
    else:
        with open(dest, "w", encoding="utf-8") as f:
            f.write(text)


def main() -> int:
    opts = parse_args()
    data = load_json(opts.inp)
    log: list = [f"# transform-settings.py log (src={opts.src_user} dst={opts.dst_user})"]
    transform_hooks(data, opts, log)
    transform_mcp(data, opts, log)
    if opts.path_rewrite:
        log.append("[path-rewrite] /Users/%s -> /home/%s" % (opts.src_user, opts.dst_user))
        data = rewrite_paths(data, opts.src_user, opts.dst_user)
    write_json(opts.out, data)
    emit_log(log, opts.log)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
