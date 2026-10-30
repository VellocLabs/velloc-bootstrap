#!/usr/bin/env python3
from __future__ import annotations

import argparse
import json
import os
import shutil
import subprocess
import sys
import threading
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
DEPOT_TOOLS_DIR = ROOT / "depot_tools"
SRC_DIR = ROOT / "src"
CUSTOM_BROWSER_DIR = SRC_DIR / "custom_browser"
GCLIENT_FILE = ROOT / ".gclient"
MANIFEST_PATH = ROOT / "release_manifest.json"
DEPOT_TOOLS_URL = "https://chromium.googlesource.com/chromium/tools/depot_tools.git"
DEFAULT_SRC_BRANCH = "custom/main"
DEFAULT_SRC_REVISION = f"refs/heads/{DEFAULT_SRC_BRANCH}"
DEFAULT_CUSTOM_BROWSER_URL = "https://github.com/VellocLabs/velloc-core.git"
DEFAULT_CUSTOM_BROWSER_BRANCH = "main"
DEFAULT_CUSTOM_BROWSER_REVISION = f"refs/heads/{DEFAULT_CUSTOM_BROWSER_BRANCH}"
_GCLIENT_CMD: list[str] | None = None


class CommandError(RuntimeError):
    pass


def _stream_pipe(pipe, target, buffer) -> None:
    for line in iter(pipe.readline, ""):
        target.write(line)
        target.flush()
        if buffer is not None:
            buffer.append(line)
    pipe.close()


def run(
    cmd: list[str],
    cwd: Path | None = None,
    env: dict[str, str] | None = None,
    capture: bool = True,
) -> str:
    if not capture:
        result = subprocess.run(
            cmd,
            cwd=str(cwd) if cwd else None,
            env=env,
            text=True,
        )
        if result.returncode != 0:
            raise CommandError(f"Command failed: {' '.join(cmd)}")
        return ""

    process = subprocess.Popen(
        cmd,
        cwd=str(cwd) if cwd else None,
        env=env,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    stdout_buffer = [] if capture else None
    stderr_buffer = [] if capture else None

    threads = []
    if process.stdout is not None:
        threads.append(
            threading.Thread(
                target=_stream_pipe, args=(process.stdout, sys.stdout, stdout_buffer), daemon=True
            )
        )
    if process.stderr is not None:
        threads.append(
            threading.Thread(
                target=_stream_pipe, args=(process.stderr, sys.stderr, stderr_buffer), daemon=True
            )
        )

    for thread in threads:
        thread.start()

    returncode = process.wait()
    for thread in threads:
        thread.join()

    if returncode != 0:
        stderr = "".join(stderr_buffer).strip() if stderr_buffer is not None else ""
        message = f"Command failed: {' '.join(cmd)}"
        if stderr:
            message = f"{message}\n{stderr}"
        raise CommandError(message)

    return "".join(stdout_buffer).strip() if stdout_buffer is not None else ""


def note(message: str) -> None:
    print(message)


def fail(message: str) -> None:
    raise CommandError(message)


def require_cmd(name: str) -> None:
    if shutil.which(name) is None:
        fail(f"{name} is required")


def setup_path() -> None:
    if not DEPOT_TOOLS_DIR.is_dir():
        fail(f"depot_tools not found at {DEPOT_TOOLS_DIR}")
    os.environ["PATH"] = str(DEPOT_TOOLS_DIR) + os.pathsep + os.environ.get("PATH", "")


def check_gclient_config() -> None:
    if not GCLIENT_FILE.is_file():
        fail(".gclient not found in workspace root")


def resolve_gclient_cmd() -> list[str]:
    global _GCLIENT_CMD
    if _GCLIENT_CMD is not None:
        return _GCLIENT_CMD

    candidates = ["gclient", "gclient.bat", "gclient.py"]
    for candidate in candidates:
        path = shutil.which(candidate)
        if not path:
            continue
        if path.lower().endswith(".py"):
            _GCLIENT_CMD = [sys.executable, path]
        else:
            _GCLIENT_CMD = [path]
        return _GCLIENT_CMD

    fail("gclient is required")
    return []


def load_src_url_from_gclient(src_url: str | None) -> str:
    if src_url:
        return src_url

    check_gclient_config()
    config: dict[str, object] = {}
    exec(GCLIENT_FILE.read_text(encoding="utf-8"), config)
    solutions = config.get("solutions", [])
    if isinstance(solutions, list):
        for solution in solutions:
            if isinstance(solution, dict) and solution.get("name") == "src":
                url = solution.get("url")
                if isinstance(url, str) and url:
                    return url
    fail("Could not determine src URL from .gclient")
    return ""


def is_dir_empty(path: Path) -> bool:
    if not path.is_dir():
        return True
    return not any(path.iterdir())


def ensure_src_remote(src_url: str) -> None:
    if not (SRC_DIR / ".git").is_dir():
        return
    current_url = ""
    try:
        current_url = run(["git", "-C", str(SRC_DIR), "remote", "get-url", "origin"])
    except CommandError:
        current_url = ""
    if not current_url:
        note(f"==> Adding src origin remote {src_url}")
        run(["git", "-C", str(SRC_DIR), "remote", "add", "origin", src_url])
    elif current_url != src_url:
        note(f"==> Updating src origin remote to {src_url}")
        run(["git", "-C", str(SRC_DIR), "remote", "set-url", "origin", src_url])


def resolve_src_branch(src_branch: str, src_revision: str) -> tuple[str, str]:
    requested_branch = src_branch

    if not (SRC_DIR / ".git").is_dir():
        return src_branch, src_revision

    try:
        run(
            [
                "git",
                "-C",
                str(SRC_DIR),
                "ls-remote",
                "--exit-code",
                "--heads",
                "origin",
                requested_branch,
            ]
        )
        return src_branch, src_revision
    except CommandError:
        pass

    origin_head = ""
    try:
        output = run(["git", "-C", str(SRC_DIR), "ls-remote", "--symref", "origin", "HEAD"])
        for line in output.splitlines():
            if line.startswith("ref:"):
                origin_head = line.split()[1].strip()
                break
    except CommandError:
        origin_head = ""

    origin_head = origin_head.replace("refs/heads/", "").replace("refs/remotes/origin/", "")
    fallback_branch = ""
    if origin_head:
        fallback_branch = origin_head
    else:
        for candidate in ("main", "master"):
            try:
                run(
                    [
                        "git",
                        "-C",
                        str(SRC_DIR),
                        "ls-remote",
                        "--exit-code",
                        "--heads",
                        "origin",
                        candidate,
                    ]
                )
                fallback_branch = candidate
                break
            except CommandError:
                continue

    if not fallback_branch:
        fail(f"Remote branch {requested_branch} not found and no default branch could be determined")

    if fallback_branch != requested_branch:
        note(f"==> Remote branch {requested_branch} not found. Falling back to {fallback_branch}")

    if src_revision in {DEFAULT_SRC_REVISION, f"refs/heads/{requested_branch}"}:
        src_revision = f"refs/heads/{fallback_branch}"
    return fallback_branch, src_revision


def resolve_custom_browser_branch(
    custom_branch: str, custom_revision: str
) -> tuple[str, str]:
    requested_branch = custom_branch

    if not (CUSTOM_BROWSER_DIR / ".git").is_dir():
        return custom_branch, custom_revision

    try:
        run(
            [
                "git",
                "-C",
                str(CUSTOM_BROWSER_DIR),
                "ls-remote",
                "--exit-code",
                "--heads",
                "origin",
                requested_branch,
            ]
        )
        return custom_branch, custom_revision
    except CommandError:
        pass

    origin_head = ""
    try:
        output = run(
            [
                "git",
                "-C",
                str(CUSTOM_BROWSER_DIR),
                "ls-remote",
                "--symref",
                "origin",
                "HEAD",
            ]
        )
        for line in output.splitlines():
            if line.startswith("ref:"):
                origin_head = line.split()[1].strip()
                break
    except CommandError:
        origin_head = ""

    origin_head = origin_head.replace("refs/heads/", "").replace("refs/remotes/origin/", "")
    fallback_branch = ""
    if origin_head:
        fallback_branch = origin_head
    else:
        for candidate in ("main", "master"):
            try:
                run(
                    [
                        "git",
                        "-C",
                        str(CUSTOM_BROWSER_DIR),
                        "ls-remote",
                        "--exit-code",
                        "--heads",
                        "origin",
                        candidate,
                    ]
                )
                fallback_branch = candidate
                break
            except CommandError:
                continue

    if not fallback_branch:
        fail(
            f"Remote branch {requested_branch} not found and no default branch could be determined"
        )

    if fallback_branch != requested_branch:
        note(f"==> Remote branch {requested_branch} not found. Falling back to {fallback_branch}")

    if custom_revision in {
        DEFAULT_CUSTOM_BROWSER_REVISION,
        f"refs/heads/{requested_branch}",
    }:
        custom_revision = f"refs/heads/{fallback_branch}"
    return fallback_branch, custom_revision


def ensure_src_checkout(src_url: str, src_branch: str, src_revision: str) -> tuple[str, str]:
    if (SRC_DIR / ".git").is_dir():
        ensure_src_remote(src_url)
        return resolve_src_branch(src_branch, src_revision)

    if SRC_DIR.exists() and not is_dir_empty(SRC_DIR):
        fail("src exists and is not empty. Use rebootstrap to clear it.")

    note("==> Cloning src")
    run(["git", "clone", src_url, str(SRC_DIR)], capture=False)
    ensure_src_remote(src_url)
    src_branch, src_revision = resolve_src_branch(src_branch, src_revision)
    note(f"==> Checking out {src_branch}")
    run(["git", "-C", str(SRC_DIR), "fetch", "origin", src_branch], capture=False)
    run(["git", "-C", str(SRC_DIR), "checkout", "-B", src_branch, f"origin/{src_branch}"])
    return src_branch, src_revision


def ensure_custom_browser_remote(custom_url: str) -> None:
    if not (CUSTOM_BROWSER_DIR / ".git").is_dir():
        return
    current_url = ""
    try:
        current_url = run(
            ["git", "-C", str(CUSTOM_BROWSER_DIR), "remote", "get-url", "origin"]
        )
    except CommandError:
        current_url = ""
    if not current_url:
        note(f"==> Adding custom_browser origin remote {custom_url}")
        run(["git", "-C", str(CUSTOM_BROWSER_DIR), "remote", "add", "origin", custom_url])
    elif current_url != custom_url:
        note(f"==> Updating custom_browser origin remote to {custom_url}")
        run(
            ["git", "-C", str(CUSTOM_BROWSER_DIR), "remote", "set-url", "origin", custom_url]
        )


def ensure_custom_browser_checkout(
    custom_url: str, custom_branch: str, custom_revision: str
) -> tuple[str, str]:
    if (CUSTOM_BROWSER_DIR / ".git").is_dir():
        ensure_custom_browser_remote(custom_url)
        custom_branch, custom_revision = resolve_custom_browser_branch(
            custom_branch, custom_revision
        )
        checkout_revision(CUSTOM_BROWSER_DIR, custom_revision, custom_branch)
        return custom_branch, custom_revision

    if CUSTOM_BROWSER_DIR.exists() and not is_dir_empty(CUSTOM_BROWSER_DIR):
        fail("src/custom_browser exists and is not empty. Use rebootstrap to clear it.")

    note("==> Cloning custom_browser")
    run(["git", "clone", custom_url, str(CUSTOM_BROWSER_DIR)], capture=False)
    ensure_custom_browser_remote(custom_url)
    custom_branch, custom_revision = resolve_custom_browser_branch(
        custom_branch, custom_revision
    )
    checkout_revision(CUSTOM_BROWSER_DIR, custom_revision, custom_branch)
    return custom_branch, custom_revision


def run_gclient_sync(src_revision: str | None) -> None:
    gclient_cmd = resolve_gclient_cmd()
    env = os.environ.copy()
    note("==> Running gclient sync --force --shallow")
    revision_args = []
    if src_revision:
        revision_args = ["--revision", f"src@{src_revision}"]
    run(
        gclient_cmd
        + [
            "sync",
            "--force",
            "--shallow",
        ]
        + revision_args,
        cwd=ROOT,
        env=env,
        capture=False,
    )


def checkout_revision(repo_dir: Path, revision: str, branch_hint: str | None = None) -> None:
    if revision.startswith("refs/heads/"):
        branch = revision.replace("refs/heads/", "", 1)
        note(f"==> Checking out {repo_dir.name} {branch}")
        run(["git", "-C", str(repo_dir), "fetch", "origin", branch], capture=False)
        run(["git", "-C", str(repo_dir), "checkout", "-B", branch, "FETCH_HEAD"])
        return

    if revision.startswith("refs/tags/"):
        tag = revision.replace("refs/tags/", "", 1)
        note(f"==> Checking out {repo_dir.name} tag {tag}")
        run(
            [
                "git",
                "-C",
                str(repo_dir),
                "fetch",
                "origin",
                f"refs/tags/{tag}:refs/tags/{tag}",
            ],
            capture=False,
        )
        run(["git", "-C", str(repo_dir), "checkout", f"refs/tags/{tag}"])
        return

    note(f"==> Checking out {repo_dir.name} {revision}")
    try:
        run(["git", "-C", str(repo_dir), "cat-file", "-e", f"{revision}^{{commit}}"])
    except CommandError:
        if branch_hint:
            try:
                run(
                    ["git", "-C", str(repo_dir), "fetch", "origin", branch_hint],
                    capture=False,
                )
            except CommandError:
                pass
        run(["git", "-C", str(repo_dir), "fetch", "origin", revision], capture=False)
    run(["git", "-C", str(repo_dir), "checkout", revision])


def fetch_branch_shallow(repo_dir: Path, branch: str) -> None:
    run(
        [
            "git",
            "-C",
            str(repo_dir),
            "fetch",
            "--depth=1",
            "--no-tags",
            "origin",
            branch,
        ],
        capture=False,
    )
    run(["git", "-C", str(repo_dir), "checkout", "-B", branch, "FETCH_HEAD"])


def ensure_src_checkout_shallow(src_url: str, src_branch: str) -> None:
    if (SRC_DIR / ".git").is_dir():
        ensure_src_remote(src_url)
        fetch_branch_shallow(SRC_DIR, src_branch)
        return

    if SRC_DIR.exists() and not is_dir_empty(SRC_DIR):
        fail("src exists and is not empty. Use rebootstrap to clear it.")

    note("==> Cloning src (shallow)")
    run(
        [
            "git",
            "clone",
            "--depth=1",
            "--no-tags",
            "--single-branch",
            "--branch",
            src_branch,
            src_url,
            str(SRC_DIR),
        ],
        capture=False,
    )
    ensure_src_remote(src_url)


def ensure_custom_browser_checkout_shallow(custom_url: str, custom_branch: str) -> None:
    if (CUSTOM_BROWSER_DIR / ".git").is_dir():
        ensure_custom_browser_remote(custom_url)
        fetch_branch_shallow(CUSTOM_BROWSER_DIR, custom_branch)
        return

    if CUSTOM_BROWSER_DIR.exists() and not is_dir_empty(CUSTOM_BROWSER_DIR):
        fail("src/custom_browser exists and is not empty. Use rebootstrap to clear it.")

    note("==> Cloning custom_browser (shallow)")
    run(
        [
            "git",
            "clone",
            "--depth=1",
            "--no-tags",
            "--single-branch",
            "--branch",
            custom_branch,
            custom_url,
            str(CUSTOM_BROWSER_DIR),
        ],
        capture=False,
    )
    ensure_custom_browser_remote(custom_url)


def install_depot_tools() -> None:
    require_cmd("git")
    if (DEPOT_TOOLS_DIR / ".git").is_dir():
        note(f"==> depot_tools already installed at {DEPOT_TOOLS_DIR}")
        return
    if DEPOT_TOOLS_DIR.exists() and not is_dir_empty(DEPOT_TOOLS_DIR):
        fail(f"depot_tools directory exists and is not empty: {DEPOT_TOOLS_DIR}")
    note("==> Installing depot_tools")
    run(["git", "clone", DEPOT_TOOLS_URL, str(DEPOT_TOOLS_DIR)], capture=False)


def bootstrap_and_sync(
    src_url: str,
    src_branch: str,
    src_revision: str,
    custom_url: str,
    custom_branch: str,
    custom_revision: str,
) -> None:
    require_cmd("git")
    setup_path()
    resolve_gclient_cmd()
    check_gclient_config()
    src_branch, src_revision = ensure_src_checkout(src_url, src_branch, src_revision)
    ensure_custom_browser_checkout(custom_url, custom_branch, custom_revision)
    run_gclient_sync(src_revision)


def sync_only(
    src_url: str,
    src_branch: str,
    src_revision: str,
    custom_url: str,
    custom_branch: str,
    custom_revision: str,
) -> None:
    setup_path()
    require_cmd("git")
    resolve_gclient_cmd()
    check_gclient_config()
    ensure_src_remote(src_url)
    src_branch, src_revision = resolve_src_branch(src_branch, src_revision)
    ensure_custom_browser_checkout(custom_url, custom_branch, custom_revision)
    run_gclient_sync(src_revision)


def fast_sync(src_url: str, src_branch: str, custom_url: str, custom_branch: str) -> None:
    setup_path()
    require_cmd("git")
    resolve_gclient_cmd()
    check_gclient_config()
    ensure_src_checkout_shallow(src_url, src_branch)
    ensure_custom_browser_checkout_shallow(custom_url, custom_branch)
    run_gclient_sync(None)


def rebootstrap(
    src_url: str,
    src_branch: str,
    src_revision: str,
    custom_url: str,
    custom_branch: str,
    custom_revision: str,
    assume_yes: bool,
) -> None:
    if SRC_DIR.exists():
        if not assume_yes:
            confirm = input(f"This will delete {SRC_DIR}. Continue? [y/N]: ").strip().lower()
            if confirm not in {"y", "yes"}:
                fail("Aborted by user.")
        note(f"==> Removing {SRC_DIR}")
        shutil.rmtree(SRC_DIR)
    bootstrap_and_sync(
        src_url, src_branch, src_revision, custom_url, custom_branch, custom_revision
    )


def ensure_git_repo(path: Path) -> None:
    run(["git", "-C", str(path), "rev-parse", "--is-inside-work-tree"])


def is_dirty(path: Path) -> bool:
    status = run(["git", "-C", str(path), "status", "--porcelain"])
    return bool(status.strip())


def ensure_commit(path: Path, commit: str, fetch: bool) -> None:
    try:
        run(["git", "-C", str(path), "cat-file", "-e", f"{commit}^{{commit}}"])
        return
    except CommandError:
        if not fetch:
            fail(f"Missing commit {commit} in {path}. Run with --fetch.")
        note(f"==> Fetching missing commit in {path}")
        run(["git", "-C", str(path), "fetch", "--all", "--tags"], capture=False)
        run(["git", "-C", str(path), "cat-file", "-e", f"{commit}^{{commit}}"])


def restore_snapshot(manifest_path: Path, force: bool, fetch: bool) -> None:
    if not manifest_path.is_file():
        fail(f"Manifest not found: {manifest_path}")

    data = json.loads(manifest_path.read_text(encoding="utf-8"))
    repos = data.get("repos", [])
    if not isinstance(repos, list) or not repos:
        fail("Manifest does not contain repos.")

    targets: list[tuple[str, Path, str]] = []
    dirty: list[str] = []

    for repo in repos:
        if not isinstance(repo, dict):
            continue
        name = str(repo.get("name", ""))
        path_str = str(repo.get("path", ""))
        head = repo.get("head")
        if not path_str or not head:
            continue
        repo_path = (ROOT / Path(path_str)).resolve()
        if not repo_path.exists():
            fail(f"Repo path missing: {repo_path}")
        ensure_git_repo(repo_path)
        if is_dirty(repo_path):
            dirty.append(f"{name} ({repo_path})")
        targets.append((name, repo_path, str(head)))

    if dirty and not force:
        fail("Dirty repos detected: " + ", ".join(dirty))

    for name, repo_path, head in targets:
        ensure_commit(repo_path, head, fetch)
        note(f"==> Checking out {name} to {head}")
        run(["git", "-C", str(repo_path), "checkout", head])

    note("==> Restore complete")


def resolve_inputs(args: argparse.Namespace) -> tuple[str, str, str, str, str, str]:
    src_url = args.src_url or os.environ.get("SRC_URL", "")
    src_branch = args.src_branch or os.environ.get("SRC_BRANCH", DEFAULT_SRC_BRANCH)
    src_revision = args.src_revision or os.environ.get("SRC_REVISION", DEFAULT_SRC_REVISION)
    custom_url = (
        getattr(args, "custom_browser_url", None)
        or os.environ.get("CUSTOM_BROWSER_URL", DEFAULT_CUSTOM_BROWSER_URL)
    )
    custom_branch = (
        getattr(args, "custom_browser_branch", None)
        or os.environ.get("CUSTOM_BROWSER_BRANCH", DEFAULT_CUSTOM_BROWSER_BRANCH)
    )
    custom_revision = (
        getattr(args, "custom_browser_revision", None)
        or os.environ.get("CUSTOM_BROWSER_REVISION", DEFAULT_CUSTOM_BROWSER_REVISION)
    )

    if src_revision == DEFAULT_SRC_REVISION and src_branch != DEFAULT_SRC_BRANCH:
        src_revision = f"refs/heads/{src_branch}"
    if (
        custom_revision == DEFAULT_CUSTOM_BROWSER_REVISION
        and custom_branch != DEFAULT_CUSTOM_BROWSER_BRANCH
    ):
        custom_revision = f"refs/heads/{custom_branch}"
    if custom_revision == custom_branch and not custom_revision.startswith("refs/"):
        custom_revision = f"refs/heads/{custom_branch}"

    src_url = load_src_url_from_gclient(src_url)
    return src_url, src_branch, src_revision, custom_url, custom_branch, custom_revision


def menu() -> int:
    print("Shift Bootstrap")
    print("1) Install depot_tools (first time only)")
    print("2) Fast sync (shallow fetch custom/main + gclient sync)")
    print("3) Bootstrap & Sync (clone src + custom_browser + gclient sync)")
    print("4) Re-bootstrap (delete src + bootstrap & sync)")
    print("5) Restore release snapshot (from release_manifest.json)")
    print("6) Exit")
    choice = input("Select option [1-6]: ").strip()

    if choice == "6":
        return 0

    args = argparse.Namespace(
        src_url=None,
        src_branch=None,
        src_revision=None,
        custom_browser_url=None,
        custom_browser_branch=None,
        custom_browser_revision=None,
        assume_yes=False,
        manifest=None,
        force=False,
        fetch=True,
    )

    try:
        if choice == "1":
            install_depot_tools()
            return 0
        if choice in {"2", "3", "4"}:
            (
                src_url,
                src_branch,
                src_revision,
                custom_url,
                custom_branch,
                custom_revision,
            ) = resolve_inputs(args)
            if choice == "2":
                fast_sync(src_url, src_branch, custom_url, custom_branch)
            elif choice == "3":
                bootstrap_and_sync(
                    src_url, src_branch, src_revision, custom_url, custom_branch, custom_revision
                )
            else:
                rebootstrap(
                    src_url,
                    src_branch,
                    src_revision,
                    custom_url,
                    custom_branch,
                    custom_revision,
                    assume_yes=False,
                )
            return 0
        if choice == "5":
            manifest = MANIFEST_PATH
            custom = input(f"Manifest path (default: {manifest}): ").strip()
            if custom:
                manifest = Path(custom)
            fetch_choice = input("Fetch missing commits? [Y/n]: ").strip().lower()
            fetch = fetch_choice not in {"n", "no"}
            force_choice = input("Allow dirty repos (checkout anyway)? [y/N]: ").strip().lower()
            force = force_choice in {"y", "yes"}
            restore_snapshot(manifest, force=force, fetch=fetch)
            return 0
    except CommandError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1

    print(f"Invalid choice: {choice}", file=sys.stderr)
    return 1


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Bootstrap and manage the workspace.")
    parser.add_argument("--src-url", help="Override src URL.")
    parser.add_argument("--src-branch", help="Override src branch.")
    parser.add_argument("--src-revision", help="Override src revision.")
    parser.add_argument("--custom-browser-url", help="Override custom_browser URL.")
    parser.add_argument("--custom-browser-branch", help="Override custom_browser branch.")
    parser.add_argument("--custom-browser-revision", help="Override custom_browser revision.")
    subparsers = parser.add_subparsers(dest="command")

    subparsers.add_parser("install-tools", help="Install depot_tools.")
    subparsers.add_parser("bootstrap", help="Clone src and run gclient sync.")
    subparsers.add_parser(
        "fast-sync",
        help="Shallow fetch src/custom_browser branches and run gclient sync.",
    )
    subparsers.add_parser("sync", help="Run gclient sync (full branch resolution).")

    rebootstrap_parser = subparsers.add_parser("rebootstrap", help="Delete src and re-bootstrap.")
    rebootstrap_parser.add_argument("--yes", action="store_true", help="Skip confirmation prompt.")

    restore_parser = subparsers.add_parser("restore", help="Restore repos from a release manifest.")
    restore_parser.add_argument("--manifest", help="Path to release_manifest.json.")
    restore_parser.add_argument("--force", action="store_true", help="Allow dirty repos.")
    restore_parser.add_argument(
        "--no-fetch", dest="fetch", action="store_false", help="Do not fetch missing commits."
    )
    restore_parser.set_defaults(fetch=True)

    return parser


def main() -> int:
    parser = build_parser()
    args = parser.parse_args()
    if not args.command:
        return menu()

    try:
        if args.command == "install-tools":
            install_depot_tools()
            return 0

        if args.command in {"bootstrap", "sync", "rebootstrap", "fast-sync"}:
            (
                src_url,
                src_branch,
                src_revision,
                custom_url,
                custom_branch,
                custom_revision,
            ) = resolve_inputs(args)

            if args.command == "bootstrap":
                bootstrap_and_sync(
                    src_url, src_branch, src_revision, custom_url, custom_branch, custom_revision
                )
            elif args.command == "sync":
                sync_only(
                    src_url, src_branch, src_revision, custom_url, custom_branch, custom_revision
                )
            elif args.command == "fast-sync":
                fast_sync(src_url, src_branch, custom_url, custom_branch)
            else:
                rebootstrap(
                    src_url,
                    src_branch,
                    src_revision,
                    custom_url,
                    custom_branch,
                    custom_revision,
                    assume_yes=args.yes,
                )
            return 0

        if args.command == "restore":
            manifest = Path(args.manifest) if args.manifest else MANIFEST_PATH
            restore_snapshot(manifest, force=args.force, fetch=args.fetch)
            return 0

        fail(f"Unknown command: {args.command}")
    except CommandError as exc:
        print(f"ERROR: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
