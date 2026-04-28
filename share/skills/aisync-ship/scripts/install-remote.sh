#!/bin/sh
# install-remote.sh — runs on the REMOTE inside a tmp dir.
#
# Contract:
#   $1 = path to a manifest TSV; one line per platform:
#          <stage_subpath><TAB><home_relative_dest_subpath>
#        e.g.:
#          .claude    .claude
#          .codex     .codex
#          .codeium/windsurf  .codeium/windsurf
#   $2 = path to the stage root (sibling of this script); contains all
#        <stage_subpath> directories.
#
# Behavior:
#   For each manifest entry, atomically swap the stage subdir into $HOME.
#   - .claude only: forward existing remote credential when staged has none.
#   - On any error, all successful swaps are rolled back to their backups.

set -eu

manifest="${1:?manifest path required}"
stage_root="${2:?stage root path required}"

[ -f "$manifest" ] || { printf 'install-remote: manifest missing: %s\n' "$manifest" >&2; exit 20; }
[ -d "$stage_root" ] || { printf 'install-remote: stage root missing: %s\n' "$stage_root" >&2; exit 20; }

stamp=$(date +%Y%m%d-%H%M%S)
applied_pairs=""   # newline-separated "dest|backup" lines for rollback

restore_all() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$applied_pairs" ]; then
    printf 'install-remote: error (rc=%s); rolling back...\n' "$rc" >&2
    # Each install is an independent leaf path — order doesn't matter.
    printf '%s\n' "$applied_pairs" | awk 'NF' \
      | while IFS='|' read -r dest backup; do
          if [ -d "$dest" ] && [ -d "$backup" ]; then
            rm -rf "$dest" && mv "$backup" "$dest"
            printf 'install-remote: restored %s\n' "$dest" >&2
          fi
        done
  fi
  exit "$rc"
}
trap restore_all EXIT HUP INT TERM

install_one() {
  stage_sub="$1"
  home_sub="$2"
  staged="$stage_root/$stage_sub"
  dest="$HOME/$home_sub"

  [ -d "$staged" ] || {
    printf 'install-remote: skip %s (stage subdir missing)\n' "$stage_sub" >&2
    return 0
  }

  # .claude-only: preserve existing credential if staged has none
  if [ "$home_sub" = ".claude" ] \
     && [ -f "$dest/.credentials.json" ] \
     && [ ! -f "$staged/.credentials.json" ]; then
    cp "$dest/.credentials.json" "$staged/.credentials.json"
    chmod 600 "$staged/.credentials.json"
    printf 'install-remote: preserved existing remote .credentials.json\n' >&2
  fi

  backup=""
  if [ -e "$dest" ]; then
    backup="$dest.bak.$stamp"
    [ -e "$backup" ] && backup="$backup.$$"
    mv "$dest" "$backup"
  fi
  mkdir -p "$(dirname "$dest")"
  mv "$staged" "$dest"
  [ -f "$dest/.credentials.json" ] && chmod 600 "$dest/.credentials.json"

  applied_pairs="$applied_pairs
$dest|$backup"
  printf 'install-remote: installed %s (backup=%s)\n' "$dest" "${backup:-<none>}" >&2
}

# Read manifest line by line (TAB-separated; tolerate spaces too)
while IFS="$(printf '\t')" read -r stage_sub home_sub _rest; do
  case "$stage_sub" in ''|\#*) continue ;; esac
  # Allow space-separated lines as a fallback
  if [ -z "$home_sub" ]; then
    set -- $stage_sub
    stage_sub="$1"; home_sub="${2:-$1}"
  fi
  install_one "$stage_sub" "$home_sub"
done < "$manifest"

trap - EXIT HUP INT TERM
printf 'install-remote: done\n' >&2
