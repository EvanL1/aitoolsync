---
name: aisync-ship
description: Use when the user wants to copy/sync their Claude Code configuration (~/.claude/) from this machine to (a) another machine over SSH, and/or (b) other agent CLI user dirs (~/.codex, ~/.gemini, ~/.cursor, ~/.codeium/windsurf, ~/.cline) on the same or remote machine. Handles path rewriting, local-bound hook stripping, runtime-data isolation, and Claude → other-tool fan-out. Credentials are NOT shipped by default. Target machine only needs ssh + tar.
tools: Read, Bash, Edit
---

# aisync-ship

Sync user-level Claude Code configuration to a remote machine. **Target machine zero-dependency** — only `ssh` + `tar` + `sh` required (no rsync, no Claude pre-installed strictly necessary).

## When to use

User says any of:
- "把配置同步到 evan@x.x.x.x" / "把 Claude 配置同步到 192.168.x.x"
- "ship my Claude setup to <host>"
- "把 ~/.claude 也同步到 ~/.codex / 让 Codex 也用一样的 skills/rules"
- "fan out my Claude config to all the agent CLIs on this machine"
- "把 Claude 的 skill 和 rule 也复制到 Codex 和 Gemini" (cross-tool, same machine)
- "let me login to Claude on machine Y / 让我在 Y 机器上登录 Claude"

## Capability matrix

| Scenario | Command |
|---|---|
| **A. Same machine, cross-tool fan-out** (Claude → Codex/Gemini/Cursor/Windsurf/Cline on this host) | `scripts/fanout.py --dry-run` (auto-detects which user_dirs exist) → review → re-run without `--dry-run` |
| **B. Cross-machine, single tool** (Claude on src → Claude on remote) | `scripts/ship.sh --dry-run <user@host>` → review → `--apply` |
| **C. Cross-machine + cross-tool** (Claude on src → Claude + Codex + ... on remote) | `scripts/ship.sh --dry-run --also codex,gemini <user@host>` → review → `--apply` |

## When NOT to use

- For project-level `.agents/` rule sync between AI tools (Claude/Codex/Gemini/Cursor/...) — use `aisync sync` instead. This skill is **user-level** (`~/.claude` → `~/.<other-tool>`), not project-level.
- For pulling configuration FROM a remote source onto this machine — Phase 3 (`--pull`), not yet implemented.

## Pre-flight checklist (MUST execute before any transfer)

Run these in order. STOP if any fails and report to user.

1. **Reachability + tar present**:
   ```bash
   ssh -o BatchMode=yes -o ConnectTimeout=5 <target> 'uname -a && command -v tar'
   ```
2. **Existing remote config?**:
   ```bash
   ssh <target> 'ls -la ~/.claude/ 2>/dev/null | head -5'
   ```
   If the remote already has `~/.claude/`, the ship script will back it up to `~/.claude.bak.<timestamp>` before overwrite. Confirm with user that overwrite is intended.
3. **Claude Code installed on remote?** (informational, not blocking):
   ```bash
   ssh <target> 'command -v claude || echo NOT_INSTALLED'
   ```

## Transformation rules (applied to staged copy, NEVER to source)

The `scripts/ship.sh` helper applies the rules below. Always run with `--dry-run` first, show the plan + diff to the user, get confirmation, THEN run with `--apply`.

Both `settings.json` AND `.mcp.json` are passed through the same transformer; `.mcp.json` typically only triggers rules 1 + 4.

| # | Rule | Source | Action |
|---|---|---|---|
| 1 | Path rewrite | settings.json, .mcp.json (any string value) | `/Users/<u>` → `/home/<remote-user>/` (POSIX-Linux assumption) |
| 2 | Local-bound hook commands | settings.json `hooks[*].hooks[*]` | Drop entries whose `command` contains `/Users/.../sweatshop/` (or any local-fs path that will not exist remotely). Empty hook groups + empty events are removed. |
| 3 | Localhost HTTP hooks | settings.json `hooks[*].hooks[*]` | Drop entries with `type:"http"` and url containing `127.0.0.1` or `localhost` |
| 4 | Local MCP server | settings.json/.mcp.json `mcpServers.*` | Drop servers whose `args` contain a non-portable absolute path (e.g. `/Users/.../sweatshop/...`) |
| 5 | Runtime data | `sessions/`, `history.jsonl`, `session-env/`, `projects/`, `file-history/`, `paste-cache/`, `shell-snapshots/`, `debug/`, `telemetry/`, `usage-data/`, `cache/`, `downloads/`, `plans/`, `tasks/`, `teams/`, `backups/`, `stats-cache.json`, `mcp-needs-auth-cache.json` | Exclude from tarball (privacy + size) |
| 6 | Plugin cache | `plugins/` (entire dir, ~200 MB cache + marketplaces re-fetchable) | Exclude; remote re-resolves from `enabledPlugins` in settings.json |
| 7 | AppleDouble | `._*`, `.DS_Store` | Exclude from tarball |
| 8 | Credentials | macOS Keychain `Claude Code-credentials` | **NOT shipped by default.** Each machine should `claude login` independently. Opt in with `--include-credentials` only when explicitly requested. |

## Execution flow

```
1. scripts/ship.sh --dry-run <target>     (default mode)
   → stages source via tar | tar (no source-side rsync needed)
   → transforms settings.json + .mcp.json (transform-settings.py)
   → extracts credentials from Keychain (extract-credentials.sh)
   → prints plan: stage dir, file count, transformation log, unified diff
2. User reviews diff + confirms
3. scripts/ship.sh --apply <target>
   → streams `tar (.claude + install-remote.sh) | ssh sh install-remote.sh`
   → install-remote.sh on the remote does an ATOMIC mv-swap:
       mv ~/.claude → ~/.claude.bak.<timestamp>   (only if existing)
       mv staged    → ~/.claude
   → on any error mid-install, the backup is auto-restored (trap-on-error)
   → if --no-credentials and remote already has .credentials.json, it is preserved
   → final chmod 600 on the credential file
4. Post-ship verify (suggest to user):
   ssh <target> 'claude --version && ls -la ~/.claude/.credentials.json'
   ssh <target> 'echo hi | claude -p "say hi"'   # smoke test
```

## Decision points (require user confirmation, do NOT default)

- **Include credentials**: **default OFF.** The user's standing preference is one `claude login` per machine — do not ship Keychain credentials unless they explicitly ask. If asked, use `--include-credentials`.
- **Wipe remote-only files (mirror mode)**: default OFF. Phase 2 will add `--mirror`.
- **Plugin cache cleanup on remote**: ship.sh already excludes `plugins/` so the staged side is clean; remote `plugins/cache/` survives unless user asks to wipe.

## Anti-patterns (what NOT to do)

- DO NOT `scp -r ~/.claude <target>:~/.claude` — captures sessions/history (privacy leak) and session-env (12K+ files, slow + brittle).
- DO NOT silently apply settings.json transformations — always show the unified diff and get explicit user OK.
- DO NOT skip credentials extraction on macOS — Keychain entries are NOT in the filesystem; without `security find-generic-password`, the remote will have no auth.
- DO NOT assume target has rsync — use the `tar | ssh tar` pipe in `ship.sh`.
- DO NOT push to a remote `~/.claude` without backing up — `ship.sh` does this automatically; if you bypass the script, replicate the backup.
- DO NOT ship credentials by default. The user's standing preference is to `claude login` on each machine independently. Only pass `--include-credentials` when the user explicitly asks ("把凭证也带过去" / "include creds").
- DO NOT shell out to `extract-credentials.sh` or copy `~/.claude/.credentials.json` "just in case" — the per-machine login model is the contract. If you bypass `--include-credentials` you violate user preference.
- (Historical note: an earlier draft of this doc said "DO NOT skip credentials extraction on macOS." That guidance was reversed once the per-machine login policy was set. Trust the current default.)

## Cross-tool fan-out (A and C scenarios)

`fanout.py` mirrors `~/.claude/`'s portable parts (root MD, `rules/`, `skills/`, `agents/`) into other agent CLIs' user dirs per `src/platforms.rs`. **What is NOT fanned out** (Claude-specific format, would corrupt other tools): `settings.json`, `.mcp.json`, `hooks/`, `commands/`, `lib/`, `scripts/`, `statusline-command.sh`, `.credentials.json`.

Fan-out target detection: `fanout.py` (no flags) auto-detects which agent user_dirs exist on this host (e.g., if `~/.cursor/` exists, Cursor is in scope). Override with `--to-platforms <list>` or `--all-platforms`.

Per-platform mapping (from `platforms.rs`):

| Source | codex | gemini | cursor | windsurf | cline |
|---|---|---|---|---|---|
| `CLAUDE.md` | `~/.codex/AGENTS.md` | `~/.gemini/GEMINI.md` | (no user root md) | (no user root md) | (no user root md) |
| `rules/*.md` | `~/.codex/rules/*.md` | (no rules dir) | `~/.cursor/rules/*.mdc` (ext rewrite) | `~/.codeium/windsurf/rules/*.md` | (no rules dir) |
| `skills/<n>/SKILL.md` | `~/.codex/skills/<n>/SKILL.md` | `~/.gemini/skills/<n>/SKILL.md` | (no skills dir) | (no skills dir) | (no skills dir) |
| `agents/*.md` | (no agents dir) | (no agents dir) | (no agents dir) | (no agents dir) | (no agents dir) |

## Helper scripts

- `scripts/extract-credentials.sh` — platform-aware. macOS: `security find-generic-password -s 'Claude Code-credentials' -w`. Linux: cat `~/.claude/.credentials.json`. Sanity-checks JSON shape (first byte `{` or `[`). Exits non-zero on failure. **Not invoked by default** (credentials opt-in via `--include-credentials`).
- `scripts/transform-settings.py` — JSON-aware transformation engine for `settings.json` AND `.mcp.json`. Reads from `--in` path, writes to `--out` path, emits a human-readable transformation log. Idempotent on already-transformed input.
- `scripts/fanout.py` — Claude → other-tool user-dir fan-out engine. Standalone for A-mode (`--dry-run` then re-run); invoked by `ship.sh --also` for C-mode (writes to a stage dir + emits manifest TSV).
- `scripts/install-remote.sh` — POSIX `sh` script that runs on the REMOTE inside a tmpdir. Reads a manifest TSV (`<stage_subpath>\t<home_subpath>`) and atomically mv-swaps each entry, with cross-platform restore-on-error. Credential preservation only applies to `.claude`.
- `scripts/ship.sh` — orchestrator. `ship.sh --help` for full usage. Calls `extract-credentials.sh` + `transform-settings.py` + `fanout.py` locally; ships `install-remote.sh` + `manifest.tsv` along with all staged platform subdirs so the remote does the install transactionally.

## Recovery

If `install-remote.sh` aborts mid-flight, it auto-restores the backup; manual recovery should not be needed. If you need to roll back a *successful* install:
```bash
ssh <target> 'ls -d ~/.claude.bak.* 2>/dev/null'                    # find backups
ssh <target> 'rm -rf ~/.claude && mv ~/.claude.bak.<ts> ~/.claude'  # restore
```

The source side is never modified — staging happens in `/tmp/aisync-ship-<ts>/`, which is left in place after dry-run for inspection (cleaned up after a successful `--apply`, unless `--keep-stage` is given).
