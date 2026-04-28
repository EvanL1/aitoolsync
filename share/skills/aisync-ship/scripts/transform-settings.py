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


def is_local_command(cmd: str) -> bool:
    return bool(SWEATSHOP_RE.search(cmd or ""))


def is_localhost_url(url: str) -> bool:
    return bool(LOCALHOST_RE.search(url or ""))


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
        kept = []
        for h in group.get("hooks", []):
            drop, reason = hook_should_drop(h, opts)
            if drop:
                log.append(f"    drop hook (matcher={group.get('matcher','?')}): {reason}")
            else:
                kept.append(h)
        if kept:
            new_group = dict(group)
            new_group["hooks"] = kept
            out.append(new_group)
        else:
            log.append(f"    drop empty group (matcher={group.get('matcher','?')})")
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


def transform_mcp(data: dict, opts: argparse.Namespace, log: list) -> None:
    if not opts.strip_local_mcp:
        return
    servers = data.get("mcpServers")
    if not isinstance(servers, dict):
        return
    log.append("[mcpServers]")
    for name in list(servers.keys()):
        cfg = servers[name] or {}
        args = cfg.get("args", []) or []
        bad = [a for a in args if isinstance(a, str) and is_local_command(a)]
        if bad:
            log.append(f"  drop server '{name}': args reference {bad[0][:80]}")
            del servers[name]


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
