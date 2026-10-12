# Devkit

Your NvChad, Pyrefly, tmux and command-line tools in a separate environment. Enter it when needed; exit to return to the computer owner's shell. The default installer provisions missing prerequisites, records what it installed, and preserves existing tools and settings.

The included NvChad configuration contains the Python import-completion fix and a plugin lockfile. Tmux uses vi copy mode and a private server.

## Install

The public repository is `https://github.com/sh1n1n-br1ght/setup`, branch `main`. Installation needs no GitHub login.

Linux/macOS:

```bash
curl -fsSL --retry 3 https://raw.githubusercontent.com/sh1n1n-br1ght/setup/main/install.sh | bash
```

Windows, from a normal PowerShell window:

```powershell
& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/sh1n1n-br1ght/setup/main/install.ps1')))
```

From a local checkout, use `bash install.sh` on Linux/macOS or `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\install.ps1` on Windows.

Linux uses a supported system package manager for missing prerequisites. macOS installs Apple's Command Line Tools and Homebrew when needed. Complete the Apple installation dialog if it appears. Windows provisions Scoop utilities and creates a dedicated Ubuntu WSL2 distribution and Linux user, leaving existing WSL distributions alone. Enabling WSL may request administrator approval and a restart; the installer never restarts the computer for you.

Run the install command again after an ordinary interruption. Partial downloads and installation attempts are retained for diagnosis. Restart continuation on Windows uses the saved installer.

## Enter and leave

Linux/macOS:

```bash
~/.local/bin/devkit shell
```

Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Devkit\devkit.ps1" -Action Shell
```

Inside, use `nvim`, `tmux`, `uv`, and `pyrefly` normally. Run `exit` to leave. A terminal with a Nerd Font displays NvChad's icons correctly; the installer does not change the owner's terminal fonts or settings.

The owner's Neovim config, plugin directories, tmux config and shell startup files stay in place. Neovim uses private XDG directories; tmux uses a separate socket and starts the private shell. Ordinary commands outside devkit continue to use the owner's configuration.

## Uninstall

Finish devkit tmux sessions and exit devkit shells first. From the original shell:

```bash
~/.local/bin/devkit uninstall
```

Windows:

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Devkit\devkit.ps1" -Action Uninstall
```

Uninstall deactivates the environment, restores any previous `devkit` launcher, and preserves your configs, projects, modifications, history and downloads in an archive. If someone replaced the launcher while devkit was installed, that replacement is preserved too.

Prerequisite cleanup is based on recorded ownership. A pre-existing package is never claimed as devkit's. Before removing an owned package, cleanup archives its complete listed file and symlink contents, including modified files; shared system directories are not copied recursively. Homebrew archives also include the complete formula Cellar, untracked files, and its `etc`/`var` data. Changed versions, detected changes during archival, dependencies required elsewhere, ambiguous ownership, unsupported cleanup, and removal scripts or hooks with effects outside the archive cause retention with an explanation. Package versions and archived contents are checked again before removal.

Cleanup never performs blanket autoremove or resets a whole PATH value to an old snapshot. Package managers can remove files belonging to packages they uninstall; personal files and archived contents are preserved. Finish other package-manager operations and file edits before uninstalling: the installer cannot lock out independently running programs across the whole machine. A subsequent fresh installation treats retained shared prerequisites as existing tools.

Linux/macOS archives are indexed under `~/.local/share/devkit/archives/`. Environment contents stay at their original paths under `environments/`, with an archive link and metadata, so executable paths and Python shebangs are not broken by moving them. A custom `--root` moves both locations together. Windows archives are under `%LOCALAPPDATA%\Devkit-archives\`. Before removing its dedicated WSL distribution, the installer exports the entire distribution and verifies the archive checksum. Owned Scoop packages are also archived before removal. Existing WSL distributions and packages are preserved; shared WSL infrastructure is retained when another user or application may depend on it. The Windows launcher, source, journals and downloads remain under `%LOCALAPPDATA%\Devkit\` for recovery.

To recover the filesystem from a Windows Linux archive, choose an unused distro name and a new empty installation path:

```powershell
wsl --import Restored-Devkit C:\path\to\new-distro C:\path\to\wsl-archive.tar --version 2
```

The export is taken after Linux devkit deactivation, so importing it recovers the files and archives rather than activating the old environment. Reinstall devkit to create an active environment, or access the retained files directly.

This restores the managed configuration and launcher; it is not a full-machine snapshot. Package managers and OS installers may also change shared caches, package databases or system components. The cleanup report describes anything retained.

## Inspect and recover

```bash
~/.local/bin/devkit status
~/.local/bin/devkit doctor
~/.local/bin/devkit archives
~/.local/bin/devkit recover
```

`status` reports installation state, `doctor` checks the environment, `archives` lists retained environments, and `recover` reconciles interrupted operations from their journals. Recovery preserves conflicting files instead of overwriting them.

If the launcher is missing or has already been restored, use the checkout:

```bash
bash install.sh --status
bash install.sh --doctor
bash install.sh --archives
bash install.sh --recover
bash install.sh --uninstall
```

The installer remembers the managed root independently of the launcher. Supply `--root /absolute/path` to select a different installation explicitly. A known installation's retained management backend can service these commands without downloading new source.

On Windows, the saved script or a checkout accepts `-Action Status`, `-Action Doctor`, `-Action Archives`, `-Action Recover`, and `-Action Uninstall`. Use the checkout if the saved launcher is unavailable. `Recover` can retry cleanup that was interrupted or retained earlier.

## Advanced options

```bash
bash install.sh --plan
bash install.sh --root /absolute/path
bash install.sh --no-system-packages
bash install.sh --config-only
```

`--plan` reports the platform, package manager and paths without installing anything. `--doctor` also makes no installation changes. They use the retained private interpreter when available, so management still works after an owned system Python has been removed. Without an installed backend, Python 3.8+ is required; a piped bootstrap then reports only basic preflight information instead of downloading files.

`--no-system-packages` provisions private tools and editor plugins using existing system prerequisites. `--config-only` copies configs and creates launchers using existing tools, without provisioning plugins; starting Neovim may subsequently download plugins. These are advanced provisioning controls, not separate installation modes. They cannot be combined.

Use `--repo HTTPS_URL --ref BRANCH_OR_TAG` for another public GitHub or GitLab repository; Windows uses `-Repository` and `-Ref`. Other hosting providers work from a local checkout. For a fixed release, use the same tag or commit in both the raw installer URL and the ref argument.

## Compatibility

The shell entry point needs Bash. Python 3.8+ is bootstrapped when missing during normal installation. Full Linux provisioning supports apt, dnf, yum, pacman, zypper, apk, xbps and eopkg, plus an existing Nix installation. Package availability still depends on the OS release and enabled repositories; an unknown distribution can use existing prerequisites with `--no-system-packages`. Arch users should update the OS normally before installing if package databases are stale.

Pinned official tool downloads cover x86-64 and ARM64 Linux/macOS. Incompatible binaries require compatible system versions; Alpine and Nix use their own Neovim. Old libc versions, uncommon architectures and unsupported OS releases may need manual prerequisites. macOS must meet [Homebrew's current requirements](https://docs.brew.sh/Installation). Windows needs WSL2-compatible Windows, virtualization, and permission to install WSL. Enterprise policies may restrict these operations.

`tools.lock.json` pins Neovim, tmux, uv, tree-sitter CLI and Pyrefly, including checksums for downloaded archives. `config/nvim/lazy-lock.json` pins editor plugins. Mason's additional HTML/CSS language servers and StyLua follow its registry. Public source downloads and package-manager repositories must be reachable.

The small `cmp-async-path` plugin is bundled under `config/nvim/vendor/cmp-async-path/` so installation does not depend on Codeberg being available. It is an exact copy of upstream commit `98185a91d49ff5dd249aebf2f7456e18063fa2a0`; `UPSTREAM.json` records the upstream URL and file checksums, and its original `LICENSE` is included.

## Maintain and validate

Edit `config/nvim/` and `config/tmux.conf` in this checkout, then publish the changes. An install copies them into its private environment. Changes made in an installed environment are preserved when archived, but are not automatically pushed to the repository.

```bash
bash -n install.sh
python3 -m unittest discover -s tests -v
```

On Windows, run `powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\tests\test_windows.ps1` for mocked lifecycle checks. GitHub Actions runs the Python lifecycle suite on Linux/macOS and PowerShell syntax/behavior checks on Windows. Those checks do not install system software.

After full provisioning, the isolated editor's completion check is:

```bash
~/.local/bin/devkit nvim --headless -i NONE -c 'lua dofile(vim.env.DEVKIT_ENV .. "/source/tests/nvim_completion.lua")'
```

The manual GitHub Actions workflow also offers a full Linux provisioning smoke test on a disposable runner. It is separate from the default checks. Mocked tests and Linux runs do not establish that a native Windows or macOS installation has succeeded; test those platforms before treating a release as verified.

Upstream references: [Homebrew](https://docs.brew.sh/Installation), [WSL](https://learn.microsoft.com/en-us/windows/wsl/basic-commands), [Scoop](https://scoop.sh/), [NvChad](https://nvchad.com/docs/quickstart/install/), [tmux](https://github.com/tmux/tmux/wiki/Installing). Copied configurations and plugins retain their upstream licensing, including the NvChad starter license.
