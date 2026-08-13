# Dotfiles

Shared workstation setup for Linux machines.

## What This Sets Up

- Base development packages from `packages.txt` (includes GitHub CLI `gh`)
- Rust through `rustup`
- Python 3.14 and tooling through `uv`
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
python --version
uv python list --only-installed
fnm install --lts
fnm default lts-latest
```

## Files

- `bootstrap.sh`: installs packages and language/tool managers.
- `install.sh`: symlinks dotfiles into `$HOME`, backing up existing files first.
- `setup-ssh-keys.sh`: generates this machine's SSH keys and prints the public keys to register.
- `check.sh`: read-only drift check — verifies symlinks, packages, toolchains, SSH keys, work identities, and repo sync.
- `packages.txt`: apt packages for a baseline development environment.
- `.bashrc.local`: aliases and local shell variables.
- `.gitconfig`: Git defaults + personal identity.
- `.gitignore_global`: global Git ignore rules.
- `githooks/`: machine-wide Git hooks (symlinked to `~/.githooks`).
- `ssh_config`: personal SSH config (symlinked to `~/.ssh/config`).
- `gitconfig.local.example` / `ssh_config.local.example`: templates for the
  machine-local work config described below.

## Git & SSH Identities (personal vs work)

Only personal config is committed and synced. Work identities, employer hosts,
custom SSH ports, and per-context keys stay **local to the machines that need
them** and are git-ignored — so personal-only devices (VM, tablet) sync cleanly
while work machines keep their own, changeable setup.

- Committed `.gitconfig` sets the default personal identity and ends with
  `[include] path = ~/.gitconfig.local`.
- Committed `ssh_config` has the personal `github.com` host and
  `Include ~/.ssh/config.local`.
- A missing local file is silently ignored, so personal machines need no extra
  setup.

On a **work machine**, create the local files from the templates:

```bash
cp gitconfig.local.example   ~/.gitconfig.local      # then edit
cp ssh_config.local.example  ~/.ssh/config.local     # then edit
# plus a leaf ~/.gitconfig-<ctx> per work identity (see the template)
chmod 600 ~/.ssh/config.local
```

Work identities are selected automatically by the repo's remote URL
(`includeIf "hasconfig:remote.*.url:…"`, requires git >= 2.36).

## Git Hooks (machine-wide)

`.gitconfig` sets `core.hooksPath = ~/.githooks`, which `install.sh` symlinks to
`githooks/` in this repo. Hooks therefore apply to **every** repo on the machine
and arrive with a `git pull` — no per-clone setup to remember, which is the
point: a hook that has to be installed per clone is a hook that will be missing
on the clone that mattered.

- `commit-msg`: strips Claude Code's `Claude-Session:` trailer, and any bare
  `https://claude.ai/code/session_…` link, out of commit messages. The links are
  auth-gated, but session ids do not belong in the permanent history of a public
  repo. A URL inside a sentence is scrubbed in place rather than deleting the
  line.

Two consequences worth knowing:

- This overrides `.git/hooks` everywhere. Nothing currently uses it, and tools
  that set `core.hooksPath` themselves (husky) still win, but a tool that
  installs *into* `.git/hooks` (pre-commit) would go silent. Opt that repo out
  with `git config core.hooksPath .git/hooks`.
- It only guards commits made from here on. History already pushed keeps
  whatever it has.

## SSH Keys (per machine)

Private keys are never stored in this repo. Instead, each machine generates its
own keypairs so a lost or retired machine can be revoked at each host
individually, without rotating any other machine's keys:

```bash
./setup-ssh-keys.sh
```

It creates the keys the SSH config expects (skipping any that already exist),
tags each with `user@hostname`, and prints the public keys plus where to
register them. Run it on every new machine and add the printed keys to GitHub /
the GitLab instances.

## Checking For Drift

Run the doctor anytime to see whether a machine still matches the repo instead
of waiting for something to break:

```bash
./check.sh
```

It's read-only and reports each item as `ok` / `warn` / `FAIL`, exiting non-zero
on any hard failure (so it can gate a login hook or CI). It checks that the
dotfile symlinks point into the repo, every `packages.txt` package is installed,
the toolchains (`rustup`, `uv`, `fnm`, `gh`, node/npm) are present, every SSH key
referenced by the config exists, work identities resolve, and the repo has no
uncommitted or unpushed changes.

## Shell Integration

Source `.bashrc.local` from your main shell config:

```bash
source ~/.bashrc.local
```

The installer creates `~/.bashrc.local` as a symlink to this repo.
