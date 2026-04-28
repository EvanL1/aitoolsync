#!/usr/bin/env bash
# Integration tests for install-remote.sh — exercises the merge/replace
# state machine with real filesystem ops in mock $HOME directories.
# No SSH involved (install-remote.sh runs locally; that's the whole point
# — it works the same on remote because it reads from $HOME).
#
# Run: ./tests/test_install_remote.sh
# CI:  bash tests/test_install_remote.sh

set -euo pipefail

REPO=$(cd "$(dirname "$0")/.." && pwd)
INSTALL=$REPO/share/skills/aisync-ship/scripts/install-remote.sh
[ -x "$INSTALL" ] || { echo "FATAL: $INSTALL not executable"; exit 2; }

PASS=0
FAIL=0
CASES=()

assert_eq() {
  local actual="$1" expected="$2" label="$3"
  if [ "$actual" = "$expected" ]; then
    PASS=$((PASS + 1))
    CASES+=("  ✓ $label")
  else
    FAIL=$((FAIL + 1))
    CASES+=("  ✗ $label  expected=[$expected] actual=[$actual]")
  fi
}

assert_file_present() {
  if [ -e "$1" ]; then
    PASS=$((PASS + 1)); CASES+=("  ✓ $2 present")
  else
    FAIL=$((FAIL + 1)); CASES+=("  ✗ $2 MISSING ($1)")
  fi
}

assert_file_absent() {
  if [ ! -e "$1" ]; then
    PASS=$((PASS + 1)); CASES+=("  ✓ $2 absent")
  else
    FAIL=$((FAIL + 1)); CASES+=("  ✗ $2 STILL PRESENT ($1)")
  fi
}

run_install() {
  local tmp="$1"
  HOME="$tmp/fake-home" sh "$INSTALL" "$tmp/manifest.tsv" "$tmp/stage" 2>&1
}

mk_tmp() {
  local d
  d=$(mktemp -d)
  echo "$d"
}

# ---------------------------------------------------------------------------
# Test 1: merge mode preserves dest non-owned files
# ---------------------------------------------------------------------------
test_merge_preserves_non_owned() {
  echo "== test_merge_preserves_non_owned =="
  local TMP; TMP=$(mk_tmp)
  mkdir -p "$TMP/fake-home/.codex"
  echo "real-config" > "$TMP/fake-home/.codex/config.toml"
  echo "real-auth" > "$TMP/fake-home/.codex/auth.json"
  mkdir -p "$TMP/stage/.codex"
  echo "new-AGENTS" > "$TMP/stage/.codex/AGENTS.md"
  printf '.codex\t.codex\tmerge\n' > "$TMP/manifest.tsv"
  run_install "$TMP" >/dev/null
  assert_file_present "$TMP/fake-home/.codex/config.toml" "config.toml preserved"
  assert_file_present "$TMP/fake-home/.codex/auth.json" "auth.json preserved"
  assert_file_present "$TMP/fake-home/.codex/AGENTS.md" "AGENTS.md installed"
  rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Test 2: replace mode atomic mv-swap
# ---------------------------------------------------------------------------
test_replace_atomic_swap() {
  echo "== test_replace_atomic_swap =="
  local TMP; TMP=$(mk_tmp)
  mkdir -p "$TMP/fake-home/.claude"
  echo "old" > "$TMP/fake-home/.claude/marker"
  mkdir -p "$TMP/stage/.claude"
  echo "new" > "$TMP/stage/.claude/marker"
  printf '.claude\t.claude\treplace\n' > "$TMP/manifest.tsv"
  run_install "$TMP" >/dev/null
  local content; content=$(cat "$TMP/fake-home/.claude/marker")
  assert_eq "$content" "new" "replace overwrote marker"
  # backup created
  # `|| true`: glob with no match → ls exits 1 → pipefail kills script
  local backups; backups=$(ls -d "$TMP/fake-home/.claude.bak."* 2>/dev/null | wc -l | tr -d ' ' || true)
  assert_eq "$backups" "1" "backup created"
  rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Test 3: rollback on multi-platform failure (replace + merge + bad-mode)
# ---------------------------------------------------------------------------
test_rollback_multi_platform_bad_mode() {
  echo "== test_rollback_multi_platform_bad_mode =="
  local TMP; TMP=$(mk_tmp)
  mkdir -p "$TMP/fake-home/.claude"
  echo "old-claude" > "$TMP/fake-home/.claude/marker"
  mkdir -p "$TMP/stage/.claude" "$TMP/stage/.codex" "$TMP/stage/.gemini"
  echo "new-claude" > "$TMP/stage/.claude/marker"
  echo "new-codex" > "$TMP/stage/.codex/AGENTS.md"
  printf '.claude\t.claude\treplace\n.codex\t.codex\tmerge\n.gemini\t.gemini\tBADMODE\n' \
    > "$TMP/manifest.tsv"
  if run_install "$TMP" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); CASES+=("  ✗ install should have failed (BADMODE)")
  else
    PASS=$((PASS + 1)); CASES+=("  ✓ install failed as expected (BADMODE)")
  fi
  local content; content=$(cat "$TMP/fake-home/.claude/marker")
  assert_eq "$content" "old-claude" "claude restored from backup"
  assert_file_absent "$TMP/fake-home/.codex" "newly-created .codex removed by rollback"
  rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Test 4: stale .partial GC
# ---------------------------------------------------------------------------
test_stale_partial_gc() {
  echo "== test_stale_partial_gc =="
  local TMP; TMP=$(mk_tmp)
  mkdir -p "$TMP/fake-home/.codex"
  echo "auth" > "$TMP/fake-home/.codex/auth.json"
  mkdir -p "$TMP/fake-home/.codex.bak.20260101-000000.partial/garbage"
  mkdir -p "$TMP/fake-home/.codex.bak.20260102-000000.partial/garbage"
  mkdir -p "$TMP/stage/.codex"
  echo "AGENTS" > "$TMP/stage/.codex/AGENTS.md"
  printf '.codex\t.codex\tmerge\n' > "$TMP/manifest.tsv"
  run_install "$TMP" >/dev/null
  local stale; stale=$(ls -d "$TMP/fake-home/".codex.bak.*.partial 2>/dev/null | wc -l | tr -d ' ' || true)
  assert_eq "$stale" "0" "stale .partial dirs garbage-collected"
  rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Test 5: orphan intermediate dir rmdir on rollback
# ---------------------------------------------------------------------------
test_orphan_intermediate_dir_rollback() {
  echo "== test_orphan_intermediate_dir_rollback =="
  local TMP; TMP=$(mk_tmp)
  mkdir -p "$TMP/fake-home"   # NO .codeium/
  mkdir -p "$TMP/stage/.codex" "$TMP/stage/.codeium/windsurf" "$TMP/stage/.gemini"
  echo "AGENTS" > "$TMP/stage/.codex/AGENTS.md"
  echo "rules" > "$TMP/stage/.codeium/windsurf/r.md"
  printf '.codex\t.codex\tmerge\n.codeium/windsurf\t.codeium/windsurf\tmerge\n.gemini\t.gemini\tBADMODE\n' \
    > "$TMP/manifest.tsv"
  run_install "$TMP" >/dev/null 2>&1 || true
  assert_file_absent "$TMP/fake-home/.codeium" "orphan ~/.codeium intermediate dir cleaned"
  rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Test 6: marker-based delete propagation
# ---------------------------------------------------------------------------
test_marker_based_delete() {
  echo "== test_marker_based_delete =="
  local TMP; TMP=$(mk_tmp)
  mkdir -p "$TMP/fake-home/.codex/rules" "$TMP/fake-home/.codex/skills/legacy"
  echo "auth" > "$TMP/fake-home/.codex/auth.json"
  echo "stale" > "$TMP/fake-home/.codex/rules/stale.md"
  echo "old-skill" > "$TMP/fake-home/.codex/skills/legacy/SKILL.md"
  echo "user-rule" > "$TMP/fake-home/.codex/rules/manual.md"
  printf '# v1\nAGENTS.md\nrules/stale.md\nskills/legacy/SKILL.md\n' \
    > "$TMP/fake-home/.codex/.aisync-ship-managed"
  mkdir -p "$TMP/stage/.codex/rules" "$TMP/stage/.codex/skills/newer"
  echo "AGENTS-new" > "$TMP/stage/.codex/AGENTS.md"
  echo "newer-rule" > "$TMP/stage/.codex/rules/newer.md"
  echo "newer-skill" > "$TMP/stage/.codex/skills/newer/SKILL.md"
  printf '# v1\nAGENTS.md\nrules/newer.md\nskills/newer/SKILL.md\n' \
    > "$TMP/stage/.codex/.aisync-ship-managed"
  printf '.codex\t.codex\tmerge\trules,skills\n' > "$TMP/manifest.tsv"
  run_install "$TMP" >/dev/null
  assert_file_present "$TMP/fake-home/.codex/rules/manual.md" "user-authored rule preserved"
  assert_file_present "$TMP/fake-home/.codex/auth.json" "non-owned auth.json preserved"
  assert_file_absent "$TMP/fake-home/.codex/rules/stale.md" "marker-tracked stale rule deleted"
  assert_file_absent "$TMP/fake-home/.codex/skills/legacy" "marker-tracked stale skill dir pruned"
  assert_file_present "$TMP/fake-home/.codex/rules/newer.md" "new rule installed"
  assert_file_present "$TMP/fake-home/.codex/skills/newer/SKILL.md" "new skill installed"
  rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Test 7: marker delete REJECTS path traversal
# ---------------------------------------------------------------------------
test_marker_delete_rejects_traversal() {
  echo "== test_marker_delete_rejects_traversal =="
  local TMP; TMP=$(mk_tmp)
  mkdir -p "$TMP/fake-home/.codex"
  mkdir -p "$TMP/innocent"
  echo "VICTIM" > "$TMP/innocent/victim.txt"
  printf 'AGENTS.md\n../../innocent/victim.txt\n/etc/passwd\n..\n' \
    > "$TMP/fake-home/.codex/.aisync-ship-managed"
  mkdir -p "$TMP/stage/.codex"
  echo "new" > "$TMP/stage/.codex/AGENTS.md"
  printf 'AGENTS.md\n' > "$TMP/stage/.codex/.aisync-ship-managed"
  printf '.codex\t.codex\tmerge\n' > "$TMP/manifest.tsv"
  local out; out=$(run_install "$TMP" 2>&1)
  assert_file_present "$TMP/innocent/victim.txt" "VICTIM survives traversal attempt"
  local rejected; rejected=$(printf '%s\n' "$out" | grep -c REJECTED || true)
  if [ "$rejected" -ge 3 ]; then
    PASS=$((PASS + 1)); CASES+=("  ✓ at least 3 REJECTED entries logged ($rejected)")
  else
    FAIL=$((FAIL + 1)); CASES+=("  ✗ expected ≥3 REJECTED entries, got $rejected")
  fi
  rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Test 8: snapshot fail leaves dest intact
# ---------------------------------------------------------------------------
test_snapshot_fail_dest_intact() {
  echo "== test_snapshot_fail_dest_intact =="
  local TMP; TMP=$(mk_tmp)
  mkdir -p "$TMP/fake-home/.codex/sessions"
  echo "auth" > "$TMP/fake-home/.codex/auth.json"
  echo "session" > "$TMP/fake-home/.codex/sessions/s.txt"
  chmod 000 "$TMP/fake-home/.codex/sessions"  # snapshot cp will fail
  mkdir -p "$TMP/stage/.codex"
  echo "AGENTS" > "$TMP/stage/.codex/AGENTS.md"
  printf '.codex\t.codex\tmerge\n' > "$TMP/manifest.tsv"
  if run_install "$TMP" >/dev/null 2>&1; then
    FAIL=$((FAIL + 1)); CASES+=("  ✗ install should have failed (snapshot)")
  else
    PASS=$((PASS + 1)); CASES+=("  ✓ install failed as expected (snapshot)")
  fi
  chmod 755 "$TMP/fake-home/.codex/sessions" 2>/dev/null
  assert_file_present "$TMP/fake-home/.codex/auth.json" "dest auth.json intact after snapshot fail"
  assert_file_absent "$TMP/fake-home/.codex/AGENTS.md" \
    "no apply happened (no AGENTS.md installed)"
  chmod -R 755 "$TMP" 2>/dev/null
  rm -rf "$TMP"
}

# ---------------------------------------------------------------------------
# Run all
# ---------------------------------------------------------------------------
# ---------------------------------------------------------------------------
# Test 9: --apply lock prevents concurrent runs
# ---------------------------------------------------------------------------
test_concurrent_lock_blocks_second_run() {
  echo "== test_concurrent_lock_blocks_second_run =="
  local SHIP=$REPO/share/skills/aisync-ship/scripts/ship.sh
  # Pre-create the lockdir to simulate a concurrent run holding it
  local fake_target="evan@unreachable.example"
  local safe; safe=$(printf '%s' "$fake_target" | tr -c 'a-zA-Z0-9._-' '_')
  local lock="${TMPDIR:-/tmp}/aisync-ship.${safe}.lock"
  mkdir -p "$lock"
  # Try to run --apply; ship.sh dies at acquire_lock (BEFORE preflight
  # so unreachable target doesn't even get ssh'd to). Capture output
  # first then grep — pipefail would mask grep's exit 0 with ship.sh's
  # exit 1.
  local out; out=$("$SHIP" --apply --yes --no-credentials "$fake_target" 2>&1 || true)
  if printf '%s' "$out" | grep -q "another aisync ship is already running"; then
    PASS=$((PASS + 1)); CASES+=("  ✓ second run blocked by lock")
  else
    FAIL=$((FAIL + 1)); CASES+=("  ✗ second run NOT blocked. Output: $out")
  fi
  rmdir "$lock" 2>/dev/null || true
}

test_merge_preserves_non_owned
test_replace_atomic_swap
test_rollback_multi_platform_bad_mode
test_stale_partial_gc
test_orphan_intermediate_dir_rollback
test_marker_based_delete
test_marker_delete_rejects_traversal
test_snapshot_fail_dest_intact
test_concurrent_lock_blocks_second_run

echo
echo "==================================="
echo "Results: $PASS passed, $FAIL failed"
echo "==================================="
printf '%s\n' "${CASES[@]}"
[ "$FAIL" -eq 0 ] || exit 1
