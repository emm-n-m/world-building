#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

export HOME="$fixture/home"
export CODEX_HOME="$HOME/.codex"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
source="$fixture/old/example"
target="$fixture/new/example"
mkdir -p "$source" "$fixture/new" "$CODEX_HOME" "$CLAUDE_CONFIG_DIR"
git -C "$source" init -q

jq -n --arg source "$source" --arg target "$target" \
  '{projects:{($source):{hasTrustDialogAccepted:true},($target):{hasTrustDialogAccepted:true}}}' \
  > "$HOME/.claude.json"
if "$project_dir/move-repo.py" --dry-run "$source" "$fixture/new" > /dev/null 2>&1; then
  echo "expected Claude state collision" >&2
  exit 1
fi
[[ -d "$source" && ! -e "$target" ]]

jq -n --arg source "$source" \
  '{projects:{($source):{hasTrustDialogAccepted:true}}}' > "$HOME/.claude.json"
cat > "$CODEX_HOME/config.toml" <<EOF
[projects."$source"]
trust_level = "trusted"
[projects."$target"]
trust_level = "trusted"
EOF
if "$project_dir/move-repo.py" --dry-run "$source" "$fixture/new" > /dev/null 2>&1; then
  echo "expected Codex state collision" >&2
  exit 1
fi
[[ -d "$source" && ! -e "$target" ]]

echo "move-repo collision test: ok"
