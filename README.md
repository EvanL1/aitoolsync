# agentsync

One command to sync your AI agent configs across **Claude Code, Codex, Gemini CLI, Cursor, Copilot, Windsurf, and Cline**.

```
.agents/          →    .claude/commands/     (Claude Code)
├── AGENTS.md     →    AGENTS.md             (Codex CLI)
├── rules/        →    GEMINI.md             (Gemini CLI)
├── skills/       →    .cursor/rules/*.mdc   (Cursor)
└── agents/       →    .github/instructions/ (Copilot)
                  →    .windsurf/rules/      (Windsurf)
                  →    .clinerules           (Cline)
```

**One source of truth. Seven platforms. Zero config.**

## Why

Every AI coding tool has its own config format:
- Claude Code: `.claude/commands/*.md`
- Cursor: `.cursor/rules/*.mdc`
- Copilot: `.github/instructions/*.instructions.md`
- Codex: just `AGENTS.md`
- Gemini: `GEMINI.md`

Maintaining 7 copies of the same rules is insane. `agentsync` reads from one `.agents/` directory and writes to all platforms, **auto-converting file extensions**.

## Install

### Cargo (all platforms)

```bash
cargo install --git https://github.com/EvanL1/agentsync
```

### Homebrew (macOS / Linux)

```bash
brew tap EvanL1/agentsync
brew install agentsync
```

### Shell script (macOS / Linux / WSL)

```bash
curl -fsSL https://raw.githubusercontent.com/EvanL1/agentsync/master/install.sh | bash
```

### Manual download

Download from [Releases](https://github.com/EvanL1/agentsync/releases):

| Platform | File |
|----------|------|
| macOS Apple Silicon | `agentsync-darwin-aarch64.tar.gz` |
| macOS Intel | `agentsync-darwin-x86_64.tar.gz` |
| Linux x86_64 | `agentsync-linux-x86_64.tar.gz` |
| Linux ARM64 | `agentsync-linux-aarch64.tar.gz` |
| Windows x64 | `agentsync-windows-x86_64.zip` |

## Quick Start

```bash
# 1. Initialize source directory
agentsync init

# 2. Import your existing Claude Code config
agentsync import claude

# 3. Edit .agents/AGENTS.md, add rules and skills

# 4. Push to all platforms
agentsync sync

# 5. Also sync user-level configs (~/.claude/, ~/.codex/, etc.)
agentsync user
```

**That's it.** Your rules now work in Claude Code, Codex, Gemini, Cursor, Copilot, Windsurf, and Cline.

## Source Layout

```
.agents/
├── AGENTS.md          # Root instructions → synced to each platform's convention
├── rules/             # Shared rules (auto-converted per platform)
│   ├── coding-style.md    → .claude/rules/coding-style.md
│   ├── coding-style.md    → .cursor/rules/coding-style.mdc
│   └── coding-style.md    → .github/instructions/coding-style.instructions.md
├── skills/            # Shared skills/commands
│   └── review.md          → .claude/commands/review.md
└── agents/            # Shared agent definitions
    └── planner.md         → .claude/agents/planner.md
```

## Platform Mapping

| Platform | Root MD | Rules Dir | Rules Ext | Skills Dir |
|----------|---------|-----------|-----------|------------|
| **Claude Code** | `CLAUDE.md` | `.claude/rules/` | `.md` | `.claude/commands/` |
| **Codex CLI** | `AGENTS.md` | — | — | — |
| **Gemini CLI** | `GEMINI.md` | — | — | — |
| **Cursor** | `.cursorrules` | `.cursor/rules/` | `.mdc` | — |
| **Copilot** | `.github/copilot-instructions.md` | `.github/instructions/` | `.instructions.md` | — |
| **Windsurf** | `.windsurfrules` | `.windsurf/rules/` | `.md` | — |
| **Cline** | `.clinerules` | — | — | — |

`AGENTS.md` is always synced to project root as the [universal standard](https://agents.md/).

## Commands

```bash
agentsync init                    # Create .agents/ source directory
agentsync import <platform>       # Import existing config into .agents/
agentsync sync [platform...]      # Sync to all (or specific) platforms
agentsync user                    # Sync to user-level (~/.claude/ etc.)
agentsync status                  # Show source and target status
agentsync platforms               # List supported platforms
```

## Examples

```bash
# Import from Claude, sync everywhere
agentsync import claude
agentsync sync

# Only sync to Codex and Gemini
agentsync sync codex gemini

# Check what would be synced
agentsync status

# Sync user-level configs for all platforms
agentsync user
```

## How It Works

1. **Read** `.agents/` source directory (`.md` files)
2. **Convert** extensions per platform (`.md` → `.mdc` for Cursor, `.instructions.md` for Copilot)
3. **Write** to each platform's expected directory
4. **Root MD** is copied with platform-specific naming (`AGENTS.md` → `CLAUDE.md`, `GEMINI.md`, etc.)

No git repos, no npm, no config files, no runtime dependencies. Just a single binary.

## vs alternatives

| | agentsync | ai-rules-sync | manual copy |
|---|---|---|---|
| Dependencies | **None** (single binary) | Node.js + npm | N/A |
| Config needed | **Zero** | git repo + JSON | N/A |
| Extension conversion | **Automatic** | Manual | Manual |
| Platforms | 7 | ~10 | ∞ |
| Install | One binary | `npm install -g` | N/A |
| Speed | **Instant** (~2ms) | ~500ms | Slow |

## Contributing

```bash
git clone https://github.com/EvanL1/agentsync
cd agentsync
cargo build
cargo test
```

## License

MIT
