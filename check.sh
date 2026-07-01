#!/usr/bin/env bash
# Reports drift between this machine and the dotfiles repo. Read-only: it never
# changes anything, only tells you what's out of sync. Exit code is non-zero if
# any hard failure is found, so it can gate other tooling or a login hook.
set -uo pipefail

repo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fail=0
warn=0

if [[ -t 1 ]]; then C_G=$'\033[32m'; C_R=$'\033[31m'; C_Y=$'\033[33m'; C_0=$'\033[0m'
else C_G=; C_R=; C_Y=; C_0=; fi

ok()      { printf '  %sok%s    %s\n'   "$C_G" "$C_0" "$1"; }
bad()     { printf '  %sFAIL%s  %s\n'   "$C_R" "$C_0" "$1"; fail=$((fail+1)); }
note()    { printf '  %swarn%s  %s\n'   "$C_Y" "$C_0" "$1"; warn=$((warn+1)); }
section() { printf '\n%s\n' "$1"; }

command_exists() { command -v "$1" >/dev/null 2>&1; }
expand() { local p="${1/#\~/$HOME}"; printf '%s' "${p/#\$HOME/$HOME}"; }

# --- Symlinks --------------------------------------------------------------
section "Symlinks"
check_link() {  # $1 = target in $HOME, $2 = expected source in repo
    local target="$1" src="$2"
    if [[ -L "$target" && "$(readlink "$target")" == "$src" ]]; then
        ok "$target"
    elif [[ -L "$target" ]]; then
        bad "$target -> $(readlink "$target") (expected $src; run install.sh)"
    elif [[ -e "$target" ]]; then
        bad "$target is a real file, not a repo symlink (run install.sh)"
    else
        bad "$target missing (run install.sh)"
    fi
}
check_link "$HOME/.bashrc.local"     "$repo_dir/.bashrc.local"
check_link "$HOME/.gitconfig"        "$repo_dir/.gitconfig"
check_link "$HOME/.gitignore_global" "$repo_dir/.gitignore_global"
check_link "$HOME/.ssh/config"       "$repo_dir/ssh_config"

# --- Packages --------------------------------------------------------------
section "Packages (packages.txt)"
if command_exists dpkg; then
    missing=()
    while read -r pkg || [[ -n "$pkg" ]]; do
        [[ -z "$pkg" || "$pkg" == \#* ]] && continue
        dpkg -s "$pkg" >/dev/null 2>&1 || missing+=("$pkg")
    done < "$repo_dir/packages.txt"
    if [[ ${#missing[@]} -eq 0 ]]; then ok "all installed"
    else bad "missing: ${missing[*]} (run bootstrap.sh)"; fi
else
    note "dpkg not found — skipping package check (non-apt system)"
fi

# --- Toolchains ------------------------------------------------------------
section "Toolchains"
for t in rustup uv fnm gh; do
    command_exists "$t" && ok "$t" || bad "$t missing (run bootstrap.sh)"
done
# node/npm come from fnm and need its shell env; load it before checking.
command_exists fnm && eval "$(fnm env 2>/dev/null)" || true
if command_exists npm; then
    ok "node/npm"
    for g in @openai/codex pnpm; do
        npm ls -g --depth=0 "$g" >/dev/null 2>&1 \
            && ok "npm -g $g" || note "npm -g $g missing (npm install -g $g)"
    done
else
    note "node/npm not on PATH (run: fnm install --lts && fnm default lts-latest)"
fi

# --- SSH keys --------------------------------------------------------------
section "SSH keys"
mapfile -t idfiles < <(
    grep -hiE '^[[:space:]]*IdentityFile[[:space:]]' \
        "$HOME/.ssh/config" "$HOME/.ssh/config.local" 2>/dev/null \
    | awk '{print $2}' | sort -u)
if [[ ${#idfiles[@]} -eq 0 ]]; then
    note "no IdentityFile entries found in ~/.ssh/config[.local]"
else
    for raw in "${idfiles[@]}"; do
        p="$(expand "$raw")"
        [[ -f "$p" ]] && ok "key $raw" || bad "key $raw missing (run setup-ssh-keys.sh)"
    done
fi

# --- Work git identities ---------------------------------------------------
section "Work git identities"
if [[ -f "$HOME/.gitconfig.local" ]]; then
    mapfile -t leaves < <(
        grep -hE '^[[:space:]]*path[[:space:]]*=' "$HOME/.gitconfig.local" \
        | sed -E 's/.*=[[:space:]]*//' | sort -u)
    if [[ ${#leaves[@]} -eq 0 ]]; then note "~/.gitconfig.local has no includes"; fi
    for raw in "${leaves[@]:-}"; do
        [[ -z "$raw" ]] && continue
        p="$(expand "$raw")"
        [[ -f "$p" ]] && ok "identity $raw" || bad "identity $raw referenced but missing"
    done
else
    ok "no ~/.gitconfig.local (personal-only machine)"
fi

# --- Dotfiles repo ---------------------------------------------------------
section "Dotfiles repo"
if git -C "$repo_dir" rev-parse --git-dir >/dev/null 2>&1; then
    [[ -n "$(git -C "$repo_dir" status --porcelain)" ]] \
        && note "uncommitted changes (git status)" || ok "working tree clean"
    if git -C "$repo_dir" rev-parse --abbrev-ref '@{u}' >/dev/null 2>&1; then
        ahead=$(git -C "$repo_dir" rev-list --count '@{u}..HEAD' 2>/dev/null || echo 0)
        behind=$(git -C "$repo_dir" rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)
        [[ "$ahead"  -gt 0 ]] && note "$ahead commit(s) not pushed (git push)"
        [[ "$behind" -gt 0 ]] && note "$behind commit(s) on remote not pulled (git pull; reflects last fetch)"
        [[ "$ahead" -eq 0 && "$behind" -eq 0 ]] && ok "in sync with origin (as of last fetch)"
    else
        note "no upstream tracking branch"
    fi
else
    note "not a git repo — skipping"
fi

# --- Summary ---------------------------------------------------------------
section "Summary"
if [[ $fail -eq 0 && $warn -eq 0 ]]; then
    printf '  %sAll good — no drift.%s\n' "$C_G" "$C_0"
elif [[ $fail -eq 0 ]]; then
    printf '  %d warning(s), no failures.\n' "$warn"
else
    printf '  %s%d failure(s)%s, %d warning(s).\n' "$C_R" "$fail" "$C_0" "$warn"
fi
[[ $fail -eq 0 ]]
