#!/usr/bin/env bash
# ship.sh — sync ~/.claude/ to a remote host. Target needs only: ssh + tar + sh.
#
# Defaults to --dry-run (stages locally + prints plan). Pass --apply to transfer.
#
# Reproduces the manual 2026-04-28 macOS → Ubuntu sync:
#   credentials migration, path rewrite, sweatshop-hook stripping,
#   AppleDouble cleanup, runtime-data exclusion, atomic remote install.

set -euo pipefail

# ---- Configuration ----------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_DIR="${HOME}/.claude"

# tar exclude patterns (relative to SOURCE_DIR; covers files AND their
# children to be safe with both BSD and GNU tar).
TAR_EXCLUDES=(
  '--exclude=./sessions'           '--exclude=./sessions/*'
  '--exclude=./session-env'        '--exclude=./session-env/*'
  '--exclude=./projects'           '--exclude=./projects/*'
  '--exclude=./file-history'       '--exclude=./file-history/*'
  '--exclude=./paste-cache'        '--exclude=./paste-cache/*'
  '--exclude=./shell-snapshots'    '--exclude=./shell-snapshots/*'
  '--exclude=./debug'              '--exclude=./debug/*'
  '--exclude=./telemetry'          '--exclude=./telemetry/*'
  '--exclude=./usage-data'         '--exclude=./usage-data/*'
  '--exclude=./cache'              '--exclude=./cache/*'
  '--exclude=./downloads'          '--exclude=./downloads/*'
  '--exclude=./plans'              '--exclude=./plans/*'
  '--exclude=./tasks'              '--exclude=./tasks/*'
  '--exclude=./teams'              '--exclude=./teams/*'
  '--exclude=./plugins'            '--exclude=./plugins/*'
  '--exclude=./backups'            '--exclude=./backups/*'
  '--exclude=./history.jsonl'
  '--exclude=./stats-cache.json'
  '--exclude=./mcp-needs-auth-cache.json'
  '--exclude=./.credentials.json'
  '--exclude=._*'                  '--exclude=*/._*'
  '--exclude=.DS_Store'            '--exclude=*/.DS_Store'
)

# Files (relative to staging) that get path-rewrite + structural transforms.
TRANSFORM_FILES=(settings.json .mcp.json)

# ---- State (set by parse_args / preflight) ----------------------------------

MODE="dry-run"          # dry-run | apply
TARGET=""
INCLUDE_CREDS=0          # default OFF — user prefers each machine logs in itself
KEEP_STAGE=0
ALLOW_MISSING_CLAUDE=0
ALSO_PLATFORMS=""        # comma-separated, empty = no fan-out
REQUIRE_CLAUDE=0         # 1 = die when remote claude is missing (default: warn-only)
REMOTE_HOME=""
REMOTE_USER=""
REMOTE_EXISTING="no"
SRC_USER="$(id -un)"
STAGE_PARENT=""
STAGE_DIR=""

# ---- Helpers ----------------------------------------------------------------

log()  { printf '[ship] %s\n' "$*" >&2; }
warn() { printf '[ship][warn] %s\n' "$*" >&2; }
err()  { printf '[ship][error] %s\n' "$*" >&2; }
die()  { err "$*"; exit 1; }

usage() {
  cat <<'EOF'
Usage: ship.sh [OPTIONS] <user@host>

Sync ~/.claude/ to a remote machine over SSH. Target only needs ssh + tar + sh.

Options:
  --dry-run               Stage + show plan, do NOT transfer (default).
  --apply                 Confirm and execute the transfer.
  --include-credentials   Extract Keychain credential and ship it (default OFF;
                          opt-in only — preferred workflow is `claude login` on
                          each machine independently).
  --no-credentials        Explicitly skip credential extraction (the default).
  --also <list>           Also fan out ~/.claude → other agent CLI user dirs on
                          the remote. Comma-separated platform names (codex,
                          gemini, cursor, windsurf, cline). Hooks/settings/.mcp
                          are NOT fanned out (Claude-specific format).
  --keep-stage            Keep /tmp staging dir after --apply (default: clean).
  --source-dir <path>     Override source dir (default: $HOME/.claude).
  --allow-missing-claude  (Deprecated alias; warning is now the default.)
  --require-claude        Strict mode: refuse to ship when 'claude' is missing
                          on the remote. Default is to warn and proceed
                          (the contract is "ship the config, target only needs
                          ssh + tar + sh").
  --help                  Show this help.

Behavior on remote: install-remote.sh swaps in the new ~/.claude atomically
after backing up the existing one to ~/.claude.bak.<timestamp>. On any error
mid-install, the backup is rolled back automatically.
EOF
}

parse_args() {
  while (( $# > 0 )); do
    case "$1" in
      --dry-run) MODE="dry-run"; shift ;;
      --apply)   MODE="apply"; shift ;;
      --include-credentials) INCLUDE_CREDS=1; shift ;;
      --no-credentials)      INCLUDE_CREDS=0; shift ;;
      --keep-stage) KEEP_STAGE=1; shift ;;
      --source-dir) SOURCE_DIR="$2"; shift 2 ;;
      --allow-missing-claude) ALLOW_MISSING_CLAUDE=1; shift ;;
      --require-claude) REQUIRE_CLAUDE=1; shift ;;
      --also) ALSO_PLATFORMS="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown flag: $1 (try --help)" ;;
      *)  [[ -z "$TARGET" ]] || die "extra arg: $1"; TARGET="$1"; shift ;;
    esac
  done
  [[ -n "$TARGET" ]] || { usage >&2; exit 2; }
  [[ -d "$SOURCE_DIR" ]] || die "source dir not found: $SOURCE_DIR"
  [[ -f "${SCRIPT_DIR}/install-remote.sh" ]] \
    || die "missing companion script: ${SCRIPT_DIR}/install-remote.sh"
  [[ -f "${SCRIPT_DIR}/transform-settings.py" ]] \
    || die "missing companion script: ${SCRIPT_DIR}/transform-settings.py"
  [[ -f "${SCRIPT_DIR}/fanout.py" ]] \
    || die "missing companion script: ${SCRIPT_DIR}/fanout.py"
}

# ---- Pre-flight -------------------------------------------------------------

preflight() {
  log "preflight: ssh $TARGET ..."
  local script='set -eu
printf home=%s\\n "$HOME"
command -v tar >/dev/null 2>&1 && printf tar=yes\\n || printf tar=no\\n
command -v claude >/dev/null 2>&1 && printf claude=yes\\n || printf claude=no\\n
[ -d "$HOME/.claude" ] && printf existing=yes\\n || printf existing=no\\n'
  local out
  if ! out=$(ssh -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "$script" 2>&1); then
    die "ssh to $TARGET failed: $out"
  fi
  REMOTE_HOME=$(printf '%s\n' "$out" | sed -n 's/^home=//p' | tail -1)
  REMOTE_USER=$(basename "$REMOTE_HOME")
  REMOTE_EXISTING=$(printf '%s\n' "$out" | sed -n 's/^existing=//p' | tail -1)
  local tar_p claude_p
  tar_p=$(printf '%s\n' "$out" | sed -n 's/^tar=//p' | tail -1)
  claude_p=$(printf '%s\n' "$out" | sed -n 's/^claude=//p' | tail -1)
  [[ "$tar_p" == "yes" ]] || die "remote does not have tar in PATH"
  if [[ "$claude_p" != "yes" ]]; then
    if [[ "$REQUIRE_CLAUDE" -eq 1 ]]; then
      die "claude not on remote PATH and --require-claude was passed"
    fi
    warn "claude not on remote PATH — config will land but 'claude' is missing (use --require-claude to refuse this case)"
  fi
  log "remote home=$REMOTE_HOME user=$REMOTE_USER existing=$REMOTE_EXISTING"
}

# ---- Staging ----------------------------------------------------------------

make_stage() {
  STAGE_PARENT=$(mktemp -d -t aisync-ship-XXXXXX)
  STAGE_DIR="${STAGE_PARENT}/.claude"
  mkdir -p "$STAGE_DIR"
}

# tar | tar — zero source-side rsync dependency, exclude patterns honored
# by both BSD and GNU tar via the COPYFILE_DISABLE-friendly form.
stage_copy_via_tar() {
  COPYFILE_DISABLE=1 tar -C "$SOURCE_DIR" "${TAR_EXCLUDES[@]}" -cf - . \
    | COPYFILE_DISABLE=1 tar -C "$STAGE_DIR" -xf -
  log "staged $(find "$STAGE_DIR" -type f | wc -l | tr -d ' ') files, $(du -sh "$STAGE_DIR" | awk '{print $1}')"
}

transform_one() {
  local rel="$1"
  local path="${STAGE_DIR}/${rel}"
  [[ -f "$path" ]] || return 0
  local tmp="${path}.transformed"
  "${SCRIPT_DIR}/transform-settings.py" \
    --in "$path" --out "$tmp" \
    --src-user "$SRC_USER" --dst-user "$REMOTE_USER" \
    --log "${STAGE_PARENT}/transform-${rel}.log"
  if cmp -s "$path" "$tmp"; then
    rm -f "$tmp"
    log "transform: $rel (no changes)"
  else
    mv "$tmp" "$path"
    log "transform: $rel (changed; log at ${STAGE_PARENT}/transform-${rel}.log)"
  fi
}

transform_files() {
  local rel
  for rel in "${TRANSFORM_FILES[@]}"; do
    transform_one "$rel"
  done
}

include_credentials() {
  if [[ "$INCLUDE_CREDS" -ne 1 ]]; then
    log "credentials: skipped (--no-credentials); remote will keep its own"
    return
  fi
  local dest="${STAGE_DIR}/.credentials.json"
  if ! bash "${SCRIPT_DIR}/extract-credentials.sh" > "$dest"; then
    rm -f "$dest"
    die "credential extraction failed (see error above)"
  fi
  chmod 600 "$dest"
  log "credentials staged at $dest (mode 0600)"
}

stage_install_script() {
  cp "${SCRIPT_DIR}/install-remote.sh" "${STAGE_PARENT}/install-remote.sh"
  chmod 0755 "${STAGE_PARENT}/install-remote.sh"
}

# Run fanout.py against the staged .claude to materialize sibling stage
# subdirs (.codex, .gemini, ...) per --also list. Writes its part of the
# manifest to MANIFEST_FANOUT, which write_manifest then concatenates
# after the .claude entry.
MANIFEST_FANOUT=""
fanout_to_other_platforms() {
  if [[ -z "$ALSO_PLATFORMS" ]]; then return; fi
  MANIFEST_FANOUT="${STAGE_PARENT}/manifest.fanout.tsv"
  "${SCRIPT_DIR}/fanout.py" \
    --from "$STAGE_DIR" \
    --out-base "$STAGE_PARENT" \
    --to-platforms "$ALSO_PLATFORMS" \
    --manifest "$MANIFEST_FANOUT" \
    --log "${STAGE_PARENT}/fanout.log"
  log "fanout: --also=$ALSO_PLATFORMS (log: ${STAGE_PARENT}/fanout.log)"
}

write_manifest() {
  local mf="${STAGE_PARENT}/manifest.tsv"
  # .claude is the tool that owns the user_dir → replace mode (atomic swap).
  printf '.claude\t.claude\treplace\n' > "$mf"
  if [[ -n "$MANIFEST_FANOUT" && -f "$MANIFEST_FANOUT" ]]; then
    cat "$MANIFEST_FANOUT" >> "$mf"
  fi
  log "manifest: $mf ($(wc -l <"$mf" | tr -d ' ') entries; .claude=replace, fan-out=merge)"
}

# ---- Plan reporting ---------------------------------------------------------

print_plan() {
  log "============================================"
  log "PLAN ($MODE)"
  log "  source:   $SOURCE_DIR"
  log "  target:   $TARGET ($REMOTE_HOME)"
  log "  staged:   $STAGE_PARENT"
  log "  .claude:  $(find "$STAGE_DIR" -type f | wc -l | tr -d ' ') files, $(du -sh "$STAGE_DIR" | awk '{print $1}')"
  if [[ -n "$ALSO_PLATFORMS" ]]; then
    log "  also:     $ALSO_PLATFORMS"
    while IFS=$'\t' read -r ssub _; do
      [[ -z "$ssub" || "$ssub" == \#* ]] && continue
      local sd="${STAGE_PARENT}/${ssub}"
      [[ -d "$sd" ]] && log "    └─ $ssub: $(find "$sd" -type f | wc -l | tr -d ' ') files, $(du -sh "$sd" | awk '{print $1}')"
    done < "${MANIFEST_FANOUT:-/dev/null}"
  fi
  log "  excludes: $(((${#TAR_EXCLUDES[@]}) / 2)) patterns"
  log "  creds:    $([[ $INCLUDE_CREDS -eq 1 ]] && echo INCLUDED || echo SKIPPED)"
  log "  install:  atomic mv-swap with restore-on-error trap (per platform)"
  local f
  for f in "${TRANSFORM_FILES[@]}"; do
    local lf="${STAGE_PARENT}/transform-${f}.log"
    [[ -f "$lf" ]] || continue
    log "--- transform log: $f ---"
    sed 's/^/[ship][xform] /' "$lf" >&2
  done
  log "--- settings.json unified diff (source vs staged) ---"
  diff -u "$SOURCE_DIR/settings.json" "$STAGE_DIR/settings.json" >&2 || true
  log "============================================"
}

# ---- Transfer ---------------------------------------------------------------

confirm_apply() {
  printf 'Proceed with transfer to %s? [y/N] ' "$TARGET" >&2
  read -r ans
  [[ "$ans" =~ ^[Yy]$ ]] || die "aborted by user"
}

# Build list of stage subdirs to ship: always .claude, plus any from manifest.
collect_stage_subdirs() {
  local out=(.claude)
  if [[ -n "$MANIFEST_FANOUT" && -f "$MANIFEST_FANOUT" ]]; then
    while IFS=$'\t' read -r ssub _; do
      [[ -z "$ssub" || "$ssub" == \#* ]] && continue
      [[ -d "${STAGE_PARENT}/${ssub}" ]] && out+=("$ssub")
    done < "$MANIFEST_FANOUT"
  fi
  printf '%s\n' "${out[@]}"
}

# Stream stage (manifest + install-remote.sh + all platform subdirs); the
# remote untars to a tmpdir then runs install-remote.sh (atomic per-platform
# mv with cross-platform rollback).
#
# Tmpdir hardening on the REMOTE:
#   - umask 077 so the tmpdir is mode 700 (settings.json + possible
#     credentials are NOT readable by other users on the remote).
#   - mktemp -d (preferred) creates an unpredictable path; the previous
#     `mkdir -p $TMPDIR/aisync-ship-$$` was both PID-predictable and
#     happily reused a stale tmpdir from an interrupted run, which would
#     overlay old staged files into the new install.
#   - mkdir (NO -p) fallback when mktemp is missing fails on collision
#     instead of silently merging.
transfer() {
  local bootstrap='set -eu
umask 077
if command -v mktemp >/dev/null 2>&1; then
  tmp=$(mktemp -d "${TMPDIR:-/tmp}/aisync-ship.XXXXXX")
else
  tmp="${TMPDIR:-/tmp}/aisync-ship.$$.$(date +%s 2>/dev/null || echo n)"
  mkdir "$tmp"
fi
trap "rm -rf \"$tmp\"" EXIT HUP INT TERM
tar xzf - -C "$tmp"
sh "$tmp/install-remote.sh" "$tmp/manifest.tsv" "$tmp"'
  local subs=()
  while IFS= read -r s; do subs+=("$s"); done < <(collect_stage_subdirs)
  ( cd "$STAGE_PARENT" && COPYFILE_DISABLE=1 tar czf - install-remote.sh manifest.tsv "${subs[@]}" ) \
    | ssh "$TARGET" "$bootstrap"
  log "transfer complete"
}

cleanup_stage() {
  if [[ "$KEEP_STAGE" -eq 1 ]]; then
    log "stage retained: $STAGE_PARENT"
  else
    rm -rf "$STAGE_PARENT"
    log "stage cleaned"
  fi
}

# ---- main -------------------------------------------------------------------

main() {
  parse_args "$@"
  preflight
  make_stage
  stage_copy_via_tar
  transform_files
  include_credentials
  fanout_to_other_platforms
  stage_install_script
  write_manifest
  print_plan
  if [[ "$MODE" == "dry-run" ]]; then
    log "DRY-RUN: stopping before transfer."
    log "Inspect staged files at: $STAGE_DIR"
    log "Re-run with --apply when ready."
    exit 0
  fi
  confirm_apply
  transfer
  cleanup_stage
  log "Done. Suggested smoke test:"
  log "  ssh $TARGET 'claude --version && ls -la ~/.claude/.credentials.json'"
  log "  ssh $TARGET 'echo hi | claude -p \"say hi\"'"
}

main "$@"
