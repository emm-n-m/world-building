#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

mkdir -p "$fixture/home" "$fixture/new-root"
git init -q "$fixture/main"
git -C "$fixture/main" config user.email test@example.com
git -C "$fixture/main" config user.name Test
git -C "$fixture/main" commit --allow-empty -qm init
git -C "$fixture/main" worktree add -qb test-branch "$fixture/checkout"

HOME="$fixture/home" \
CODEX_HOME="$fixture/home/.codex" \
CLAUDE_CONFIG_DIR="$fixture/home/.claude" \
XDG_STATE_HOME="$fixture/home/.local/state" \
  "$project_dir/move-repo.py" "$fixture/checkout" "$fixture/new-root" >/dev/null

[[ ! -e "$fixture/checkout" ]]
git -C "$fixture/new-root/checkout" status --short >/dev/null
git -C "$fixture/main" worktree list --porcelain \
  | grep -Fqx "worktree $fixture/new-root/checkout"

# A Git-level move failure must restore any agent state changed before the move.
locked="$fixture/locked-checkout"
locked_target="$fixture/new-root/locked-checkout"
git -C "$fixture/main" worktree add -qb locked-branch "$locked"
git -C "$fixture/main" worktree lock --reason test "$locked"
mkdir -p "$fixture/home/.codex" "$fixture/home/.claude/projects"
cat > "$fixture/home/.codex/config.toml" <<EOF
[projects."$locked"]
trust_level = "trusted"
EOF
jq -n --arg source "$locked" \
  '{projects:{($source):{hasTrustDialogAccepted:true,allowedTools:["Bash(git status)"]}}}' \
  > "$fixture/home/.claude.json"
old_slug=${locked//\//-}
mkdir -p "$fixture/home/.claude/projects/$old_slug"
printf '{"type":"user","cwd":"%s","sessionId":"rollback"}\n' "$locked" \
  > "$fixture/home/.claude/projects/$old_slug/rollback.jsonl"

if HOME="$fixture/home" \
  CODEX_HOME="$fixture/home/.codex" \
  CLAUDE_CONFIG_DIR="$fixture/home/.claude" \
  XDG_STATE_HOME="$fixture/home/.local/state" \
    "$project_dir/move-repo.py" "$locked" "$fixture/new-root" >/dev/null 2>&1; then
  echo "expected locked worktree move to fail" >&2
  exit 1
fi
[[ -d "$locked" && ! -e "$locked_target" ]]
grep -Fq "[projects.\"$locked\"]" "$fixture/home/.codex/config.toml"
jq -e --arg source "$locked" '.projects[$source].hasTrustDialogAccepted == true' \
  "$fixture/home/.claude.json" >/dev/null
[[ -f "$fixture/home/.claude/projects/$old_slug/rollback.jsonl" ]]
jq -e --arg source "$locked" '.cwd == $source' \
  "$fixture/home/.claude/projects/$old_slug/rollback.jsonl" >/dev/null

echo "move-repo worktree test: ok"
