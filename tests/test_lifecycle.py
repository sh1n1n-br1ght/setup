import hashlib
import importlib.util
import io
import json
import os
import select
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch


SOURCE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("devkit", SOURCE / "lib/devkit.py")
devkit = importlib.util.module_from_spec(spec)
spec.loader.exec_module(devkit)


class LifecycleTests(unittest.TestCase):
    def setUp(self):
        # Test fixtures are retained so the test run also deletes no files.
        self.work = Path(tempfile.mkdtemp(prefix="devkit-test-"))
        self.user_home = self.work / "owner's home"
        self.user_home.mkdir()
        self.install = devkit.Installation(self.user_home / ".local/share/devkit", self.user_home)
        self.owner_files = {
            ".config/nvim/init.lua": "print('owner config')\n",
            ".tmux.conf": "set -g prefix C-a\n",
            ".bashrc": "export OWNER_SETTING=1\n",
            "projects/work.py": "valuable = True\n",
            ".local/share/nvim/owner-plugin": "original plugin\n",
            ".local/state/nvim/shada/main.shada": "original history\n",
        }
        for name, text in self.owner_files.items():
            devkit.write_new(self.user_home / name, text)

    def assert_owner_unchanged(self):
        for name, text in self.owner_files.items():
            self.assertEqual((self.user_home / name).read_text(), text)

    def make(self):
        with patch.object(devkit.shutil, "which", return_value=None):
            return self.install.install(SOURCE, config_only=True)

    def test_round_trip_preserves_original_and_new_files(self):
        devkit.write_new(self.install.launcher, "#!/bin/sh\nprintf original\n", True)
        mode = self.install.launcher.stat().st_mode
        envroot = self.make()
        self.assert_owner_unchanged()
        devkit.write_new(envroot / "my-new-notes.txt", "keep my new notes")
        (envroot / "xdg/config/nvim/lua/options.lua").write_text("local modified = true\n")
        archive = self.install.uninstall()
        self.assert_owner_unchanged()
        self.assertEqual(self.install.launcher.read_text(), "#!/bin/sh\nprintf original\n")
        self.assertEqual(self.install.launcher.stat().st_mode, mode)
        self.assertEqual((archive / "environment/my-new-notes.txt").read_text(), "keep my new notes")
        self.assertEqual((archive / "environment/xdg/config/nvim/lua/options.lua").read_text(), "local modified = true\n")
        self.assertIsNone(self.install.current())

    def test_existing_symlink_and_target_preserved(self):
        target = self.user_home / "old-command"
        devkit.write_new(target, "original command")
        self.install.launcher.parent.mkdir(parents=True)
        self.install.launcher.symlink_to(target)
        self.make()
        self.install.uninstall()
        self.assertTrue(self.install.launcher.is_symlink())
        self.assertEqual(self.install.launcher.resolve(), target)
        self.assertEqual(target.read_text(), "original command")

    def test_replaced_launcher_is_archived_not_lost(self):
        self.make()
        self.install.launcher.rename(self.work / "installed-launcher")
        devkit.write_new(self.install.launcher, "owner created a different command")
        archive = self.install.uninstall()
        self.assertEqual((archive / "launcher-at-uninstall").read_text(), "owner created a different command")

    def test_repeat_uninstall_and_second_install(self):
        self.make()
        first = self.install.uninstall()
        self.assertIsNone(self.install.uninstall())
        self.make()
        second = self.install.uninstall()
        self.assertNotEqual(first, second)
        self.assertTrue(first.exists())
        self.assert_owner_unchanged()

    def test_install_again_refuses_to_overwrite(self):
        envroot = self.make()
        with self.assertRaisesRegex(RuntimeError, "already active"):
            self.make()
        self.assertEqual(self.install.current(), envroot)

    def test_foreign_root_is_not_modified(self):
        devkit.write_new(self.install.root / "owner-file", "keep")
        with self.assertRaisesRegex(RuntimeError, "belongs to something else"):
            self.make()
        self.assertEqual((self.install.root / "owner-file").read_text(), "keep")

    def test_failure_restores_launcher(self):
        devkit.write_new(self.install.launcher, "old launcher")
        original = Path.symlink_to

        def fail_active(path, *args, **kwargs):
            if path == self.install.active:
                raise OSError("simulated interrupted activation")
            return original(path, *args, **kwargs)

        with patch.object(Path, "symlink_to", fail_active):
            with self.assertRaisesRegex(OSError, "interrupted"):
                self.make()
        self.assertEqual(self.install.launcher.read_text(), "old launcher")
        self.assertIsNone(self.install.current())
        self.assertTrue(list(self.install.root.glob("environments/*/journal.jsonl")))

    def test_active_shell_blocks_uninstall(self):
        envroot = self.make()
        with patch.dict(os.environ, {"DEVKIT_ENV": str(envroot)}):
            with self.assertRaisesRegex(RuntimeError, "Exit the devkit shell"):
                self.install.uninstall()
        self.assertEqual(self.install.current(), envroot)

    def test_live_tmux_sessions_are_preserved(self):
        envroot = self.make()
        manifest = self.install.manifest(envroot)
        fake_tmux = self.work / "tmux"
        devkit.write_new(fake_tmux, "#!/bin/sh\nexit 0\n", True)
        manifest["commands"]["tmux"] = str(fake_tmux)
        self.install.record(envroot, manifest)
        with patch.object(devkit.subprocess, "run", return_value=subprocess.CompletedProcess([], 0)):
            with self.assertRaisesRegex(RuntimeError, "live sessions"):
                self.install.uninstall()
        self.assertTrue(envroot.exists())

    def test_wrappers_accept_spaces_quotes_and_editor_flags(self):
        envroot = self.make()
        fake_nvim = self.work / "fake nvim"
        devkit.write_new(fake_nvim, '#!/bin/sh\nprintf "%s\\n" "$NVIM_APPNAME" "$XDG_CONFIG_HOME" "$@"\n', True)
        manifest = self.install.manifest(envroot)
        manifest["commands"]["nvim"] = str(fake_nvim)
        self.install.record(envroot, manifest)
        result = subprocess.run([str(envroot / "bin/nvim"), "--version", "-u", "NONE"], capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout.splitlines(), ["nvim", str(envroot / "xdg/config"), "--version", "-u", "NONE"])

    def test_isolated_neovim_paths(self):
        envroot = self.make()
        env = devkit.nvim_environment(envroot)
        self.assertEqual(env["XDG_CONFIG_HOME"], str(envroot / "xdg/config"))
        self.assertEqual(env["XDG_DATA_HOME"], str(envroot / "xdg/data"))
        self.assertNotIn("VIMINIT", env)
        self.assertNotEqual(devkit.Installation(self.work / "other").socket_name(), self.install.socket_name())

    def test_shared_packages_are_not_explicitly_reinstalled(self):
        def query(args, **kwargs):
            result = "installed" if args[-1] == "git" else "config-files"
            return subprocess.CompletedProcess(args, 0, stdout=result)

        with patch.object(devkit.subprocess, "run", side_effect=query):
            self.assertEqual(devkit.missing_packages("apt-get", ["git", "curl"]), ["curl"])

    def test_shell_does_not_load_owners_startup_hooks(self):
        envroot = self.make()
        inherited = {"PROMPT_COMMAND": "touch owner-file", "BASH_ENV": "/owner/startup", "BASH_FUNC_nvim%%": "() { false; }"}
        with patch.dict(os.environ, inherited), patch.object(devkit.subprocess, "call", return_value=0) as called:
            self.install.execute("shell", [])
        args, kwargs = called.call_args
        self.assertEqual(args[0][1:], ["--noprofile", "--rcfile", str(envroot / "bashrc"), "-i"])
        for name in inherited:
            self.assertNotIn(name, kwargs["env"])

    def test_bash_entrypoint_forwards_options_without_installing(self):
        log = self.work / "arguments"
        fake_python = self.work / "fake-bin/python3"
        devkit.write_new(fake_python, '#!/bin/sh\nprintf "%s\\n" "$@" >> "$DEVKIT_ARGUMENT_LOG"\n', True)
        values = dict(os.environ, PATH=str(fake_python.parent) + os.pathsep + os.environ["PATH"], DEVKIT_ARGUMENT_LOG=str(log))
        result = subprocess.run(["bash", str(SOURCE / "install.sh"), "--root", str(self.install.root),
                                 "--config-only"], env=values, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(log.read_text().splitlines()[-5:], [str(SOURCE / "lib/devkit.py"), "--root", str(self.install.root),
                                                           "install", "--config-only"])

    def test_uninstall_can_resume_after_each_filesystem_transition(self):
        devkit.write_new(self.install.launcher, "owner launcher")
        actual_move = devkit.move_preserving
        for fail_at in ("active", "devkit", "previous-launcher"):
            with self.subTest(transition=fail_at):
                envroot = self.make()
                def interrupted_move(source, destination):
                    actual_move(source, destination)
                    if source.name == fail_at:
                        raise OSError("interrupted after rename")
                with patch.object(devkit, "move_preserving", side_effect=interrupted_move):
                    with self.assertRaisesRegex(OSError, "interrupted"):
                        self.install.uninstall()
                archive = self.install.uninstall()
                self.assertEqual(self.install.launcher.read_text(), "owner launcher")
                self.assertEqual((archive / "environment").resolve(), envroot)
                self.assertTrue(envroot.exists())
                self.assert_owner_unchanged()

    def test_partial_journal_tail_is_preserved_and_recovered(self):
        devkit.write_new(self.install.launcher, "owner launcher")
        envroot = self.make()
        journal = envroot / "journal.jsonl"
        with journal.open("ab") as stream:
            stream.write(b'{"interrupted":')
        self.assertEqual(self.install.manifest(envroot)["status"], "ready")
        self.install.uninstall()
        self.assertEqual(self.install.launcher.read_text(), "owner launcher")
        self.assertIn(b'{"interrupted":\n', journal.read_bytes())
        self.assertEqual(self.install.manifest(envroot)["status"], "archived")

    def test_symlinked_ancestor_and_dotdot_root_work(self):
        parent = self.work / "actual"
        parent.mkdir()
        alias = self.work / "alias"
        alias.symlink_to(parent, target_is_directory=True)
        proposed = alias / "child/../devkit"
        self.install = devkit.Installation(proposed, self.user_home)
        envroot = self.make()
        self.assertEqual(self.install.current(), envroot)
        self.assertEqual(self.install.root, parent / "devkit")
        self.install.uninstall()

    def test_competing_roots_cannot_displace_launcher(self):
        devkit.write_new(self.install.launcher, "owner launcher")
        envroot = self.make()
        other = devkit.Installation(self.work / "other-root", self.user_home)
        with self.assertRaisesRegex(RuntimeError, "Another installation"):
            other.install(SOURCE, config_only=True)
        self.assertFalse(other.root.exists())
        self.assertEqual(self.install.current(), envroot)
        self.install.uninstall()
        with patch.object(devkit.shutil, "which", return_value=None):
            other.install(SOURCE, config_only=True)
        other.uninstall()
        self.assertEqual(other.launcher.read_text(), "owner launcher")

    def test_editor_in_another_process_blocks_uninstall(self):
        envroot = self.make()
        fake_editor = self.work / "waiting-editor"
        devkit.write_new(fake_editor, '#!/bin/sh\nprintf "READY\\n"\nread response\nprintf "%s\\n" "$response" > "$DEVKIT_ENV/new-note"\n', True)
        manifest = self.install.manifest(envroot)
        manifest["commands"]["nvim"] = str(fake_editor)
        self.install.record(envroot, manifest)
        process = subprocess.Popen([str(envroot / "bin/nvim")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            self.assertTrue(select.select([process.stdout], [], [], 10)[0], "editor did not start")
            self.assertEqual(process.stdout.readline().strip(), "READY")
            with self.assertRaisesRegex(RuntimeError, "other terminals"):
                self.install.uninstall()
            _, stderr = process.communicate("preserve my work\n", timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
        finally:
            if process.poll() is None:
                process.communicate("preserve my work\n", timeout=10)
        archive = self.install.uninstall()
        self.assertEqual((archive / "environment/new-note").read_text(), "preserve my work\n")

    def test_second_shell_retains_history_on_exit(self):
        envroot = self.make()
        process = subprocess.Popen([str(envroot / "bin/devkit"), "shell"], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
        try:
            process.stdin.write("echo DEVKIT_READY\n")
            process.stdin.flush()
            self.assertTrue(select.select([process.stdout], [], [], 10)[0], "shell did not start")
            self.assertEqual(process.stdout.readline().strip(), "DEVKIT_READY")
            with self.assertRaisesRegex(RuntimeError, "other terminals"):
                self.install.uninstall()
            _, stderr = process.communicate("exit\n", timeout=10)
            self.assertEqual(process.returncode, 0, stderr)
        finally:
            if process.poll() is None:
                process.communicate("exit\n", timeout=10)
        archive = self.install.uninstall()
        self.assertIn("echo DEVKIT_READY", (archive / "environment/bash_history").read_text())

    def test_cleanup_failure_can_resume_without_touching_restored_launcher(self):
        devkit.write_new(self.install.launcher, "original")
        envroot = self.make()
        with patch.object(devkit, "cleanup_packages", return_value={"errors": ["simulated package failure"]}):
            with self.assertRaisesRegex(RuntimeError, "Cleanup is incomplete"):
                self.install.uninstall()
        self.assertEqual(self.install.launcher.read_text(), "original")
        self.install.recover()
        self.assertEqual(self.install.launcher.read_text(), "original")
        self.assertEqual(self.install.manifest(envroot)["status"], "archived")

    def test_cleanup_retry_preserves_launcher_created_after_restoration(self):
        envroot = self.make()
        with patch.object(devkit, "cleanup_packages", return_value={"errors": ["temporary cleanup error"]}):
            with self.assertRaisesRegex(RuntimeError, "Cleanup is incomplete"):
                self.install.uninstall()
        devkit.write_new(self.install.launcher, "owner's newly installed command")
        expected = devkit.identity(self.install.launcher)
        with patch.object(devkit, "cleanup_packages", return_value={"errors": []}):
            self.install.recover()
        self.assertEqual(self.install.launcher.read_text(), "owner's newly installed command")
        self.assertEqual(devkit.identity(self.install.launcher), expected)
        self.assertEqual(self.install.manifest(envroot)["status"], "archived")

    def test_cleanup_retry_preserves_replacement_of_restored_launcher(self):
        devkit.write_new(self.install.launcher, "owner's original command")
        envroot = self.make()
        with patch.object(devkit, "cleanup_packages", return_value={"errors": ["temporary cleanup error"]}):
            with self.assertRaisesRegex(RuntimeError, "Cleanup is incomplete"):
                self.install.uninstall()
        self.install.launcher.rename(self.work / "owner-preserved-original")
        devkit.write_new(self.install.launcher, "owner's replacement command")
        expected = devkit.identity(self.install.launcher)
        with patch.object(devkit, "cleanup_packages", return_value={"errors": []}):
            self.install.recover()
        self.assertEqual(self.install.launcher.read_text(), "owner's replacement command")
        self.assertEqual(devkit.identity(self.install.launcher), expected)
        self.assertEqual(self.install.manifest(envroot)["status"], "archived")

    def test_recover_adopts_new_bootstrap_into_ready_environment_without_retiring(self):
        envroot = self.make()
        controller = (self.install.root / "manager").resolve()
        registry = self.install.registry()
        journal = self.install.root / "bootstrap-journal.jsonl"
        devkit.append_record(journal, {"kind": "package", "manager": "apt-get", "name": "devkit-bootstrap-fixture",
                                      "before_present": False, "status": "installed", "installed_by_devkit": True,
                                      "installed_version": "1"})
        with patch.dict(os.environ, {"DEVKIT_BOOTSTRAP_JOURNAL": str(journal)}), \
                patch.object(devkit, "cleanup_packages", side_effect=AssertionError("ready environment must not be cleaned up")):
            self.assertEqual(self.install.recover(), [])
        self.assertEqual(self.install.current(), envroot)
        self.assertEqual(self.install.registry(), registry)
        self.assertEqual((self.install.root / "manager").resolve(), controller)
        self.assertEqual(len(self.install.entries()), 1)
        manifest = self.install.manifest(envroot)
        self.assertEqual(manifest["status"], "ready")
        self.assertEqual(manifest["packages"]["owned"], {"devkit-bootstrap-fixture": "1"})
        self.assertEqual(devkit.journal_read(journal)[-1]["kind"], "adopted")

    def test_uninstall_adopts_pending_bootstrap_before_cleanup(self):
        envroot = self.make()
        journal = self.install.root / "bootstrap-journal.jsonl"
        devkit.append_record(journal, {"kind": "package", "manager": "apt-get", "name": "devkit-bootstrap-fixture",
                                      "before_present": False, "status": "installed", "installed_by_devkit": True,
                                      "installed_version": "1"})
        with patch.dict(os.environ, {"DEVKIT_BOOTSTRAP_JOURNAL": str(journal)}), \
                patch.object(devkit, "cleanup_packages", return_value={"errors": []}) as cleaned:
            self.install.uninstall()
        self.assertEqual(cleaned.call_count, 1)
        self.assertEqual(cleaned.call_args.args[0], envroot)
        self.assertEqual(cleaned.call_args.args[1]["owned"], {"devkit-bootstrap-fixture": "1"})
        self.assertEqual(self.install.manifest(envroot)["status"], "archived")
        self.assertEqual(len(self.install.entries()), 1)

    def test_stable_controller_and_archive_inventory_remain_after_removal(self):
        envroot = self.make()
        self.install.uninstall()
        self.assertEqual((self.install.root / "manager").resolve(), envroot / "source")
        self.assertEqual(self.install.archives()[0]["environment"], str(envroot))
        self.assertEqual(devkit.default_root(self.user_home), str(self.install.root))

    def test_source_nested_install_root_rejected_before_copy(self):
        source = self.work / "source"
        source.mkdir()
        installation = devkit.Installation(source / "nested-install", self.user_home)
        with self.assertRaisesRegex(RuntimeError, "inside its source"):
            installation.install(source, config_only=True)
        self.assertFalse(installation.root.exists())

    def test_tar_traversal_rejected(self):
        archive = self.work / "malicious.tar.gz"
        with tarfile.open(archive, "w:gz") as bundle:
            entry = tarfile.TarInfo("../escape")
            entry.size = 4
            bundle.addfile(entry, io.BytesIO(b"oops"))
        with self.assertRaisesRegex(RuntimeError, "Unsafe archive"):
            devkit.extract(archive, self.work / "extract")
        self.assertFalse((self.work / "escape").exists())

    def test_manifest_contains_checked_assets(self):
        lock = json.loads((SOURCE / "tools.lock.json").read_text())
        for tool in ("nvim", "tmux", "uv", "tree-sitter"):
            for asset in lock[tool]["assets"].values():
                self.assertEqual(len(asset["sha256"]), 64)
                self.assertTrue(asset["url"].startswith("https://github.com/"))


if __name__ == "__main__":
    unittest.main()
