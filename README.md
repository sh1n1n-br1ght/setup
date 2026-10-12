# Setup

My Neovim (NvChad) and tmux setup, installed on any machine with one command. Whatever Neovim and tmux config the machine already had is moved into a backup and comes back, unchanged, when the setup is uninstalled.

## Install

Linux, macOS, BSD, WSL or Termux:

```bash
curl -fsSL https://sh1n1n-br1ght.github.io/setup | sh
```

Without curl (for example Alpine): `wget -qO- https://sh1n1n-br1ght.github.io/setup | sh`

Windows, from PowerShell (no administrator rights needed):

```powershell
irm https://sh1n1n-br1ght.github.io/setup/w | iex
```

Open a new terminal and run `nvim`. Running the install command again updates the setup. From a checkout, use `sh install.sh` or `.\install.ps1`.

## Uninstall

```bash
devkit uninstall
```

or `curl -fsSL https://sh1n1n-br1ght.github.io/setup/u | sh`. On Windows: `irm https://sh1n1n-br1ght.github.io/setup/x | iex`.

Uninstall deletes everything the setup added (tools, plugins, its config and the PATH lines) and puts the previous config back exactly as it was. Edits made to this setup's config on that machine are deleted with it, so push anything worth keeping to this repo first. `devkit status` shows what is installed and what was backed up.

## What it changes

| | Linux, macOS, BSD | Windows |
| --- | --- | --- |
| Neovim config | `~/.config/nvim` | `%LOCALAPPDATA%\nvim` |
| Neovim plugins, history, cache | `~/.local/share/nvim`, `~/.local/state/nvim`, `~/.cache/nvim` | `%LOCALAPPDATA%\nvim-data` |
| tmux config | `~/.tmux.conf` (`~/.config/tmux/tmux.conf` is moved aside too) | none: tmux has no native Windows build |
| Tools and backups | `~/.local/share/devkit` | `%LOCALAPPDATA%\devkit` |
| PATH | a marked block in the shell startup files | entries in the user PATH |

`XDG_*` variables are respected. Existing files at these paths go to `devkit/backup`. Shell startup files get only the PATH block, and uninstall restores them byte for byte unless they were edited in the meantime, in which case only the block is removed.

The shell gets `nvim`, `tmux`, `uv`, `pyrefly`, `rg` and `devkit`. Helpers that only plugins need (tree-sitter, Node.js, a C compiler) are visible inside Neovim only, so the machine's own versions stay in charge everywhere else.

## Tools

`tools.lock` pins every download with a SHA-256 checksum: Neovim 0.12.6, tmux 3.7c, tree-sitter CLI 0.27.1, uv 0.13.0 with Pyrefly 1.3.2, ripgrep 15.2.0, plus Node.js 24 and Git for Windows only when the machine has none. `config/nvim/lazy-lock.json` pins the plugins. The small `cmp-async-path` plugin is vendored in `config/nvim/vendor/` (see its `UPSTREAM.json`) so installs do not depend on Codeberg.

## Unusual machines

- Linux older than glibc 2.34 (Ubuntu 20.04, RHEL 8, Amazon Linux 2): Neovim's own builds for old distributions.
- The tree-sitter CLI needs glibc 2.39. Older Linux gets it from conda-forge through a private micromamba, which needs neither root nor a package manager.
- Missing basics (git, curl, unzip, a C compiler) come from the system package manager (apt, dnf, yum, zypper, pacman, apk, xbps or pkg) when the account is root or has sudo; sudo asks for a password first. Otherwise they come from private conda-forge packages, with zig as the C compiler. `--no-system` never touches the package manager. Uninstall lists any system packages it installed but leaves them in place.
- Alpine (musl), BSD and Termux use their package manager for Neovim.
- macOS needs Apple's Command Line Tools for git and the compiler; if they are missing, macOS shows its install dialog. Homebrew is not used.
- Windows without a C compiler (Visual Studio Build Tools or MinGW-w64 gcc) skips syntax parsers, so highlighting uses Vim's regex syntax until `:TSInstall` runs with a compiler available.

Anything optional that cannot be installed is reported as a warning at the end, and the editor still works. Full details go to `devkit/state/install.log`.

Other options: `--ref BRANCH_OR_TAG`, `--repo OWNER/NAME`, `--config-only` (only swap configs and use the Neovim already installed) and `--no-system`. On Windows: `-Ref`, `-Repo`, `-ConfigOnly`, `-Action Status`.

## Upgrading from the previous version

The previous version kept an isolated environment in `~/.local/share/devkit` and never changed your own configs. The new installer refuses to run over it; remove it first:

```bash
rm -rf ~/.local/share/devkit ~/.local/state/devkit ~/.local/bin/devkit
```

On Windows, run the old uninstaller, then delete `%LOCALAPPDATA%\Devkit` and `%LOCALAPPDATA%\Devkit-archives`:

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Devkit\devkit.ps1" -Action Uninstall
```

## Maintain

Edit `config/nvim/` and `config/tmux.conf`, then push. Tests:

```bash
sh tests/test_install.sh
sh tests/test_e2e.sh
```

`test_install.sh` checks backup and restore round trips without network access. `test_e2e.sh` runs a full install, editor checks and uninstall in a throwaway home directory. On Windows, `tests\test_windows.ps1` does the same (`-Full` for the real install). GitHub Actions runs them on Ubuntu (x86_64 and arm64), several distribution containers, macOS (Apple silicon and Intel) and Windows (x64 and arm64, PowerShell 5.1 and 7), and publishes the short install URLs to GitHub Pages from `main`.

Copied configurations and plugins keep their upstream licenses, including the NvChad starter license.
