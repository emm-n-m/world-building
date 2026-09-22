#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)
fixture=$(mktemp -d)
trap 'rm -rf -- "$fixture"' EXIT

export HOME="$fixture/home"
export CODEX_HOME="$HOME/.codex"
export CLAUDE_CONFIG_DIR="$HOME/.claude"
export XDG_STATE_HOME="$HOME/.local/state"

old_root="$fixture/old root"
new_root="$fixture/new root"
source="$old_root/example-repo"
target="$new_root/example-repo"
mkdir -p "$source" "$new_root" "$CODEX_HOME/sessions/2026/01/02" \
  "$CODEX_HOME/rules" "$CLAUDE_CONFIG_DIR/projects"
git -C "$source" init -q

cat > "$CODEX_HOME/config.toml" <<EOF
[projects."$source"]
trust_level = "trusted"
EOF
cat > "$CODEX_HOME/rules/default.rules" <<EOF
prefix_rule(pattern=["git", "-C", "$source", "status"], decision="allow")
EOF
cat > "$CODEX_HOME/sessions/2026/01/02/session.jsonl" <<EOF
{"type":"session_meta","payload":{"cwd":"$source","runtime_workspace_roots":["$source","/tmp"],"sandbox_policy":{"writable_roots":["$source/generated"]}}}
{"type":"response_item","payload":{"text":"historical mention: $source"}}
EOF

python3 - "$CODEX_HOME/state_5.sqlite" "$source" <<'PY'
import json
import sqlite3
import sys

database, source = sys.argv[1:]
connection = sqlite3.connect(database)
connection.execute("create table threads (cwd text, sandbox_policy text)")
connection.execute("create table project_roots (path text)")
connection.execute(
    "insert into threads values (?, ?)",
    (source, json.dumps({"writable_roots": [source + "/generated"]})),
)
connection.execute("insert into project_roots values (?)", (source,))
connection.commit()
connection.close()
PY

jq -n --arg source "$source" \
  '{projects:{($source):{hasTrustDialogAccepted:true,allowedTools:[("Bash(git -C " + $source + " status)")]}}}' \
  > "$HOME/.claude.json"
cat > "$CLAUDE_CONFIG_DIR/history.jsonl" <<EOF
{"display":"historical mention: $source","project":"$source","sessionId":"session-1"}
EOF
old_slug=${source//\//-}
new_slug=${target//\//-}
mkdir -p "$CLAUDE_CONFIG_DIR/projects/$old_slug/memory"
cat > "$CLAUDE_CONFIG_DIR/projects/$old_slug/session-1.jsonl" <<EOF
{"type":"user","cwd":"$source","sessionId":"session-1","message":{"content":"historical mention: $source"}}
{"type":"assistant","cwd":"$source/subdir","sessionId":"session-1","message":{"content":"done"}}
EOF
printf 'Run from %s\n' "$source" > "$CLAUDE_CONFIG_DIR/projects/$old_slug/memory/MEMORY.md"

"$project_dir/move-repo.py" --dry-run "$source" "$new_root" >/dev/null
[[ -d "$source" && ! -e "$target" ]]
jq -e --arg source "$source" '.projects[$source].hasTrustDialogAccepted == true' \
  "$HOME/.claude.json" >/dev/null

"$project_dir/move-repo.py" "$source" "$new_root" > "$fixture/output"

[[ ! -e "$source" && -d "$target/.git" ]]
git -C "$target" status --short >/dev/null
grep -Fq "[projects.\"$target\"]" "$CODEX_HOME/config.toml"
! grep -Fq "$source" "$CODEX_HOME/config.toml"
grep -Fq "$target" "$CODEX_HOME/rules/default.rules"

codex_session="$CODEX_HOME/sessions/2026/01/02/session.jsonl"
jq -e --arg target "$target" \
  'select(.type == "session_meta") | .payload.cwd == $target and .payload.runtime_workspace_roots[0] == $target and .payload.sandbox_policy.writable_roots[0] == ($target + "/generated")' \
  "$codex_session" >/dev/null
jq -e --arg source "$source" \
  'select(.type == "response_item") | .payload.text == ("historical mention: " + $source)' \
  "$codex_session" >/dev/null

python3 - "$CODEX_HOME/state_5.sqlite" "$target" <<'PY'
import json
import sqlite3
import sys

database, target = sys.argv[1:]
connection = sqlite3.connect(database)
cwd, policy = connection.execute("select cwd, sandbox_policy from threads").fetchone()
root = connection.execute("select path from project_roots").fetchone()[0]
assert cwd == target
assert json.loads(policy)["writable_roots"] == [target + "/generated"]
assert root == target
connection.close()
PY

jq -e --arg source "$source" --arg target "$target" \
  '.projects[$source] == null and .projects[$target].hasTrustDialogAccepted == true and (.projects[$target].allowedTools[0] | contains($target))' \
  "$HOME/.claude.json" >/dev/null
[[ ! -e "$CLAUDE_CONFIG_DIR/projects/$old_slug" ]]
[[ -d "$CLAUDE_CONFIG_DIR/projects/$new_slug" ]]
jq -e --arg target "$target" 'select(.type == "user") | .cwd == $target' \
  "$CLAUDE_CONFIG_DIR/projects/$new_slug/session-1.jsonl" >/dev/null
jq -e --arg target "$target" 'select(.type == "assistant") | .cwd == ($target + "/subdir")' \
  "$CLAUDE_CONFIG_DIR/projects/$new_slug/session-1.jsonl" >/dev/null
jq -e --arg source "$source" \
  'select(.type == "user") | .message.content == ("historical mention: " + $source)' \
  "$CLAUDE_CONFIG_DIR/projects/$new_slug/session-1.jsonl" >/dev/null
jq -e --arg source "$source" --arg target "$target" \
  '.project == $target and .display == ("historical mention: " + $source)' \
  "$CLAUDE_CONFIG_DIR/history.jsonl" >/dev/null
grep -Fq "$target" "$CLAUDE_CONFIG_DIR/projects/$new_slug/memory/MEMORY.md"

manifest=$(find "$XDG_STATE_HOME/repo-move/backups" -name manifest.json -print -quit)
jq -e '.complete == true' "$manifest" >/dev/null
[[ $(stat -c '%a' "$(dirname "$manifest")") == 700 ]]
grep -Fq "Moved repository to $target" "$fixture/output"

echo "move-repo test: ok"
