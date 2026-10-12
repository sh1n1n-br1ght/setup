#!/usr/bin/env python3
"""Build the short public installer endpoints from the canonical scripts."""

import argparse
from pathlib import Path
import re


def replace_once(content, old, new, label):
    if content.count(old) != 1:
        raise ValueError("Expected exactly one {} marker".format(label))
    return content.replace(old, new, 1)


def build(output, revision):
    if not re.fullmatch(r"[0-9a-fA-F]{40}", revision):
        raise ValueError("Revision must be a full 40-character Git commit SHA")

    source = Path(__file__).resolve().parent.parent
    shell = (source / "install.sh").read_bytes()
    windows = (source / "install.ps1").read_bytes()
    shell_entry = b'devkit_bootstrap "$@"\n'
    if not shell.endswith(shell_entry):
        raise ValueError("The shell entry point must remain the final statement")
    uninstall_shell = replace_once(
        shell, shell_entry, b'devkit_bootstrap --uninstall "$@"\n', "shell entry point"
    )
    uninstall_windows = replace_once(
        windows,
        b"[string]$Action = 'Install',",
        b"[string]$Action = 'Uninstall',",
        "PowerShell default action",
    )
    files = {
        "index.html": shell,
        "w": b"& {\n" + windows + b"\n}\n",
        "u": uninstall_shell,
        "x": b"& {\n" + uninstall_windows + b"\n}\n",
        ".nojekyll": b"",
        "revision.txt": (revision.lower() + "\n").encode("ascii"),
    }
    if output.is_symlink():
        raise ValueError("Output directory cannot be a symlink")
    if output.resolve() == source:
        raise ValueError("Use a separate build output directory")
    output.mkdir(parents=True, exist_ok=True)
    for name in files:
        target = output / name
        if target.is_symlink() or (target.exists() and not target.is_file()):
            raise ValueError("Refusing to replace non-regular output: {}".format(target))
    for name, content in files.items():
        (output / name).write_bytes(content)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("output", type=Path, help="Generated Pages artifact directory")
    parser.add_argument("--revision", required=True, help="Full source Git commit SHA")
    args = parser.parse_args()
    try:
        build(args.output, args.revision)
    except (OSError, ValueError) as error:
        parser.error(str(error))


if __name__ == "__main__":
    main()
