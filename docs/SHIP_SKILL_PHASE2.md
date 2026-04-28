# `aisync ship` Phase 2 — design notes

**Status**: Proposal
**Date**: 2026-04-28
**Predecessors**: `docs/SHIP_SKILL_DESIGN.md` (Phase 1 plan), commits `46661f2..3210ac1` (Phase 1 + cross-tool fan-out + 8 rounds of Codex review fixes)
**Real-world validation**: `ship.sh --apply --also codex,gemini evan@192.168.70.27` succeeded 2026-04-28; `~/.claude` replace + `~/.codex`/`~/.gemini` merge worked, `~/.codex` private state (auth.json, config.toml, sessions/, memories/, history.jsonl) preserved, codex-cli on the remote correctly enumerated the fanned-out skills/rules.

---

## 1. What Phase 1 left on the table

Issues Codex flagged as **by-design Phase 1 trade-offs**, not bugs — Phase 2 should resolve them:

1. **Subtree-replace is a blunt instrument** (Codex P2.1 in adversarial review). Today, fan-out claims ownership of *every* file inside `rules/`, `skills/`, `agents/` for any platform you `--also`. A rule the user wrote by hand against codex specifically gets deleted. The user's only escape is "don't fan out to that platform" or "move the rule into `~/.claude/rules/` first".
2. **Newly-created intermediate dirs are not rolled back** on failure (`mkdir -p $(dirname dest)` in install-remote.sh). E.g. if `~/.codeium/` did not pre-exist and `.codeium/windsurf` install fails before completing, the empty `~/.codeium/` directory is left behind.
3. **`.partial` snapshots are diagnostic garbage**, never garbage-collected. Documented as manual cleanup in SKILL.md, but should self-clean.
4. **No `--mirror` mode for `.claude` itself**. ship.sh's replace mode does atomic mv-swap → backup, then leaves backup forever. After 5 syncs the remote has `.claude.bak.<ts>` × 5 piling up.
5. **No reverse sync (`--pull`)**. Original Phase 3 plan; still not done.
6. **No CI/headless mode**. `confirm_apply` requires interactive `y`. Pipelines need `--yes`.

Issues Phase 1 didn't really address:

7. **No detection of source-side machine-specific paths beyond known macOS-only roots**. transform-settings.py warns on `/Users/<u>/Documents/`-style paths but doesn't help the user *fix* them. Phase 2 could surface these in the dry-run plan and offer canned rewrites.
8. **No verification that the remote-staged files actually match what `--apply` will install**. The dry-run stage and apply stage are two separate runs; in between, source could change.

---

## 2. Phase 2 scope (proposed, prioritized)

### Tier 1 — Correctness/safety improvements

**A. Managed-marker file for fan-out (`Codex P2.1`)**

Per platform, write a hidden marker `~/.codex/.aisync-ship-managed.json` listing paths fan-out installed last run. On the next fan-out:
- Files in marker AND not in current source → **delete** (drift propagation)
- Files in marker AND still in current source → overwrite as today
- Files in current source NOT in marker → install + add to next marker
- Files NOT in marker AND NOT in current source → leave alone (user-authored)

This eliminates the "fan-out claims the whole rules/ subtree" problem. Manual user-authored rules in `~/.codex/rules/` survive — fan-out only touches files it previously installed.

Manifest format extension: `<stage_subpath>\t<home_subpath>\tmerge\t<owned_subtrees_csv>\t<marker_file_path>`.

**B. Rollback orphan dirs (`Phase 1 limitation #2`)**

Track every `mkdir -p $(dirname dest)` that succeeded but where `dest` itself failed to install. Roll those back too (rmdir, which only removes empty dirs — safe).

**C. `.partial` GC (`Phase 1 limitation #3`)**

`install-remote.sh` cleans `<dest>.bak.*.partial` from previous runs at start. Same script also adds optional `--gc-old-backups N` to keep only the most recent N timestamped `.bak.*` per platform.

### Tier 2 — UX & operability

**D. Headless mode**

`ship.sh --yes` skips confirm_apply. Documented as "for CI / scripted use only". CI users can also pre-set `AISYNC_SHIP_YES=1` env var.

**E. Dry-run includes "deletion preview"**

Today the dry-run plan shows the file count and unified diff of settings.json. Phase 2 also lists exact paths that will be deleted on the remote (computed from manager marker × current source).

**F. Smoke-test integrated**

After successful `--apply`, run the suggested smoke test automatically: `ssh -n target 'claude --version'` (and equivalents for codex/gemini if `--also` covered them) and report exit codes.

### Tier 3 — Reverse direction

**G. `ship.sh --pull <source>`**

Tar-pipe in reverse: `ssh source 'tar -C ~/.claude czf - .' | tar -C ~/.claude -xzf -`, with the same exclude list and the same transform-settings.py applied locally. Useful for "I just provisioned a new machine, copy my home machine's setup down".

### Tier 4 — Phase 3 collapse into Rust CLI

**H. `aitoolsync ship` Rust subcommand**

Now that Phase 1 has stable interfaces (`fanout.py` → manifest TSV → `install-remote.sh`), port the orchestrator to Rust:
- Re-export the platform map from `src/platforms.rs` to Python via JSON dump (no more duplicated dict in fanout.py).
- Or: keep helpers as embedded scripts in the Rust binary (`include_str!`), unpack to a tmp dir at runtime.
- Or: the Rust CLI just shells out to the helpers (thin wrapper); skill remains primary UX.

Trade-off: collapsing into Rust gains type-safety + single source of truth for platform mappings. Costs: the helpers stop being editable without `cargo build`. Defer this until Phase 1 helpers have lived in production for a while and we know which lines actually need to change.

---

## 3. Estimated effort

| Item | Effort | Dependency |
|---|---|---|
| A. Managed-marker | 1-2 days | Touches fanout.py + install-remote.sh + new on-disk format |
| B. Rollback orphan dirs | 0.5 day | install-remote.sh only |
| C. .partial GC | 0.5 day | install-remote.sh only |
| D. Headless mode | 0.5 day | ship.sh only |
| E. Deletion preview | 0.5 day | Depends on A (managed marker computes the diff) |
| F. Auto smoke-test | 0.5 day | ship.sh only |
| G. `--pull` | 1 day | New transfer direction; reuses transforms |
| H. Rust port | 2-3 days | Touches src/, requires Phase 2 interfaces stable |

Total Tier 1 + Tier 2 + Tier 3: ~5 days.

---

## 4. Out of scope (still)

- **Multi-target parallel push**: still v3+. Single target works fine for almost all use cases.
- **Differential sync**: still N/A. tar-full + atomic mv beats rsync-diff for correctness; size has not been a problem (1.3 MB staged).
- **Encryption**: ssh handles transport; no app-layer crypto.
- **Windows host**: WSL covers it; native Win32 cmd.exe transfer is uninteresting.

---

## 5. Validation plan for Phase 2

Reuse the Phase 1 test pattern: each new feature ships with a local-simulation test (mocked HOME, no SSH) + one real `--apply` against a known-state remote. Specifically:

- A: place a manual `~/.codex/rules/manual.md` on the remote, run fan-out twice (with and without source-side change), verify manual.md survives both
- B: kill install-remote.sh after `mkdir -p` but before mv, verify orphan dir is cleaned
- C: leave 5 `.partial` from forced failures, run install, verify GC reduces to 0
- D: `AISYNC_SHIP_YES=1 ship --apply ...` runs through with no prompt
- E: dry-run plan includes a "Will delete on remote: …" section
- F: post-apply smoke runs the codex equivalent of `claude --version` automatically
- G: `--pull` from staging machine, diff stays at 0 if source already matched
