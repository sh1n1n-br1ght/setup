import hashlib
import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tarfile
import tempfile
import unittest
from unittest.mock import patch
import urllib.error


SOURCE = Path(__file__).resolve().parents[1]
spec = importlib.util.spec_from_file_location("devkit_provision_test", SOURCE / "lib/provision.py")
provision = importlib.util.module_from_spec(spec)
spec.loader.exec_module(provision)


class ProvisionTests(unittest.TestCase):
    def setUp(self):
        self.work = Path(tempfile.mkdtemp(prefix="devkit-provision-test-"))
        self.envroot = self.work / "environments/test"
        self.envroot.mkdir(parents=True)
        self.archive = self.work / "archive"
        self.bootstrap = self.work / "bootstrap-journal.jsonl"
        self.values = patch.dict(os.environ, {"DEVKIT_BOOTSTRAP_JOURNAL": str(self.bootstrap)})
        self.values.start()
        self.addCleanup(self.values.stop)

    def test_download_retries_and_reuses_only_verified_cache(self):
        data = b"a verified release archive"
        digest = hashlib.sha256(data).hexdigest()
        destination = self.envroot / "downloads/tool.tar.gz"
        cache = self.work / "download-cache"
        with patch.object(provision.urllib.request, "urlopen", side_effect=[urllib.error.URLError("offline"), io.BytesIO(data)]) as opened, patch.object(provision.time, "sleep"):
            provision.download("https://example.invalid/tool", destination, digest, cache=cache)
        self.assertEqual(opened.call_count, 2)
        second = self.work / "second-download"
        with patch.object(provision.urllib.request, "urlopen", side_effect=AssertionError("cache should avoid network")):
            provision.download("https://example.invalid/tool", second, digest, cache=cache)
        self.assertEqual(second.read_bytes(), data)
        self.assertEqual((cache / digest).read_bytes(), data)

    def test_corrupt_download_and_cache_are_preserved_and_replaced(self):
        data = b"good"
        digest = hashlib.sha256(data).hexdigest()
        cache = self.work / "cache"
        cache.mkdir()
        (cache / digest).write_bytes(b"bad cache")
        destination = self.work / "download"
        destination.write_bytes(b"partial old download")
        with patch.object(provision.urllib.request, "urlopen", return_value=io.BytesIO(data)):
            provision.download("https://example.invalid/tool", destination, digest, cache=cache)
        self.assertEqual(destination.read_bytes(), data)
        self.assertEqual(next(self.work.glob("download.rejected-*")).read_bytes(), b"partial old download")
        self.assertEqual(next(cache.glob("*.rejected-*")).read_bytes(), b"bad cache")

    def test_checksum_failure_never_populates_verified_cache(self):
        destination = self.work / "download"
        cache = self.work / "cache"
        digest = hashlib.sha256(b"expected").hexdigest()
        with patch.object(provision.urllib.request, "urlopen", side_effect=lambda *a, **k: io.BytesIO(b"wrong")), patch.object(provision.time, "sleep"):
            with self.assertRaisesRegex(RuntimeError, "Checksum mismatch"):
                provision.download("https://example.invalid/tool", destination, digest, cache=cache, retries=2)
        self.assertFalse(destination.exists())
        self.assertFalse((cache / digest).exists())
        self.assertEqual(len(list(self.work.glob("download.partial-*"))), 2)

    def test_package_intent_precedes_mutation_and_failed_install_retains_ownership(self):
        inventory = {"git": "existing"}
        calls = []

        def mutate(args, **kwargs):
            journal = provision.journal_read(self.envroot / "packages.jsonl")[-1]
            self.assertEqual(journal["status"], "installing")
            self.assertEqual(journal["before"], {"git": "existing"})
            self.assertEqual(journal["planned_additions"], ["curl", "libcurl"])
            calls.append(args)
            inventory.update(curl="1", libcurl="1", unrelated="1")
            raise subprocess.CalledProcessError(1, args)

        with patch.dict(provision.MANAGERS, {"apt-get": ([], ["apt-get", "install", "-y"], "git curl")}), \
                patch.object(provision, "package_inventory", side_effect=lambda *a: dict(inventory)), \
                patch.object(provision, "installation_candidates", return_value=["curl", "libcurl"]), \
                patch.object(provision.os, "geteuid", return_value=0), \
                patch.object(provision, "run", side_effect=mutate):
            with self.assertRaises(subprocess.CalledProcessError):
                provision.system_packages(self.envroot, "apt-get")
        info = provision.journal_read(self.envroot / "packages.jsonl")[-1]
        self.assertEqual(info["owned"], {"curl": "1", "libcurl": "1"})
        self.assertEqual(info["observed_dependencies"], {"unrelated": "1"})
        self.assertEqual(calls, [["apt-get", "install", "-y", "curl"]])

    def test_cleanup_preserves_nonowned_changed_and_required_packages(self):
        inventory = {"git": "existing", "curl": "1", "libshared": "1", "python": "newer"}
        info = {"manager": "apt-get", "before": {"git": "existing"}, "owned": {"curl": "1", "libshared": "1", "python": "older"}}
        provision.package_record(self.envroot, info)
        mutations = []

        def transaction(args, **kwargs):
            names = args[args.index("--remove") + 1:]
            if "--no-act" in args:
                return subprocess.CompletedProcess(args, int("libshared" in names), stdout="", stderr="required by another app")
            mutations.append(args)
            for name in names:
                inventory.pop(name)
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        with patch.object(provision, "package_inventory", side_effect=lambda *a: dict(inventory)), \
                patch.object(provision, "package_files", return_value=[]), \
                patch.object(provision.os, "geteuid", return_value=0), \
                patch.object(provision.subprocess, "run", side_effect=transaction):
            report = provision.cleanup_packages(self.envroot, {}, self.archive)
        self.assertEqual(report["removed"], ["curl"])
        self.assertEqual(set(report["retained"]), {"libshared", "python"})
        self.assertEqual(mutations, [["dpkg", "--remove", "curl"]])
        self.assertEqual(inventory["git"], "existing")
        self.assertTrue(list(self.archive.glob("package-payloads/curl-*/payload.tar")))

    def test_configuration_backup_failure_prevents_package_removal(self):
        provision.package_record(self.envroot, {"manager": "apt-get", "owned": {"curl": "1"}})
        with patch.object(provision, "package_inventory", return_value={"curl": "1"}), \
                patch.object(provision, "archive_package_configs", side_effect=PermissionError("unreadable owner config")), \
                patch.object(provision.os, "geteuid", return_value=0), \
                patch.object(provision.subprocess, "run", side_effect=AssertionError("must not remove")):
            report = provision.cleanup_packages(self.envroot, {}, self.archive)
        self.assertIn("unreadable owner config", report["retained"]["curl"])
        self.assertEqual(report["removed"], [])

    def test_bootstrap_ownership_is_adopted_once_across_installations(self):
        record = {"kind": "package", "manager": "apt-get", "name": "python3", "before_present": False,
                  "status": "installed", "installed_by_devkit": True, "installed_version": "3.12"}
        self.bootstrap.write_text(json.dumps(record) + "\n")
        first = provision.adopt_bootstrap(self.envroot)
        self.assertEqual(first["owned"], {"python3": "3.12"})
        other = self.work / "environments/other"
        other.mkdir()
        self.assertEqual(provision.adopt_bootstrap(other), {})
        self.assertEqual(provision.journal_read(self.bootstrap)[-1]["kind"], "adopted")
        self.assertTrue((self.envroot / "packages.jsonl").is_file())

    def test_partial_package_journal_tail_does_not_hide_owned_records(self):
        record = {"manager": "apt-get", "owned": {"curl": "1"}}
        provision.package_record(self.envroot, record)
        with (self.envroot / "packages.jsonl").open("a") as stream:
            stream.write('{"partial":')
        self.assertEqual(provision.journal_read(self.envroot / "packages.jsonl")[-1], record)

    def test_preflight_rejects_recursive_copy_and_old_locked_tools_without_writes(self):
        nested = SOURCE / "must-not-be-created-by-preflight"
        report = provision.preflight(SOURCE, nested, config_only=True)
        self.assertFalse(report["ok"])
        self.assertIn("inside the source", " ".join(report["errors"]))
        self.assertFalse(nested.exists())
        with patch.object(provision.platform, "machine", return_value="unsupported-cpu"), \
                patch.object(provision.shutil, "which", return_value=None), \
                patch.object(provision, "manager_name", return_value="apt-get"):
            report = provision.preflight(SOURCE, self.work / "fresh-root")
        self.assertFalse(report["ok"])
        self.assertTrue(any("No compatible bundled nvim" in error for error in report["errors"]))
        self.assertFalse((self.work / "fresh-root").exists())

    def test_npm_and_uv_writes_use_private_directories(self):
        with patch.dict(os.environ, {"npm_config_cache": "/owner/npm", "NPM_CONFIG_USERCONFIG": "/owner/npmrc"}):
            values = provision.environment(self.envroot)
        self.assertEqual(values["NPM_CONFIG_CACHE"], str(self.envroot / "cache/npm"))
        self.assertEqual(values["npm_config_cache"], str(self.envroot / "cache/npm"))
        self.assertEqual(values["NPM_CONFIG_USERCONFIG"], str(self.envroot / "npmrc"))
        self.assertEqual(values["UV_PYTHON_INSTALL_DIR"], str(self.envroot / "python"))
        self.assertEqual(values["UV_PYTHON_BIN_DIR"], str(self.envroot / "python-bin"))

    def test_python_provisioning_cannot_publish_a_shared_python_launcher(self):
        commands = {}
        for name in ("nvim", "tmux", "uv", "tree-sitter", "python"):
            path = self.work / "fake-tools" / name
            path.parent.mkdir(exist_ok=True)
            path.write_text("fixture")
            commands[name] = str(path)
        calls = []

        def invoke(args, **kwargs):
            calls.append((args, kwargs))
            if args[1:3] == ["python", "install"]:
                self.assertIn("--no-bin", args)
                self.assertEqual(kwargs["env"]["UV_PYTHON_BIN_DIR"], str(self.envroot / "python-bin"))
                self.assertEqual(kwargs["env"]["UV_PYTHON_INSTALL_DIR"], str(self.envroot / "python"))

        def output(args, **kwargs):
            if args[0] == commands["nvim"]:
                return "NVIM v0.12.6\n"
            if args[0] == commands["tree-sitter"]:
                return "tree-sitter 0.27.1\n"
            return commands["python"] + "\n"

        with patch.object(provision.platform, "machine", return_value="mock-architecture"), \
                patch.object(provision.shutil, "which", side_effect=lambda tool, **kw: commands.get(tool)), \
                patch.object(provision, "run", side_effect=invoke), \
                patch.object(provision.subprocess, "check_output", side_effect=output):
            result = provision.install_tools(self.envroot, SOURCE, {})
        self.assertEqual(result["python"], commands["python"])
        self.assertTrue(any(args[1:3] == ["python", "install"] for args, kwargs in calls))

    def test_full_payload_archive_preserves_modified_data_outside_etc(self):
        shared = self.work / "host/usr/share"
        shared.mkdir(parents=True)
        modified = shared / "package-data"
        modified.write_text("owner edited package data")
        unrelated = shared / "owner-untracked"
        unrelated.write_text("must not traverse all of usr/share")
        link = shared / "package-link"
        link.symlink_to(modified)
        files = [str(shared), str(modified), str(link)]
        with patch.object(provision, "package_files", return_value=files), \
                patch.object(provision, "removal_risk", return_value=None):
            location = provision.archive_package_configs("apt-get", "fixture", self.archive, {})
        with tarfile.open(location / "payload.tar") as bundle:
            member = "filesystem/" + str(modified).lstrip("/")
            self.assertEqual(bundle.extractfile(member).read(), b"owner edited package data")
            self.assertTrue(bundle.getmember("filesystem/" + str(link).lstrip("/")).issym())
            self.assertNotIn("filesystem/" + str(unrelated).lstrip("/"), bundle.getnames())
        self.assertEqual(modified.read_text(), "owner edited package data")

    def test_homebrew_archives_untracked_cellar_and_runtime_data(self):
        prefix = self.work / "brew"
        cellar = prefix / "Cellar/example/1.0"
        cellar.mkdir(parents=True)
        (cellar / "untracked-personal-file").write_text("preserve this too")
        (prefix / "var/example").mkdir(parents=True)
        (prefix / "var/example/database").write_text("user data")
        with patch.object(provision, "package_files", return_value=[]):
            location = provision.archive_package_configs("brew", "example", self.archive, {"prefix": str(prefix)})
        self.assertEqual((location / "homebrew-cellar/1.0/untracked-personal-file").read_text(), "preserve this too")
        self.assertEqual((location / "homebrew-var/example/database").read_text(), "user data")

    def test_unbounded_removal_hook_retains_package_without_mutation(self):
        provision.package_record(self.envroot, {"manager": "apt-get", "owned": {"curl": "1"}})
        with patch.object(provision, "package_inventory", return_value={"curl": "1"}), \
                patch.object(provision, "package_files", return_value=[]), \
                patch.object(provision, "removal_risk", return_value="removal script can delete untracked data"), \
                patch.object(provision.os, "geteuid", return_value=0), \
                patch.object(provision.subprocess, "run", side_effect=AssertionError("must not remove")):
            report = provision.cleanup_packages(self.envroot, {}, self.archive)
        self.assertIn("untracked data", report["retained"]["curl"])
        self.assertEqual(report["removed"], [])

    def test_recovery_never_reclaims_reinstalled_homebrew_after_archival(self):
        original_archive = self.work / "old-homebrew"
        original_archive.mkdir()
        replacement = self.work / "new-homebrew"
        replacement.mkdir()
        (replacement / "owner-file").write_text("new installation")
        info = {"manager": "brew", "prefix": str(replacement), "owned": {"curl": "1"},
                "resources": {"homebrew": {"owned": True, "status": "archiving", "archive_path": str(original_archive),
                                             "source_identity": provision.directory_identity(original_archive)}}}
        provision.package_record(self.envroot, info)
        with patch.object(provision, "package_inventory", side_effect=AssertionError("must not inspect/remove new installation")), \
                patch.object(provision, "run", side_effect=AssertionError("must not move new installation")):
            report = provision.cleanup_packages(self.envroot, {}, self.archive)
        self.assertIn("homebrew-reappeared", report["retained"])
        self.assertEqual((replacement / "owner-file").read_text(), "new installation")

    def test_package_upgraded_during_archival_is_not_removed(self):
        inventory = {"fixture": "1"}
        provision.package_record(self.envroot, {"manager": "apt-get", "owned": dict(inventory)})
        archive_payload = provision.archive_package_configs

        def archive_then_upgrade(*args):
            target = archive_payload(*args)
            inventory["fixture"] = "2"
            return target

        def probe_only(args, **kwargs):
            self.assertIn("--no-act", args, "The upgraded package must not be removed")
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        with patch.object(provision, "package_inventory", side_effect=lambda *a: dict(inventory)), \
                patch.object(provision, "package_files", return_value=[]), \
                patch.object(provision, "removal_risk", return_value=None), \
                patch.object(provision, "archive_package_configs", side_effect=archive_then_upgrade), \
                patch.object(provision.os, "geteuid", return_value=0), \
                patch.object(provision.subprocess, "run", side_effect=probe_only):
            report = provision.cleanup_packages(self.envroot, {}, self.archive)
        self.assertEqual(report["removed"], [])
        self.assertIn("version changed", report["retained"]["fixture"])
        self.assertEqual(inventory["fixture"], "2")

    def test_payload_edited_after_archival_is_retained(self):
        data = self.work / "package-data"
        data.write_text("original contents")
        provision.package_record(self.envroot, {"manager": "apt-get", "owned": {"fixture": "1"}})

        def edit_during_probe(args, **kwargs):
            self.assertIn("--no-act", args, "Changed package data must not be removed")
            data.write_text("new owner data after archival")
            return subprocess.CompletedProcess(args, 0, stdout="", stderr="")

        with patch.object(provision, "package_inventory", return_value={"fixture": "1"}), \
                patch.object(provision, "package_files", return_value=[str(data)]), \
                patch.object(provision, "removal_risk", return_value=None), \
                patch.object(provision.os, "geteuid", return_value=0), \
                patch.object(provision.subprocess, "run", side_effect=edit_during_probe):
            report = provision.cleanup_packages(self.envroot, {}, self.archive)
        self.assertEqual(report["removed"], [])
        self.assertIn("changed after archival", report["retained"]["fixture"])
        self.assertEqual(data.read_text(), "new owner data after archival")

    def test_homebrew_untracked_data_changed_during_copy_is_retained(self):
        prefix = self.work / "brew"
        cellar = prefix / "Cellar/example"
        (cellar / "1.0").mkdir(parents=True)
        data = cellar / "1.0/owner-file"
        data.write_text("before copying")
        copytree = provision.shutil.copytree

        def copy_then_edit(source, destination, *args, **kwargs):
            result = copytree(source, destination, *args, **kwargs)
            if Path(source) == cellar:
                data.write_text("owner changed it during copy")
            return result

        with patch.object(provision, "package_files", return_value=[]), \
                patch.object(provision.shutil, "copytree", side_effect=copy_then_edit):
            with self.assertRaisesRegex(RuntimeError, "changed during archival"):
                provision.archive_package_configs("brew", "example", self.archive, {"prefix": str(prefix)})
        self.assertEqual(data.read_text(), "owner changed it during copy")

    def test_external_rpm_file_triggers_prevent_unbounded_removal(self):
        def query(args):
            return "transaction file trigger script" if args == ["rpm", "-qa", "--filetriggers"] else ""

        with patch.object(provision, "query", side_effect=query):
            risk = provision.removal_risk("dnf", "fixture", [], {})
        self.assertIn("external file-trigger", risk)


if __name__ == "__main__":
    unittest.main()
