# aitoolsync

[![CI](https://github.com/EvanL1/aitoolsync/actions/workflows/ci.yml/badge.svg)](https://github.com/EvanL1/aitoolsync/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

[English](README.md) | 中文

一条命令，将 AI 编程助手的配置同步到 **Claude Code、Codex、Gemini CLI、Cursor、Copilot、Windsurf 和 Cline** 七个平台。

```
.agents/          →    CLAUDE.md             (Claude Code)
├── AGENTS.md     →    AGENTS.md             (Codex CLI)
├── rules/        →    GEMINI.md             (Gemini CLI)
├── skills/       →    .cursor/rules/*.mdc   (Cursor)
└── agents/       →    .github/instructions/ (Copilot)
                  →    .windsurf/rules/      (Windsurf)
                  →    .clinerules           (Cline)
```

**一份源文件，七个平台，零配置。**

## 痛点

你在 Claude Code 里维护 `CLAUDE.md`，在 Cursor 里写 `.cursorrules`，Copilot 又要 `copilot-instructions.md`……改了一个忘了另外几个。新同事加入时，一半的配置已经过时了。

`aisync` 解决这个问题：在 `.agents/` 里写一次规则，一条命令同步到所有平台。文件扩展名自动转换（`.md` → Cursor 的 `.mdc`，Copilot 的 `.instructions.md`）。

## 安装

### npm（推荐）

```bash
npm install -g aitoolsync
```

### Cargo

```bash
cargo install --git https://github.com/EvanL1/aitoolsync
```

### Homebrew（macOS / Linux）

```bash
brew tap EvanL1/aitoolsync
brew install aisync
```

### Shell 脚本（macOS / Linux / WSL）

```bash
curl -fsSL https://raw.githubusercontent.com/EvanL1/aitoolsync/master/install.sh | bash
```

### 手动下载

从 [Releases](https://github.com/EvanL1/aitoolsync/releases) 下载：

| 平台 | 文件 |
|------|------|
| macOS Apple Silicon | `aisync-darwin-aarch64.tar.gz` |
| macOS Intel | `aisync-darwin-x86_64.tar.gz` |
| Linux x86_64 | `aisync-linux-x86_64.tar.gz` |
| Linux ARM64 | `aisync-linux-aarch64.tar.gz` |
| Windows x64 | `aisync-windows-x86_64.zip` |

## 快速开始

```bash
aisync init                  # 创建 .agents/ 目录和初始 AGENTS.md
aisync import claude         # 导入现有的 Claude Code 配置（可选）
# 编辑 .agents/AGENTS.md 和 .agents/rules/
aisync sync                  # 同步到全部 7 个平台
```

**完成。** 你的规则现在在所有平台都生效了。

## 日常工作流

```bash
# 写一次规则
vim .agents/rules/code-style.md

# 同步到所有 AI 工具（~2ms）
aisync sync

# 写入前先预览（安全模式）
aisync sync --dry-run

# 只同步特定平台
aisync sync cursor copilot

# 提交所有文件 — 源文件 + 生成的配置
git add .agents/ .claude/ .cursor/ .github/
git commit -m "chore: update AI agent rules"
```

## 源目录结构

```
.agents/
├── AGENTS.md          # 根指令 → 同步为每个平台的约定文件名
├── rules/             # 共享规则（按平台自动转换扩展名）
│   ├── coding-style.md    → .claude/rules/coding-style.md
│   ├── coding-style.md    → .cursor/rules/coding-style.mdc
│   └── coding-style.md    → .github/instructions/coding-style.instructions.md
├── skills/            # 共享技能/命令
│   └── review.md          → .claude/commands/review.md
└── agents/            # 共享 Agent 定义
    └── planner.md         → .claude/agents/planner.md
```

## 平台映射表

| 平台 | 根文件 | 规则目录 | 规则扩展名 | 技能目录 |
|------|--------|----------|------------|----------|
| **Claude Code** | `CLAUDE.md` | `.claude/rules/` | `.md` | `.claude/commands/` |
| **Codex CLI** | `AGENTS.md` | — | — | — |
| **Gemini CLI** | `GEMINI.md` | — | — | — |
| **Cursor** | `.cursorrules` | `.cursor/rules/` | `.mdc` | — |
| **Copilot** | `.github/copilot-instructions.md` | `.github/instructions/` | `.instructions.md` | — |
| **Windsurf** | `.windsurfrules` | `.windsurf/rules/` | `.md` | — |
| **Cline** | `.clinerules` | — | — | — |

`AGENTS.md` 始终会同步到项目根目录，作为[通用标准](https://agents.md/)。

## 命令

```bash
aisync init                    # 创建 .agents/ 源目录
aisync import <platform>       # 导入现有平台配置到 .agents/
aisync sync [platform...]      # 同步到所有（或指定的）平台
aisync sync --dry-run          # 预览将会同步的内容
aisync user                    # 同步到用户级配置（~/.claude/ 等）
aisync status                  # 显示源和目标状态
aisync platforms               # 列出支持的平台
```

## 生成的文件需要提交吗？

**需要。** 同时提交 `.agents/`（你的源文件）和生成的平台配置文件（`.claude/`、`.cursor/`、`.github/` 等）。它们都只是 markdown 文件——没有二进制文件，没有构建产物。这样每个团队成员和 CI 环境都能拿到正确的配置，无需安装 aitoolsync。

## 工作原理

1. **读取** `.agents/` 源目录中的 `.md` 文件
2. **转换** 文件扩展名（`.md` → Cursor 的 `.mdc`，Copilot 的 `.instructions.md`）
3. **写入** 到每个平台期望的目录
4. **根文件** 按平台命名复制（`AGENTS.md` → `CLAUDE.md`、`GEMINI.md` 等）

不依赖 git hooks、npm、配置文件或任何运行时。只是一个单独的二进制文件（执行时间 ~2ms）。

## 对比

| | aitoolsync | ai-rules-sync |
|---|---|---|
| 依赖 | **零**（单一二进制） | Node.js + npm |
| 需要配置 | **零** | git 仓库 + JSON |
| 扩展名转换 | **自动** | 手动 |
| 平台数 | 7 | ~10 |
| 速度 | **~2ms** | ~500ms |

## 参与贡献

```bash
git clone https://github.com/EvanL1/aitoolsync
cd aitoolsync
cargo build
cargo test
```

欢迎 PR！如需添加新平台，编辑 `src/platforms.rs`——每个平台就是一个 struct。

## 许可证

MIT
