#!/bin/sh
# install-remote.sh — runs on the REMOTE inside a tmp dir.
#
# Contract:
#   $1 = path to a manifest TSV; one line per platform:
#          <stage_subpath><TAB><home_relative_dest_subpath>[<TAB><mode>]
#        where <mode> is "replace" (default) or "merge":
#          replace — atomic mv-swap; whole dest dir is replaced by the staged
#                    one. Use for the tool that owns the user_dir (Claude
#                    shipping its own ~/.claude).
#          merge   — snapshot dest to backup (cp -aR) then overlay staged
#                    contents into dest, preserving any files in dest not
#                    present in staged. Use for fan-out into other tools'
#                    user_dirs (~/.codex, ~/.gemini, ...) so we DO NOT wipe
#                    their auth.json / config.toml / sessions etc.
#        e.g.:
#          .claude    .claude              replace
#          .codex     .codex               merge
#          .codeium/windsurf  .codeium/windsurf  merge
#   $2 = path to the stage root (sibling of this script); contains all
#        <stage_subpath> directories.
#
# Behavior:
#   For each manifest entry, install per its mode. On any error, all
#   successful installs (replace AND merge) are rolled back to their
#   pre-install state, including dirs that were newly created during a
#   failed transaction.
#
#   .claude only: forward existing remote credential when staged has none.

set -eu

manifest="${1:?manifest path required}"
stage_root="${2:?stage root path required}"

[ -f "$manifest" ]   || { printf 'install-remote: manifest missing: %s\n' "$manifest" >&2; exit 20; }
[ -d "$stage_root" ] || { printf 'install-remote: stage root missing: %s\n' "$stage_root" >&2; exit 20; }

stamp=$(date +%Y%m%d-%H%M%S)
# applied_pairs lines: <dest>|<backup>|<mode>     (backup is "" if dest didn't pre-exist)
applied_pairs=""

restore_all() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$applied_pairs" ]; then
    printf 'install-remote: error (rc=%s); rolling back...\n' "$rc" >&2
    printf '%s\n' "$applied_pairs" | awk 'NF' \
      | while IFS='|' read -r dest backup mode; do
          if [ -n "$backup" ] && [ -d "$backup" ]; then
            # backup snapshot exists → restore (covers replace AND merge,
            # whether the destructive step succeeded fully or partially)
            rm -rf "$dest"
            mv "$backup" "$dest"
            printf 'install-remote: restored %s (%s)\n' "$dest" "$mode" >&2
          elif [ -z "$backup" ] && [ -d "$dest" ]; then
            # backup="" means dest did NOT pre-exist; anything we find at
            # dest now was created by this transaction → safe to remove
            rm -rf "$dest"
            printf 'install-remote: removed newly-created %s (%s)\n' "$dest" "$mode" >&2
          else
            # backup was supposed to exist but is missing — backup snapshot
            # itself failed before completing. Leave dest alone (user data
            # may still be intact) and surface the situation.
            printf 'install-remote: cannot rollback %s (backup %s missing)\n' "$dest" "$backup" >&2
          fi
        done
  fi
  exit "$rc"
}
trap restore_all EXIT HUP INT TERM

install_one() {
  stage_sub="$1"
  home_sub="$2"
  mode="${3:-replace}"
  staged="$stage_root/$stage_sub"
  dest="$HOME/$home_sub"

  [ -d "$staged" ] || {
    printf 'install-remote: skip %s (stage subdir missing)\n' "$stage_sub" >&2
    return 0
  }
  case "$mode" in
    replace|merge) ;;
    *) printf 'install-remote: invalid mode "%s" for %s\n' "$mode" "$stage_sub" >&2; exit 21 ;;
  esac

  # .claude-only: preserve existing credential if staged has none
  if [ "$home_sub" = ".claude" ] \
     && [ -f "$dest/.credentials.json" ] \
     && [ ! -f "$staged/.credentials.json" ]; then
    cp "$dest/.credentials.json" "$staged/.credentials.json"
    chmod 600 "$staged/.credentials.json"
    printf 'install-remote: preserved existing remote .credentials.json\n' >&2
  fi

  # Decide backup path WITHOUT creating it yet.
  backup=""
  if [ -e "$dest" ]; then
    backup="$dest.bak.$stamp"
    [ -e "$backup" ] && backup="$backup.$$"
  fi

  # CRITICAL: record the rollback entry BEFORE any destructive operation.
  # If snapshot/cp/mv fails partway through, restore_all uses this entry to
  # undo whatever partial state was left behind. If we recorded after the
  # operation, a mid-op failure (set -e exits before append) would leave
  # the rollback log empty for this entry → orphan backup + half-merged dest.
  applied_pairs="$applied_pairs
$dest|$backup|$mode"

  # Snapshot or move-aside dest (skip if dest didn't exist).
  #
  # CRITICAL for merge mode: write the snapshot to a `.partial` path first
  # and rename it to the final backup path only after cp completes. Reason:
  # cp -aR is non-atomic; a mid-cp failure leaves a half-populated dir at
  # the target. If that half-populated dir lived at the final backup path,
  # restore_all's `[ -d backup ]` check would treat it as a valid snapshot
  # and `rm dest && mv backup dest` would replace the user's data with a
  # partial copy. The atomic rename ensures the final backup path either
  # holds a complete snapshot or doesn't exist at all.
  #
  # mv (replace mode) is already a single rename syscall on the same fs,
  # so it's intrinsically atomic — no .partial dance needed.
  if [ -n "$backup" ]; then
    if [ "$mode" = "merge" ]; then
      backup_partial="$backup.partial"
      cp -aR "$dest" "$backup_partial"
      mv "$backup_partial" "$backup"
    else
      mv "$dest" "$backup"
    fi
  fi

  # Apply staged content.
  if [ "$mode" = "merge" ]; then
    mkdir -p "$dest"
    cp -aR "$staged/." "$dest/"     # overlay (preserves dest's other files)
  else
    mkdir -p "$(dirname "$dest")"
    mv "$staged" "$dest"            # atomic swap
  fi

  [ -f "$dest/.credentials.json" ] && chmod 600 "$dest/.credentials.json"
  printf 'install-remote: installed %s mode=%s backup=%s\n' "$dest" "$mode" "${backup:-<none>}" >&2
}

# Read manifest line by line (TAB-separated; tolerate spaces too).
while IFS="$(printf '\t')" read -r stage_sub home_sub mode _rest; do
  case "$stage_sub" in ''|\#*) continue ;; esac
  # Allow space-separated fallback
  if [ -z "$home_sub" ]; then
    set -- $stage_sub
    stage_sub="$1"; home_sub="${2:-$1}"; mode="${3:-replace}"
  fi
  install_one "$stage_sub" "$home_sub" "${mode:-replace}"
done < "$manifest"

trap - EXIT HUP INT TERM
printf 'install-remote: done\n' >&2
