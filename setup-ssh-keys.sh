#!/usr/bin/env bash
set -euo pipefail

# Generates this machine's SSH keys — one per IdentityFile referenced by your
# SSH config (~/.ssh/config, which Includes ~/.ssh/config.local). Keys are
# per-machine and never copied between machines, so a retired or compromised
# machine can be revoked at each host individually, without rotating the keys
# on any other machine. Private keys never leave the machine and are never
# committed (see .gitignore).
#
# The committed config only knows the personal github.com key; work hosts (and
# their key filenames) come from the untracked ~/.ssh/config.local, so this
# script stays free of any employer-specific details.
#
# Safe to re-run: existing keys are left untouched.

ssh_dir="$HOME/.ssh"
mkdir -p "$ssh_dir"
chmod 700 "$ssh_dir"

comment="${USER}@$(hostname)"   # identifies the machine in each host's key list

# Collect every IdentityFile the SSH config references (committed config plus the
# Include'd local file). This is why the script needs no hardcoded hostnames.
mapfile -t idfiles < <(
    grep -hiE '^[[:space:]]*IdentityFile[[:space:]]' \
        "$ssh_dir/config" "$ssh_dir/config.local" 2>/dev/null \
    | awk '{print $2}' | sort -u
)

if [[ ${#idfiles[@]} -eq 0 ]]; then
    echo "No IdentityFile entries found in ~/.ssh/config[.local]." >&2
    echo "Set up your SSH config first (see ssh_config.local.example)." >&2
    exit 1
fi

expand() { local p="${1/#\~/$HOME}"; echo "${p/#\$HOME/$HOME}"; }

for raw in "${idfiles[@]}"; do
    path="$(expand "$raw")"
    if [[ -f "$path" ]]; then
        echo "Exists, skipping: $path"
    else
        ssh-keygen -t ed25519 -f "$path" -C "$comment" -N ""
        echo "Generated: $path"
    fi
done

echo
echo "=================================================================="
echo "Register these PUBLIC keys with the matching host (private keys"
echo "never leave this machine). Key comment: $comment"
echo "=================================================================="
for raw in "${idfiles[@]}"; do
    path="$(expand "$raw")"
    [[ -f "$path.pub" ]] || continue
    echo
    echo "# $(basename "$path")"
    cat "$path.pub"
done
