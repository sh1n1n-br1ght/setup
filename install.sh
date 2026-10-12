#!/usr/bin/env bash
set -euo pipefail

devkit_privileged() {
    if [ "$(id -u)" = 0 ]; then "$@"; else sudo "$@"; fi
}

devkit_event() {
    local kind="$1" manager="$2" name="$3" status="$4" owned=false
    [ "$status" != installed ] || owned=true
    printf '\n{"kind":"%s","manager":"%s","name":"%s","before_present":false,"status":"%s","installed_by_devkit":%s}\n' \
        "$kind" "$manager" "$name" "$status" "$owned" >> "$DEVKIT_BOOTSTRAP_JOURNAL"
}

devkit_brew_event() {
    local status="$1" prefix="$2" before_prefix_present="$3" owned=false
    [ "$status" != installed ] || owned=true
    printf '\n{"kind":"package_manager","manager":"brew","name":"homebrew","before_present":false,"before_prefix_present":%s,"prefix":"%s","status":"%s","installed_by_devkit":%s}\n' \
        "$before_prefix_present" "$prefix" "$status" "$owned" >> "$DEVKIT_BOOTSTRAP_JOURNAL"
}

devkit_has_package() {
    case "$1" in
        apt-get) [ "$(dpkg-query -W '-f=${db:Status-Status}' "$2" 2>/dev/null || true)" = installed ] ;;
        dnf|yum|zypper) rpm -q "$2" >/dev/null 2>&1 ;;
        pacman) pacman -Q "$2" >/dev/null 2>&1 ;;
        apk) apk info -e "$2" >/dev/null 2>&1 ;;
        xbps-install) xbps-query -p pkgver "$2" >/dev/null 2>&1 ;;
        eopkg) LC_ALL=C eopkg info "$2" 2>/dev/null | grep -q '^Installed package:' ;;
        brew) brew list --versions "$2" >/dev/null 2>&1 ;;
        *) return 1 ;;
    esac
}

devkit_prepare_bootstrap_root() {
    local root="$1" marker="$1/.devkit-owner" entry value
    if [ -L "$root" ] || { [ -e "$root" ] && [ ! -d "$root" ]; }; then
        printf '%s\n' 'Installation root must be a directory, not a symlink or file.' >&2
        return 1
    fi
    if [ -e "$marker" ] || [ -L "$marker" ]; then
        if [ ! -f "$marker" ] || [ -L "$marker" ]; then printf '%s\n' 'Invalid installation ownership marker.' >&2; return 1; fi
        value="$(cat "$marker")"
        case "$value" in devkit-v1|devkit-v2) ;; *) printf '%s\n' 'Unknown installation owner marker.' >&2; return 1 ;; esac
    else
        for entry in "$root"/.[!.]* "$root"/..?* "$root"/*; do
            if [ -e "$entry" ] || [ -L "$entry" ]; then printf 'Directory already contains unrelated files: %s\n' "$root" >&2; return 1; fi
        done
        (umask 077; mkdir -p "$root"; set -C; printf 'devkit-v2\n' > "$marker")
    fi
    if [ -L "$root/bootstrap-journal.jsonl" ] || { [ -e "$root/bootstrap-journal.jsonl" ] && [ ! -f "$root/bootstrap-journal.jsonl" ]; }; then
        printf '%s\n' 'Invalid bootstrap ownership journal.' >&2
        return 1
    fi
    export DEVKIT_BOOTSTRAP_JOURNAL="$root/bootstrap-journal.jsonl"
    (umask 077; : >> "$DEVKIT_BOOTSTRAP_JOURNAL")
}

devkit_private_controller() {
    local root="$1" physical source envroot name marker
    [ -d "$root" ] && [ ! -L "$root" ] || return 1
    [ -f "$root/.devkit-owner" ] && [ ! -L "$root/.devkit-owner" ] || return 1
    marker="$(cat "$root/.devkit-owner")"
    case "$marker" in devkit-v1|devkit-v2) ;; *) return 1 ;; esac
    [ -L "$root/manager" ] && [ -d "$root/manager" ] || return 1
    physical="$(cd -- "$root" && pwd -P)"
    source="$(cd -- "$root/manager" && pwd -P)"
    case "$source" in */source) ;; *) return 1 ;; esac
    envroot="${source%/source}"
    name="${envroot##*/}"
    [ "$envroot" = "$physical/environments/$name" ] || return 1
    [ -f "$envroot/journal.jsonl" ] && [ ! -L "$envroot/journal.jsonl" ] || return 1
    [ -f "$envroot/bin/devkit" ] && [ -x "$envroot/bin/devkit" ] && [ ! -L "$envroot/bin/devkit" ] || return 1
    printf '%s\n' "$envroot/bin/devkit"
}

devkit_python_bootstrap() {
    local work manager package missing="" candidate attempts=0 brew_prefix before_prefix_present=false
    devkit_prepare_bootstrap_root "$1"
    work="$(mktemp -d "${TMPDIR:-/tmp}/devkit-bootstrap.XXXXXX")"
    printf 'Bootstrap ownership: %s\nDownloads retained at: %s\n' "$DEVKIT_BOOTSTRAP_JOURNAL" "$work"
    case "$(uname -s)" in
        Darwin)
            if ! xcode-select -p >/dev/null 2>&1; then
                if [ -e /Library/Developer/CommandLineTools ] || [ -L /Library/Developer/CommandLineTools ]; then
                    printf '%s\n' 'Apple Command Line Tools already exist, but xcode-select cannot use them. Repair the existing developer-tools selection before retrying; the installer will not claim or replace those files.' >&2
                    return 1
                fi
                devkit_event developer_tools apple command-line-tools installing
                xcode-select --install || true
                printf '%s\n' 'Complete the Apple Command Line Tools installation dialog to continue.'
                until xcode-select -p >/dev/null 2>&1; do
                    attempts=$((attempts + 1))
                    if [ "$attempts" -ge 720 ]; then printf '%s\n' 'Command Line Tools are not ready. Finish the installation and rerun.' >&2; return 1; fi
                    sleep 5
                done
                devkit_event developer_tools apple command-line-tools installed
            fi
            if ! command -v brew >/dev/null 2>&1; then
                if [ -x /opt/homebrew/bin/brew ]; then
                    export PATH="/opt/homebrew/bin:$PATH"
                elif [ -x /usr/local/bin/brew ]; then
                    export PATH="/usr/local/bin:$PATH"
                else
                    case "$(uname -m)" in arm64|aarch64) brew_prefix=/opt/homebrew ;; *) brew_prefix=/usr/local ;; esac
                    if [ -e "$brew_prefix" ] || [ -L "$brew_prefix" ]; then before_prefix_present=true; fi
                    devkit_brew_event installing "$brew_prefix" "$before_prefix_present"
                    curl -fLSs --retry 3 --connect-timeout 30 https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh -o "$work/homebrew-install.sh"
                    if [ -t 1 ]; then
                        /bin/bash "$work/homebrew-install.sh" < /dev/tty
                    else
                        /bin/bash "$work/homebrew-install.sh"
                    fi
                    export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"
                    command -v brew >/dev/null 2>&1 || { printf '%s\n' 'Homebrew installation did not finish. The attempt is preserved.' >&2; return 1; }
                    devkit_brew_event installed "$brew_prefix" "$before_prefix_present"
                fi
            fi
            if devkit_has_package brew python; then
                printf '%s\n' 'Homebrew already has Python, but python3 is unavailable or too old. Fix its PATH/version, then rerun; the existing package was not changed.' >&2
                return 1
            fi
            devkit_event package brew python installing
            brew install python
            devkit_event package brew python installed
            ;;
        Linux)
            manager=""
            for candidate in apt-get dnf yum pacman zypper apk xbps-install eopkg; do
                if command -v "$candidate" >/dev/null 2>&1; then manager="$candidate"; break; fi
            done
            if [ -z "$manager" ]; then
                printf '%s\n' 'Install Python 3.8+ using your package manager, then rerun. No supported bootstrap package manager was found.' >&2
                return 1
            fi
            if [ "$(id -u)" != 0 ] && ! command -v sudo >/dev/null 2>&1; then
                printf '%s\n' 'Installing Python requires sudo or an administrator-provided Python 3.8+.' >&2
                return 1
            fi
            case "$manager" in
                pacman) set -- python ca-certificates ;;
                eopkg) set -- python3 ca-certs ;;
                *) set -- python3 ca-certificates ;;
            esac
            for package in "$@"; do
                if ! devkit_has_package "$manager" "$package"; then
                    missing="$missing $package"
                    devkit_event package "$manager" "$package" installing
                fi
            done
            if [ -z "$missing" ]; then
                printf '%s\n' 'Python is already installed but unavailable or older than 3.8. Fix its PATH/version, then rerun; existing packages were not changed.' >&2
                return 1
            fi
            # These words are fixed package names selected above, never user input.
            case "$manager" in
                apt-get) devkit_privileged apt-get update; devkit_privileged apt-get install -y $missing ;;
                dnf|yum) devkit_privileged "$manager" install -y $missing ;;
                pacman) devkit_privileged pacman -S --needed --noconfirm $missing ;;
                zypper) devkit_privileged zypper --non-interactive install $missing ;;
                apk) devkit_privileged apk add $missing ;;
                xbps-install) devkit_privileged xbps-install -Sy $missing ;;
                eopkg) devkit_privileged eopkg install -y $missing ;;
            esac
            for package in $missing; do
                if devkit_has_package "$manager" "$package"; then devkit_event package "$manager" "$package" installed; fi
            done
            ;;
        *) printf '%s\n' 'Use install.ps1 on Windows. This entry point supports Linux and macOS.' >&2; return 1 ;;
    esac
}

devkit_bootstrap() {
    local repo="${DEVKIT_REPOSITORY:-https://github.com/sh1n1n-br1ght/setup.git}" ref="${DEVKIT_REF:-main}"
    local root="${DEVKIT_ROOT:-$HOME/.local/share/devkit}" root_explicit=0 action=install action_set=0
    local config_only=0 no_packages=0 local_source="" work="" bootstrap selected bootstrapped=0 controller="" pointer
    [ -z "${DEVKIT_ROOT:-}" ] || root_explicit=1
    while [ "$#" -gt 0 ]; do
        case "$1" in
            --repo|--ref|--root)
                if [ "$#" -lt 2 ] || [ -z "$2" ] || [[ "$2" == --* ]]; then printf 'Missing value for %s\n' "$1" >&2; return 2; fi
                case "$1" in
                    --repo) repo="$2" ;;
                    --ref) ref="$2" ;;
                    --root) root="$2"; root_explicit=1 ;;
                esac
                shift 2 ;;
            --config-only) config_only=1; shift ;;
            --no-system-packages) no_packages=1; shift ;;
            install|uninstall|status|plan|doctor|archives|recover|--uninstall|--status|--plan|--doctor|--archives|--recover)
                selected="${1#--}"
                if [ "$action_set" = 1 ] && [ "$action" != "$selected" ]; then printf '%s\n' 'Choose one action per invocation.' >&2; return 2; fi
                action="$selected"; action_set=1; shift ;;
            --help|-h)
                printf '%s\n' 'Usage: bash install.sh [install|uninstall|status|plan|doctor|archives|recover]' \
                    '                       [--repo HTTPS_URL] [--ref BRANCH] [--root /PATH]' \
                    '                       [--config-only | --no-system-packages]' \
                    'Actions also accept -- prefixes. Default repository: sh1n1n-br1ght/setup, branch main.'
                return ;;
            *) printf 'Unknown option: %s\n' "$1" >&2; return 2 ;;
        esac
    done
    if [ "$config_only" = 1 ] && [ "$no_packages" = 1 ]; then printf '%s\n' 'Choose either --config-only or --no-system-packages.' >&2; return 2; fi
    if [ "$action" != install ] && { [ "$config_only" = 1 ] || [ "$no_packages" = 1 ]; }; then printf '%s\n' 'Provisioning options apply only to install.' >&2; return 2; fi
    case "$root" in /*) ;; *) printf '%s\n' '--root must be an absolute path.' >&2; return 2 ;; esac
    case "$root" in *$'\n'*) printf '%s\n' 'Installation roots cannot contain newlines.' >&2; return 2 ;; esac
    if ! [[ "$repo" =~ ^https://(github\.com|gitlab\.com)/[A-Za-z0-9_.-]+(/[A-Za-z0-9_.-]+)+/?$ ]]; then
        printf '%s\n' '--repo must be a public github.com or gitlab.com HTTPS repository URL without credentials or query parameters.' >&2
        return 2
    fi
    case "$repo/" in */../*|*/./*) printf '%s\n' 'Repository paths cannot contain . or .. segments.' >&2; return 2 ;; esac

    if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
        local_source="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
        [ -f "$local_source/lib/devkit.py" ] || local_source=""
    fi
    pointer="$HOME/.local/state/devkit/root-path"
    if [ "$root_explicit" = 0 ] && [ -f "$pointer" ] && [ ! -L "$pointer" ] \
        && [ ! -L "$HOME/.local/state/devkit" ] \
        && [ -f "$HOME/.local/state/devkit/.devkit-owner" ] \
        && [ ! -L "$HOME/.local/state/devkit/.devkit-owner" ] \
        && [ "$(cat "$HOME/.local/state/devkit/.devkit-owner")" = devkit-control-v2 ]; then
        selected="$(cat "$pointer")"
        case "$selected" in
            *$'\n'*|'') printf '%s\n' 'Invalid remembered installation root. Supply --root /absolute/path.' >&2; return 1 ;;
            /*) root="$selected" ;;
            *) printf '%s\n' 'Invalid remembered installation root. Supply --root /absolute/path.' >&2; return 1 ;;
        esac
    fi
    if [ -f "$root/bootstrap-journal.jsonl" ] && [ ! -L "$root/bootstrap-journal.jsonl" ]; then
        export DEVKIT_BOOTSTRAP_JOURNAL="$root/bootstrap-journal.jsonl"
    fi
    if [ "$action" != install ] && controller="$(devkit_private_controller "$root")"; then
        if [ "$root_explicit" = 1 ]; then "$controller" --root "$root" "$action"; else "$controller" "$action"; fi
        return
    fi
    if ! command -v python3 >/dev/null 2>&1 || ! python3 -c 'import sys; sys.exit(sys.version_info < (3, 8))' >/dev/null 2>&1; then
        if [ "$config_only" = 1 ] || [ "$no_packages" = 1 ] || [ "$action" != install ]; then
            printf '%s\n' 'Python 3.8+ is required for this action. Preflight made no changes.' >&2
            return 1
        fi
        devkit_python_bootstrap "$root"
        bootstrapped=1
    fi
    python3 -c 'import sys; sys.exit(0 if sys.version_info >= (3, 8) else "Python 3.8+ is required")'
    if [ "$bootstrapped" = 1 ]; then
        python3 - "$DEVKIT_BOOTSTRAP_JOURNAL" <<'PY'
import json, pathlib, subprocess, sys
journal = pathlib.Path(sys.argv[1])
records = {}
for line in journal.read_text().splitlines():
    try: item = json.loads(line)
    except ValueError: continue
    if not isinstance(item, dict): continue
    if item.get('kind') == 'adopted': records = {}; continue
    records[(item.get('kind'), item.get('manager'), item.get('name'))] = item
def output(args):
    return subprocess.check_output(args, text=True).strip()
for item in records.values():
    if item.get('status') != 'installed': continue
    enriched = dict(item)
    try:
        manager, name = item['manager'], item['name']
        if item['kind'] == 'package' and manager == 'brew':
            info = json.loads(output(['brew', 'info', '--json=v2', '--formula', name]))['formulae'][0]
            enriched['canonical_name'] = info['name']
            enriched['installed_version'] = ','.join(str(p['version']) for p in info['installed'])
        elif item['kind'] == 'package_manager' and manager == 'brew':
            enriched['prefix'] = output(['brew', '--prefix'])
            enriched['path'] = str(pathlib.Path(enriched['prefix']) / 'bin/brew')
        elif item['kind'] == 'package' and manager == 'apt-get':
            enriched['installed_version'] = output(['dpkg-query', '-W', '-f=${Version}', name])
        elif item['kind'] == 'package' and manager in ('dnf', 'yum', 'zypper'):
            enriched['installed_version'] = output(['rpm', '-q', '--qf', '%{VERSION}-%{RELEASE}.%{ARCH}', name])
        elif item['kind'] == 'package' and manager == 'pacman':
            enriched['installed_version'] = output(['pacman', '-Q', name]).split()[1]
        elif item['kind'] == 'package' and manager == 'xbps-install':
            enriched['installed_version'] = output(['xbps-query', '-p', 'pkgver', name])[len(name) + 1:]
        elif item['kind'] == 'package' and manager == 'apk':
            for entry in pathlib.Path('/lib/apk/db/installed').read_text().split('\n\n'):
                fields = dict(line.split(':', 1) for line in entry.splitlines() if ':' in line)
                if fields.get('P') == name: enriched['installed_version'] = fields['V']; break
        with journal.open('a') as stream: stream.write('\n' + json.dumps(enriched) + '\n')
    except (OSError, subprocess.CalledProcessError, KeyError, IndexError, ValueError):
        print('Bootstrap metadata could not be completed; cleanup will retain ambiguous prerequisites.', file=sys.stderr)
PY
    fi

    if [ "$root_explicit" = 0 ]; then
        root="$(python3 - "$root" <<'PY'
import json, pathlib, sys
selected = sys.argv[1]
journal = pathlib.Path.home() / '.local/state/devkit/ownership.jsonl'
if journal.is_file():
    for line in journal.read_text().splitlines():
        try:
            item = json.loads(line)
            root = item.get('root')
            if isinstance(root, str) and pathlib.Path(root).is_absolute(): selected = root
        except (ValueError, TypeError):
            continue
print(selected)
PY
)"
    fi
    if [ -f "$root/bootstrap-journal.jsonl" ] && [ ! -L "$root/bootstrap-journal.jsonl" ]; then
        export DEVKIT_BOOTSTRAP_JOURNAL="$root/bootstrap-journal.jsonl"
    fi
    if [ "$action" != install ] && [ -f "$root/manager/lib/devkit.py" ]; then
        local_source="$root/manager"
    fi
    if [ -z "$local_source" ] && { [ "$action" = plan ] || [ "$action" = doctor ] || [ "$action" = status ] || [ "$action" = archives ]; }; then
        printf 'Platform: %s\nPython: %s\nEnvironment root: %s\n' "$(uname -s)" "$(command -v python3)" "$root"
        printf '%s\n' 'No installed management backend found. No files or packages were changed.'
        [ "$action" != doctor ] || return 1
        return
    fi
    if [ -z "$local_source" ]; then
        work="$(mktemp -d "${TMPDIR:-/tmp}/devkit-source.XXXXXX")"
        python3 - "$repo" "$ref" "$work" <<'PY'
import hashlib, json, pathlib, shutil, sys, tarfile, time, urllib.parse, urllib.request
repo, ref, work = sys.argv[1:]
parsed = urllib.parse.urlparse(repo)
if parsed.scheme != 'https' or parsed.username or parsed.password or parsed.query or parsed.fragment or parsed.port:
    raise SystemExit('Use a public HTTPS repository URL without credentials, query, fragment or port.')
path = parsed.path.rstrip('/')
if path.endswith('.git'): path = path[:-4]
parts = path.strip('/').split('/')
if len(parts) < 2 or any(p in ('', '.', '..') for p in parts): raise SystemExit('Invalid repository path.')
if parsed.hostname == 'github.com' and len(parts) == 2:
    url = 'https://github.com' + path + '/archive/' + urllib.parse.quote(ref, safe='') + '.tar.gz'
elif parsed.hostname == 'gitlab.com':
    url = 'https://gitlab.com' + path + '/-/archive/' + urllib.parse.quote(ref, safe='') + '/' + parts[-1] + '.tar.gz'
else:
    raise SystemExit('Remote bootstrap supports github.com and gitlab.com. Run a local checkout for other hosts.')
root = pathlib.Path(work)
for attempt in range(1, 4):
    archive = root / ('source-attempt-' + str(attempt) + '.tar.gz')
    try:
        request = urllib.request.Request(url, headers={'User-Agent': 'devkit-installer/2'})
        with urllib.request.urlopen(request, timeout=120) as response, archive.open('xb') as target:
            shutil.copyfileobj(response, target)
        break
    except OSError:
        if attempt == 3: raise
        print('Source download failed; preserving partial download and retrying.', file=sys.stderr)
        time.sleep(attempt)
stage = root / 'staging'
stage.mkdir()
with tarfile.open(archive) as bundle:
    for member in bundle:
        parts = pathlib.PurePosixPath(member.name).parts
        target = stage.joinpath(*parts)
        if not parts or member.name.startswith('/') or '..' in parts or not (member.isdir() or member.isfile()):
            raise SystemExit('Unsupported or unsafe source archive member: ' + member.name)
        if member.isdir():
            target.mkdir(parents=True, exist_ok=True)
        else:
            target.parent.mkdir(parents=True, exist_ok=True)
            with bundle.extractfile(member) as source, target.open('xb') as output:
                shutil.copyfileobj(source, output)
            target.chmod(member.mode & 0o777)
checkouts = [p for p in stage.iterdir() if p.is_dir() and (p / 'lib/devkit.py').is_file()]
if len(checkouts) != 1: raise SystemExit('Expected exactly one complete source checkout.')
checkout = checkouts[0]
for required in ('install.sh', 'tools.lock.json', 'config/nvim/init.lua', 'config/tmux.conf'):
    if not (checkout / required).is_file(): raise SystemExit('Incomplete source checkout: missing ' + required)
with (checkout / '.devkit-source-complete').open('x') as stream:
    json.dump({'repository': repo, 'ref': ref, 'sha256': hashlib.sha256(archive.read_bytes()).hexdigest()}, stream)
print('Downloaded source and failed attempts retained at ' + work)
PY
        for bootstrap in "$work"/staging/*/lib/devkit.py; do
            if [ -f "$bootstrap" ]; then local_source="${bootstrap%/lib/devkit.py}"; break; fi
        done
        [ -n "$local_source" ] || { printf '%s\n' 'The repository does not contain lib/devkit.py.' >&2; return 1; }
    fi
    set -- python3 "$local_source/lib/devkit.py"
    if [ "$root_explicit" = 1 ]; then set -- "$@" --root "$root"; fi
    set -- "$@" "$action"
    if [ "$config_only" = 1 ]; then set -- "$@" --config-only; fi
    if [ "$no_packages" = 1 ]; then set -- "$@" --no-system-packages; fi
    PYTHONDONTWRITEBYTECODE=1 "$@"
}

devkit_bootstrap "$@"
