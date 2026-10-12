#!/usr/bin/env python3
"""Install and recover an isolated development environment (Python 3.8+)."""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import fcntl
import hashlib
import json
import os
from pathlib import Path
import platform
import shlex
import shutil
import subprocess
import sys

# Works with python -I and with importlib-based tests, without inheriting PYTHONPATH.
sys.path.insert(0, str(Path(__file__).resolve().parent))
from provision import (MANAGERS, stamp, exists, write_new, run, download, extract,
                       manager_name, environment, nvim_environment, install_tools,
                       system_packages, cleanup_packages, preflight, missing_packages,
                       adopt_bootstrap, journal_read)

SOURCE = Path(__file__).resolve().parents[1]


def read_record(path, optional=False):
    """Recover the last complete record, retaining any interrupted journal tail."""
    if not path.exists():
        if optional:
            return None
        raise RuntimeError("Missing recovery journal: " + str(path))
    for line in reversed(path.read_bytes().splitlines()):
        try:
            value = json.loads(line)
            if isinstance(value, dict):
                return value
        except (ValueError, UnicodeError):
            continue
    raise RuntimeError("No complete recovery record in " + str(path))


def append_record(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a+b") as stream:
        stream.seek(0, os.SEEK_END)
        size = stream.tell()
        if size:
            stream.seek(-1, os.SEEK_END)
            if stream.read(1) != b"\n":
                stream.write(b"\n")
        stream.write((json.dumps(value, sort_keys=True) + "\n").encode())
        stream.flush()
        os.fsync(stream.fileno())


def identity(path):
    if not exists(path):
        return None
    info = path.lstat()
    return {"device": info.st_dev, "inode": info.st_ino, "type": info.st_mode & 0o170000}


def same_file(path, expected):
    return expected is not None and identity(path) == expected


def sync_directory(path):
    descriptor = os.open(str(path), os.O_RDONLY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def move_preserving(source, destination):
    """Never replace an existing destination, including a dangling symlink."""
    if not exists(source):
        return
    if exists(destination):
        raise RuntimeError("Recovery destination already occupied: " + str(destination))
    source.rename(destination)
    sync_directory(source.parent)
    if source.parent != destination.parent:
        sync_directory(destination.parent)


def default_root(user_home=None):
    if os.environ.get("DEVKIT_ROOT"):
        return os.environ["DEVKIT_ROOT"]
    home = Path(user_home or Path.home()).resolve()
    state = read_record(home / ".local/state/devkit/ownership.jsonl", optional=True)
    return state.get("root") if state and state.get("root") else str(home / ".local/share/devkit")


class Installation:
    def __init__(self, root, user_home=None):
        proposed = Path(root).expanduser().absolute()
        self.root_is_symlink = proposed.is_symlink()
        self.root = proposed.resolve()
        if "\n" in str(self.root) or "\r" in str(self.root):
            raise RuntimeError("Installation paths cannot contain newline characters.")
        self.user_home = Path(user_home or Path.home()).resolve()
        self.launcher = self.user_home / ".local/bin/devkit"
        self.active = self.root / "active"
        self.control = self.user_home / ".local/state/devkit"
        self.ownership = self.control / "ownership.jsonl"
        self._mutation_depth = 0

    @staticmethod
    def _prepare_directory(directory, marker, content):
        owner = directory / marker
        if directory.is_symlink():
            raise RuntimeError("Control directory must not be a symlink: " + str(directory))
        if directory.exists() and any(directory.iterdir()) and not owner.exists():
            raise RuntimeError("Directory belongs to something else: " + str(directory))
        directory.mkdir(parents=True, exist_ok=True)
        if not owner.exists():
            write_new(owner, content)
        if owner.read_text() not in (content, "devkit-v1\n"):
            raise RuntimeError("Unknown installation owner marker: " + str(owner))

    def prepare(self):
        if self.root_is_symlink:
            raise RuntimeError("Installation root itself must not be a symlink.")
        self._prepare_directory(self.root, ".devkit-owner", "devkit-v2\n")

    @contextmanager
    def mutation(self):
        if self._mutation_depth:
            yield
            return
        self._prepare_directory(self.control, ".devkit-owner", "devkit-control-v2\n")
        with (self.control / "operation.lock").open("a") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("Another devkit install, uninstall, or recovery is running.")
            self._mutation_depth += 1
            try:
                yield
            finally:
                self._mutation_depth -= 1

    def registry(self):
        return read_record(self.ownership, optional=True)

    def claim(self, envroot, status):
        append_record(self.ownership, {"version": 2, "root": str(self.root),
                                     "environment": str(envroot), "status": status})
        pointer = self.control / "root-path"
        if pointer.is_file() and pointer.read_text() == str(self.root) + "\n":
            return
        temporary = self.control / ("root-path-" + stamp())
        write_new(temporary, str(self.root) + "\n")
        if exists(pointer):
            history = self.control / "pointer-history"
            history.mkdir(exist_ok=True)
            shutil.copy2(pointer, history / stamp(), follow_symlinks=False)
        os.replace(temporary, pointer)
        sync_directory(self.control)

    def assert_available(self):
        owned = self.registry()
        if owned and owned.get("status") != "released" and Path(owned["root"]).resolve() != self.root:
            raise RuntimeError("Another installation owns the launcher at " + owned["root"] + "; uninstall or recover it first.")
        if self.launcher.is_symlink():
            target = self.launcher.resolve()
            if target.name == "devkit" and target.parent.name == "bin" and target.parent.parent.parent.name == "environments":
                other_root = target.parent.parent.parent.parent
                if other_root != self.root and (other_root / ".devkit-owner").exists():
                    raise RuntimeError("Another installation owns the launcher at " + str(other_root))

    def current(self):
        if not exists(self.active):
            return None
        if not self.active.is_symlink():
            raise RuntimeError("The active environment pointer is not a symlink; refusing to alter it.")
        envroot = self.active.resolve()
        if envroot.parent != self.root / "environments":
            raise RuntimeError("Unexpected active environment path; refusing to change it.")
        return envroot

    @staticmethod
    def record(envroot, manifest):
        append_record(envroot / "journal.jsonl", manifest)

    @staticmethod
    def manifest(envroot):
        value = read_record(envroot / "journal.jsonl")
        if value.get("version") not in (1, 2) or not value.get("environment"):
            raise RuntimeError("Unsupported environment journal: " + str(envroot))
        if Path(value["environment"]).resolve() != envroot.resolve():
            raise RuntimeError("Journal belongs to another environment: " + str(envroot))
        return value

    def entries(self):
        result = []
        for path in sorted((self.root / "environments").glob("*/journal.jsonl")):
            result.append((path.parent, self.manifest(path.parent)))
        return result

    def _controller(self, envroot):
        manager = self.root / "manager"
        if manager.is_symlink() and manager.resolve() == envroot / "source":
            return
        if exists(manager):
            history = self.root / "controller-history"
            history.mkdir(exist_ok=True)
            move_preserving(manager, history / stamp())
        manager.symlink_to(envroot / "source", target_is_directory=True)
        sync_directory(self.root)

    def _source_check(self, source):
        source = source.resolve()
        if source == self.root or source in self.root.parents:
            raise RuntimeError("Installation root cannot be inside its source checkout.")
        for name in ("lib/devkit.py", "lib/provision.py", "config/nvim/init.lua", "config/tmux.conf", "tools.lock.json"):
            if not (source / name).is_file():
                raise RuntimeError("Incomplete source checkout; missing " + name)
        root_parent = self.root
        while not root_parent.exists():
            root_parent = root_parent.parent
        launcher_parent = self.launcher.parent
        while not launcher_parent.exists():
            launcher_parent = launcher_parent.parent
        if root_parent.stat().st_dev != launcher_parent.stat().st_dev:
            raise RuntimeError("Choose an installation root on the same filesystem as the launcher; backups use atomic renames.")
        return source

    def install(self, source, config_only=False, no_packages=False):
        with self.mutation():
            self.assert_available()
            source = self._source_check(Path(source))
            if self.root.exists():
                self.prepare()
            if self.current():
                raise RuntimeError("An environment is already active. Uninstall it before installing another.")
            # A failed previous attempt owns its added prerequisites until recovery finishes.
            self._recover_pending()
            diagnostics = preflight(source, self.root, config_only=config_only, no_packages=no_packages)
            if diagnostics.get("errors"):
                raise RuntimeError("Preflight failed: " + "; ".join(diagnostics["errors"]))
            self.prepare()
            envroot = self.root / "environments" / stamp()
            envroot.mkdir(parents=True)
            for name in ("bin", "downloads", "backups", "xdg/config"):
                (envroot / name).mkdir(parents=True)
            manifest = {"version": 2, "root": str(self.root), "environment": str(envroot),
                        "launcher": str(self.launcher), "launcher_backup": None, "original_identity": None,
                        "activation_intent": False, "packages": {}, "commands": {},
                        "config_only": config_only, "status": "installing", "phase": "provisioning"}
            self.record(envroot, manifest)
            self.claim(envroot, "claimed")
            try:
                manifest["packages"] = adopt_bootstrap(envroot)
                self.record(envroot, manifest)
                shutil.copytree(source, envroot / "source", ignore=shutil.ignore_patterns(".git", "__pycache__", ".pytest_cache"))
                self._controller(envroot)
                shutil.copytree(source / "config/nvim", envroot / "xdg/config/nvim", symlinks=True)
                shutil.copy2(source / "config/tmux.conf", envroot / "tmux.conf")
                if not config_only:
                    if not no_packages:
                        def checkpoint(info):
                            manifest["packages"] = info
                            self.record(envroot, manifest)
                        manifest["packages"] = system_packages(envroot, manager_name(), checkpoint=checkpoint)
                    manifest["commands"] = install_tools(envroot, source, manifest["packages"])
                else:
                    manifest["commands"] = {name: shutil.which(name) for name in ("nvim", "tmux", "uv", "tree-sitter")}
                self.record(envroot, manifest)
                self.make_wrappers(envroot, manifest)
                if not config_only:
                    values = nvim_environment(envroot, manifest["packages"])
                    executable = manifest["commands"]["nvim"]
                    (envroot / "logs").mkdir()
                    for name, script, timeout in (("plugins", "lib/bootstrap-nvim.lua", 1200),
                                                  ("completion", "tests/nvim_completion.lua", 120)):
                        log = envroot / "logs" / (name + ".log")
                        print("Checking " + name + "; log: " + str(log), flush=True)
                        try:
                            with log.open("x") as output:
                                run([executable, "--headless", "-i", "NONE", "-c", "lua dofile(vim.env.DEVKIT_ENV .. '/source/" + script + "')"],
                                    env=values, timeout=timeout, stdout=output, stderr=subprocess.STDOUT)
                        except subprocess.SubprocessError as error:
                            print("\n".join(log.read_text(errors="replace").splitlines()[-20:]), file=sys.stderr)
                            raise RuntimeError(name + " check failed; see " + str(log)) from error
                self.launcher.parent.mkdir(parents=True, exist_ok=True)
                manifest.update(status="activating", phase="activation-planned", activation_intent=True,
                                original_identity=identity(self.launcher))
                if exists(self.launcher):
                    manifest["launcher_backup"] = str(envroot / "backups/previous-launcher")
                self.record(envroot, manifest)
                if manifest["launcher_backup"]:
                    move_preserving(self.launcher, Path(manifest["launcher_backup"]))
                manifest["phase"] = "launcher-backed-up"
                self.record(envroot, manifest)
                self.launcher.symlink_to(envroot / "bin/devkit")
                self.active.symlink_to(envroot)
                sync_directory(self.root)
                manifest.update(status="ready", phase="active")
                self.record(envroot, manifest)
                self.claim(envroot, "active")
            except BaseException:
                manifest["status"] = "failed"
                try:
                    self.record(envroot, manifest)
                    # Retire incomplete activation immediately; a second failure is recoverable.
                    self._retire(envroot, cleanup=False)
                except BaseException as recovery_error:
                    print("Recovery remains pending: " + str(recovery_error), file=sys.stderr)
                print("Files retained at " + str(envroot) + ". Run install.sh --recover before retrying.", file=sys.stderr)
                raise
            print("Installed. Enter: " + shlex.quote(str(self.launcher)) + " shell")
            print("Uninstall: " + shlex.quote(str(self.launcher)) + " uninstall")
            return envroot

    def make_wrappers(self, envroot, manifest=None):
        manifest = manifest or self.manifest(envroot)
        private_python = manifest["commands"].get("python") or ""
        program = shlex.quote(str(envroot / "source/lib/devkit.py"))
        root = shlex.quote(str(self.root))
        for command in ("devkit", "nvim", "tmux"):
            operation = "" if command == "devkit" else command + " "
            script = ("#!/bin/sh\n" + "for candidate in " + shlex.quote(private_python) +
                      ' "$(command -v python3 2>/dev/null)" /usr/bin/python3 ' + shlex.quote(sys.executable) + "; do\n" +
                      '  [ -n "$candidate" ] && [ -x "$candidate" ] || continue\n' +
                      '  "$candidate" -I -c "import sys; sys.exit(sys.version_info < (3, 8))" >/dev/null 2>&1 || continue\n' +
                      '  exec "$candidate" -I ' + program + " --root " + root + " " + operation + '"$@"\n' +
                      'done\nprintf "%s\\n" "devkit: Python 3.8+ is unavailable; run install.sh --recover using a working Python installation." >&2\nexit 1\n')
            write_new(envroot / "bin" / command, script, True)
        write_new(envroot / "bashrc", 'export HISTFILE="$DEVKIT_ENV/bash_history"\nHISTCONTROL=ignoredups\nPS1="[devkit] \\w \\$ "\nalias ll="ls -alF"\n')

    @contextmanager
    def session(self, envroot, exclusive=False):
        with (envroot / "session.lock").open("a") as lock:
            try:
                fcntl.flock(lock, (fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH) | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("Close all devkit shells and editors in other terminals before uninstalling or recovering.")
            yield lock

    def _check_tmux(self, envroot, manifest):
        tmux = manifest["commands"].get("tmux")
        if not tmux:
            return
        if not Path(tmux).exists():
            raise RuntimeError("Cannot inspect devkit tmux sessions because tmux is missing. Restore that executable before recovery.")
        sessions = subprocess.run([tmux, "-L", self.socket_name(envroot), "list-sessions"],
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if sessions.returncode == 0:
            raise RuntimeError("The devkit tmux server has live sessions. Finish them first; they have not been stopped.")

    def _retire(self, envroot, cleanup=True):
        manifest = self.manifest(envroot)
        if manifest["status"] == "archived":
            return Path(manifest["archive"])
        if os.environ.get("DEVKIT_ENV") == str(envroot):
            raise RuntimeError("Exit the devkit shell first, then uninstall from the original shell.")
        self.launcher = Path(manifest["launcher"])
        launcher_restored = manifest.get("launcher_restored", False) or manifest.get("phase") in (
            "launcher-restored", "configuration-archived", "complete")
        with self.session(envroot, exclusive=True):
            self._check_tmux(envroot, manifest)
            archive = Path(manifest.get("archive") or self.root / "archives" / envroot.name)
            archive.mkdir(parents=True, exist_ok=True)
            if manifest.get("version") == 1:
                # Old manifests have no identity token; recover it from the retained backup.
                backup = Path(manifest["launcher_backup"]) if manifest.get("launcher_backup") else None
                manifest.update(version=2, activation_intent=True, original_identity=identity(backup) if backup else None)
            manifest.update(status="removing", archive=str(archive), phase="retirement-planned")
            self.record(envroot, manifest)
            current = self.current()
            if current == envroot:
                move_preserving(self.active, archive / "active-link")
            elif current:
                raise RuntimeError("A different environment is active; refusing to restore its launcher.")
            if manifest.get("activation_intent") and not launcher_restored:
                original = manifest.get("original_identity")
                backup = Path(manifest["launcher_backup"]) if manifest.get("launcher_backup") else None
                if not same_file(self.launcher, original):
                    if original and not (backup and exists(backup)):
                        raise RuntimeError("Original launcher backup is missing. Files are retained; inspect " + str(archive))
                    if exists(self.launcher):
                        destination = archive / "launcher-at-uninstall"
                        if exists(destination):
                            destination = archive / ("later-launcher-" + stamp())
                        move_preserving(self.launcher, destination)
                    if backup and exists(backup):
                        self.launcher.parent.mkdir(parents=True, exist_ok=True)
                        move_preserving(backup, self.launcher)
            manifest.update(phase="launcher-restored", launcher_restored=True)
            self.record(envroot, manifest)
            link = archive / "environment"
            if not exists(link):
                link.symlink_to(envroot, target_is_directory=True)
            elif not link.is_symlink() or link.resolve() != envroot:
                raise RuntimeError("Archive environment pointer is occupied: " + str(link))
            note = archive / "RESTORE.txt"
            if not note.exists():
                write_new(note, "Personal files are retained at their original path:\n" + str(envroot) +
                          "\nThe environment link in this archive points there.\nPrevious launcher restored.\n" +
                          "Use install.sh --recover to finish interrupted prerequisite cleanup.\n")
            manifest.update(status="cleanup-pending", phase="configuration-archived")
            self.record(envroot, manifest)
            if cleanup:
                try:
                    report = cleanup_packages(envroot, manifest.get("packages", {}), archive)
                except Exception as error:
                    report = {"removed": [], "retained": [], "errors": [str(error)]}
                manifest["cleanup_report"] = report
                if not report.get("errors"):
                    manifest.update(status="archived", phase="complete")
                self.record(envroot, manifest)
            else:
                report = {"errors": ["Prerequisite cleanup deferred until recovery."]}
            if manifest["status"] == "archived":
                self.claim(envroot, "released")
            else:
                self.claim(envroot, "claimed")
            print("Owner launcher restored; personal files retained in " + str(archive))
            if report.get("retained"):
                print("Some prerequisites were retained: " + json.dumps(report["retained"]))
            if report.get("errors") and cleanup:
                raise RuntimeError("Cleanup is incomplete; run --recover: " + "; ".join(map(str, report["errors"])))
            return archive

    def _recover_pending(self):
        recovered = []
        for envroot, manifest in self.entries():
            if manifest["status"] not in ("ready", "archived"):
                recovered.append(str(self._retire(envroot)))
        owned = self.registry()
        if owned and owned.get("status") != "released" and Path(owned["root"]).resolve() == self.root:
            envroot = Path(owned["environment"])
            if envroot.exists() and self.manifest(envroot)["status"] == "archived":
                self.claim(envroot, "released")
        return recovered

    def recover(self):
        with self.mutation():
            self.assert_available()
            if not self.root.exists():
                print("No installation to recover.")
                return []
            self.prepare()
            self._recover_bootstrap()
            result = self._recover_pending()
            if not result:
                print("No interrupted operation needs recovery.")
            return result

    def _recover_bootstrap(self):
        journal = Path(os.environ.get("DEVKIT_BOOTSTRAP_JOURNAL", str(self.root / "bootstrap-journal.jsonl")))
        records = journal_read(journal)
        pending = []
        for item in records:
            if item.get("kind") == "adopted":
                pending = []
            else:
                pending.append(item)
        if not pending:
            return
        active = self.current()
        if active:
            manifest = self.manifest(active)
            if manifest["status"] == "archived":
                raise RuntimeError("Active pointer references an archived environment; bootstrap ownership was not changed.")
            if manifest.get("packages") and not (active / "packages.jsonl").exists():
                # Upgrade legacy ownership without dropping its Homebrew prefix.
                packages = dict(manifest["packages"])
                for name, default in (("owned", {}), ("resources", {}), ("bootstrap", [])):
                    packages.setdefault(name, default)
                append_record(active / "packages.jsonl", packages)
            adopted = adopt_bootstrap(active)
            if adopted:
                manifest["packages"] = adopted
                self.record(active, manifest)
            # A ready environment may use these prerequisites. Their ownership
            # follows it until uninstall; recovery must not deactivate it.
            return
        envroot = self.root / "environments" / stamp()
        envroot.mkdir(parents=True)
        for name in ("bin", "backups", "downloads"):
            (envroot / name).mkdir()
        manifest = {"version": 2, "root": str(self.root), "environment": str(envroot),
                    "launcher": str(self.launcher), "launcher_backup": None, "original_identity": None,
                    "activation_intent": False, "packages": {}, "commands": {}, "config_only": True,
                    "status": "failed", "phase": "bootstrap-recovery"}
        self.record(envroot, manifest)
        self.claim(envroot, "claimed")
        manifest["packages"] = adopt_bootstrap(envroot)
        self.record(envroot, manifest)
        shutil.copytree(SOURCE, envroot / "source", ignore=shutil.ignore_patterns(".git", "__pycache__", ".pytest_cache"))
        self._controller(envroot)

    def uninstall(self):
        with self.mutation():
            self.assert_available()
            if not self.root.exists():
                print("No active environment; nothing to restore.")
                return None
            self.prepare()
            self._recover_bootstrap()
            envroot = self.current()
            if envroot:
                return self._retire(envroot)
            recovered = self._recover_pending()
            if not recovered:
                print("No active environment; nothing to restore.")
            return Path(recovered[-1]) if recovered else None

    def archives(self):
        return [{"archive": manifest.get("archive"), "environment": str(envroot),
                 "status": manifest["status"], "cleanup": manifest.get("cleanup_report", {})}
                for envroot, manifest in self.entries() if manifest.get("archive")]

    def doctor(self):
        result = preflight(SOURCE, self.root, config_only=False, no_packages=True)
        result["root"] = str(self.root)
        result["launcher"] = str(self.launcher)
        try:
            envroot = self.current()
            result["active"] = str(envroot) if envroot else None
            result["pending_recovery"] = [str(p) for p, m in self.entries() if m["status"] not in ("ready", "archived")]
            if envroot:
                manifest = self.manifest(envroot)
                result["missing_commands"] = [name for name, path in manifest["commands"].items() if path and not Path(path).exists()]
        except (RuntimeError, OSError) as error:
            result.setdefault("errors", []).append(str(error))
        result["ok"] = not result.get("errors") and not result.get("missing_commands") and not result.get("pending_recovery")
        return result

    def socket_name(self, envroot=None):
        target = envroot or self.current() or self.root
        return "devkit-" + hashlib.sha256(str(target).encode()).hexdigest()[:12]

    def execute(self, command, args):
        envroot = self.current()
        if not envroot:
            raise RuntimeError("No active devkit environment.")
        with self.session(envroot) as lock:
            if self.current() != envroot:
                raise RuntimeError("The environment was deactivated; retry after installation finishes.")
            manifest = self.manifest(envroot)
            if manifest["status"] != "ready":
                raise RuntimeError("Environment is not ready; run install.sh --recover.")
            values = environment(envroot, manifest["packages"])
            if command == "shell":
                for key in ("BASH_ENV", "ENV", "PROMPT_COMMAND", "PYTHONHOME", "PYTHONPATH", "VIRTUAL_ENV", "CONDA_PREFIX"):
                    values.pop(key, None)
                for key in list(values):
                    if key.startswith("BASH_FUNC_"):
                        values.pop(key)
                executable = shutil.which("bash", path=values["PATH"])
                if not executable:
                    raise RuntimeError("Bash is unavailable; run doctor to inspect prerequisites.")
                argv = [executable, "--noprofile", "--rcfile", str(envroot / "bashrc"), "-i"]
            else:
                executable = manifest["commands"].get(command)
                if not executable:
                    raise RuntimeError(command + " is not installed in this environment.")
                if command == "nvim":
                    values = nvim_environment(envroot, manifest["packages"])
                elif command == "tmux":
                    values.pop("TMUX", None)
                    args = ["-L", self.socket_name(envroot), "-f", str(envroot / "tmux.conf")] + args
                argv = [executable] + args
            return subprocess.call(argv, env=values, pass_fds=(lock.fileno(),))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", default=None)
    sub = parser.add_subparsers(dest="action", required=True)
    install = sub.add_parser("install")
    install.add_argument("--config-only", action="store_true")
    install.add_argument("--no-system-packages", action="store_true")
    for name in ("uninstall", "recover", "status", "plan", "doctor", "archives", "shell"):
        sub.add_parser(name)
    for name in ("nvim", "tmux"):
        sub.add_parser(name, add_help=False)
    header = argparse.ArgumentParser(add_help=False)
    header.add_argument("--root")
    header.add_argument("action", nargs="?")
    header.add_argument("tail", nargs=argparse.REMAINDER)
    prefix, _ = header.parse_known_args()
    if prefix.action in ("nvim", "tmux"):
        args = parser.parse_args((["--root", prefix.root] if prefix.root else []) + [prefix.action])
        args.args = prefix.tail
    else:
        args = parser.parse_args()
    installation = Installation(args.root or default_root())
    if args.action == "plan":
        print(json.dumps({"platform": platform.system(), "architecture": platform.machine(),
                          "package_manager": manager_name(), "root": str(installation.root),
                          "launcher": str(installation.launcher), "owner_configs_modified": False,
                          "uninstall": "archive personal files; restore launcher; remove only tracked prerequisites when safe"}, indent=2))
    elif args.action == "status":
        envroot = installation.current()
        result = installation.manifest(envroot) if envroot else {"status": "not installed"}
        result["pending_cleanup"] = [str(p) for p, m in installation.entries() if m["status"] not in ("ready", "archived")]
        print(json.dumps(result, indent=2))
    elif args.action == "archives":
        print(json.dumps(installation.archives(), indent=2))
    elif args.action == "doctor":
        result = installation.doctor()
        print(json.dumps(result, indent=2))
        return 0 if result["ok"] else 1
    elif args.action in ("shell", "nvim", "tmux"):
        return installation.execute(args.action, getattr(args, "args", []))
    elif args.action == "install":
        installation.install(SOURCE, args.config_only, args.no_system_packages)
    elif args.action == "recover":
        installation.recover()
    else:
        installation.uninstall()
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main())
    except (RuntimeError, OSError, subprocess.SubprocessError, ValueError) as error:
        print("devkit: " + str(error), file=sys.stderr)
        sys.exit(1)
