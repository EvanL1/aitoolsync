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
INCLUDE_CREDS=1
KEEP_STAGE=0
ALLOW_MISSING_CLAUDE=0
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
  --no-credentials        Skip credential extraction; remote keeps its own.
  --keep-stage            Keep /tmp staging dir after --apply (default: clean).
  --source-dir <path>     Override source dir (default: $HOME/.claude).
  --allow-missing-claude  Continue when 'claude' is not on remote PATH.
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
      --no-credentials) INCLUDE_CREDS=0; shift ;;
      --keep-stage) KEEP_STAGE=1; shift ;;
      --source-dir) SOURCE_DIR="$2"; shift 2 ;;
      --allow-missing-claude) ALLOW_MISSING_CLAUDE=1; shift ;;
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
    if [[ "$ALLOW_MISSING_CLAUDE" -eq 1 ]]; then
      warn "claude not on remote PATH (proceeding due to --allow-missing-claude)"
    else
      die "claude not on remote PATH; rerun with --allow-missing-claude to override"
    fi
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

# ---- Plan reporting ---------------------------------------------------------

print_plan() {
  log "============================================"
  log "PLAN ($MODE)"
  log "  source:   $SOURCE_DIR"
  log "  target:   $TARGET ($REMOTE_HOME/.claude)"
  log "  staged:   $STAGE_DIR"
  log "  files:    $(find "$STAGE_DIR" -type f | wc -l | tr -d ' ')"
  log "  size:     $(du -sh "$STAGE_DIR" | awk '{print $1}')"
  log "  excludes: $(((${#TAR_EXCLUDES[@]}) / 2)) patterns"
  log "  creds:    $([[ $INCLUDE_CREDS -eq 1 ]] && echo INCLUDED || echo SKIPPED)"
  log "  install:  atomic mv-swap with restore-on-error trap"
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

# Stream the staged .claude AND install-remote.sh together; the remote
# untars to a tmpdir then runs install-remote.sh (atomic mv with rollback).
transfer() {
  local bootstrap='set -eu
tmp="${TMPDIR:-/tmp}/aisync-ship-$$"
trap "rm -rf $tmp" EXIT HUP INT TERM
mkdir -p "$tmp"
tar xzf - -C "$tmp"
sh "$tmp/install-remote.sh" "$tmp/.claude"'
  ( cd "$STAGE_PARENT" && COPYFILE_DISABLE=1 tar czf - .claude install-remote.sh ) \
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
  stage_install_script
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
