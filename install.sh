#!/usr/bin/env bash
set -euo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
backup_dir="$HOME/.dotfiles-backup/$(date +%Y%m%d-%H%M%S)"

link_file() {
    local source="$1"
    local target="$2"

    if [[ -L "$target" && "$(readlink "$target")" == "$source" ]]; then
        echo "Already linked: $target"
        return
    fi

    if [[ -e "$target" || -L "$target" ]]; then
        mkdir -p "$backup_dir"
        mv "$target" "$backup_dir/"
        echo "Backed up: $target -> $backup_dir/"
    fi

    ln -s "$source" "$target"
    echo "Linked: $target -> $source"
}

link_file "$repo_dir/.bashrc.local" "$HOME/.bashrc.local"
link_file "$repo_dir/.gitconfig" "$HOME/.gitconfig"
link_file "$repo_dir/.gitignore_global" "$HOME/.gitignore_global"
