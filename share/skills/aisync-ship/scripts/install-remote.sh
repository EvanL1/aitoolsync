#!/bin/sh
# install-remote.sh — runs on the REMOTE inside a tmp dir.
#
# Contract:
#   $1 = path to a manifest TSV; one line per platform:
#          <stage_subpath><TAB><home_subpath>[<TAB><mode>[<TAB><owned_subtrees_csv>]]
#        where <mode> is "replace" (default) or "merge":
#          replace — atomic mv-swap; whole dest dir is replaced by the staged
#                    one. Use for the tool that owns the user_dir (Claude
#                    shipping its own ~/.claude).
#          merge   — snapshot dest to backup (cp -aR) then overlay staged
#                    contents into dest, preserving any files in dest not
#                    present in staged. Use for fan-out into other tools'
#                    user_dirs (~/.codex, ~/.gemini, ...) so we DO NOT wipe
#                    their auth.json / config.toml / sessions etc.
#        <owned_subtrees_csv> (merge mode only): comma-separated subdir names
#        we fully own inside dest (e.g. "rules,skills"). Before the merge cp,
#        these subdirs are rm -rf'd from dest so deletions at the source side
#        propagate. dest entries OUTSIDE these subdirs are still preserved.
#        e.g.:
#          .claude    .claude              replace
#          .codex     .codex               merge   rules,skills
#          .codeium/windsurf  .codeium/windsurf  merge   rules
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
# Newly-created intermediate dirs (one per line, deepest first) — used by
# restore_all to rmdir them on failure so we don't leave empty parents like
# ~/.codeium when only `.codeium/windsurf` was being installed and aborted.
created_intermediates=""

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
  if [ "$rc" -ne 0 ] && [ -n "$created_intermediates" ]; then
    # rmdir is safe — only removes EMPTY dirs. If a successful sibling
    # install populated this ancestor, rmdir will refuse and we leave it
    # alone. Order is deepest-first thanks to how install_one prepends.
    printf '%s\n' "$created_intermediates" | awk 'NF' \
      | while read -r p; do
          if rmdir "$p" 2>/dev/null; then
            printf 'install-remote: removed orphan intermediate dir %s\n' "$p" >&2
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
  owned_csv="${4:-}"
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

  # GC: clear any stale .partial snapshots left by a previous failed run of
  # THIS dest. They're diagnostic-only garbage and would not be reused
  # (atomic rename in the snapshot path means a stale .partial is never
  # consulted), but they accumulate on disk if not cleaned. Per-dest scope
  # avoids touching unrelated paths.
  for stale in "$dest".bak.*.partial; do
    [ -e "$stale" ] || continue
    printf 'install-remote: GC stale partial %s\n' "$stale" >&2
    rm -rf "$stale"
  done

  # .claude-only: preserve existing credential if staged has none
  if [ "$home_sub" = ".claude" ] \
     && [ -f "$dest/.credentials.json" ] \
     && [ ! -f "$staged/.credentials.json" ]; then
    cp "$dest/.credentials.json" "$staged/.credentials.json"
    chmod 600 "$staged/.credentials.json"
    printf 'install-remote: preserved existing remote .credentials.json\n' >&2
  fi

  # Track ancestors we're about to mkdir -p so restore_all can rmdir them
  # on failure (safely — rmdir won't remove non-empty dirs).
  parent=$(dirname "$dest")
  walk="$parent"
  while [ "$walk" != "/" ] && [ "$walk" != "." ] && [ -n "$walk" ] && [ ! -d "$walk" ]; do
    # Prepend so rollback order is deepest-first
    created_intermediates="$walk
$created_intermediates"
    walk=$(dirname "$walk")
  done

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
      # CRITICAL: clear any stale .partial left by a previous failed snapshot.
      # If we skip this and the path exists as a dir, cp -aR src dir nests
      # the source under it (cp creates dir/<basename src>/...). The
      # subsequent atomic mv would then rename a poisoned, nested dir to
      # the final backup path, and a later rollback would replace dest
      # with that broken layout (data corruption + stale garbage merged in).
      rm -rf "$backup_partial"
      cp -aR "$dest" "$backup_partial"
      mv "$backup_partial" "$backup"
    else
      mv "$dest" "$backup"
    fi
  fi

  # Apply staged content.
  if [ "$mode" = "merge" ]; then
    mkdir -p "$dest"

    # PREFERRED: marker-based delete propagation. fanout.py writes
    # ".aisync-ship-managed" listing every file it installed. On the next
    # run, files in OLD marker but not in NEW marker are exactly those we
    # installed previously and have since dropped — delete those, but
    # NEVER touch files outside the marker (user-authored entries are
    # protected automatically because they were never recorded).
    new_marker="$staged/.aisync-ship-managed"
    old_marker="$dest/.aisync-ship-managed"
    if [ -f "$new_marker" ]; then
      if [ -f "$old_marker" ]; then
        # grep -vxFf: print lines from old_marker that don't exactly
        # match any line in new_marker. POSIX-portable; no jq/python.
        grep -vxFf "$new_marker" "$old_marker" 2>/dev/null \
          | while read -r rel; do
              case "$rel" in '#'*|'') continue ;; esac
              # Reject path traversal, absolute paths, backslash injection.
              # Wrap with /…/ so the case patterns can spot ".." or "."
              # as full segments anywhere in the path.
              unsafe=0
              case "$rel" in
                ''|/*) unsafe=1 ;;
                *\\*) unsafe=1 ;;
              esac
              if [ "$unsafe" -eq 0 ]; then
                case "/$rel/" in
                  *'/../'*|*'/./'*|*'//'*) unsafe=1 ;;
                esac
              fi
              if [ "$unsafe" -eq 1 ]; then
                printf 'install-remote: marker-delete REJECTED unsafe path %s\n' "$rel" >&2
                continue
              fi
              if [ -e "$dest/$rel" ] || [ -L "$dest/$rel" ]; then
                rm -rf "$dest/$rel"
                printf 'install-remote: marker-delete %s\n' "$dest/$rel" >&2
              fi
              # Prune empty ancestor dirs (rmdir refuses non-empty → safe)
              parent=$(dirname "$rel")
              while [ "$parent" != "." ] && [ "$parent" != "/" ]; do
                rmdir "$dest/$parent" 2>/dev/null || break
                parent=$(dirname "$parent")
              done
            done
      fi
      # New marker present → suppress legacy owned-subtree replace.
      owned_csv=""
    fi

    # LEGACY (no marker): owned-subtree replace. Kept for backward-compat
    # with old fanout.py manifests that didn't write a marker. Once all
    # remote dests have been touched by a marker-aware fan-out at least
    # once, this branch becomes dead code.
    if [ -n "$owned_csv" ]; then
      OLD_IFS="$IFS"; IFS=,
      for sub in $owned_csv; do
        IFS="$OLD_IFS"
        if [ -n "$sub" ]; then
          if [ -d "$staged/$sub" ]; then
            rm -rf "$dest/$sub"
          else
            printf 'install-remote: ignoring owned-subtree claim "%s" — staged has no such dir\n' "$sub" >&2
          fi
        fi
        OLD_IFS="$IFS"; IFS=,
      done
      IFS="$OLD_IFS"
    fi
    cp -aR "$staged/." "$dest/"     # overlay (preserves dest's other files)
  else
    mkdir -p "$(dirname "$dest")"
    mv "$staged" "$dest"            # atomic swap
  fi

  [ -f "$dest/.credentials.json" ] && chmod 600 "$dest/.credentials.json"
  printf 'install-remote: installed %s mode=%s backup=%s\n' "$dest" "$mode" "${backup:-<none>}" >&2
}

# Read manifest line by line (TAB-separated; tolerate spaces too).
while IFS="$(printf '\t')" read -r stage_sub home_sub mode owned_csv _rest; do
  case "$stage_sub" in ''|\#*) continue ;; esac
  # Allow space-separated fallback
  if [ -z "$home_sub" ]; then
    set -- $stage_sub
    stage_sub="$1"; home_sub="${2:-$1}"; mode="${3:-replace}"; owned_csv="${4:-}"
  fi
  install_one "$stage_sub" "$home_sub" "${mode:-replace}" "${owned_csv:-}"
done < "$manifest"

trap - EXIT HUP INT TERM
printf 'install-remote: done\n' >&2
