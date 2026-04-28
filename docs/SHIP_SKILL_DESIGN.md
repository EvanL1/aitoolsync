# `aisync ship` — 用户级配置跨机器同步设计

**Status**: Proposal
**Date**: 2026-04-28
**Author**: 来自一次手动同步 `~/.claude/` 到内网另一台 Linux 机器的实战复盘

---

## 1. Why this exists

aisync 0.4 解决的是 **"同一台机器上,不同 AI 工具之间的规则文件"** 同步(`.agents/` → Claude/Codex/Gemini/Cursor/Copilot/...)。

它**不解决** **"同一个 AI 工具,跨机器整套配置"** 同步(macOS 的 `~/.claude/` → Linux 的 `~/.claude/`)。

后者是工程师在多机环境下的高频痛点 —— 笔记本、内网工作站、远程 dev box,每加一台机器都要重新走一遍 `claude login` + 手动 copy 配置 + 改路径。

这次手动从 macOS `~/.claude/` 同步到 `evan@192.168.70.27` (Ubuntu) 暴露了一组系统性痛点,值得做成 aisync 的一类新能力。

---

## 2. 痛点清单(实战采集)

按工程价值排序,每条括号里是这次踩到的具体证据:

| # | 痛点 | 证据 | 价值 |
|---|---|---|:-:|
| 1 | **目标端零依赖** | rsync 失败,因为远程 Ubuntu 没装 rsync。tar+ssh 才跑通 | ★★★ |
| 2 | **凭证存储跨平台异质** | macOS 在 Keychain,Linux 在 `~/.claude/.credentials.json`。盲目同步 `~/.claude/` 会丢登录 | ★★★ |
| 3 | **跨平台路径硬编码** | `settings.json` 里 9 处 `/Users/evan/...`,`.mcp.json` 里 PATH/proxy/cwd 全是 macOS 路径 | ★★★ |
| 4 | **本机绑定的副作用 hook** | 9 处 hook 引用本机 shell 脚本,7 处 HTTP hook 指向 localhost:18522,3 处 plugin/mcp 注册引用本机自建 marketplace | ★★ |
| 5 | **配置/运行时混在 `~/.claude/`** | `sessions/`, `history.jsonl`(3.7MB), `session-env/`(12115 文件), 各类 cache 必须 exclude,否则慢且泄露隐私 | ★★ |
| 6 | **远程独有内容的"叠加污染"** | tar/rsync 默认 merge 模式,目标端 41 项 skills 子目录 + 8557 项 plugin cache 是历史残留,看着对齐实则脏 | ★★ |
| 7 | **AppleDouble `._*` 污染** | macOS → Linux 带过去 9290 个 `._*` 元数据垃圾 | ★ |
| 8 | **rsync 跨平台版本不兼容** | macOS 自带 2.6.9 不支持 `--info=`,远程没装 rsync | ★ |
| 9 | **凭证文件权限要求** | Linux `.credentials.json` 必须 0600,否则 Claude Code 拒绝读 | ★ |

---

## 3. 核心洞察:为什么是 skill 而不是 CLI

把这件事做成 `aisync ship` Rust 子命令是**直觉但次优**的方案。做成 Claude Code skill 在两个维度上更优:

### 3.1 Skill 自我复制,破解鸡生蛋问题

CLI 模式:
```
源端 → ssh + rsync/scp → 目标端
                          ↑
                          需要装 rsync 或 aisync,鸡生蛋
```

Skill 模式:
```
源端 Claude → tar+ssh → 目标端 ~/.claude/ (skill 文件随之同步)
                          ↑
                          目标端获得 aisync-ship skill,自动具备同步能力
```

**Skill 是"被同步的内容"的一部分**,所以第一次 ship 完成后,目标机器免费获得同步能力。无须独立分发。

### 3.2 Transformation 决策本就是 LLM 判断

这次同步过程中,Claude 做了大量**语义判断**:

- 识别 `cat | /Users/evan/dev/sweatshop/bin/ensure-bridge.sh` 是"本机绑定的 hook" → 应剔除
- 识别 `127.0.0.1:18522` 是"localhost 服务" → 远程跑没意义
- 识别 `plugins/cache/` 下 8557 项是 cache 而非真正的 skill → 可清空
- 识别 `session-env/` 12115 文件是运行时数据 → 必须 exclude
- 识别 `settings.json` 里 `mcpServers.sweatshop` 是 sweatshop 项目 MCP server 而非通用 MCP → 应一并删

把这些规则**硬编码进 Rust binary** 会面对维护噩梦:每出一个新 plugin/marketplace,规则要更新一次。把它们**留给 LLM 判断 + skill 提供"必查清单 + helper script"**,弹性强得多。

### 3.3 不是非此即彼

skill 是 primary UX,CLI 仍保留作为 CI/无 Claude 环境的兜底:

| 场景 | 推荐入口 |
|---|---|
| 用户在 Claude Code 里说"把配置同步到 192.168.70.27" | **skill** |
| GitHub Action 里跨环境同步 | aisync ship CLI |
| 脚本/cron | CLI |
| 需要 LLM 判断 transformation | skill |

底层都调一组**共享的 helper script**(`tar`, `ssh`, `python3`, `security`),不是两套实现。

---

## 4. Skill 形态设计

### 4.1 目录布局(plugin 内)

```
ai-sweatshop-aisync/                  # 暂用此 plugin 名,可改
├── .claude-plugin/
│   └── plugin.json
├── skills/
│   └── aisync-ship/
│       ├── SKILL.md                  # 主入口,LLM 读这个
│       ├── checklist.md              # 必查项清单(LLM 引用)
│       └── scripts/
│           ├── extract-credentials.sh    # macOS Keychain → JSON
│           ├── plan-transform.py         # 列出要做的 transformation,JSON 输出
│           ├── ship.sh                   # tar 打包 + ssh 传输 + 远程解压
│           └── audit-remote.sh           # 列出"远程独有"清单(供 mirror 模式用)
└── README.md
```

### 4.2 `SKILL.md` 核心内容(草稿)

```markdown
---
name: aisync-ship
description: Use when the user wants to copy/sync their Claude Code configuration (~/.claude/) from this machine to another machine over SSH. Handles credentials, path rewriting, hook portability, and runtime-data isolation.
tools: Read, Bash, Edit
---

# aisync-ship

Sync user-level Claude Code configuration to a remote machine, **target machine zero-dependency** (only ssh + tar + sh required).

## Trigger

User says: "把配置同步到 evan@x.x.x.x", "ship my Claude setup to ...", "let me login to Claude on machine Y", or similar.

## Pre-flight checklist (MUST execute before transferring)

1. **Reachability**: `ssh -o BatchMode=yes -o ConnectTimeout=5 <target> 'uname -a && which tar'`
2. **Claude Code installed?**: `ssh <target> 'command -v claude'` — if missing, warn user, do NOT proceed by default
3. **Existing remote config?**: `ssh <target> 'ls -la ~/.claude/ 2>/dev/null'` — if exists, plan to back up before overwrite

## Transformation rules (apply BEFORE sending)

For each rule, scan the matching files and either rewrite or remove. Use scripts/plan-transform.py and report the plan to the user before executing (NEVER apply silently).

| Rule | Source | Action |
|---|---|---|
| Path rewrite | settings.json, .mcp.json | `/Users/<u>` → `/home/<u>` (POSIX-Linux assumption) |
| Local-bound hook commands | settings.json hooks[].command | If references local path / 127.0.0.1 / non-portable bin → remove the hook entry |
| Local MCP server bound to disk | settings.json/.mcp.json mcpServers.* | If args contains absolute path on local fs that won't exist remotely → remove or warn |
| Runtime data | sessions/, history.jsonl, session-env/, *cache*, telemetry/, projects/ | exclude from tarball |
| AppleDouble | `._*` files | exclude from tarball |
| Credentials | macOS Keychain `Claude Code-credentials` | extract via `security`, deliver as ~/.claude/.credentials.json (mode 0600) |

## Decision points (require user confirmation)

- **Mirror mode** (delete remote-only files): default OFF. Ask user. If ON, run scripts/audit-remote.sh and confirm deletion list.
- **Include credentials**: default ON for first-time setup, OFF for re-sync. Ask if ambiguous.
- **Plugin cache cleanup**: ~/.claude/plugins/cache/ on remote can be wiped; ask before doing.

## Execution flow

1. plan = scripts/plan-transform.py --target <user@host>
2. Show plan to user, get confirmation
3. scripts/ship.sh executes the plan
4. Post-ship verify: `ssh <target> 'claude --version && ls ~/.claude/.credentials.json'`
5. Suggest user run `echo hi | claude -p "say hi"` from target as smoke test

## Anti-patterns

- DO NOT use scp/rsync of entire ~/.claude/ — captures sessions/history (privacy) and session-env (12K+ files, slow)
- DO NOT silently rewrite settings.json — always show diff to user
- DO NOT skip credentials transformation on macOS — Keychain entries are not in the filesystem
- DO NOT assume target has rsync — use `tar | ssh tar` pipe
```

### 4.3 Helper scripts(职责切分)

每个脚本职责单一,可独立测试:

- **`extract-credentials.sh`**: 平台感知。macOS 用 `security find-generic-password -s 'Claude Code-credentials' -w` 输出 JSON,Linux 直接 `cat ~/.claude/.credentials.json`。失败时退出码非零,LLM 接住。
- **`plan-transform.py`**: 读 `~/.claude/settings.json` 和 `.mcp.json`,递归扫描所有 string,输出 JSON `{"path_rewrites":[...], "hooks_to_remove":[...], "mcp_servers_to_remove":[...], "files_excluded":[...], "estimated_size":"..."}`。LLM 决定是否要把额外项加入(语义判断)。
- **`ship.sh`**: 接受 plan(stdin JSON)+ target arg,做 transformation 在 `/tmp` 里生成 staged 目录,然后 `tar czf - -C /tmp/staged . | ssh <target> 'tar xzf - -C ~/.claude'`,最后 ssh 设权限。
- **`audit-remote.sh`**: 在 mirror 模式下,远程跑 `find ~/.claude -mindepth 1 -maxdepth 4`,本地用 `comm -23` 找差集,输出"远程独有"清单。

### 4.4 Plugin 打包(分发)

把这个 skill 通过 plugin 系统分发,用户用一句:

```bash
claude plugin add aisync-ship --from EvanL1/ai-sync-ship
```

或者更进一步,把 skill 直接放进 `aitoolsync` npm/cargo 包的 `share/skills/` 子目录,由 aisync CLI 提供 `aisync skill install` 命令,这样 CLI 和 skill 互为补充。

---

## 5. 与现有 aisync CLI 的关系

### 5.1 不是替代,是新维度

| | aisync sync | aisync ship (新) |
|---|---|---|
| 同步内容 | 项目级 `.agents/` 规则 | 用户级 `~/.claude/` 整套 |
| 跨工具 fan-out | 是(Claude/Codex/Gemini/Cursor/...) | 否(只 Claude Code) |
| 跨机器 | 通过 `serve`/`pull` | 是,**核心特性** |
| transformation | 文件名/扩展名转换 | 路径重写、hook 剔除、凭证桥接 |
| 目标端依赖 | 需要 aisync(`pull`)或 rsync(`remote push`) | **零依赖**(ssh + tar) |

### 5.2 共享底层

Helper script(`extract-credentials.sh`, `ship.sh`, `audit-remote.sh`)同时被 skill 和 CLI 调用:

```
aisync ship target            # CLI 入口,直接跑 helper
                              ↓
[ helper scripts in share/ ]  # 复用
                              ↑
SKILL.md                      # skill 入口,LLM 编排 + 跑 helper
```

CLI 路径走"硬规则 + 默认值";skill 路径走"LLM 判断 + 用户确认"。

### 5.3 Rust 还是 Bash/Python?

helper 故意用 **bash + python3** 而非 Rust,因为:

1. 这些工具在任何 Unix 都自带(target 端如果只跑 helper 也能跑)
2. 修改门槛低,贡献者无需 cargo build
3. 和 skill 形态一致(skill 内嵌 script 通常都是 shell/python)

aisync CLI 主体仍 Rust,但 ship 这块走 helper 路线 —— **skill 是 primary,CLI 是 thin wrapper around helpers**。

---

## 6. 实现路径(MVP → 完整)

### Phase 1: MVP (1-2 天)

- 写 `extract-credentials.sh`(macOS only)
- 写 `ship.sh` 最小版:hardcoded exclude list,sed-based 路径替换,tar+ssh 传输
- 写 `SKILL.md` 主体
- 测试:从这台 macOS ship 到 192.168.70.27 复现这次手动流程

### Phase 2: Transformation engine (2-3 天)

- 写 `plan-transform.py` JSON 输出格式
- skill 调 plan-transform 后展示给用户,确认再执行
- 加入 mirror mode + audit-remote.sh

### Phase 3: 反向同步 + CLI 兜底 (2-3 天)

- `aisync ship --pull <source>`:从远程拉回(用于"在新机器上反向同步原机配置")
- aisync Rust CLI 加 `cmd_ship` 子命令,thin wrapper
- 文档 + 测试

### Phase 4: Plugin 分发

- `.claude-plugin/plugin.json` 打包
- 注册 marketplace
- npm package 嵌入 skill 文件

---

## 7. 边界与风险

### 不在 scope 内

- **Windows 支持**: 暂不考虑(Claude Code on Windows 用法很少,WSL 走 Linux 路径)
- **多目标并发推送**: v1 单 target,后续可加
- **增量同步**: tar 全量,不做差量。简单优先,目标端零依赖也排除了 rsync
- **加密/签名**: 走 ssh,信任传输层。不额外加密 tarball

### 风险点

| 风险 | 缓解 |
|---|---|
| settings.json transformation 误删用户自定义 hook | 默认 dry-run,显示 diff,用户确认 |
| Keychain 提取失败(权限/锁屏) | 检查退出码,提示用户解锁 |
| 远程已有配置被覆盖 | 自动备份 `*.bak.<timestamp>`,我们这次也是这么做的 |
| OAuth token 同时在两台机用导致 rate limit 或风控 | 文档说明:同账号同 token 在 Anthropic 后端是同会话配额,不冲突;若担心可远程跑后 source 端 logout |
| skill 描述不够精准导致误触发 | description 显式列出"用户 → 远程机器"语义,trigger 列举中英文示例 |

---

## 8. 评估指标

ship skill 是否成功的判据:

1. **冷启动 ship 流程总耗时** < 3 分钟(从用户说"同步到 X" 到目标机能跑 `claude -p "hi"`)
2. **目标端预装** 只要求 ssh + tar(覆盖 macOS / 主流 Linux 默认)
3. **transformation 准确率** 100%(不引入 broken hook,不误删用户自定义)
4. **隐私数据零泄露** sessions/history 永不离开源端
5. **skill 自我复制可达** 第一次 ship 后,目标机器自动具备 ship 能力
