# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What is this project?

**aitoolsync** (`aisync`) is a zero-dependency Rust CLI that syncs AI agent configs from a single `.agents/` source directory to 7 platforms: Claude Code, Codex CLI, Gemini CLI, Cursor, Copilot, Windsurf, and Cline. It auto-converts file extensions per platform (`.md` → `.mdc` for Cursor, `.instructions.md` for Copilot).

Binary name: `aisync`. Crate name: `aitoolsync`.

## Build & Test

```bash
cargo build                  # debug build
cargo build --release        # release build
cargo check                  # type-check only
cargo clippy -- -D warnings  # lint (CI enforced, warnings = errors)
cargo test                   # run all tests
```

No external dependencies — the project uses only `std`.

## Architecture

Source files (Rust, in `src/`):

- **`src/main.rs`** — CLI entry point. Manual arg parsing (no clap). Dispatches subcommands: `init`, `sync`/`push`, `status`, `import`, `user`, `serve`, `pull`, `remote`, `ship`, `platforms`, `help`, `version`. Contains ANSI color helpers.
- **`src/platforms.rs`** — Static platform definitions. Each platform is a `Platform` struct with paths for root MD, rules dir, skills dir, agents dir, and user-level dir. The `PLATFORMS` const array is the single source of truth for all platform config paths.
- **`src/sync.rs`** — Core project-level sync engine. Handles: `init_source` (scaffold `.agents/`), `sync_project` (`.agents/` → platform dirs), `sync_user` (→ user-level `~/` dirs), `import_from` (reverse: platform → `.agents/`), `detect_platforms`. Rules sync includes extension conversion logic.
- **`src/server.rs`** / **`src/remote.rs`** — LAN config server (HTTP `aisync serve`) + SSH push (`aisync remote add/push`).
- **`src/ship.rs`** — Cross-machine `~/.claude` ship subcommand. Embeds the 5 shell/Python helpers from `share/skills/aisync-ship/scripts/` via `include_str!` and unpacks to a mode-700 tmpdir at runtime, then execs `bash ship.sh "$@"`. Unix-only (cfg-gated; Windows builds get a stub that errors with "use WSL").

Shell/Python helpers (in `share/skills/aisync-ship/scripts/`, also distributed as a Claude Code skill via `share/skills/aisync-ship/SKILL.md`):

- **`ship.sh`** — Push / `--pull` orchestrator. Stages local `~/.claude` via `tar | tar`, runs transformations, calls `fanout.py` for cross-tool fan-out, ships everything via `tar | ssh tar` + `install-remote.sh`. Defaults to `--dry-run`; `--apply` (or `--yes`/`AISYNC_SHIP_YES=1` for headless) commits.
- **`fanout.py`** — `~/.claude` → other agent CLI user_dirs. Mirrors `platforms.rs` map. Marker-based delete propagation preserves user-authored target files.
- **`transform-settings.py`** — JSON-aware transform of `settings.json`/`.mcp.json`: strips local-bound hooks/MCP servers, rewrites paths (`--reverse` for pull direction).
- **`install-remote.sh`** — POSIX sh script that runs on the remote inside a mode-700 tmpdir. Atomic mv-swap with cross-platform restore-on-error rollback, marker-based delete with path-traversal validation.
- **`extract-credentials.sh`** — macOS Keychain → JSON / Linux `.credentials.json`. NOT invoked by default (per-machine `claude login` is the contract).

### Key data flow

```
.agents/AGENTS.md   →  CLAUDE.md, AGENTS.md, GEMINI.md, .cursorrules, ...
.agents/rules/*.md  →  .claude/rules/*.md, .cursor/rules/*.mdc, .github/instructions/*.instructions.md, ...
.agents/skills/*.md →  .claude/skills/*/SKILL.md, .codex/skills/*/SKILL.md, .gemini/skills/*/SKILL.md
.agents/agents/*.md →  .claude/agents/*.md (recursive — supports subdirectories)
.agents/platforms/claude/{settings.json,.mcp.json,hooks/,plugins/,output-styles/} → ~/.claude/
```

Skills use directory format (`<name>/SKILL.md`) for Claude Code, Codex, and Gemini. The `skills_as_dir` flag in `Platform` controls this conversion. Platform-specific extras (settings, hooks, plugins) are stored under `.agents/platforms/<name>/` and synced via `extra_files`/`extra_dirs` fields. Build artifacts (`node_modules`, `target`, `cache`, etc.) are auto-skipped.

### Adding a new platform

Add a `Platform` struct entry to the `PLATFORMS` array in `src/platforms.rs`. The sync engine picks it up automatically — no other changes needed.

## Distribution

- **npm**: `npm/` directory contains a wrapper package that downloads the binary via `postinstall` (`npm/install.js`)
- **Homebrew**: Separate tap repo `EvanL1/homebrew-aitoolsync`, auto-updated by release workflow
- **Shell script**: `install.sh` for curl-pipe-bash install
- **GitHub Releases**: Cross-compiled binaries for macOS (x86_64/aarch64), Linux (x86_64/aarch64), Windows (x86_64)

## CI/CD

- **CI** (`.github/workflows/ci.yml`): `cargo check` + `cargo clippy` + `cargo test` on push/PR to master
- **Release** (`.github/workflows/release.yml`): Triggered by `v*` tags. Builds 5 platform targets, creates GitHub release, publishes to npm, updates Homebrew formula
