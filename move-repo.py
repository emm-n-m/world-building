#!/usr/bin/env python3
"""Move a Git repository while keeping local Codex and Claude project state."""

from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import tomllib
from typing import Any, Callable


class MoveError(RuntimeError):
    pass


def under(path: str | Path, root: Path) -> bool:
    candidate = os.path.normpath(os.fspath(path))
    base = os.fspath(root)
    return candidate == base or candidate.startswith(base + os.sep)


def remap_path(value: str, source: Path, target: Path) -> str:
    if not under(value, source):
        return value
    return os.fspath(target) + os.path.normpath(value)[len(os.fspath(source)) :]


def replace_embedded_path(value: str, source: Path, target: Path) -> str:
    """Replace source where it is a complete path or a path prefix in text."""
    old = re.escape(os.fspath(source))
    return re.sub(old + r"(?=$|[/\s\"'])", lambda _: os.fspath(target), value)


def remap_tree(value: Any, source: Path, target: Path) -> Any:
    if isinstance(value, str):
        return replace_embedded_path(value, source, target)
    if isinstance(value, list):
        return [remap_tree(item, source, target) for item in value]
    if isinstance(value, dict):
        result: dict[str, Any] = {}
        for key, item in value.items():
            new_key = replace_embedded_path(key, source, target)
            if new_key in result:
                raise MoveError(f"state key collision while mapping {key!r} to {new_key!r}")
            result[new_key] = remap_tree(item, source, target)
        return result
    return value


def load_json(path: Path) -> Any:
    try:
        with path.open(encoding="utf-8") as handle:
            return json.load(handle)
    except (OSError, json.JSONDecodeError) as exc:
        raise MoveError(f"cannot read JSON state {path}: {exc}") from exc


def atomic_write(path: Path, data: str) -> None:
    mode = path.stat().st_mode
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False
    ) as handle:
        temp = Path(handle.name)
        try:
            handle.write(data)
            handle.flush()
            os.fsync(handle.fileno())
            os.chmod(temp, mode)
        except BaseException:
            temp.unlink(missing_ok=True)
            raise
    os.replace(temp, path)


def dump_json(path: Path, value: Any) -> None:
    atomic_write(path, json.dumps(value, ensure_ascii=False, indent=2) + "\n")


def transform_jsonl(path: Path, transform: Callable[[Any], Any]) -> bool:
    changed = False
    output: list[str] = []
    try:
        with path.open(encoding="utf-8") as handle:
            for number, line in enumerate(handle, 1):
                if not line.strip():
                    output.append(line)
                    continue
                try:
                    before = json.loads(line)
                except json.JSONDecodeError as exc:
                    raise MoveError(f"invalid JSON on {path}:{number}: {exc}") from exc
                after = transform(before)
                if after != before:
                    changed = True
                    output.append(json.dumps(after, ensure_ascii=False, separators=(",", ":")) + "\n")
                else:
                    output.append(line)
    except OSError as exc:
        raise MoveError(f"cannot read state file {path}: {exc}") from exc
    if changed:
        atomic_write(path, "".join(output))
    return changed


def claude_slug(path: Path) -> str:
    # This is the directory encoding used by Claude Code on Unix. Collision
    # checks below protect against its intentionally lossy slash-to-dash mapping.
    return os.fspath(path).replace(os.sep, "-")


def active_sessions(source: Path, claude_home: Path) -> list[str]:
    found: set[str] = set()
    sessions = claude_home / "sessions"
    if sessions.is_dir():
        for path in sessions.glob("*.json"):
            with contextlib.suppress(Exception):
                state = load_json(path)
                cwd, pid = state.get("cwd"), int(state.get("pid"))
                if isinstance(cwd, str) and under(cwd, source):
                    os.kill(pid, 0)
                    found.add(f"Claude PID {pid}")

    uid = os.getuid()
    proc = Path("/proc")
    if proc.is_dir():
        for entry in proc.iterdir():
            if not entry.name.isdigit():
                continue
            with contextlib.suppress(OSError, UnicodeDecodeError):
                if entry.stat().st_uid != uid or int(entry.name) == os.getpid():
                    continue
                cwd = Path(os.readlink(entry / "cwd"))
                if not under(cwd, source):
                    continue
                command = (entry / "cmdline").read_bytes().replace(b"\0", b" ").decode()
                if re.search(r"(?:^|[/ ])(?:codex|claude)(?:[ /]|$)", command, re.I):
                    found.add(f"PID {entry.name}: {command[:100].strip()}")
    return sorted(found)


class Backup:
    def __init__(self, root: Path, source: Path, target: Path) -> None:
        self.root = root
        self.source = source
        self.target = target
        self.files: dict[Path, Path] = {}
        self.databases: dict[Path, Path] = {}
        self.directories: dict[Path, Path] = {}
        self.renames: list[tuple[Path, Path]] = []
        self.repo_moved = False
        self.repo_move_kind = "directory"

    def snapshot_file(self, path: Path, label: str) -> None:
        if path in self.files:
            return
        destination = self.root / "files" / label
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(path, destination)
        self.files[path] = destination

    def snapshot_database(self, path: Path, label: str) -> None:
        if path in self.databases:
            return
        destination = self.root / "databases" / label
        destination.parent.mkdir(parents=True, exist_ok=True)
        source_db = sqlite3.connect(path)
        backup_db = sqlite3.connect(destination)
        try:
            source_db.backup(backup_db)
        finally:
            backup_db.close()
            source_db.close()
        self.databases[path] = destination

    def snapshot_directory(self, path: Path, label: str) -> None:
        if path in self.directories:
            return
        destination = self.root / "directories" / label
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copytree(path, destination, symlinks=True)
        self.directories[path] = destination

    def manifest(self, complete: bool = False) -> None:
        data = {
            "source": os.fspath(self.source),
            "target": os.fspath(self.target),
            "complete": complete,
            "files": {os.fspath(k): os.fspath(v.relative_to(self.root)) for k, v in self.files.items()},
            "databases": {
                os.fspath(k): os.fspath(v.relative_to(self.root)) for k, v in self.databases.items()
            },
            "directories": {
                os.fspath(k): os.fspath(v.relative_to(self.root)) for k, v in self.directories.items()
            },
        }
        path = self.root / "manifest.json"
        if path.exists():
            dump_json(path, data)
        else:
            path.write_text(json.dumps(data, indent=2) + "\n", encoding="utf-8")

    def rollback(self) -> list[str]:
        errors: list[str] = []
        if self.repo_moved and self.target.exists() and not self.source.exists():
            try:
                move_repository(self.target, self.source, self.repo_move_kind)
            except Exception as exc:
                errors.append(f"repo rollback failed: {exc}")
        for old, new in reversed(self.renames):
            try:
                if new.exists() and not old.exists():
                    new.rename(old)
            except Exception as exc:
                errors.append(f"state directory rollback failed for {old}: {exc}")
        for original, saved in self.directories.items():
            try:
                if original.exists():
                    shutil.rmtree(original)
                shutil.copytree(saved, original, symlinks=True)
            except Exception as exc:
                errors.append(f"directory rollback failed for {original}: {exc}")
        for original, saved in self.files.items():
            try:
                original.parent.mkdir(parents=True, exist_ok=True)
                shutil.copy2(saved, original)
            except Exception as exc:
                errors.append(f"file rollback failed for {original}: {exc}")
        for original, saved in self.databases.items():
            try:
                source_db = sqlite3.connect(saved)
                target_db = sqlite3.connect(original)
                try:
                    source_db.backup(target_db)
                finally:
                    target_db.close()
                    source_db.close()
            except Exception as exc:
                errors.append(f"database rollback failed for {original}: {exc}")
        return errors


def codex_session_transform(source: Path, target: Path) -> Callable[[Any], Any]:
    def transform(record: Any) -> Any:
        if not isinstance(record, dict) or record.get("type") != "session_meta":
            return record
        payload = record.get("payload")
        if not isinstance(payload, dict):
            return record
        result = dict(record)
        new_payload = dict(payload)
        for key in ("cwd", "runtime_workspace_roots", "sandbox_policy"):
            if key in new_payload:
                new_payload[key] = remap_tree(new_payload[key], source, target)
        result["payload"] = new_payload
        return result

    return transform


def check_codex_config_collision(source: Path, target: Path, home: Path) -> None:
    path = home / "config.toml"
    if not path.is_file():
        return
    try:
        with path.open("rb") as handle:
            config = tomllib.load(handle)
    except (OSError, tomllib.TOMLDecodeError) as exc:
        raise MoveError(f"cannot parse Codex config {path}: {exc}") from exc
    projects = config.get("projects", {})
    if not isinstance(projects, dict):
        return
    keys = set(projects)
    for old_key in keys:
        if not under(old_key, source):
            continue
        new_key = remap_path(old_key, source, target)
        if new_key != old_key and new_key in keys:
            raise MoveError(f"Codex project state already exists at destination: {new_key}")


def migrate_codex(source: Path, target: Path, home: Path, backup: Backup) -> dict[str, int]:
    counts = {"config": 0, "rules": 0, "sessions": 0, "databases": 0}
    config = home / "config.toml"
    if config.is_file():
        text = config.read_text(encoding="utf-8")
        updated = replace_embedded_path(text, source, target)
        if updated != text:
            backup.snapshot_file(config, "codex/config.toml")
            atomic_write(config, updated)
            counts["config"] += 1

    rules = home / "rules"
    if rules.is_dir():
        for path in rules.rglob("*.rules"):
            text = path.read_text(encoding="utf-8")
            updated = replace_embedded_path(text, source, target)
            if updated != text:
                backup.snapshot_file(path, f"codex/{path.relative_to(home)}")
                atomic_write(path, updated)
                counts["rules"] += 1

    transform = codex_session_transform(source, target)
    for dirname in ("sessions", "archived_sessions"):
        root = home / dirname
        if not root.is_dir():
            continue
        for path in root.rglob("*.jsonl"):
            if os.fspath(source) not in path.read_text(encoding="utf-8", errors="replace"):
                continue
            backup.snapshot_file(path, f"codex/{path.relative_to(home)}")
            if transform_jsonl(path, transform):
                counts["sessions"] += 1

    for database in home.glob("state_*.sqlite"):
        connection = sqlite3.connect(database, timeout=2)
        try:
            tables = {row[0] for row in connection.execute("select name from sqlite_master where type='table'")}
            thread_columns = (
                {row[1] for row in connection.execute("pragma table_info(threads)")}
                if "threads" in tables
                else set()
            )
            has_policy = "sandbox_policy" in thread_columns
            updates: list[tuple[Any, ...]] = []
            if "cwd" in thread_columns:
                policy_select = ", sandbox_policy" if has_policy else ""
                for row in connection.execute(f"select rowid, cwd{policy_select} from threads"):
                    rowid, cwd = row[:2]
                    policy = row[2] if has_policy else None
                    new_cwd = remap_path(cwd, source, target) if isinstance(cwd, str) else cwd
                    new_policy = policy
                    if isinstance(policy, str) and os.fspath(source) in policy:
                        try:
                            new_policy = json.dumps(
                                remap_tree(json.loads(policy), source, target), separators=(",", ":")
                            )
                        except json.JSONDecodeError:
                            new_policy = replace_embedded_path(policy, source, target)
                    if (new_cwd, new_policy) != (cwd, policy):
                        updates.append((new_cwd, new_policy, rowid) if has_policy else (new_cwd, rowid))
            root_updates: list[tuple[str, int]] = []
            root_columns = (
                {row[1] for row in connection.execute("pragma table_info(project_roots)")}
                if "project_roots" in tables
                else set()
            )
            if "path" in root_columns:
                for rowid, value in connection.execute("select rowid, path from project_roots"):
                    new_value = remap_path(value, source, target) if isinstance(value, str) else value
                    if new_value != value:
                        root_updates.append((new_value, rowid))
            if not updates and not root_updates:
                continue
            backup.snapshot_database(database, f"codex/{database.name}")
            connection.execute("begin immediate")
            thread_sql = (
                "update threads set cwd = ?, sandbox_policy = ? where rowid = ?"
                if has_policy
                else "update threads set cwd = ? where rowid = ?"
            )
            connection.executemany(thread_sql, updates)
            connection.executemany("update project_roots set path = ? where rowid = ?", root_updates)
            connection.commit()
            counts["databases"] += 1
        except sqlite3.Error as exc:
            with contextlib.suppress(sqlite3.Error):
                connection.rollback()
            raise MoveError(f"cannot migrate Codex database {database}: {exc}") from exc
        finally:
            connection.close()
    return counts


def claude_project_dirs(source: Path, target: Path, home: Path, config: Any) -> list[tuple[Path, Path]]:
    projects_dir = home / "projects"
    mappings: dict[Path, Path] = {}
    project_keys: list[Path] = []
    if isinstance(config, dict) and isinstance(config.get("projects"), dict):
        project_keys = [Path(key) for key in config["projects"] if under(key, source)]
    project_keys.append(source)
    for old_path in project_keys:
        old_dir = projects_dir / claude_slug(old_path)
        if old_dir.exists():
            new_path = Path(remap_path(old_path, source, target))
            new_dir = projects_dir / claude_slug(new_path)
            if old_dir in mappings and mappings[old_dir] != new_dir:
                raise MoveError(f"ambiguous Claude project directory encoding: {old_dir}")
            mappings[old_dir] = new_dir
    for old_dir, new_dir in mappings.items():
        if new_dir.exists() and new_dir != old_dir:
            raise MoveError(f"Claude state already exists at destination: {new_dir}")
    return sorted(mappings.items(), key=lambda pair: len(os.fspath(pair[0])), reverse=True)


def migrate_claude(source: Path, target: Path, home: Path, backup: Backup) -> dict[str, int]:
    counts = {"config": 0, "history": 0, "project_dirs": 0, "transcripts": 0}
    config_path = home.parent / ".claude.json"
    config: Any = load_json(config_path) if config_path.is_file() else {}
    directories = claude_project_dirs(source, target, home, config)

    if config_path.is_file():
        updated = remap_tree(config, source, target)
        if updated != config:
            backup.snapshot_file(config_path, "claude/.claude.json")
            dump_json(config_path, updated)
            counts["config"] += 1

    history = home / "history.jsonl"
    if history.is_file() and os.fspath(source) in history.read_text(encoding="utf-8", errors="replace"):
        def transform_history(record: Any) -> Any:
            if not isinstance(record, dict):
                return record
            result = dict(record)
            for key in ("project", "cwd"):
                if isinstance(result.get(key), str):
                    result[key] = remap_path(result[key], source, target)
            return result

        backup.snapshot_file(history, "claude/history.jsonl")
        if transform_jsonl(history, transform_history):
            counts["history"] += 1

    for old_dir, new_dir in directories:
        backup.snapshot_directory(old_dir, f"claude/projects/{old_dir.name}")
        old_dir.rename(new_dir)
        backup.renames.append((old_dir, new_dir))
        counts["project_dirs"] += 1
        for transcript in new_dir.rglob("*.jsonl"):
            def transform_transcript(record: Any) -> Any:
                if not isinstance(record, dict):
                    return record
                result = dict(record)
                if isinstance(result.get("cwd"), str):
                    result["cwd"] = remap_path(result["cwd"], source, target)
                return result

            if transform_jsonl(transcript, transform_transcript):
                counts["transcripts"] += 1
        memory = new_dir / "memory"
        if memory.is_dir():
            for path in memory.rglob("*.md"):
                text = path.read_text(encoding="utf-8")
                updated = replace_embedded_path(text, source, target)
                if updated != text:
                    atomic_write(path, updated)
    return counts


def git_output(repo: Path, *args: str) -> str:
    result = subprocess.run(
        ["git", "-C", os.fspath(repo), *args], text=True, capture_output=True, check=False
    )
    if result.returncode:
        raise MoveError(result.stderr.strip() or f"git {' '.join(args)} failed")
    return result.stdout.strip()


def repository_move_kind(repo: Path) -> str:
    git_dir = Path(git_output(repo, "rev-parse", "--path-format=absolute", "--git-dir"))
    common_dir = Path(git_output(repo, "rev-parse", "--path-format=absolute", "--git-common-dir"))
    return "worktree" if git_dir != common_dir else "directory"


def move_repository(source: Path, target: Path, kind: str) -> None:
    if kind == "worktree":
        result = subprocess.run(
            [
                "git",
                "-C",
                os.fspath(source),
                "worktree",
                "move",
                os.fspath(source),
                os.fspath(target),
            ],
            text=True,
            capture_output=True,
            check=False,
        )
        if result.returncode:
            raise MoveError(result.stderr.strip() or "git worktree move failed")
    else:
        shutil.move(os.fspath(source), os.fspath(target))


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(
        description="Move REPOSITORY under NEW_ROOT and migrate its Codex/Claude chats and permissions."
    )
    parser.add_argument("repository", type=Path, help="Git repository to move")
    parser.add_argument("new_root", type=Path, help="existing parent directory for the repository")
    parser.add_argument("--dry-run", action="store_true", help="show the move without changing anything")
    parser.add_argument(
        "--allow-active",
        action="store_true",
        help="proceed even if a Codex/Claude process appears active in the repository",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    source_arg = args.repository.expanduser()
    root_arg = args.new_root.expanduser()
    if source_arg.is_symlink():
        raise MoveError("the repository argument must not be a symlink")
    if not source_arg.is_dir():
        raise MoveError(f"repository does not exist: {source_arg}")
    if not root_arg.is_dir():
        raise MoveError(f"destination root must already exist: {root_arg}")
    source = source_arg.resolve()
    new_root = root_arg.resolve()
    repo_root = Path(git_output(source, "rev-parse", "--show-toplevel")).resolve()
    if repo_root != source:
        raise MoveError(f"repository must name its top level: {repo_root}")
    target = new_root / source.name
    if target == source:
        raise MoveError("repository is already under that root")
    if under(target, source) or under(new_root, source):
        raise MoveError("destination root cannot be inside the repository")
    if target.exists() or target.is_symlink():
        raise MoveError(f"destination already exists: {target}")

    codex_home = Path(os.environ.get("CODEX_HOME", Path.home() / ".codex")).expanduser()
    claude_home = Path(os.environ.get("CLAUDE_CONFIG_DIR", Path.home() / ".claude")).expanduser()
    active = active_sessions(source, claude_home)
    if active and not args.allow_active and not args.dry_run:
        detail = "\n  ".join(active)
        raise MoveError(
            "close active Codex/Claude sessions in this repository first "
            f"(or use --allow-active):\n  {detail}"
        )

    config_path = claude_home.parent / ".claude.json"
    config = load_json(config_path) if config_path.is_file() else {}
    check_codex_config_collision(source, target, codex_home)
    remap_tree(config, source, target)  # preflight key collisions before making changes
    claude_dirs = claude_project_dirs(source, target, claude_home, config)
    kind = repository_move_kind(source)

    print(f"Repository: {source}")
    print(f"Target:     {target}")
    print(f"Git move:   {kind}")
    print(f"Claude project directories: {len(claude_dirs)}")
    if active:
        print(f"Active Codex/Claude sessions detected: {len(active)}")
    if args.dry_run:
        print("Dry run: no files were changed.")
        return 0

    state_root = Path(os.environ.get("XDG_STATE_HOME", Path.home() / ".local/state"))
    operation_root = state_root / "repo-move"
    operation_root.mkdir(parents=True, exist_ok=True)
    os.chmod(operation_root, 0o700)
    lock_path = operation_root / "move.lock"
    stamp = dt.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S-%f%z")
    backup_root = operation_root / "backups" / f"{stamp}-{source.name}"
    backup_root.mkdir(parents=True)
    os.chmod(backup_root, 0o700)
    backup = Backup(backup_root, source, target)
    backup.repo_move_kind = kind

    with lock_path.open("w") as lock:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError as exc:
            raise MoveError("another repo move is already running") from exc
        try:
            codex_counts = migrate_codex(source, target, codex_home, backup)
            claude_counts = migrate_claude(source, target, claude_home, backup)
            backup.manifest()
            move_repository(source, target, kind)
            backup.repo_moved = True
            backup.manifest(complete=True)
        except BaseException:
            errors = backup.rollback()
            if errors:
                print("Rollback was incomplete:", file=sys.stderr)
                for error in errors:
                    print(f"  {error}", file=sys.stderr)
                print(f"Backups: {backup_root}", file=sys.stderr)
            raise

    print(f"Moved repository to {target}")
    print(
        "Codex: "
        f"{codex_counts['sessions']} session file(s), "
        f"{codex_counts['databases']} database(s), "
        f"{codex_counts['config']} config file(s), "
        f"{codex_counts['rules']} rule file(s)"
    )
    print(
        "Claude: "
        f"{claude_counts['project_dirs']} project directory/directories, "
        f"{claude_counts['transcripts']} transcript(s), "
        f"{claude_counts['config']} config file(s), "
        f"{claude_counts['history']} history file(s)"
    )
    print(f"Backups: {backup_root}")
    print(f"Next: cd {shlex_quote(os.fspath(target))}")
    return 0


def shlex_quote(value: str) -> str:
    import shlex

    return shlex.quote(value)


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except MoveError as exc:
        print(f"Error: {exc}", file=sys.stderr)
        raise SystemExit(2)
