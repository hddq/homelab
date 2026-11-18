#!/usr/bin/env python3
"""Automated disk space cleanup for forge."""

from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
import os
import shutil
import sqlite3
import subprocess
import time
from dataclasses import dataclass
from pathlib import Path

HOME = Path(os.environ.get("HOME", "/home/hddq"))
T3_WORKTREES_DIR = HOME / ".t3" / "worktrees"
T3_DB_PATH = HOME / ".t3" / "userdata" / "statev2.sqlite"
DIRENV_LAYOUTS_DIR = HOME / ".cache" / "direnv-layouts"
GO_BUILD_CACHE = HOME / ".cache" / "go-build"
GO_MOD_CACHE = HOME / "go" / "pkg" / "mod"
GRADLE_DIR = HOME / ".gradle"
PRE_COMMIT_CACHE = HOME / ".cache" / "pre-commit"
PIP_CACHE = HOME / ".cache" / "pip"

HIGH_USAGE_PERCENT = 80.0
CRITICAL_USAGE_PERCENT = 85.0
MIN_FREE_BYTES = 10 * 1024**3  # 10 GiB
GO_BUILD_MAX_BYTES = 1500 * 1024**2  # 1.5 GiB

WORKTREE_ARTIFACT_DIRS = (
    "app/build",
    "build",
    ".gradle",
    "target",
    ".direnv",
    "node_modules/.cache",
)


@dataclass
class ThreadRef:
    thread_id: str
    updated_at: float
    deleted: bool
    archived: bool
    settled: bool


def log(msg: str) -> None:
    print(f"[forge-disk-cleanup] {msg}", flush=True)


def run_cmd(
    cmd: list[str], dry_run: bool = False
) -> subprocess.CompletedProcess[str] | None:
    if dry_run:
        log(f"DRY-RUN cmd: {' '.join(cmd)}")
        return None
    return subprocess.run(cmd, text=True, capture_output=True, check=False)


def disk_pressure(path: Path = HOME) -> tuple[float, int, bool, bool]:
    usage = shutil.disk_usage(path)
    used_pct = (usage.used / usage.total) * 100.0 if usage.total else 0.0
    high = used_pct >= HIGH_USAGE_PERCENT or usage.free < MIN_FREE_BYTES
    critical = used_pct >= CRITICAL_USAGE_PERCENT or usage.free < (MIN_FREE_BYTES // 2)
    return used_pct, usage.free, high, critical


def parse_iso_ts(value: str | None) -> float:
    if not value:
        return 0.0
    try:
        normalized = value.replace("Z", "+00:00")
        return dt.datetime.fromisoformat(normalized).timestamp()
    except ValueError:
        return 0.0


def _rmtree_writable(path: Path) -> None:
    def onerror(func, target, _exc_info) -> None:
        try:
            os.chmod(target, 0o700)
            func(target)
        except OSError:
            pass

    shutil.rmtree(path, onerror=onerror)


def remove_tree(path: Path, dry_run: bool) -> bool:
    if not path.exists() and not path.is_symlink():
        return False
    if dry_run:
        log(f"DRY-RUN rm -rf {path}")
        return True
    try:
        if path.is_symlink() or path.is_file():
            path.unlink()
        else:
            _rmtree_writable(path)
        log(f"Removed {path}")
        return True
    except OSError as exc:
        log(f"WARN: failed to remove {path}: {exc}")
        return False


def dir_size(path: Path) -> int:
    total = 0
    if not path.exists():
        return 0
    for root, _dirs, files in os.walk(path, followlinks=False):
        for name in files:
            fp = Path(root) / name
            try:
                if not fp.is_symlink():
                    total += fp.stat().st_size
            except OSError:
                pass
    return total


def max_mtime(path: Path) -> float:
    latest = 0.0
    try:
        latest = path.stat().st_mtime
    except OSError:
        return 0.0
    if not path.is_dir():
        return latest
    for root, dirs, files in os.walk(path, followlinks=False):
        for name in [*dirs, *files]:
            try:
                st = (Path(root) / name).lstat()
                latest = max(latest, st.st_mtime)
            except OSError:
                pass
    return latest


def prune_old_files(root: Path, max_age_days: float, dry_run: bool) -> int:
    if not root.exists():
        return 0
    cutoff = time.time() - max_age_days * 86400
    removed = 0
    for dirpath, dirs, files in os.walk(root, topdown=False, followlinks=False):
        dp = Path(dirpath)
        for name in files:
            fp = dp / name
            try:
                if fp.is_symlink():
                    continue
                if fp.stat().st_mtime < cutoff:
                    if dry_run:
                        log(f"DRY-RUN unlink {fp}")
                    else:
                        try:
                            fp.unlink()
                        except PermissionError:
                            fp.chmod(0o600)
                            fp.unlink()
                    removed += 1
            except OSError:
                pass
        for name in dirs:
            sub = dp / name
            try:
                if not sub.is_symlink() and not any(sub.iterdir()) and not dry_run:
                    sub.rmdir()
            except OSError:
                pass
    return removed


def load_t3_worktree_refs() -> tuple[dict[Path, list[ThreadRef]], set[Path]]:
    refs: dict[Path, list[ThreadRef]] = {}
    project_roots: set[Path] = set()
    if not T3_DB_PATH.exists():
        return refs, project_roots

    try:
        conn = sqlite3.connect(f"file:{T3_DB_PATH}?mode=ro", uri=True, timeout=5.0)
    except sqlite3.Error as exc:
        log(f"WARN: could not open T3 DB {T3_DB_PATH}: {exc}")
        return refs, project_roots

    try:
        for (root_str,) in conn.execute(
            "SELECT workspace_root FROM projection_projects"
        ):
            if root_str:
                p = Path(root_str)
                if (p / ".git").exists():
                    project_roots.add(p)

        rows = conn.execute(
            """
            SELECT thread_id, updated_at, archived_at, deleted_at, payload_json
            FROM orchestration_v2_projection_threads
            """
        ).fetchall()
        for tid, upd, arch, dele, pj in rows:
            if not pj:
                continue
            try:
                payload = json.loads(pj)
            except json.JSONDecodeError:
                continue
            wt_str = payload.get("worktreePath")
            if not wt_str:
                continue
            wt_path = Path(wt_str)
            refs.setdefault(wt_path, []).append(
                ThreadRef(
                    thread_id=tid,
                    updated_at=parse_iso_ts(upd),
                    deleted=dele is not None,
                    archived=arch is not None,
                    settled=payload.get("settledAt") is not None,
                )
            )
    except sqlite3.Error as exc:
        log(f"WARN: failed reading T3 DB: {exc}")
    finally:
        conn.close()

    return refs, project_roots


def discover_repos(project_roots: set[Path]) -> set[Path]:
    repos = set(project_roots)
    if HOME.exists():
        for entry in HOME.iterdir():
            if entry.is_dir() and (entry / ".git").exists():
                repos.add(entry)
    return repos


def resolve_worktree_repo(wt: Path, repos: set[Path]) -> Path | None:
    git_file = wt / ".git"
    if git_file.is_file():
        try:
            content = git_file.read_text(encoding="utf-8", errors="ignore").strip()
            if content.startswith("gitdir:"):
                gitdir = Path(content.split(":", 1)[1].strip())
                # Typically <repo>/.git/worktrees/<name>
                for parent in gitdir.parents:
                    if parent.name == ".git":
                        return parent.parent
        except OSError:
            pass
    # Fallback: match /home/hddq/.t3/worktrees/<project>/<wt> -> /home/hddq/<project>
    candidate = HOME / wt.parent.name
    if candidate in repos or (candidate / ".git").exists():
        return candidate
    return None


def is_git_clean(wt: Path) -> bool:
    if not (wt / ".git").exists():
        return True
    res = subprocess.run(
        ["git", "-C", str(wt), "status", "--porcelain"],
        text=True,
        capture_output=True,
        check=False,
    )
    if res.returncode != 0:
        return False
    return res.stdout.strip() == ""


def remove_worktree(wt: Path, repo: Path | None, dry_run: bool) -> bool:
    if repo and (repo / ".git").exists():
        res = run_cmd(
            ["git", "-C", str(repo), "worktree", "remove", "--force", str(wt)],
            dry_run=dry_run,
        )
        if dry_run or (res is not None and res.returncode == 0 and not wt.exists()):
            if not dry_run:
                log(f"Removed git worktree {wt}")
            return True
    removed = remove_tree(wt, dry_run=dry_run)
    if repo and (repo / ".git").exists():
        run_cmd(["git", "-C", str(repo), "worktree", "prune"], dry_run=dry_run)
    return removed


def cleanup_worktrees(dry_run: bool, high_pressure: bool) -> None:
    now = time.time()
    refs_by_wt, project_roots = load_t3_worktree_refs()
    repos = discover_repos(project_roots)

    for repo in sorted(repos):
        res = run_cmd(
            ["git", "-C", str(repo), "worktree", "prune", "-v"], dry_run=dry_run
        )
        if res and res.stdout.strip():
            log(f"Pruned worktrees in {repo.name}: {res.stdout.strip()}")

    if not T3_WORKTREES_DIR.exists():
        return

    settled_artifact_age = 12 * 3600 if high_pressure else 24 * 3600
    settled_remove_age = 3 * 86400 if high_pressure else 7 * 86400
    orphan_age = 12 * 3600 if high_pressure else 24 * 3600

    for proj_dir in sorted(T3_WORKTREES_DIR.iterdir()):
        if not proj_dir.is_dir():
            continue
        for wt in sorted(proj_dir.iterdir()):
            if not wt.is_dir():
                continue

            repo = resolve_worktree_repo(wt, repos)
            thread_refs = refs_by_wt.get(wt, [])
            wt_mtime = wt.stat().st_mtime
            clean = is_git_clean(wt)

            if thread_refs:
                active_refs = [r for r in thread_refs if not r.deleted]
                if not active_refs:
                    # All referencing threads were deleted in T3.
                    latest_upd = max(r.updated_at for r in thread_refs)
                    if clean or (now - latest_upd) > 3 * 86400:
                        remove_worktree(wt, repo, dry_run=dry_run)
                    else:
                        log(f"Skipping dirty deleted-thread worktree (<3d): {wt}")
                    continue

                all_settled_or_archived = all(
                    r.settled or r.archived for r in active_refs
                )
                latest_upd = max(r.updated_at for r in active_refs)
                age = now - max(latest_upd, wt_mtime)

                if all_settled_or_archived and age > settled_remove_age and clean:
                    remove_worktree(wt, repo, dry_run=dry_run)
                    continue

                if all_settled_or_archived and age > settled_artifact_age:
                    for rel in WORKTREE_ARTIFACT_DIRS:
                        target = wt / rel
                        if target.exists() or target.is_symlink():
                            remove_tree(target, dry_run=dry_run)
            else:
                # Not tracked in T3 DB (or DB unavailable: only remove if DB opened cleanly).
                if refs_by_wt and (now - wt_mtime) > orphan_age and clean:
                    remove_worktree(wt, repo, dry_run=dry_run)

    for repo in sorted(repos):
        run_cmd(["git", "-C", str(repo), "worktree", "prune"], dry_run=dry_run)


def compute_direnv_layout_hash(directory: Path) -> str | None:
    flake_nix = directory / "flake.nix"
    if not flake_nix.is_file():
        return None
    lines: list[str] = []
    for fname in (flake_nix, directory / "flake.lock"):
        if fname.is_file():
            digest = hashlib.sha256(fname.read_bytes()).hexdigest()
            lines.append(f"{digest}\n")
    if not lines:
        return None
    return hashlib.sha256("".join(lines).encode("utf-8")).hexdigest()


def active_main_layout_hashes() -> set[str]:
    hashes: set[str] = set()
    if not HOME.exists():
        return hashes
    for entry in HOME.iterdir():
        if entry.is_dir() and (entry / "flake.nix").is_file():
            h = compute_direnv_layout_hash(entry)
            if h:
                hashes.add(h)
    return hashes


def cleanup_direnv_layouts(dry_run: bool, high_pressure: bool) -> int:
    if not DIRENV_LAYOUTS_DIR.exists():
        return 0
    max_age_days = 1.0 if high_pressure else 3.0
    cutoff = time.time() - max_age_days * 86400
    protected = active_main_layout_hashes()
    removed = 0

    for layout in sorted(DIRENV_LAYOUTS_DIR.iterdir()):
        if not layout.is_dir():
            continue
        if layout.name in protected:
            continue
        rc_files = list(layout.glob("flake-profile*.rc"))
        latest = max(
            [layout.stat().st_mtime, *(f.stat().st_mtime for f in rc_files)],
        )
        if latest < cutoff and remove_tree(layout, dry_run=dry_run):
            removed += 1
    return removed


def cleanup_caches(dry_run: bool, high_pressure: bool, critical: bool) -> None:
    # 1. Go build cache
    if GO_BUILD_CACHE.exists():
        if critical or dir_size(GO_BUILD_CACHE) > GO_BUILD_MAX_BYTES:
            remove_tree(GO_BUILD_CACHE, dry_run=dry_run)
        else:
            max_days = 1.0 if high_pressure else 3.0
            n = prune_old_files(GO_BUILD_CACHE, max_days, dry_run=dry_run)
            if n:
                log(f"Pruned {n} old files from {GO_BUILD_CACHE}")

    # 2. Go module cache (only under critical disk pressure)
    if critical and GO_MOD_CACHE.exists():
        remove_tree(GO_MOD_CACHE, dry_run=dry_run)

    # 3. Gradle caches
    caches_dir = GRADLE_DIR / "caches"
    if caches_dir.exists():
        build_cache_days = 2.0 if high_pressure else 7.0
        for bc in caches_dir.glob("build-cache-*"):
            if bc.is_dir():
                n = prune_old_files(bc, build_cache_days, dry_run=dry_run)
                if n:
                    log(f"Pruned {n} old entries from {bc}")

        # Prune old Gradle version-specific cache dirs (>14d untouched), keeping newest.
        ver_dirs = [
            d for d in caches_dir.iterdir() if d.is_dir() and d.name[0].isdigit()
        ]
        if len(ver_dirs) > 1:
            ver_dirs.sort(key=max_mtime, reverse=True)
            ver_cutoff = time.time() - (7.0 if high_pressure else 14.0) * 86400
            for old_ver in ver_dirs[1:]:
                if max_mtime(old_ver) < ver_cutoff:
                    remove_tree(old_ver, dry_run=dry_run)

    daemon_dir = GRADLE_DIR / "daemon"
    if daemon_dir.exists():
        cutoff = time.time() - 3.0 * 86400
        pruned_logs = 0
        for log_file in daemon_dir.glob("*/daemon-*.out.log"):
            try:
                if log_file.stat().st_mtime < cutoff:
                    if dry_run:
                        log(f"DRY-RUN unlink {log_file}")
                    else:
                        log_file.unlink()
                    pruned_logs += 1
            except OSError:
                pass
        if pruned_logs:
            log(f"Pruned {pruned_logs} old gradle daemon logs")

    # 4. Pre-commit and pip caches
    misc_days = 3.0 if critical else (7.0 if high_pressure else 30.0)
    for cache_dir in (PRE_COMMIT_CACHE, PIP_CACHE):
        if cache_dir.exists():
            n = prune_old_files(cache_dir, misc_days, dry_run=dry_run)
            if n:
                log(f"Pruned {n} old files from {cache_dir}")


def main() -> int:
    parser = argparse.ArgumentParser(description="Automated disk cleanup for forge")
    parser.add_argument(
        "--dry-run", action="store_true", help="Print actions without deleting"
    )
    args = parser.parse_args()

    used_pct, free_bytes, high, critical = disk_pressure()
    log(
        f"Starting cleanup (used={used_pct:.1f}%, free={free_bytes / (1024**3):.2f} GiB, "
        f"high={high}, critical={critical})"
    )

    cleanup_worktrees(dry_run=args.dry_run, high_pressure=high)
    removed_layouts = cleanup_direnv_layouts(dry_run=args.dry_run, high_pressure=high)
    cleanup_caches(dry_run=args.dry_run, high_pressure=high, critical=critical)

    if removed_layouts > 0 or high:
        log("Running nix-store --gc...")
        res = run_cmd(["nix-store", "--gc"], dry_run=args.dry_run)
        if res and res.returncode != 0:
            log(
                f"WARN: nix-store --gc exited with {res.returncode}: {res.stderr.strip()}"
            )

    used_pct_after, free_after, _, _ = disk_pressure()
    log(
        f"Finished cleanup (used={used_pct_after:.1f}%, "
        f"free={free_after / (1024**3):.2f} GiB)"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
