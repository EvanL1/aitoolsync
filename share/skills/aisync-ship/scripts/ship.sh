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
ASSUME_YES=0             # 1 = skip confirm_apply prompt (CI / scripted use)
PULL_SOURCE=""           # non-empty = reverse direction (--pull <user@host>)
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
  --yes, -y               Skip the interactive "Proceed with transfer?" prompt.
                          For CI / scripted use only — interactive operators
                          should review the dry-run plan first.
                          Env: AISYNC_SHIP_YES=1 has the same effect.
  --pull <user@host>      REVERSE direction: pull <user@host>:~/.claude → local
                          ~/.claude (atomic mv with backup). Useful for
                          provisioning a new machine from an existing one.
                          Mutually exclusive with --also and --include-credentials.
                          Local ~/.claude (including sessions/history) is
                          BACKED UP — review the dry-run plan carefully.
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
      --yes|-y) ASSUME_YES=1; shift ;;
      --pull) PULL_SOURCE="$2"; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) die "unknown flag: $1 (try --help)" ;;
      *)  [[ -z "$TARGET" ]] || die "extra arg: $1"; TARGET="$1"; shift ;;
    esac
  done
  if [[ -n "$PULL_SOURCE" ]]; then
    # In pull mode TARGET is unused; reject conflicting flags
    [[ -z "$ALSO_PLATFORMS" ]] || die "--pull is incompatible with --also"
    [[ "$INCLUDE_CREDS" -eq 0 ]] || die "--pull is incompatible with --include-credentials"
    [[ -z "$TARGET" ]] || die "--pull and a positional target are mutually exclusive"
  else
    [[ -n "$TARGET" ]] || { usage >&2; exit 2; }
    [[ -d "$SOURCE_DIR" ]] || die "source dir not found: $SOURCE_DIR"
  fi
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
  # -n: don't read from stdin. Without this, ssh drains the parent shell's
  # stdin (the operator's "y\n" intended for confirm_apply) and the
  # subsequent read prompt hangs / receives empty input.
  if ! out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" "$script" 2>&1); then
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
  print_deletion_preview
  log "============================================"
}

# Show, in the dry-run/print-plan phase, exactly which files install-remote.sh
# would marker-delete on the remote when --apply runs. Computed by fetching
# the remote marker via ssh and diffing locally — no destructive op happens.
# Edge cases handled:
#   - --also empty: skip (no fan-out targets, no preview).
#   - .claude (replace mode): skip (replace doesn't use markers).
#   - remote marker missing: print "first install" note, no diff.
#   - ssh fetch fails: print "unavailable", non-fatal.
#   - traversal/absolute paths in remote marker: tag [REJECTED unsafe]
#     so the operator sees what install-remote.sh would refuse.
print_deletion_preview() {
  [[ -z "$ALSO_PLATFORMS" ]] && return
  [[ -n "$MANIFEST_FANOUT" && -f "$MANIFEST_FANOUT" ]] || return
  log "--- deletion preview (what install-remote.sh would marker-delete) ---"
  while IFS=$'\t' read -r ssub _ mode _; do
    [[ -z "$ssub" || "$ssub" == \#* ]] && continue
    [[ "$mode" == "merge" ]] || continue
    local new_marker="${STAGE_PARENT}/${ssub}/.aisync-ship-managed"
    [[ -f "$new_marker" ]] || continue
    local remote_path="${REMOTE_HOME}/${ssub}/.aisync-ship-managed"
    local old_content
    if ! old_content=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" \
                          "cat \"$remote_path\" 2>/dev/null" 2>/dev/null); then
      log "  [$ssub] preview unavailable (could not fetch remote marker)"
      continue
    fi
    if [[ -z "$old_content" ]]; then
      log "  [$ssub] first marker-aware install on remote — no deletions"
      continue
    fi
    local diff_output
    diff_output=$(diff <(printf '%s\n' "$old_content" | grep -v '^#' | grep -v '^$' | sort -u) \
                       <(grep -v '^#' "$new_marker" | grep -v '^$' | sort -u) 2>/dev/null \
                  | grep '^<' | sed 's/^< //' || true)
    if [[ -z "$diff_output" ]]; then
      log "  [$ssub] no marker-deletions (remote marker matches new managed set)"
      continue
    fi
    # `grep -c` exits 1 when 0 matches → pipefail + set -e would kill the
    # script. `|| true` swallows that even though here we only get here
    # when diff_output is non-empty (defensive — same bug class as
    # post_smoke's grep -v | head pipeline).
    local count; count=$(printf '%s\n' "$diff_output" | grep -c '^.' || true)
    log "  [$ssub] will marker-delete $count entry/entries on remote:"
    local shown=0
    printf '%s\n' "$diff_output" | while IFS= read -r rel; do
      [[ -z "$rel" ]] && continue
      shown=$((shown + 1))
      [[ $shown -gt 15 ]] && { log "      ... ($((count - 15)) more not shown)"; break; }
      # Mirror install-remote.sh's safety check
      local tag="[DEL]"
      case "$rel" in
        ''|/*|*\\*) tag="[REJECTED unsafe]" ;;
      esac
      [[ "$tag" == "[DEL]" ]] && case "/$rel/" in
        *'/../'*|*'/./'*|*'//'*) tag="[REJECTED unsafe]" ;;
      esac
      log "      $tag $rel"
    done
  done < "$MANIFEST_FANOUT"
}

# ---- Transfer ---------------------------------------------------------------

confirm_apply() {
  if [[ "$ASSUME_YES" -eq 1 || "${AISYNC_SHIP_YES:-0}" == "1" ]]; then
    log "confirm: skipped (--yes / AISYNC_SHIP_YES=1)"
    return
  fi
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

# Post-apply smoke test: ssh into the remote and check `<binary> --version`
# for each platform we just installed. Never fails the script — purely
# informational. Aligns with the warn-and-proceed default for missing
# claude on the remote.
#
# Skipped: cursor / windsurf / cline (GUI tools, no headless --version).
# Always: claude (since .claude is always shipped).
# Plus:   codex/gemini if --also includes them.
post_smoke() {
  local cmds=(claude)
  if [[ -n "$ALSO_PLATFORMS" ]]; then
    local plat
    # Replace commas with spaces — avoids fiddling with IFS (interacts
    # with set -e in subtle ways).
    for plat in ${ALSO_PLATFORMS//,/ }; do
      case "$plat" in
        codex|gemini) cmds+=("$plat") ;;
        cursor|windsurf|cline) ;;
        *) warn "smoke-test: unknown platform '$plat', skipping" ;;
      esac
    done
  fi
  log "smoke test: ${cmds[*]} on $TARGET"
  local cmd out first
  for cmd in "${cmds[@]}"; do
    # IMPORTANT: post_smoke must NEVER fail the script — install already
    # succeeded by the time we get here. Two pipefail traps to defang:
    #   1. ssh exits non-zero when the binary is missing → the if/else
    #      handles it (already correct).
    #   2. grep -v setlocale may match nothing (all output is setlocale
    #      noise) → grep exits 1 → pipefail kills the assignment → set -e
    #      kills ship.sh. The `|| true` swallows that case.
    if out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$TARGET" \
                  "$cmd --version 2>&1" 2>&1); then
      first=$(printf '%s\n' "$out" | grep -v -E 'setlocale|^$' | head -1 || true)
      [[ -n "$first" ]] || first="(empty output)"
      log "  ✓ $cmd: $first"
    else
      first=$(printf '%s\n' "$out" | grep -v -E 'setlocale|^$' | head -1 || true)
      [[ -n "$first" ]] || first="(no error output)"
      warn "  ✗ $cmd: not present or errored ($first)"
    fi
  done
}

# ---- main -------------------------------------------------------------------

main() {
  parse_args "$@"
  if [[ -n "$PULL_SOURCE" ]]; then
    main_pull
  else
    main_push
  fi
}

main_push() {
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
  post_smoke
  log "Done."
}

# ---- Pull (reverse direction) ----------------------------------------------
#
# Tar-pipes <source>:~/.claude back into a local stage, transforms paths
# from /home/<src> → /Users/<dst>, then runs install-remote.sh locally
# (HOME=$HOME) for the same atomic mv-with-backup semantics as a push.
#
# Caveats (printed to user in print_plan_pull):
#   - Local ~/.claude is BACKED UP to ~/.claude.bak.<ts> and replaced
#     wholesale (replace mode). Local sessions/, history.jsonl,
#     plugins/ etc. move to the backup; restore by mv if needed.
#   - Credentials are NEVER pulled. Run `claude login` locally after.
#   - No fan-out is done in pull (single direction, single tool).

preflight_pull() {
  log "preflight pull: ssh -n $PULL_SOURCE ..."
  # NB: use `echo` instead of `printf "%s\n"` — some remote /bin/sh
  # implementations (busybox, certain dash builds) print the literal
  # `\n` rather than a newline, which would mash setlocale stderr
  # into the parsed values (e.g. REMOTE_HOME=/home/evannbash:...).
  local script='set -eu
[ -d "$HOME/.claude" ] || { echo PULL_NO_CLAUDE >&2; exit 11; }
echo "home=$HOME"
echo "user=$(id -un)"
echo "size=$(du -s "$HOME/.claude" 2>/dev/null | cut -f1)"'
  local out
  if ! out=$(ssh -n -o BatchMode=yes -o ConnectTimeout=10 "$PULL_SOURCE" "$script" 2>&1); then
    die "ssh to $PULL_SOURCE failed or source has no ~/.claude: $out"
  fi
  # Strip noise lines (setlocale warnings, etc.) before parsing — only
  # accept fully-formed key=value lines we expect.
  REMOTE_HOME=$(printf '%s\n' "$out" | sed -n 's/^home=//p' | tail -1)
  REMOTE_USER=$(printf '%s\n' "$out" | sed -n 's/^user=//p' | tail -1)
  local remote_size; remote_size=$(printf '%s\n' "$out" | sed -n 's/^size=//p' | tail -1)
  [[ -n "$REMOTE_HOME" && -n "$REMOTE_USER" ]] \
    || die "could not parse remote preflight output: $out"
  log "pull source: $PULL_SOURCE home=$REMOTE_HOME user=$REMOTE_USER (~$((remote_size / 1024)) MB at source, before excludes)"
}

pull_via_tar() {
  STAGE_PARENT=$(mktemp -d -t aisync-pull-XXXXXX)
  STAGE_DIR="${STAGE_PARENT}/.claude"
  mkdir -p "$STAGE_DIR"
  log "pull-stage: $STAGE_DIR"
  # Build a single-string exclude list for the remote tar invocation.
  local exclude_args=""
  local e
  for e in "${TAR_EXCLUDES[@]}"; do
    exclude_args="$exclude_args $e"
  done
  ssh -o BatchMode=yes -o ConnectTimeout=10 "$PULL_SOURCE" \
      "cd \"\$HOME/.claude\" && COPYFILE_DISABLE=1 tar $exclude_args -czf - ." \
    | tar -C "$STAGE_DIR" -xzf -
  log "pulled $(find "$STAGE_DIR" -type f | wc -l | tr -d ' ') files, $(du -sh "$STAGE_DIR" | awk '{print $1}')"
}

# Pull-side transform: source is REMOTE (Linux), dest is LOCAL (macOS).
# transform-settings.py --reverse rewrites /home/<remote-user> → /Users/<local-user>.
transform_files_pull() {
  local local_user; local_user=$(id -un)
  local rel
  for rel in "${TRANSFORM_FILES[@]}"; do
    local path="${STAGE_DIR}/${rel}"
    [[ -f "$path" ]] || continue
    local tmp="${path}.transformed"
    "${SCRIPT_DIR}/transform-settings.py" \
      --in "$path" --out "$tmp" \
      --src-user "$REMOTE_USER" --dst-user "$local_user" --reverse \
      --log "${STAGE_PARENT}/transform-${rel}.log"
    if cmp -s "$path" "$tmp"; then
      rm -f "$tmp"
      log "transform: $rel (no changes)"
    else
      mv "$tmp" "$path"
      log "transform: $rel (reverse rewrite applied)"
    fi
  done
}

print_plan_pull() {
  log "============================================"
  log "PLAN ($MODE, PULL direction)"
  log "  source:    $PULL_SOURCE ($REMOTE_HOME/.claude)"
  log "  dest:      LOCAL $HOME/.claude (will be backed up to .claude.bak.<ts>)"
  log "  staged:    $STAGE_DIR"
  log "  files:     $(find "$STAGE_DIR" -type f | wc -l | tr -d ' ')"
  log "  size:      $(du -sh "$STAGE_DIR" | awk '{print $1}')"
  log "  excludes:  $(((${#TAR_EXCLUDES[@]}) / 2)) patterns"
  log "  install:   atomic mv-swap (LOCAL); credentials NOT pulled"
  log "  WARNING:   local sessions/ history.jsonl plugins/ move to backup"
  log "             — restore via: mv ~/.claude.bak.<ts>/sessions ~/.claude/"
  local f
  for f in "${TRANSFORM_FILES[@]}"; do
    local lf="${STAGE_PARENT}/transform-${f}.log"
    [[ -f "$lf" ]] || continue
    log "--- pull transform log: $f ---"
    sed 's/^/[ship][xform] /' "$lf" >&2
  done
  log "============================================"
}

install_local() {
  cp "${SCRIPT_DIR}/install-remote.sh" "${STAGE_PARENT}/install-remote.sh"
  chmod 0755 "${STAGE_PARENT}/install-remote.sh"
  printf '.claude\t.claude\treplace\n' > "${STAGE_PARENT}/manifest.tsv"
  ( umask 077 && sh "${STAGE_PARENT}/install-remote.sh" \
                       "${STAGE_PARENT}/manifest.tsv" "${STAGE_PARENT}" )
}

post_smoke_local() {
  local out first
  if out=$(claude --version 2>&1); then
    first=$(printf '%s\n' "$out" | grep -v -E 'setlocale|^$' | head -1 || true)
    [[ -n "$first" ]] || first="(empty output)"
    log "  ✓ claude (local): $first"
  else
    warn "  ✗ claude (local): not present or errored — run 'claude login' to bootstrap"
  fi
}

main_pull() {
  preflight_pull
  pull_via_tar
  transform_files_pull
  print_plan_pull
  if [[ "$MODE" == "dry-run" ]]; then
    log "DRY-RUN: stopping before local install."
    log "Inspect staged files at: $STAGE_DIR"
    log "Re-run with --apply when ready (will backup + replace local ~/.claude)."
    exit 0
  fi
  printf 'Proceed with pull from %s, OVERWRITING local ~/.claude (backup will be created)? [y/N] ' "$PULL_SOURCE" >&2
  if [[ "$ASSUME_YES" -eq 1 || "${AISYNC_SHIP_YES:-0}" == "1" ]]; then
    log "confirm: skipped (--yes)"
  else
    read -r ans
    [[ "$ans" =~ ^[Yy]$ ]] || die "aborted by user"
  fi
  install_local
  cleanup_stage
  log "smoke test: claude on LOCAL"
  post_smoke_local
  log "Done."
}

main "$@"
