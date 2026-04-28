# Changelog

## [0.6.0] - 2026-04-28

### Added — `aisync ship` cross-machine `~/.claude` synchronization

The big one in this release: a new `aisync ship` subcommand for syncing user-level Claude Code config (`~/.claude/`) across machines, plus optional fan-out to other agent CLIs (`~/.codex`, `~/.gemini`, `~/.cursor`, `~/.codeium/windsurf`, `~/.cline`). Target only needs `ssh` + `tar` + `sh`.

Three call modes:
- **Push** to a new machine: `aisync ship --apply --yes user@host`
- **Push + fan out** to other CLIs: `aisync ship --apply --yes --also codex,gemini user@host`
- **Pull** from another machine: `aisync ship --pull user@host`

Pipeline guarantees:
- Runtime data excluded (sessions, history.jsonl, plugin caches, AppleDouble) — only portable config is shipped
- Path rewrite `/Users/<u>` → `/home/<u>` in `settings.json` / `.mcp.json` (and `--reverse` for pull)
- Local-bound hooks (sweatshop bridges, localhost HTTP) and macOS-only paths (`/opt/homebrew/...`) stripped — `--strict` for unrecognised local paths too
- Cross-tool fan-out is delete-aware (managed-marker tracking): rules/skills written by hand on the target survive
- Atomic install on remote with restore-on-error rollback (per-platform); `mkdir`-based concurrent-run lock
- Credentials NOT shipped by default (per-machine `claude login` is the contract); `--include-credentials` opt-in

The full pipeline is implemented as 5 helpers under `share/skills/aisync-ship/scripts/` (also published as a Claude Code skill at `share/skills/aisync-ship/SKILL.md`). The Rust binary embeds them via `include_str!` and unpacks at runtime to a mode-700 tmpdir, so the single `aisync` binary contains the entire pipeline. Unix-only via `cfg(unix)` (Windows builds get a friendly stub).

### Added — testing & CI

- 31 Python unit tests (`tests/test_fanout.py`) covering pure-functional helpers: `is_safe_rel` (path traversal validation), `plan_managed_paths`, `apply_marker_deletions`, `container_is_unsafe`, marker round-trip, `--strict` mode behavior
- 22 shell integration tests (`tests/test_install_remote.sh`) covering 9 scenarios of `install-remote.sh`'s state machine: merge preserve, replace atomic swap, multi-platform rollback, `.partial` GC, orphan dir rollback, marker delete propagation, REJECTED unsafe paths, snapshot-fail dest preservation, concurrent-run lock
- New `ship-helpers` CI job alongside the existing `rust` job: bash/sh syntax check, `python3 -m py_compile`, optional `shellcheck`, both test suites

### Fixed
- `clippy::needless_borrows_for_generic_args` warning surfaced by rustc 1.95.0 (`src/sync.rs:550` had been failing CI silently before the new `ship-helpers` job exposed it)

## [0.5.0] - 2026-04-07

### Added
- **Platform-specific extras**: `extra_files` and `extra_dirs` fields in `Platform` struct for runtime configs that don't fit the shared rules/skills/agents model
- Claude Code now imports and syncs: `settings.json`, `.mcp.json`, `hooks/`, `plugins/`, and `output-styles/`
- Extras are stored under `.agents/platforms/<name>/` to stay namespaced from shared configs
- `SKIP_DIRS` constant to automatically exclude build artifacts (`node_modules`, `target`, `cache`, `__pycache__`, etc.) when copying extra directories

### Fixed
- **CLAUDE.md never imported**: init template (66 chars) exceeded the 50-char threshold; now compares against exact template content instead of arbitrary length
- **Root MD import for user-level configs**: falls back to user-level path (e.g. `~/.claude/CLAUDE.md`) when project-level file doesn't exist
- **Agent subdirectories ignored**: `import_md_files` and `copy_md_dir` now recurse into subdirectories (e.g. `_negotiation/`, `_shared/`)
- **`sync_user` missing agents**: added agents sync step to user-level sync
- **Codex rules never synced**: changed `rules_dir` from `None` to `Some("rules")`

### Architecture
- New `copy_dir_all()` — recursive copy for any file type (not just `.md`), with `SKIP_DIRS` filtering
- New `sync_extras()` — syncs platform-specific extra files and directories

## [0.4.2] - 2026-04-07

### Fixed
- Fixed CLAUDE.md import, agent subdirectories, and Codex rules sync (see 0.5.0 for details — released together)

## [0.4.1] - 2026-03-18

### Changed
- Updated README with v0.4.0 features (serve/pull, remote push, skills directory format)
- Added CHANGELOG.md

## [0.4.0] - 2026-03-18

### Added
- `aisync serve` — HTTP config server for LAN sync (default port 9753)
- `aisync pull <url>` — Pull `.agents/` from a config server
- `aisync remote add/remove/push/list` — SSH/rsync push to remote machines
- Remote config stored in `.agents/remotes.toml` (hand-rolled TOML parser)
- All new features use pure `std`, zero external dependencies

### Architecture
- New `src/server.rs` (106 lines) — HTTP/1.0 server with `/manifest` and `/file/<path>` endpoints
- New `src/remote.rs` (317 lines) — SSH push + HTTP pull client

## [0.3.0] - 2026-03-18

### Added
- Frontmatter validation during `aisync sync` — warns about missing YAML frontmatter or `description` field in skills/agents files
- `warnings` field in `SyncResult` for non-fatal issues

### Changed
- Skills now sync as directory format (`<name>/SKILL.md`) for Claude Code, Codex CLI, and Gemini CLI
- Added `skills_as_dir` field to `Platform` struct
- Claude Code: `skills_dir` changed from `commands` to `skills`
- Codex CLI: added skills support (`.codex/skills/`)
- Gemini CLI: added skills support (`.gemini/skills/`)
- Windsurf: updated `user_dir` to `~/.codeium/windsurf`
- Platform documentation sources refreshed (verified 2026-03)

### Architecture
- New `sync_skills_dir()` — flat `.md` → `<name>/SKILL.md` directory conversion
- New `import_skills_dir()` — reverse: `<name>/SKILL.md` → flat `.md`

## [0.2.0] - 2026-03-17

### Added
- Initial release with 7 platform support
- `init`, `sync`, `import`, `user`, `status`, `platforms` commands
- Extension conversion (`.md` → `.mdc`, `.instructions.md`)
- npm, Homebrew, shell script, and GitHub Releases distribution
