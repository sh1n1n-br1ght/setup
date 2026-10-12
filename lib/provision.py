#!/usr/bin/env python3
"""An isolated, reversible development environment. Requires Python 3.8+."""
from __future__ import annotations

import argparse
import datetime
import fcntl
import fnmatch
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shlex
import shutil
import stat
import subprocess
import sys
import tarfile
import time
import urllib.request
import uuid
import zipfile


SOURCE = Path(__file__).resolve().parents[1]


def stamp():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ") + "-" + uuid.uuid4().hex[:8]


def exists(path):
    return os.path.lexists(str(path))


def write_new(path, text, executable=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("x", encoding="utf-8") as stream:
        stream.write(text)
    if executable:
        path.chmod(0o755)


def run(args, **kwargs):
    print("+ " + shlex.join([str(arg) for arg in args]), flush=True)
    return subprocess.run([str(arg) for arg in args], check=True, **kwargs)


def run_interactive(args):
    # A curl | bash bootstrap has pipe stdin; Homebrew still needs the terminal.
    try:
        terminal = open("/dev/tty", "r")
    except OSError:
        terminal = None
    try:
        return run(args, stdin=terminal)
    finally:
        if terminal:
            terminal.close()


def sha256_file(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def download(url, destination, digest=None, cache=None, retries=3):
    destination = Path(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if exists(destination):
        if digest and destination.is_file() and sha256_file(destination) == digest:
            return destination
        destination.rename(destination.with_name(destination.name + ".rejected-" + stamp()))
    cached = Path(cache) / digest if cache and digest else None
    if cached and cached.is_file():
        if sha256_file(cached) == digest:
            shutil.copyfile(cached, destination)
            return destination
        cached.rename(cached.with_name(cached.name + ".rejected-" + stamp()))
    request = urllib.request.Request(url, headers={"User-Agent": "devkit-installer/1"})
    for attempt in range(retries):
        partial = destination.with_name(destination.name + ".partial-" + stamp())
        try:
            with urllib.request.urlopen(request, timeout=120) as response, partial.open("xb") as stream:
                shutil.copyfileobj(response, stream)
                stream.flush()
                os.fsync(stream.fileno())
            if digest and sha256_file(partial) != digest:
                raise RuntimeError("Checksum mismatch; retained download: " + str(partial))
            partial.rename(destination)
            if cached:
                cached.parent.mkdir(parents=True, exist_ok=True)
                if not exists(cached):
                    with destination.open("rb") as src, cached.open("xb") as dst:
                        shutil.copyfileobj(src, dst)
            return destination
        except (OSError, RuntimeError) as error:
            if attempt + 1 == retries:
                raise RuntimeError("Download failed after " + str(retries) + " attempts: " + str(error)) from error
            time.sleep(min(2 ** attempt, 5))


def extract(archive, destination):
    destination.mkdir(parents=True, exist_ok=False)
    root = destination.resolve()

    def safe(name):
        candidate = root / name
        if os.path.commonpath([str(root), str(candidate.resolve())]) != str(root):
            raise RuntimeError("Unsafe archive member: " + name)
        return candidate

    if archive.name.endswith(".zip"):
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.infolist():
                target = safe(member.filename)
                if member.is_dir():
                    target.mkdir(parents=True, exist_ok=True)
                else:
                    target.parent.mkdir(parents=True, exist_ok=True)
                    with bundle.open(member) as src, target.open("xb") as dst:
                        shutil.copyfileobj(src, dst)
                    target.chmod(((member.external_attr >> 16) & 0o777) or 0o644)
        return
    with tarfile.open(archive) as bundle:
        for member in bundle:
            target = safe(member.name)
            if member.isdir():
                target.mkdir(parents=True, exist_ok=True)
            elif member.isfile():
                target.parent.mkdir(parents=True, exist_ok=True)
                with bundle.extractfile(member) as src, target.open("xb") as dst:
                    shutil.copyfileobj(src, dst)
                target.chmod(member.mode & 0o777)
            elif member.issym():
                link = target.parent / member.linkname
                safe(str(link.relative_to(root)))
                target.parent.mkdir(parents=True, exist_ok=True)
                target.symlink_to(member.linkname)
            elif member.islnk():
                target.parent.mkdir(parents=True, exist_ok=True)
                os.link(str(safe(member.linkname)), str(target))
            else:
                raise RuntimeError("Unsupported archive member: " + member.name)


MANAGERS = {
    "apt-get": (["apt-get", "update"], ["apt-get", "install", "-y"],
                "git curl ca-certificates zip unzip ripgrep build-essential cmake ninja-build gettext pkg-config python3 nodejs npm tar gzip bzip2 xz-utils coreutils findutils grep sed gawk"),
    "dnf": ([], ["dnf", "install", "-y"],
            "git curl ca-certificates zip unzip ripgrep gcc gcc-c++ make cmake ninja-build gettext pkgconf-pkg-config python3 nodejs npm tar gzip bzip2 xz coreutils findutils grep sed gawk"),
    "yum": ([], ["yum", "install", "-y"],
            "git curl ca-certificates zip unzip gcc gcc-c++ make cmake gettext pkgconfig python3 nodejs npm tar gzip bzip2 xz coreutils findutils grep sed gawk"),
    "pacman": ([], ["pacman", "-S", "--needed", "--noconfirm"],
               "git curl ca-certificates zip unzip ripgrep base-devel cmake ninja gettext pkgconf python nodejs npm tar gzip bzip2 xz coreutils findutils grep sed gawk"),
    "zypper": (["zypper", "--non-interactive", "refresh"], ["zypper", "--non-interactive", "install"],
               "git curl ca-certificates zip unzip ripgrep gcc gcc-c++ make cmake ninja gettext-tools pkg-config python3 nodejs npm tar gzip bzip2 xz coreutils findutils grep sed gawk"),
    "apk": ([], ["apk", "add", "--no-cache"],
            "bash git curl ca-certificates zip unzip ripgrep build-base cmake ninja gettext-dev pkgconf python3 nodejs npm tar gzip bzip2 xz coreutils findutils grep sed gawk neovim"),
    "xbps-install": ([], ["xbps-install", "-Sy"],
                     "git curl ca-certificates zip unzip ripgrep base-devel cmake ninja gettext pkg-config python3 nodejs npm tar gzip bzip2 xz coreutils findutils grep sed gawk neovim"),
    "eopkg": ([], ["eopkg", "install", "-y"],
              "git curl ca-certs zip unzip ripgrep gcc g++ make cmake ninja gettext pkg-config python3 nodejs tar gzip bzip2 xz coreutils findutils grep sed gawk"),
}


def manager_name():
    if platform.system() == "Darwin":
        return "brew"
    for manager in MANAGERS:
        if shutil.which(manager):
            return manager
    if shutil.which("nix"):
        return "nix"
    return None


def missing_packages(manager, packages):
    queries = {
        "apt-get": ["dpkg-query", "-W", "-f=${db:Status-Status}"],
        "dnf": ["rpm", "-q"], "yum": ["rpm", "-q"], "zypper": ["rpm", "-q"],
        "pacman": ["pacman", "-Q"], "apk": ["apk", "info", "-e"],
        "xbps-install": ["xbps-query", "-p", "pkgver"],
    }
    query = queries.get(manager)
    if not query:
        return packages
    missing = []
    for package in packages:
        result = subprocess.run(query + [package], stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        installed = result.returncode == 0
        if manager == "apt-get":
            installed = installed and result.stdout.strip() == "installed"
        if not installed:
            missing.append(package)
    return missing


def journal_read(path):
    if not Path(path).is_file():
        return []
    records = []
    for line in Path(path).read_text().splitlines():
        try:
            value = json.loads(line)
        except json.JSONDecodeError:
            continue
        if isinstance(value, dict):
            records.append(value)
    return records


def package_record(envroot, info, checkpoint=None):
    with (Path(envroot) / "packages.jsonl").open("a", encoding="utf-8") as stream:
        stream.write("\n" + json.dumps(info, sort_keys=True) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    if checkpoint:
        checkpoint(dict(info))


def query(args):
    result = subprocess.run([str(arg) for arg in args], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError("Package query failed: " + shlex.join([str(a) for a in args]) + ": " + result.stderr.strip())
    return result.stdout


def brew_command():
    return shutil.which("brew") or next((str(p) for p in (Path("/opt/homebrew/bin/brew"), Path("/usr/local/bin/brew")) if p.exists()), None)


def package_inventory(manager, command=None):
    """A missing/failed inventory must never be mistaken for an empty machine."""
    if manager == "brew":
        data = json.loads(query([command or brew_command(), "info", "--json=v2", "--installed"]))
        return {p["name"]: ",".join(str(v["version"]) for v in p["installed"]) for p in data["formulae"]}
    if manager == "apt-get":
        output = query(["dpkg-query", "-W", "-f=${binary:Package}\t${Version}\t${db:Status-Status}\n"])
        return {fields[0]: fields[1] for line in output.splitlines()
                if len(fields := line.split("\t")) == 3 and fields[2] == "installed"}
    if manager in ("dnf", "yum", "zypper"):
        output = query(["rpm", "-qa", "--qf", "%{NAME}\t%{VERSION}-%{RELEASE}.%{ARCH}\n"])
    elif manager == "pacman":
        output = query(["pacman", "-Q"])
    elif manager == "apk":
        # APK v2/v3 both provide name/version pairs through the installed database.
        output = Path("/lib/apk/db/installed").read_text()
        packages = {}
        for entry in output.split("\n\n"):
            fields = dict(line.split(":", 1) for line in entry.splitlines() if ":" in line)
            if "P" in fields and "V" in fields:
                packages[fields["P"]] = fields["V"]
        return packages
    elif manager == "xbps-install":
        output = query(["xbps-query", "-l"])
        packages = {}
        for line in output.splitlines():
            fields = line.split()
            if len(fields) >= 2 and fields[0] == "ii":
                name, _, version = fields[1].rpartition("-")
                packages[name] = version
        return packages
    elif manager == "eopkg":
        output = query(["eopkg", "list-installed"])
        return {line.split()[0]: line for line in output.splitlines() if " - " in line}
    elif manager == "nix":
        return {}
    else:
        raise RuntimeError("No inventory adapter for " + str(manager))
    packages = {}
    for line in output.splitlines():
        fields = line.split()
        if len(fields) >= 2:
            packages[fields[0]] = fields[1]
    return packages


def bootstrap_records():
    location = os.environ.get("DEVKIT_BOOTSTRAP_JOURNAL")
    return journal_read(location) if location else []


def adopt_bootstrap(envroot):
    """Durably transfer pending bootstrap ownership to one environment."""
    envroot = Path(envroot)
    path = Path(os.environ.get("DEVKIT_BOOTSTRAP_JOURNAL", str(envroot.parent.parent / "bootstrap-journal.jsonl")))
    records = journal_read(path)
    start = 0
    for index, item in enumerate(records):
        if item.get("kind") == "adopted":
            start = index + 1
    pending = records[start:]
    if not pending:
        return {}
    installed = [item for item in pending if item.get("status") == "installed" and item.get("installed_by_devkit")]
    manager = next((item.get("manager") for item in installed if item.get("manager") in MANAGERS or item.get("manager") == "brew"), manager_name())
    previous = journal_read(envroot / "packages.jsonl")
    info = previous[-1] if previous else {"manager": manager, "status": "bootstrap-adopted", "owned": {}, "resources": {}, "before": {}}
    info["bootstrap"] = info.get("bootstrap", []) + pending
    for item in installed:
        if item.get("before_present") is not False:
            continue
        if item.get("kind") == "package" and item.get("installed_version"):
            info["owned"][item.get("canonical_name", item["name"])] = item["installed_version"]
        elif item.get("kind") == "package_manager" and item.get("manager") == "brew":
            info["resources"]["homebrew"] = dict(item, owned=True)
            if item.get("prefix"):
                info["prefix"] = item["prefix"]
                if Path(item["prefix"]).exists():
                    info["resources"]["homebrew"]["source_identity"] = directory_identity(item["prefix"])
            if item.get("path"):
                info["command"] = item["path"]
        elif item.get("kind") == "developer_tools" and item.get("manager") == "apple":
            info["resources"]["developer_tools"] = dict(item, owned=True)
            if Path("/Library/Developer/CommandLineTools").exists():
                info["resources"]["developer_tools"]["source_identity"] = directory_identity("/Library/Developer/CommandLineTools")
    package_record(envroot, info)
    with path.open("a", encoding="utf-8") as stream:
        stream.write("\n" + json.dumps({"kind": "adopted", "environment": str(envroot), "at": stamp()}) + "\n")
        stream.flush()
        os.fsync(stream.fileno())
    return info


def installation_candidates(manager, names, command=None):
    """Record a concrete dependency plan before the package transaction."""
    if not names:
        return []
    if manager == "apt-get":
        output = query(["apt-get", "--simulate", "--no-remove", "install"] + names)
        return sorted(set(names + re.findall(r"^Inst (\S+)", output, flags=re.MULTILINE)))
    if manager == "pacman":
        return sorted(set(names + query(["pacman", "-Sp", "--print-format", "%n"] + names).splitlines()))
    if manager == "brew":
        return sorted(set(names + query([command or brew_command(), "deps", "--union"] + names).splitlines()))
    # Other managers have different transaction output formats across versions.
    # Explicit targets remain proven; uncertain transitive additions are retained.
    return names


def system_packages(envroot, manager, checkpoint=None):
    if not manager:
        raise RuntimeError("Unknown package manager. Install the listed prerequisites first and use --no-system-packages.")
    envroot = Path(envroot)
    adopt_bootstrap(envroot)
    records = journal_read(envroot / "packages.jsonl")
    info = records[-1] if records else {"manager": manager, "status": "preparing", "owned": {},
                                      "resources": {}, "bootstrap": []}
    if info["manager"] != manager:
        raise RuntimeError("Package manager changed during an interrupted installation.")
    package_record(envroot, info, checkpoint)
    if manager == "nix":
        profile = envroot / "nix-profile"
        info.update(status="installing", prefix=str(profile), requested_packages=[])
        package_record(envroot, info, checkpoint)
        packages = "git curl cacert zip unzip ripgrep gcc gnumake cmake ninja gettext pkg-config python3 nodejs coreutils findutils gnused gnugrep gawk neovim tmux".split()
        run(["nix", "--extra-experimental-features", "nix-command flakes", "profile", "install", "--profile", profile] + ["nixpkgs#" + p for p in packages])
        info["status"] = "installed"
        package_record(envroot, info, checkpoint)
        return info
    command = None
    if manager == "brew":
        clt = info["resources"].setdefault("developer_tools", {
            "owned": not Path("/Library/Developer/CommandLineTools").exists(), "status": "existing"})
        if subprocess.run(["xcode-select", "-p"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
            clt["status"] = "installing"
            package_record(envroot, info, checkpoint)
            subprocess.run(["xcode-select", "--install"], check=False)
            print("Complete Apple's Command Line Tools installer. Waiting for it to finish...", flush=True)
            deadline = time.monotonic() + 3600
            while subprocess.run(["xcode-select", "-p"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
                if time.monotonic() > deadline:
                    raise RuntimeError("Developer tools installation did not finish within an hour.")
                time.sleep(5)
            clt["status"] = "installed"
            if clt.get("owned") and Path("/Library/Developer/CommandLineTools").exists():
                clt["source_identity"] = directory_identity("/Library/Developer/CommandLineTools")
            package_record(envroot, info, checkpoint)
        command = brew_command()
        info["resources"].setdefault("homebrew", {"owned": not bool(command), "status": "existing",
                                                    "before_prefix_present": Path("/opt/homebrew").exists()})
        if not command:
            info["resources"]["homebrew"]["status"] = "installing"
            package_record(envroot, info, checkpoint)
            installer = envroot / "downloads/homebrew-install.sh"
            download("https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh", installer)
            run_interactive(["/bin/bash", installer])
            command = brew_command()
            if not command:
                raise RuntimeError("Homebrew installation did not finish.")
            info["resources"]["homebrew"]["status"] = "installed"
            package_record(envroot, info, checkpoint)
        info.update(prefix=query([command, "--prefix"]).strip(), command=command)
        resource = info["resources"]["homebrew"]
        if resource.get("owned") and not resource.get("source_identity"):
            resource["source_identity"] = directory_identity(info["prefix"])
        packages = "git curl zip unzip ripgrep coreutils findutils gnu-sed grep gawk gnu-tar make cmake ninja gettext pkgconf python node".split()
        packages = [entry["name"] for entry in json.loads(query([command, "info", "--json=v2", "--formula"] + packages))["formulae"]]
        install = [command, "install"]
        refresh = []
        prefix = []
    else:
        refresh, install, names = MANAGERS[manager]
        packages = names.split()
        prefix = [] if os.geteuid() == 0 else ["sudo"]
        if prefix and not shutil.which("sudo"):
            raise RuntimeError("Installing missing system dependencies needs sudo.")
    before = package_inventory(manager, command)
    if not info.get("before"):
        info["before"] = {name: version for name, version in before.items() if name not in info.get("owned", {})}
    missing = [name for name in packages if name not in before]
    planned = installation_candidates(manager, missing, command)
    info.update(status="installing", requested_packages=missing, planned_additions=[name for name in planned if name not in before])
    package_record(envroot, info, checkpoint)
    try:
        if missing:
            if refresh:
                run(prefix + refresh)
            install_env = dict(os.environ, HOMEBREW_NO_INSTALL_CLEANUP="1", HOMEBREW_NO_AUTOREMOVE="1")
            run(prefix + install + missing, env=install_env)
    finally:
        after = package_inventory(manager, command)
        # Claim only additions in the recorded transaction plan, never an
        # unrelated program observed in the after-inventory.
        info["owned"].update({name: after[name] for name in info["planned_additions"] if name in after and name not in info["before"]})
        info["observed_dependencies"] = {name: version for name, version in after.items()
                                         if name not in info["before"] and name not in info["owned"]}
        info["status"] = "installed" if all(name in after for name in missing) else "incomplete"
        package_record(envroot, info, checkpoint)
    return info


def version_tuple(text):
    match = re.search(r"(?:^|\s)v?(\d+)\.(\d+)(?:\.(\d+))?", text)
    return tuple(int(value or 0) for value in match.groups()) if match else ()


def preflight(source, root, config_only=False, no_packages=False):
    source, root = Path(source).resolve(), Path(root).expanduser().resolve()
    errors, checks = [], []
    if source == root or source in root.parents:
        errors.append("Installation root cannot be inside the source checkout.")
    for relative in ("config/nvim/init.lua", "config/nvim/lazy-lock.json", "config/tmux.conf", "tools.lock.json"):
        if not (source / relative).is_file():
            errors.append("Missing source file: " + relative)
    ancestor = root
    while not ancestor.exists():
        ancestor = ancestor.parent
    free = shutil.disk_usage(ancestor).free
    required = 10 * 1024 ** 2 if config_only else 2 * 1024 ** 3
    checks.append({"check": "disk_space", "available_bytes": free, "required_bytes": required})
    if free < required:
        errors.append("Insufficient disk space: need at least " + str(required // 1024 ** 2) + " MiB.")
    manager = manager_name()
    system = platform.system()
    arch = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "x86_64", "amd64": "x86_64"}.get(platform.machine().lower())
    checks.append({"check": "platform", "system": system, "architecture": arch, "manager": manager})
    if system not in ("Linux", "Darwin"):
        errors.append("This installer requires Linux or macOS; Windows uses install.ps1.")
    if not config_only:
        if not manager and not no_packages:
            errors.append("No supported package manager found.")
        key = ("macos" if system == "Darwin" else "linux") + "-" + str(arch)
        lock = json.loads((source / "tools.lock.json").read_text()) if (source / "tools.lock.json").is_file() else {}
        for tool, minimum in (("nvim", (0, 12, 0)), ("tree-sitter", (0, 26, 1)), ("tmux", None), ("uv", None)):
            record = lock.get(tool, {})
            bundled = key in record.get("assets", {})
            if tool == "nvim" and (Path("/etc/alpine-release").exists() or manager == "nix"):
                bundled = False
            if bundled:
                if minimum and version_tuple(record.get("version", "")) < minimum:
                    errors.append("Pinned " + tool + " version is below " + ".".join(map(str, minimum)))
                continue
            existing = shutil.which(tool)
            if not existing:
                if not (tool == "nvim" and manager in ("apk", "nix") and not no_packages):
                    errors.append("No compatible bundled " + tool + " for " + key + "; install a compatible system version first.")
            elif minimum:
                result = subprocess.run([existing, "--version"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if result.returncode or version_tuple(result.stdout) < minimum:
                    errors.append("System " + tool + " must be at least " + ".".join(map(str, minimum)))
        if no_packages:
            for tool in ("git", "curl", "unzip", "cc", "make", "node", "npm"):
                if not shutil.which(tool):
                    errors.append("Missing prerequisite: " + tool)
            if shutil.which("node"):
                result = subprocess.run(["node", "--version"], text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
                if result.returncode or version_tuple(result.stdout) < (18, 0, 0):
                    errors.append("Node.js 18 or later is needed for language servers.")
    return {"ok": not errors, "errors": errors, "checks": checks}


def package_files(manager, package, command=None):
    if manager == "apt-get":
        return query(["dpkg-query", "-L", package]).splitlines()
    if manager in ("dnf", "yum", "zypper"):
        return query(["rpm", "-ql", package]).splitlines()
    if manager == "pacman":
        return query(["pacman", "-Qlq", package]).splitlines()
    if manager == "xbps-install":
        return [line.strip() for line in query(["xbps-query", "-f", package]).splitlines()]
    if manager == "brew":
        return query([command or brew_command(), "list", "--verbose", package]).splitlines()
    raise RuntimeError("No safe package-file inventory adapter for " + manager)


def removal_risk(manager, package, files, info):
    """Fail closed when package code could remove data beyond its file list."""
    if manager == "apt-get":
        metadata = Path("/var/lib/dpkg/info")
        for suffix in ("prerm", "postrm"):
            script = metadata / (package + "." + suffix)
            if script.is_file() and script.stat().st_size:
                return "removal maintainer script has unbounded filesystem effects: " + str(script)
        triggers = Path("/var/lib/dpkg/triggers/File")
        if triggers.is_file():
            for line in triggers.read_text().splitlines():
                fields = line.split()
                if not fields or not fields[0].startswith("/"):
                    continue
                trigger_path = fields[0].rstrip("/")
                if any(name == trigger_path or name.startswith(trigger_path + "/") for name in files):
                    return "removal activates an external package trigger: " + line
        return None
    if manager in ("dnf", "yum", "zypper"):
        if query(["rpm", "-q", "--scripts", "--triggers", "--filetriggers", package]).strip():
            return "RPM scriptlets may change data outside the recorded package payload"
        if query(["rpm", "-qa", "--qf", "[%{TRIGGERNAME}\\n]"]).strip():
            return "RPM has external transaction triggers whose filesystem effects cannot be scoped"
        if query(["rpm", "-qa", "--filetriggers"]).strip():
            return "RPM has external file-trigger scriptlets whose filesystem effects cannot be scoped"
        return None
    if manager == "pacman":
        database = Path(query(["pacman-conf", "DBPath"]).strip()) / "local"
        version = info.get("owned", {}).get(package, "")
        script = database / (package + "-" + version) / "install"
        if script.is_file() and script.stat().st_size:
            return "pacman install script can run removal hooks outside the package payload: " + str(script)
        hooks = {}
        directories = [Path("/usr/share/libalpm/hooks")] + [Path(p) for p in query(["pacman-conf", "HookDir"]).splitlines()]
        for directory in directories:
            if directory.is_dir():
                hooks.update({path.name: path for path in directory.glob("*.hook")})
        for path in hooks.values():
            if path.resolve() == Path("/dev/null"):
                continue
            triggers, section = [], None
            for line in path.read_text().splitlines():
                line = line.strip()
                if not line or line.startswith("#"):
                    continue
                if line == "[Trigger]":
                    section = {}
                    triggers.append(section)
                elif line.startswith("["):
                    section = None
                elif section is not None and "=" in line:
                    key, value = (part.strip() for part in line.split("=", 1))
                    section.setdefault(key, []).append(value)
            for trigger in triggers:
                if "Remove" not in trigger.get("Operation", []):
                    continue
                values = [package] if trigger.get("Type") == ["Package"] else [name.lstrip("/") for name in files]
                positive = [pattern for pattern in trigger.get("Target", []) if not pattern.startswith("!")]
                if not positive or any(fnmatch.fnmatchcase(value, pattern) for value in values for pattern in positive):
                    return "pacman removal activates a hook outside the recorded payload: " + str(path)
        return None
    if manager == "brew":
        cellar = Path(info["prefix"]) / "Cellar" / package
        if not cellar.is_dir() or cellar.is_symlink():
            return "formula Cellar ownership cannot be verified"
        for recipe in cellar.glob("*/.brew/*.rb"):
            if re.search(r"\b(?:pre_uninstall|post_uninstall|uninstall|service)\b", recipe.read_text()):
                return "formula contains service or uninstall logic beyond its archived payload: " + str(recipe)
        return None
    return "removal script and hook effects have not been verified for " + manager


def payload_fingerprint(files, trees=()):
    """Describe removable files without following links or shared directories."""
    paths = set(str(path) for path in files)
    for tree in trees:
        tree = Path(tree)
        paths.add(str(tree))
        if tree.is_dir() and not tree.is_symlink():
            def failed(error):
                raise error
            for parent, directories, leaves in os.walk(tree, followlinks=False, onerror=failed):
                paths.update(str(Path(parent) / name) for name in directories + leaves)
    result = {}
    for name in sorted(paths):
        path = Path(name)
        if not path.is_absolute() or ".." in path.parts:
            raise RuntimeError("Unexpected package payload path: " + name)
        if not exists(path):
            result[name] = None
            continue
        before = path.lstat()
        entry = {"device": before.st_dev, "inode": before.st_ino, "mode": before.st_mode,
                 "uid": before.st_uid, "gid": before.st_gid}
        if stat.S_ISREG(before.st_mode):
            entry.update(size=before.st_size, mtime_ns=before.st_mtime_ns, ctime_ns=before.st_ctime_ns,
                         sha256=sha256_file(path))
            after = path.lstat()
            if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns):
                raise RuntimeError("Package payload changed while checking it: " + name)
        elif stat.S_ISLNK(before.st_mode):
            entry.update(target=os.readlink(path), mtime_ns=before.st_mtime_ns, ctime_ns=before.st_ctime_ns)
        elif not stat.S_ISDIR(before.st_mode):
            raise RuntimeError("Cannot preserve special package file: " + name)
        result[name] = entry
    return result


def validate_payload_archive(target):
    record = json.loads((Path(target) / "payload-snapshot.json").read_text())
    if payload_fingerprint(record["files"], record["trees"]) != record["fingerprint"]:
        raise RuntimeError("Package payload changed after archival; the current files were left installed.")


def archive_package_configs(manager, package, archive, info):
    """Archive the full removable payload, including modified non-config files."""
    files = package_files(manager, package, info.get("command"))
    running_python = Path(sys.executable).resolve()
    if any(Path(name).is_file() and Path(name).resolve() == running_python for name in files if name.startswith("/")):
        raise RuntimeError("package provides the running recovery interpreter")
    risk = removal_risk(manager, package, files, info)
    if risk:
        raise RuntimeError(risk)
    trees = []
    if manager == "brew":
        trees = [str(Path(info["prefix"]) / "Cellar" / package)] + [str(Path(info["prefix"]) / name) for name in ("etc", "var")]
    snapshot = payload_fingerprint(files, trees)
    target = Path(archive) / "package-payloads" / (package.replace("/", "_") + "-" + stamp())
    target.mkdir(parents=True, mode=0o700)
    payload = target / "payload.tar"
    with tarfile.open(payload, "x", dereference=False) as bundle:
        for name in sorted(set(files)):
            path = Path(name)
            if not path.is_absolute() or ".." in path.parts:
                raise RuntimeError("Unexpected package payload path: " + name)
            if not exists(path):
                continue
            before = path.lstat()
            if not (stat.S_ISREG(before.st_mode) or stat.S_ISDIR(before.st_mode) or stat.S_ISLNK(before.st_mode)):
                raise RuntimeError("Cannot preserve special package file: " + name)
            # Record each listed directory without walking a shared /usr or /etc.
            # Native managers leave unlisted files in nonempty directories alone.
            bundle.add(str(path), arcname="filesystem/" + str(path).lstrip("/"), recursive=False)
            after = path.lstat()
            if (before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns) != (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns):
                raise RuntimeError("Package payload changed while being archived: " + name)
    with payload.open("rb") as stream:
        os.fsync(stream.fileno())
    if manager == "brew":
        cellar = Path(info["prefix"]) / "Cellar" / package
        if cellar.resolve() in target.resolve().parents:
            raise RuntimeError("Archive destination is inside the formula being removed.")
        # Formula uninstallation removes a whole keg, including untracked files.
        shutil.copytree(cellar, target / "homebrew-cellar", symlinks=True)
        for directory in ("etc", "var"):
            settings = Path(info["prefix"]) / directory
            if settings.is_symlink():
                shutil.copy2(settings, target / ("homebrew-" + directory), follow_symlinks=False)
            elif settings.is_dir():
                shutil.copytree(settings, target / ("homebrew-" + directory), symlinks=True)
    if payload_fingerprint(files, trees) != snapshot:
        raise RuntimeError("Package payload changed during archival; package retained with its partial archive.")
    write_new(target / "payload-snapshot.json", json.dumps({"files": files, "trees": trees, "fingerprint": snapshot}, sort_keys=True) + "\n")
    write_new(target / "PRESERVATION.txt", "Full listed package payload: payload.tar. Shared directories were not traversed.\n"
              "Homebrew snapshots, when present, include the complete formula Cellar and prefix etc/var data.\n")
    return target


def cleanup_toolchains(envroot, info, archive, report):
    resources = info.get("resources", {})
    brew = resources.get("homebrew", {})
    if brew.get("owned") and brew.get("status") in ("installed", "archiving"):
        prefix = Path(info.get("prefix") or brew.get("prefix") or "/opt/homebrew")
        try:
            recorded_target = Path(brew["archive_path"]) if brew.get("archive_path") else None
            if recorded_target and recorded_target.exists():
                if brew.get("source_identity") != directory_identity(recorded_target):
                    raise RuntimeError("Recorded archive exists but its ownership identity cannot be verified; both paths were preserved.")
                brew["status"] = "archived"
                if prefix.exists():
                    report["retained"]["homebrew-reappeared"] = "A new prefix appeared after the original was archived; it was left untouched."
            elif not prefix.exists():
                brew["status"] = "archived"
            elif prefix != Path("/opt/homebrew") or brew.get("before_prefix_present") is not False:
                report["retained"]["homebrew"] = "Its installation prefix existed before devkit or is shared with other software."
            elif prefix in Path(sys.executable).resolve().parents:
                report["retained"]["homebrew"] = "The running recovery interpreter still belongs to Homebrew."
            elif package_inventory("brew", info.get("command")) or query([info.get("command") or brew_command(), "list", "--cask"]).strip():
                report["retained"]["homebrew"] = "Homebrew still contains packages; preserving their package manager."
            else:
                target = Path(brew.get("archive_path") or (Path(archive) / "system" / ("homebrew-" + stamp())))
                target.parent.mkdir(parents=True, exist_ok=True)
                identity = directory_identity(prefix)
                if brew.get("source_identity") and brew["source_identity"] != identity:
                    raise RuntimeError("Homebrew prefix identity changed; the replacement is not owned by this installation.")
                if prefix.stat().st_dev != target.parent.stat().st_dev:
                    raise RuntimeError("Homebrew archival requires the same filesystem for an atomic move; prefix retained.")
                brew.update(status="archiving", archive_path=str(target), source_identity=identity)
                package_record(envroot, info)
                elevation = [] if os.access(prefix.parent, os.W_OK) else ["sudo"]
                run(elevation + ["/bin/mv", str(prefix), str(target)])
                brew["status"] = "archived"
                report["removed"].append("homebrew (files archived)")
        except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
            report["errors"].append("Homebrew cleanup: " + str(error))
    clt = resources.get("developer_tools", {})
    if clt.get("owned") and clt.get("status") in ("installed", "archiving"):
        path = Path("/Library/Developer/CommandLineTools")
        try:
            recorded_target = Path(clt["archive_path"]) if clt.get("archive_path") else None
            if recorded_target and recorded_target.exists():
                if clt.get("source_identity") != directory_identity(recorded_target):
                    raise RuntimeError("Recorded developer-tools archive identity cannot be verified; both paths were preserved.")
                clt["status"] = "archived"
                if path.exists():
                    report["retained"]["developer-tools-reappeared"] = "New developer tools appeared after the original was archived; they were left untouched."
            elif not path.exists():
                clt["status"] = "archived"
            elif brew_command() or Path("/Applications/Xcode.app").exists():
                report["retained"]["developer_tools"] = "Homebrew or Xcode remains installed and may require Apple's tools."
            else:
                target = Path(clt.get("archive_path") or (Path(archive) / "system" / ("apple-command-line-tools-" + stamp())))
                target.parent.mkdir(parents=True, exist_ok=True)
                identity = directory_identity(path)
                if clt.get("source_identity") and clt["source_identity"] != identity:
                    raise RuntimeError("Developer-tools identity changed; the replacement is not owned by this installation.")
                if path.stat().st_dev != target.parent.stat().st_dev:
                    raise RuntimeError("Developer-tools archival requires the same filesystem for an atomic move; tools retained.")
                clt.update(status="archiving", archive_path=str(target), source_identity=identity)
                package_record(envroot, info)
                run((["sudo"] if os.geteuid() else []) + ["/bin/mv", str(path), str(target)])
                clt["status"] = "archived"
                report["removed"].append("apple-command-line-tools (files archived)")
        except (OSError, RuntimeError, subprocess.CalledProcessError) as error:
            report["errors"].append("Apple developer-tools cleanup: " + str(error))


def directory_identity(path):
    status = Path(path).lstat()
    return {"device": status.st_dev, "inode": status.st_ino, "mode": stat.S_IFMT(status.st_mode)}


def finish_cleanup(envroot, info, archive, report):
    cleanup_toolchains(envroot, info, archive, report)
    info.update(cleanup_status="complete" if not report["errors"] else "retry", cleanup_report=report)
    package_record(envroot, info)
    write_new(Path(archive) / ("package-cleanup-" + stamp() + ".json"), json.dumps(report, indent=2) + "\n")
    return report


def cleanup_packages(envroot, package_info, archive):
    """Remove proven additions only. Never force dependencies or run autoremove."""
    envroot, archive = Path(envroot), Path(archive)
    records = journal_read(envroot / "packages.jsonl")
    info = records[-1] if records else dict(package_info or {})
    manager = info.get("manager")
    report = {"manager": manager, "removed": [], "retained": {}, "errors": []}
    if not manager:
        return report
    if manager == "nix":
        report["retained"]["nix-store"] = "Private profile is archived; shared store garbage collection would affect other environments."
        return report
    command = info.get("command") or (brew_command() if manager == "brew" else None)
    homebrew = info.get("resources", {}).get("homebrew", {})
    if manager == "brew" and homebrew.get("owned") and homebrew.get("status") in ("archived", "archiving"):
        prefix = Path(info.get("prefix") or homebrew.get("prefix") or "/opt/homebrew")
        if homebrew.get("archive_path") and Path(homebrew["archive_path"]).exists():
            if homebrew.get("source_identity") != directory_identity(homebrew["archive_path"]):
                report["errors"].append("Homebrew archive ownership identity is unknown; no replacement installation was modified.")
                return report
            homebrew["status"] = "archived"
            if prefix.exists():
                report["retained"]["homebrew-reappeared"] = "A new Homebrew prefix appeared after the original was archived; it was left untouched."
            return finish_cleanup(envroot, info, archive, report)
    if manager == "brew" and homebrew.get("owned"):
        prefix = Path(info.get("prefix") or homebrew.get("prefix") or "/opt/homebrew")
        if homebrew.get("status") == "replaced" or (prefix.exists() and homebrew.get("source_identity") != directory_identity(prefix)):
            reason = "Homebrew prefix identity changed or was not recorded; the current installation is not proven to be owned."
            homebrew["status"] = "replaced"
            report["retained"]["homebrew"] = reason
            report["retained"].update({name: reason for name in info.get("owned", {})})
            return finish_cleanup(envroot, info, archive, report)
    try:
        current = package_inventory(manager, command)
    except (OSError, RuntimeError, ValueError) as error:
        report["errors"].append(str(error))
        return report
    owned = dict(info.get("owned", {}))
    # Import bootstrap ownership without treating everything currently installed
    # since the baseline as ours. A completed record is necessary proof.
    for item in info.get("bootstrap", []):
        if (item.get("kind") == "package" and item.get("manager") == manager
                and item.get("status") == "installed" and item.get("installed_by_devkit")
                and item.get("before_present") is False):
            name = item.get("canonical_name", item["name"])
            if name in current:
                version = item.get("installed_version") or info.get("before", {}).get(name)
                if version:
                    owned.setdefault(name, version)
                else:
                    report["retained"][name] = "Bootstrap ownership lacks its installed version."
    for name in info.get("observed_dependencies", {}):
        if name in current:
            report["retained"][name] = "Transitive addition has no explicit installation ownership record."
    for name in info.get("planned_additions", []):
        if name in current and name not in owned:
            report["retained"][name] = "Installation was interrupted before completion was recorded; ownership is unconfirmed."
    remaining = []
    for name, version in owned.items():
        if name not in current:
            continue
        if current[name] != version:
            report["retained"][name] = "Version changed after installation; another operation may now own it."
        else:
            remaining.append(name)
    if manager in ("apk", "eopkg"):
        report["retained"].update({name: "This manager's removal transaction cannot yet be restricted to proven additions." for name in remaining})
        return finish_cleanup(envroot, info, archive, report)
    if not remaining:
        return finish_cleanup(envroot, info, archive, report)
    prefix = [] if manager == "brew" or os.geteuid() == 0 else ["sudo"]
    if prefix and not shutil.which("sudo"):
        report["errors"].append("sudo is required to remove the recorded system packages.")
        return report
    protected = set()
    preserved = {}
    for name in remaining:
        try:
            preserved[name] = archive_package_configs(manager, name, archive, info)
        except (OSError, RuntimeError) as error:
            protected.add(name)
            report["retained"][name] = "Payload preservation, hook safety, or interpreter protection: " + str(error)
    remaining = [name for name in remaining if name not in protected]
    remove_env = dict(os.environ, HOMEBREW_NO_INSTALL_CLEANUP="1", HOMEBREW_NO_AUTOREMOVE="1", LC_ALL="C")

    def removal(names, probe):
        if manager == "apt-get":
            return ["dpkg"] + (["--no-act"] if probe else []) + ["--remove"] + names
        if manager in ("dnf", "yum", "zypper"):
            return ["rpm"] + (["--test"] if probe else []) + ["-e"] + names
        if manager == "pacman":
            return ["pacman", "-R", "--noconfirm"] + (["--print", "--print-format", "%n"] if probe else []) + names
        if manager == "xbps-install":
            return ["xbps-remove", "-y"] + (["-n"] if probe else []) + names
        return [command, "uninstall", "--formula"] + names

    while remaining:
        # Try the group first to handle dependencies/cycles within our own set.
        # Then try individual leaves so one protected package need not retain all.
        candidates = [remaining[:]] + [[name] for name in remaining]
        changed = False
        for names in candidates:
            if manager == "brew":
                try:
                    dependents = set()
                    for name in names:
                        dependents.update(query([command, "uses", "--installed", "--recursive", name]).split())
                    if dependents - set(names):
                        continue
                except (OSError, RuntimeError) as error:
                    report["errors"].append(str(error))
                    break
            else:
                probe = subprocess.run(prefix + removal(names, True), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=remove_env)
                if probe.returncode:
                    continue
            info.update(cleanup_status="removing", cleanup_candidates=names, cleanup_report=report)
            package_record(envroot, info)
            # Recheck after potentially lengthy archiving and dependency probes.
            # Another package manager or editor may have changed the payload.
            latest = package_inventory(manager, command)
            unsafe = set()
            for name in names:
                if latest.get(name) != owned[name]:
                    unsafe.add(name)
                    report["retained"][name] = "Package version changed during cleanup; no removal was attempted."
                    continue
                try:
                    validate_payload_archive(preserved[name])
                except (OSError, RuntimeError, ValueError) as error:
                    unsafe.add(name)
                    report["retained"][name] = "Package changed during cleanup: " + str(error)
            if unsafe:
                remaining = [name for name in remaining if name not in unsafe]
                changed = True
                break
            result = subprocess.run(prefix + removal(names, False), stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=remove_env)
            refreshed = package_inventory(manager, command)
            gone = [name for name in names if name not in refreshed]
            report["removed"].extend(gone)
            remaining = [name for name in remaining if name not in gone]
            if result.returncode:
                report["errors"].append("Removal did not complete: " + result.stderr.strip())
            info.update(cleanup_status="partial", cleanup_report=report)
            package_record(envroot, info)
            changed = bool(gone)
            break
        if not changed:
            for name in remaining:
                report["retained"][name] = "Dependency checks prevented removal; another installed package may require it."
            break
    return finish_cleanup(envroot, info, archive, report)

def environment(envroot, package_info=None):
    values = os.environ.copy()
    prefix = (package_info or {}).get("prefix")
    paths = [str(envroot / "bin"), str(envroot / "uv-bin"), str(envroot / "python-bin")]
    if prefix:
        paths += [str(Path(prefix) / "bin"), str(Path(prefix) / "sbin")]
        for formula in ("coreutils", "findutils", "gnu-sed", "grep", "gawk", "gnu-tar", "make"):
            paths.append(str(Path(prefix) / "opt" / formula / "libexec/gnubin"))
    values.update({
        "PATH": os.pathsep.join(paths + [values.get("PATH", "/usr/bin:/bin")]),
        "DEVKIT_ENV": str(envroot),
        "UV_TOOL_DIR": str(envroot / "uv-tools"),
        "UV_TOOL_BIN_DIR": str(envroot / "uv-bin"),
        "UV_PYTHON_INSTALL_DIR": str(envroot / "python"),
        "UV_PYTHON_BIN_DIR": str(envroot / "python-bin"),
        "UV_CACHE_DIR": str(envroot / "cache/uv"),
        "NPM_CONFIG_CACHE": str(envroot / "cache/npm"),
        "npm_config_cache": str(envroot / "cache/npm"),
        "NPM_CONFIG_USERCONFIG": str(envroot / "npmrc"),
        "npm_config_userconfig": str(envroot / "npmrc"),
    })
    return values


def nvim_environment(envroot, package_info=None):
    values = environment(envroot, package_info)
    for kind in ("CONFIG", "DATA", "STATE", "CACHE"):
        values["XDG_" + kind + "_HOME"] = str(envroot / "xdg" / kind.lower())
    values["NVIM_APPNAME"] = "nvim"
    values.pop("VIMINIT", None)
    values.pop("EXINIT", None)
    values.pop("VIMRUNTIME", None)
    return values


def install_tools(envroot, source, package_info):
    lock = json.loads((source / "tools.lock.json").read_text())
    system = "macos" if platform.system() == "Darwin" else "linux"
    machine = {"aarch64": "arm64", "arm64": "arm64", "x86_64": "x86_64", "amd64": "x86_64"}.get(platform.machine().lower())
    key = system + "-" + str(machine)
    commands = {}
    values = environment(envroot, package_info)
    for tool in ("nvim", "tmux", "uv", "tree-sitter"):
        asset = lock[tool]["assets"].get(key)
        if tool == "nvim" and (Path("/etc/alpine-release").exists() or package_info.get("manager") == "nix"):
            asset = None
        if asset is None:
            installed = shutil.which(tool, path=values["PATH"])
            if not installed:
                raise RuntimeError("No bundled " + tool + " for " + key + "; install it using your package manager and rerun.")
            commands[tool] = installed
            continue
        archive = envroot / "downloads" / asset["name"]
        download(asset["url"], archive, asset["sha256"], cache=envroot.parent.parent / "download-cache")
        target = envroot / "tools" / tool
        extract(archive, target)
        executable = next((p for p in target.rglob(tool) if p.is_file() and not p.name.endswith(".vim")), None)
        if executable is None:
            raise RuntimeError("Missing executable in " + str(archive))
        executable.chmod(executable.stat().st_mode | 0o755)
        try:
            run([executable, "-V" if tool == "tmux" else "--version"], stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        except (OSError, subprocess.CalledProcessError):
            installed = shutil.which(tool, path=values["PATH"])
            if not installed:
                raise RuntimeError(tool + " binary cannot run on this OS/libc. Install a compatible version with your package manager, then rerun with --no-system-packages.")
            executable = Path(installed)
        commands[tool] = str(executable)
        if tool in ("uv", "tree-sitter"):
            (envroot / "bin" / tool).symlink_to(executable)
        if tool == "uv":
            uvx = executable.with_name("uvx")
            if uvx.exists():
                (envroot / "bin/uvx").symlink_to(uvx)
    version = subprocess.check_output([commands["nvim"], "--version"], text=True).splitlines()[0]
    numbers = re.search(r"v(\d+)\.(\d+)", version)
    if not numbers or tuple(map(int, numbers.groups())) < (0, 12):
        raise RuntimeError("This NvChad configuration needs Neovim 0.12 or later; found " + version)
    ts_version = subprocess.check_output([commands["tree-sitter"], "--version"], text=True)
    if version_tuple(ts_version) < (0, 26, 1):
        raise RuntimeError("This treesitter configuration needs tree-sitter CLI 0.26.1 or later; found " + ts_version.strip())
    run([commands["uv"], "python", "install", "--no-bin", "3.12"], env=values)
    commands["python"] = subprocess.check_output([commands["uv"], "python", "find", "--managed-python", "3.12"], env=values, text=True).strip()
    if not Path(commands["python"]).is_file():
        raise RuntimeError("uv did not provide a private recovery interpreter.")
    run([commands["uv"], "tool", "install", "--python", "3.12", "pyrefly==" + lock["pyrefly"]], env=values)
    return commands
