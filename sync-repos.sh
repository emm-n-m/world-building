#!/usr/bin/env bash
# Sync all git repos under a directory: fetch, then fast-forward the current branch.
# Never merges or rebases — a repo that has diverged (or has conflicting local
# changes) is reported and left untouched for you to resolve by hand.
set -uo pipefail

usage() {
  cat <<EOF
Usage: $(basename "$0") [DIRECTORY]

Sync the Git repositories immediately below DIRECTORY. If DIRECTORY is omitted,
the current working directory is used.
EOF
}

if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

if [ "${1:-}" = "-h" ] || [ "${1:-}" = "--help" ]; then
  usage
  exit 0
fi

ROOT=${1:-$PWD}
if ! ROOT=$(cd -- "$ROOT" 2>/dev/null && pwd -P); then
  printf 'Error: directory does not exist or is not accessible: %s\n' "${1:-$PWD}" >&2
  exit 2
fi

RED=$'\033[0;31m'; GREEN=$'\033[0;32m'; YELLOW=$'\033[1;33m'; DIM=$'\033[2m'; NC=$'\033[0m'
failures=0

status() { # status <color> <repo> <message>
  printf "  %-28s %s%s%s\n" "$2" "$1" "$3" "$NC"
}

echo "Syncing repos under $ROOT"
echo ""

for dir in "$ROOT"/*/; do
  [ -d "$dir/.git" ] || continue
  name=$(basename "$dir")

  branch=$(git -C "$dir" symbolic-ref --short -q HEAD) || {
    status "$YELLOW" "$name" "skipped: detached HEAD"
    continue
  }

  if ! git -C "$dir" fetch --prune --quiet 2>/dev/null; then
    status "$RED" "$name" "fetch failed (remote unreachable?)"
    failures=$((failures + 1))
    continue
  fi

  if ! git -C "$dir" rev-parse --verify -q '@{u}' >/dev/null 2>&1; then
    status "$YELLOW" "$name" "skipped: $branch has no upstream"
    continue
  fi

  read -r behind ahead < <(git -C "$dir" rev-list --left-right --count '@{u}...HEAD' 2>/dev/null)

  dirty=""
  [ -n "$(git -C "$dir" status --porcelain)" ] && dirty=" ${DIM}(uncommitted changes)${NC}"

  if [ "$behind" -eq 0 ]; then
    extra=""
    [ "$ahead" -gt 0 ] && extra=", $ahead to push"
    status "$GREEN" "$name" "up to date ($branch$extra)$dirty"
    continue
  fi

  if [ "$ahead" -gt 0 ]; then
    status "$YELLOW" "$name" "diverged ($branch: $behind behind, $ahead ahead) — resolve manually"
    failures=$((failures + 1))
    continue
  fi

  if git -C "$dir" merge --ff-only --quiet '@{u}' 2>/dev/null; then
    status "$GREEN" "$name" "pulled $behind commit(s) ($branch)$dirty"
  else
    status "$RED" "$name" "fast-forward failed ($branch) — local changes conflict, resolve manually"
    failures=$((failures + 1))
  fi
done

echo ""
if [ "$failures" -gt 0 ]; then
  echo "${RED}$failures repo(s) need attention.${NC}"
  exit 1
fi
echo "${GREEN}All repos in sync.${NC}"
