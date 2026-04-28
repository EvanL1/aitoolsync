#!/usr/bin/env bash
# extract-credentials.sh — platform-aware Claude Code credentials extractor.
#
# Behavior:
#   macOS  → security find-generic-password -s 'Claude Code-credentials' -w
#   Linux  → cat $HOME/.claude/.credentials.json (must be mode 0600)
#
# Output: raw credential JSON on stdout. Exit non-zero on failure so callers
# (ship.sh, LLM) can surface the error rather than write an empty file.

set -euo pipefail

err() { printf 'extract-credentials: %s\n' "$*" >&2; }

looks_like_json() {
  # Returns 0 if first non-whitespace byte is { or [.
  local first
  first=$(printf '%s' "$1" | tr -d '[:space:]' | cut -c1)
  [[ "$first" == "{" || "$first" == "[" ]]
}

extract_macos() {
  if ! command -v security >/dev/null 2>&1; then
    err "macOS detected but 'security' binary not found"
    exit 3
  fi
  local out
  if ! out=$(security find-generic-password -s 'Claude Code-credentials' -w 2>/dev/null); then
    err "Keychain entry 'Claude Code-credentials' not found or access denied."
    err "Hint: unlock the keychain (security unlock-keychain), or sign in via 'claude login'."
    exit 4
  fi
  if ! looks_like_json "$out"; then
    err "extracted Keychain item does not look like JSON (first byte not { or [)"
    exit 6
  fi
  printf '%s' "$out"
}

extract_linux() {
  local path="${HOME}/.claude/.credentials.json"
  if [[ ! -f "$path" ]]; then
    err "no credentials file at $path"
    err "Hint: run 'claude login' on this machine first."
    exit 5
  fi
  local out
  out=$(cat "$path")
  if ! looks_like_json "$out"; then
    err "credential file at $path does not look like JSON (first byte not { or [)"
    exit 6
  fi
  printf '%s' "$out"
}

main() {
  case "$(uname -s)" in
    Darwin) extract_macos ;;
    Linux)  extract_linux ;;
    *)
      err "unsupported platform: $(uname -s)"
      exit 2
      ;;
  esac
}

main "$@"
