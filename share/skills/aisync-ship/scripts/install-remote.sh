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
            # dest pre-existed — restore from backup
            rm -rf "$dest"
            mv "$backup" "$dest"
            printf 'install-remote: restored %s (%s)\n' "$dest" "$mode" >&2
          elif [ -d "$dest" ]; then
            # dest was newly created during this transaction — remove it
            rm -rf "$dest"
            printf 'install-remote: removed newly-created %s (%s)\n' "$dest" "$mode" >&2
          fi
        done
  fi
  exit "$rc"
}
trap restore_all EXIT HUP INT TERM

# Returns the backup path (or "" if dest didn't pre-exist). On invocation,
# dest is moved/copied aside so install_replace/merge can write into dest.
take_backup() {
  dest="$1"
  mode="$2"
  if [ ! -e "$dest" ]; then
    printf ''
    return
  fi
  backup="$dest.bak.$stamp"
  [ -e "$backup" ] && backup="$backup.$$"
  if [ "$mode" = "merge" ]; then
    # snapshot: keep dest in place, copy aside
    cp -aR "$dest" "$backup"
  else
    # replace: move dest aside, leaving slot empty
    mv "$dest" "$backup"
  fi
  printf '%s' "$backup"
}

install_replace() {
  staged="$1"; dest="$2"
  mkdir -p "$(dirname "$dest")"
  mv "$staged" "$dest"
}

install_merge() {
  staged="$1"; dest="$2"
  mkdir -p "$dest"
  # Overlay staged contents into dest, preserving any dest files not in staged.
  # cp -aR with /. trailing copies CONTENTS rather than the dir itself.
  cp -aR "$staged/." "$dest/"
}

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

  backup=$(take_backup "$dest" "$mode")
  if [ "$mode" = "merge" ]; then
    install_merge "$staged" "$dest"
  else
    install_replace "$staged" "$dest"
  fi
  [ -f "$dest/.credentials.json" ] && chmod 600 "$dest/.credentials.json"

  applied_pairs="$applied_pairs
$dest|$backup|$mode"
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
