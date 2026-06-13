# Dotfiles

Shared workstation setup for Linux machines.

## What This Sets Up

- Base development packages from `packages.txt`
- Rust through `rustup`
- Python tooling through `uv`
- Node.js through `fnm`
- Global npm tools: `@openai/codex` and `pnpm`
- Personal shell, Git, and global ignore configuration

## Bootstrap A New Machine

```bash
./bootstrap.sh
./install.sh
```

Then restart your shell and run:

```bash
fnm install --lts
fnm default lts-latest
```

## Files

- `bootstrap.sh`: installs packages and language/tool managers.
- `install.sh`: symlinks dotfiles into `$HOME`, backing up existing files first.
- `packages.txt`: apt packages for a baseline development environment.
- `.bashrc.local`: aliases and local shell variables.
- `.gitconfig`: Git defaults.
- `.gitignore_global`: global Git ignore rules.

## Shell Integration

Source `.bashrc.local` from your main shell config:

```bash
source ~/.bashrc.local
```

The installer creates `~/.bashrc.local` as a symlink to this repo.
