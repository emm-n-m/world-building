#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

echo "Installing base packages..."

if ! command_exists apt; then
    echo "This bootstrap currently supports apt-based Linux distributions." >&2
    exit 1
fi

sudo apt update
xargs sudo apt install -y < "$repo_dir/packages.txt"

echo "Installing Rust..."
if ! command_exists rustup; then
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
fi

echo "Installing uv..."
if ! command_exists uv; then
    curl -LsSf https://astral.sh/uv/install.sh | sh
fi

echo "Installing fnm..."
if ! command_exists fnm; then
    curl -fsSL https://fnm.vercel.app/install | bash
fi

if command_exists npm; then
    echo "Installing global npm tools..."
    npm install -g @openai/codex pnpm
else
    cat <<'EOF'

npm is not available yet. Restart your shell and run:
  fnm install --lts
  fnm default lts-latest
  npm install -g @openai/codex pnpm
EOF
fi

cat <<'EOF'

Bootstrap complete.

If fnm was installed during this run, restart your shell and run:
  fnm install --lts
  fnm default lts-latest
EOF
