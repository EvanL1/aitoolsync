#!/bin/sh
# install-remote.sh — runs on the REMOTE inside a tmp dir.
#
# Contract:
#   $1 = path to the freshly-extracted .claude staging dir
#   The target install location is $HOME/.claude.
#
# Behavior:
#   1. If the remote already has a credential file and the staged copy does not,
#      copy it forward (lets a re-sync skip --include-credentials).
#   2. Atomically swap: mv $HOME/.claude $HOME/.claude.bak.<ts>, then mv staged → $HOME/.claude.
#   3. On any error mid-flight, restore the backup so the user is not left with no config.

set -eu

staged_dir="${1:?staged .claude directory required as first argument}"
dest="$HOME/.claude"
stamp=$(date +%Y%m%d-%H%M%S)
backup=""

restore_on_error() {
  rc=$?
  if [ "$rc" -ne 0 ] && [ -n "$backup" ] && [ ! -e "$dest" ] && [ -e "$backup" ]; then
    mv "$backup" "$dest"
    printf 'install-remote: rolled back to %s\n' "$backup" >&2
  fi
  exit "$rc"
}
trap restore_on_error EXIT HUP INT TERM

[ -d "$staged_dir" ] || {
  printf 'install-remote: staged directory missing: %s\n' "$staged_dir" >&2
  exit 20
}

# Forward existing remote credential when staged side has none (re-sync ergonomics).
if [ -f "$dest/.credentials.json" ] && [ ! -f "$staged_dir/.credentials.json" ]; then
  cp "$dest/.credentials.json" "$staged_dir/.credentials.json"
  chmod 600 "$staged_dir/.credentials.json"
  printf 'install-remote: preserved existing remote .credentials.json\n' >&2
fi

# Atomic swap.
if [ -e "$dest" ]; then
  backup="$dest.bak.$stamp"
  [ -e "$backup" ] && backup="$backup.$$"
  mv "$dest" "$backup"
fi
mv "$staged_dir" "$dest"

[ -f "$dest/.credentials.json" ] && chmod 600 "$dest/.credentials.json"

trap - EXIT HUP INT TERM

if [ -n "$backup" ]; then
  printf 'installed=%s\nbackup=%s\n' "$dest" "$backup"
else
  printf 'installed=%s\nbackup=\n' "$dest"
fi
