#!/bin/sh
# Installs sh1n1n-br1ght's Neovim (NvChad) and tmux setup on Linux, macOS and BSD.
#
#   curl -fsSL https://sh1n1n-br1ght.github.io/setup | sh      install or update
#   curl -fsSL https://sh1n1n-br1ght.github.io/setup/u | sh    uninstall
#   wget -qO- https://sh1n1n-br1ght.github.io/setup | sh       same, without curl
#
# Configs already on the machine (Neovim config/data/state/cache and tmux.conf) are
# moved into ~/.local/share/devkit/backup and put back by `devkit uninstall`.
# Tools are pinned downloads (tools.lock) kept under ~/.local/share/devkit. Missing
# basics (git, a C compiler, curl, unzip) come from the system package manager when
# root or sudo is available, otherwise from a private conda-forge environment.
# Plain POSIX sh, so dash, busybox ash, bash and zsh can all run it.
# shellcheck disable=SC2046 # $(pm_name ...) expands to several package names on purpose

# `curl ... | zsh` works too: sh emulation gives POSIX word splitting and traps.
if [ -n "${ZSH_VERSION:-}" ]; then emulate sh; fi
set -u

SCRIPT=$0
REPO=sh1n1n-br1ght/setup
REF=main
SOURCE_REQUESTED=0
ACTION=install
CONFIG_ONLY=0
NO_SYSTEM=0
WARNINGS=0
LOG=
TAB=$(printf '\t')
BEGIN_MARK='# >>> devkit (sh1n1n-br1ght/setup) >>>'
END_MARK='# <<< devkit <<<'
# Paths this setup replaces while installed; the owner's copies go to $BACKUP/<name>.
TARGETS='nvim-config nvim-data nvim-state nvim-cache tmux-conf'

say() { printf '%s\n' "$*"; }
step() { printf '\n==> %s\n' "$*"; }
warn() {
	WARNINGS=$((WARNINGS + 1))
	printf 'warning: %s\n' "$*" >&2
	if [ -n "$LOG" ]; then printf 'warning: %s\n' "$*" >>"$LOG"; fi
}
die() { printf 'error: %s\n' "$*" >&2; exit 1; }
have() { command -v "$1" >/dev/null 2>&1; }
exists() { [ -e "$1" ] || [ -L "$1" ]; }
runs() { "$@" >/dev/null 2>&1 </dev/null; }
quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/'/'\\\\''/g")"; }
fish_quote() { printf "'%s'" "$(printf '%s' "$1" | sed "s/[\\\\']/\\\\&/g")"; }
put() { rm -f "$2" && ln -s "$1" "$2"; }
write_script() { printf '#!/bin/sh\n%s\n' "$2" >"$1.new" && chmod 755 "$1.new" && mv "$1.new" "$1"; }
remove() {
	case $1 in
	/*/*) rm -rf "$1" ;;
	*) die "refusing to remove $1" ;;
	esac
}

usage() {
	cat <<'EOF'
Usage: sh install.sh [install|update|uninstall|status] [options]

  install     Install, or update an existing installation (default)
  uninstall   Remove this setup and put back the configs that were here before
  status      Show what is installed

Options:
  --ref REF          Branch, tag or commit to install (default: main)
  --repo OWNER/NAME  GitHub repository to install from (default: sh1n1n-br1ght/setup)
  --config-only      Only swap the configs and keep using this machine's Neovim and tmux
  --no-system        Never use sudo or the system package manager
EOF
}

absolute_or() {
	case ${1:-} in
	/*) printf '%s' "$1" ;;
	*) printf '%s' "$2" ;;
	esac
}

setup_paths() {
	case ${HOME:-} in
	/?*) ;;
	*) die "HOME must be an absolute path" ;;
	esac
	CONFIG_HOME=$(absolute_or "${XDG_CONFIG_HOME:-}" "$HOME/.config")
	DATA_HOME=$(absolute_or "${XDG_DATA_HOME:-}" "$HOME/.local/share")
	STATE_HOME=$(absolute_or "${XDG_STATE_HOME:-}" "$HOME/.local/state")
	CACHE_HOME=$(absolute_or "${XDG_CACHE_HOME:-}" "$HOME/.cache")
	ROOT=$(absolute_or "${DEVKIT_ROOT:-}" "$DATA_HOME/devkit")
	BIN=$ROOT/bin LIBEXEC=$ROOT/libexec TOOLS=$ROOT/tools BACKUP=$ROOT/backup STATE=$ROOT/state
	PATH=$LIBEXEC:$PATH
}

target_path() {
	# The location recorded at install time wins, in case XDG variables changed since.
	if [ -f "$STATE/$1.path" ]; then
		cat "$STATE/$1.path"
		return
	fi
	case $1 in
	nvim-config) printf '%s' "$CONFIG_HOME/nvim" ;;
	nvim-data) printf '%s' "$DATA_HOME/nvim" ;;
	nvim-state) printf '%s' "$STATE_HOME/nvim" ;;
	nvim-cache) printf '%s' "$CACHE_HOME/nvim" ;;
	tmux-conf) printf '%s' "$HOME/.tmux.conf" ;;
	tmux-xdg) printf '%s' "$CONFIG_HOME/tmux/tmux.conf" ;;
	esac
}

detect_platform() {
	OS=$(uname -s 2>/dev/null) ARCH=$(uname -m 2>/dev/null) LIBC='' GLIBC=''
	case $OS in
	Linux) OS=linux ;;
	Darwin) OS=macos ;;
	*BSD | DragonFly) OS=bsd ;;
	MINGW* | MSYS* | CYGWIN*) OS=windows ;;
	*) OS=unknown ;;
	esac
	case $ARCH in
	x86_64 | amd64) ARCH=x86_64 ;;
	aarch64 | arm64) ARCH=arm64 ;;
	armv7* | armv8l | armhf) ARCH=armv7 ;;
	i[3-6]86) ARCH=x86 ;;
	esac
	# A terminal running under Rosetta reports x86_64; native arm64 tools are much faster.
	if [ "$OS" = macos ] && [ "$(sysctl -n sysctl.proc_translated 2>/dev/null)" = 1 ]; then ARCH=arm64; fi
	if [ "$OS" = linux ]; then
		if [ "$(uname -o 2>/dev/null)" = Android ]; then
			LIBC=android
		elif GLIBC=$(getconf GNU_LIBC_VERSION 2>/dev/null) && [ -n "$GLIBC" ]; then
			LIBC=glibc GLIBC=${GLIBC#glibc }
		elif ls /lib/ld-musl-* >/dev/null 2>&1; then
			LIBC=musl GLIBC=
		else
			# Unknown libc: glibc builds are tried and test-run.
			LIBC=glibc GLIBC=
		fi
	fi
	PLATFORM=$OS-$ARCH
}

# Versions: the first x.y[.z] in the first line of a command's output.
version_of() { "$@" 2>/dev/null </dev/null | sed -n '1s/[^0-9]*\([0-9][0-9]*\.[0-9][0-9]*\(\.[0-9][0-9]*\)\{0,1\}\).*/\1/p'; }
version_ge() {
	[ -n "$1" ] && awk -v a="$1" -v b="$2" 'BEGIN {
		split(a, x, "."); split(b, y, ".")
		for (i = 1; i <= 3; i++) { if (x[i] + 0 > y[i] + 0) exit 0; if (x[i] + 0 < y[i] + 0) exit 1 }
		exit 0 }'
}

fetch() {
	if ! have curl && ! have wget; then pm_install $(pm_name curl) || return 1; fi
	if have curl; then
		curl -fsSL --retry 3 --connect-timeout 30 -o "$2" "$1"
	else
		wget -q -T 60 -O "$2" "$1"
	fi
}

sha256() {
	if have sha256sum; then
		set -- sha256sum "$1"
	elif have shasum; then
		set -- shasum -a 256 "$1"
	elif have sha256; then
		set -- sha256 -q "$1"
	elif have openssl; then
		set -- openssl dgst -sha256 -r "$1"
	else
		return 1
	fi
	"$@" | awk '{ print $1; exit }'
}

verify() {
	[ "$2" != - ] || return 0
	if ! actual=$(sha256 "$1") || [ -z "$actual" ]; then
		warn "no SHA-256 tool found, so ${1##*/} was not verified"
		return 0
	fi
	[ "$actual" = "$2" ] || { warn "checksum mismatch for ${1##*/}"; return 1; }
}

# lock_find NAME picks the pinned download for this machine and sets L_VERSION, L_SHA and
# L_URL. Builds that need a newer glibc than the machine has are skipped.
lock_find() {
	[ "$LIBC" != android ] || return 1
	for key in "$PLATFORM-$LIBC" "$PLATFORM"; do
		line=$(awk -F "$TAB" -v n="$1" -v p="$key" '$1 == n && $3 == p { print; exit }' "$LOCK")
		[ -n "$line" ] || continue
		IFS=$TAB read -r _ L_VERSION _ L_GLIBC L_SHA L_URL <<EOF
$line
EOF
		if [ "$L_GLIBC" != - ]; then
			[ "$LIBC" = glibc ] || continue
			[ -z "$GLIBC" ] || version_ge "$GLIBC" "$L_GLIBC" || continue
		fi
		return 0
	done
	return 1
}
lock_version() { awk -F "$TAB" -v n="$1" '$1 == n { print $2; exit }' "$LOCK"; }

# fetch_tool NAME downloads, verifies and unpacks the pinned build into $TOOLS (sets DIR).
fetch_tool() {
	lock_find "$1" || return 1
	DIR=$TOOLS/$1-$L_VERSION
	[ ! -f "$DIR/.complete" ] || return 0
	file=$WORK/${L_URL##*/}
	say "  downloading $1 $L_VERSION"
	fetch "$L_URL" "$file" || { warn "could not download $L_URL"; return 1; }
	verify "$file" "$L_SHA" || return 1
	remove "$DIR" && mkdir -p "$DIR" || return 1
	case $file in
	*.tar.gz) gzip -dc "$file" | tar -xf - -C "$DIR" ;;
	*.gz) gzip -dc "$file" >"$DIR/$1" && chmod 755 "$DIR/$1" ;;
	*) cp "$file" "$DIR/$1" && chmod 755 "$DIR/$1" ;;
	esac || { warn "could not unpack ${file##*/}"; return 1; }
	: >"$DIR/.complete"
}

exe_in() {
	found=$(find "$1" -path "*/bin/$2" -type f 2>/dev/null | head -n 1)
	[ -n "$found" ] || found=$(find "$1" -name "$2" -type f 2>/dev/null | head -n 1)
	printf '%s' "$found"
}

# Old tool versions left behind by updates.
prune_tools() {
	for old in "$TOOLS"/*-*; do
		[ -f "$old/.complete" ] || continue
		awk -F "$TAB" -v d="${old##*/}" '$1 "-" $2 == d { found = 1 } END { exit !found }' "$LOCK" || remove "$old"
	done
}

detect_pm() {
	PM='' SUDO='' PM_UPDATED=0
	[ "$NO_SYSTEM" = 0 ] || return 0
	if [ "$LIBC" = android ]; then PM=pkg; return 0; fi
	[ "$OS" != macos ] || return 0
	for candidate in apt-get dnf yum zypper pacman apk xbps-install pkg; do
		if have "$candidate"; then PM=$candidate; break; fi
	done
	if [ -z "$PM" ] || [ "$(id -u)" = 0 ]; then return 0; fi
	if have sudo; then SUDO=sudo; elif have doas; then SUDO=doas; else PM=; fi
}

pm_name() {
	case $1 in
	cc)
		case $PM in
		apt-get) echo 'gcc libc6-dev' ;;
		apk) echo 'gcc musl-dev' ;;
		pkg) if [ "$LIBC" = android ]; then echo clang; fi ;;
		*) echo gcc ;;
		esac
		;;
	node)
		case $PM in
		pkg) if [ "$LIBC" = android ]; then echo nodejs; else echo 'node npm'; fi ;;
		zypper) echo 'nodejs-default npm-default' ;;
		*) echo 'nodejs npm' ;;
		esac
		;;
	curl | git)
		# --no-install-recommends would leave HTTPS without certificates.
		if [ "$PM" = apt-get ]; then echo "$1 ca-certificates"; else echo "$1"; fi
		;;
	nvim) echo neovim ;;
	rg) echo ripgrep ;;
	tree-sitter) case $PM in pacman | apk) echo tree-sitter-cli ;; esac ;;
	*) echo "$1" ;;
	esac
}

# pm_install PACKAGE... installs system packages (recorded so uninstall can list them).
pm_install() {
	[ -n "$PM" ] && [ $# -gt 0 ] || return 1
	if [ -n "$SUDO" ]; then
		say "  installing $* with $SUDO $PM (it may ask for your password)"
	else
		say "  installing $* with $PM"
	fi
	if [ "$PM" = apt-get ] && [ "$PM_UPDATED" = 0 ]; then
		$SUDO apt-get update -qq </dev/null >>"$LOG" 2>&1
		PM_UPDATED=1
	fi
	case $PM in
	apt-get) $SUDO env DEBIAN_FRONTEND=noninteractive apt-get install -y -qq --no-install-recommends "$@" ;;
	dnf | yum) $SUDO "$PM" install -y "$@" ;;
	zypper) $SUDO zypper --non-interactive install "$@" ;;
	pacman) $SUDO pacman -Sy --needed --noconfirm "$@" ;;
	apk) $SUDO apk add --no-cache "$@" ;;
	xbps-install) $SUDO xbps-install -Sy "$@" ;;
	pkg) if [ "$LIBC" = android ]; then pkg install -y "$@"; else $SUDO env ASSUME_ALWAYS_YES=yes pkg install "$@"; fi ;;
	esac </dev/null >>"$LOG" 2>&1 || { warn "$PM could not install $*"; return 1; }
	printf '%s\n' "$@" >>"$STATE/system-packages"
}

# conda_install PACKAGE... installs private conda-forge packages into $TOOLS/conda.
# It needs neither root nor a package manager, only glibc 2.17+.
conda_install() {
	[ "$LIBC" = glibc ] || return 1
	if [ -z "${MAMBA:-}" ]; then
		fetch_tool micromamba || return 1
		MAMBA=$DIR/micromamba
	fi
	say "  installing $* from conda-forge into $TOOLS/conda"
	verb=create
	if [ -d "$TOOLS/conda/conda-meta" ]; then verb=install; fi
	MAMBA_ROOT_PREFIX=$TOOLS/mamba "$MAMBA" "$verb" --yes --quiet --no-rc --override-channels \
		--channel conda-forge --prefix "$TOOLS/conda" "$@" </dev/null >>"$LOG" 2>&1 ||
		{ warn "conda-forge could not install $*"; return 1; }
}

# need COMMAND [CONDA_PACKAGE] makes sure a basic command exists.
need() {
	have "$1" && return 0
	pm_install $(pm_name "$1") && have "$1" && return 0
	[ -n "${2:-}" ] && conda_install "$2" && [ -x "$TOOLS/conda/bin/$1" ] && put "$TOOLS/conda/bin/$1" "$LIBEXEC/$1"
}

need_cc() {
	for compiler in cc gcc clang; do
		if have "$compiler"; then
			[ "$compiler" = cc ] || put "$(command -v "$compiler")" "$LIBEXEC/cc"
			return 0
		fi
	done
	pm_install $(pm_name cc) && have cc && return 0
	conda_install zig && write_script "$LIBEXEC/cc" "exec $(quote "$TOOLS/conda/bin/zig") cc \"\$@\""
}

macos_command_line_tools() {
	! xcode-select -p >/dev/null 2>&1 || return 0
	say "  Apple's Command Line Tools provide git and a C compiler; finish the dialog macOS opens."
	xcode-select --install >/dev/null 2>&1
	waited=0
	until xcode-select -p >/dev/null 2>&1; do
		waited=$((waited + 5))
		[ "$waited" -le 3600 ] || return 1
		sleep 5
	done
}

# Even `nvim --version` creates its state directory, which must not happen before the
# owner's one is backed up.
nvim_ok() { [ -n "$1" ] && version_ge "$(version_of env XDG_STATE_HOME="$WORK/xdg" "$1" --version)" 0.12; }
install_nvim() {
	for name in nvim nvim-legacy; do
		if fetch_tool "$name"; then
			NVIM=$(exe_in "$DIR" nvim)
			nvim_ok "$NVIM" && return 0
			say "  the $name build does not run here; trying another one"
		fi
	done
	NVIM=$(command -v nvim 2>/dev/null)
	nvim_ok "$NVIM" && return 0
	pm_install $(pm_name nvim) && NVIM=$(command -v nvim 2>/dev/null) && nvim_ok "$NVIM" && return 0
	NVIM=
	return 1
}

ts_ok() { [ -n "$1" ] && version_ge "$(version_of "$1" --version)" 0.26.1; }
install_tree_sitter() {
	if fetch_tool tree-sitter && ts_ok "$DIR/tree-sitter"; then
		TS=$DIR/tree-sitter
	elif ts_ok "$(command -v tree-sitter 2>/dev/null)"; then
		TS=$(command -v tree-sitter)
	elif conda_install "tree-sitter-cli=$(lock_version tree-sitter)" && ts_ok "$TOOLS/conda/bin/tree-sitter"; then
		TS=$TOOLS/conda/bin/tree-sitter
	elif pm_install $(pm_name tree-sitter) && ts_ok "$(command -v tree-sitter 2>/dev/null)"; then
		TS=$(command -v tree-sitter)
	else
		return 1
	fi
	put "$TS" "$LIBEXEC/tree-sitter"
}

install_tmux() {
	if fetch_tool tmux; then
		exe=$(exe_in "$DIR" tmux)
		if [ -n "$exe" ] && runs "$exe" -V; then put "$exe" "$BIN/tmux"; return 0; fi
	fi
	have tmux && return 0
	pm_install tmux && return 0
	conda_install tmux && put "$TOOLS/conda/bin/tmux" "$BIN/tmux"
}

# Node.js runs the HTML/CSS language servers. It stays private to Neovim (libexec),
# so the shell keeps the owner's own node.
install_node() {
	if have npm && version_ge "$(version_of node --version)" 18; then return 0; fi
	if fetch_tool node; then
		exe=$(exe_in "$DIR" node)
		if [ -n "$exe" ] && runs "$exe" --version; then
			for name in node npm npx; do put "${exe%/node}/$name" "$LIBEXEC/$name"; done
			return 0
		fi
	fi
	if conda_install nodejs && runs "$TOOLS/conda/bin/node" --version; then
		for name in node npm npx; do put "$TOOLS/conda/bin/$name" "$LIBEXEC/$name"; done
		return 0
	fi
	pm_install $(pm_name node) && have npm
}

install_uv() {
	UV=
	if fetch_tool uv; then
		UV=$(exe_in "$DIR" uv)
		runs "$UV" --version || UV=
	fi
	if [ -z "$UV" ] && conda_install uv; then UV=$TOOLS/conda/bin/uv; fi
	[ -n "$UV" ] || return 1
	put "$UV" "$BIN/uv"
	if [ -x "${UV%/uv}/uvx" ]; then put "${UV%/uv}/uvx" "$BIN/uvx"; fi
}

install_pyrefly() {
	version=$(lock_version pyrefly)
	say "  installing pyrefly $version"
	UV_TOOL_DIR=$TOOLS/uv-tools UV_TOOL_BIN_DIR=$TOOLS/uv-bin UV_PYTHON_INSTALL_DIR=$TOOLS/python \
		UV_PYTHON_BIN_DIR=$TOOLS/python-bin UV_CACHE_DIR=$TOOLS/uv-cache UV_NO_CONFIG=1 \
		"$UV" tool install --force "pyrefly==$version" </dev/null >>"$LOG" 2>&1 &&
		[ -x "$TOOLS/uv-bin/pyrefly" ] && put "$TOOLS/uv-bin/pyrefly" "$BIN/pyrefly"
}

install_rg() {
	if fetch_tool ripgrep; then
		exe=$(exe_in "$DIR" rg)
		if [ -n "$exe" ] && runs "$exe" --version; then put "$exe" "$BIN/rg"; return 0; fi
	fi
	have rg && return 0
	pm_install $(pm_name rg) && return 0
	conda_install ripgrep && put "$TOOLS/conda/bin/rg" "$BIN/rg"
}

install_tools() {
	step "Installing tools into $TOOLS"
	remove "$LIBEXEC" && remove "$BIN" && mkdir -p "$TOOLS" "$LIBEXEC" "$BIN" || die "cannot write to $ROOT"
	write_devkit_command
	if [ "$OS" = macos ]; then
		macos_command_line_tools || die "Apple's Command Line Tools are required: run xcode-select --install, then run this again"
	fi
	need git git || die "git is required for Neovim plugins; install it and run this again"
	need curl curl || warn "curl is missing, so Neovim cannot download syntax parsers"
	need unzip unzip || warn "unzip is missing, so Mason cannot install stylua"
	need_cc || warn "no C compiler, so syntax parsers cannot be built"
	install_nvim || die "no Neovim 0.12+ build for $PLATFORM${GLIBC:+ (glibc $GLIBC)}; install Neovim 0.12+ yourself, then run this again"
	install_tree_sitter || warn "no tree-sitter CLI 0.26.1+ for $PLATFORM, so syntax highlighting falls back to regex"
	install_tmux || warn "could not install tmux"
	install_node || warn "no Node.js 18+, so the HTML/CSS language servers are skipped"
	if install_uv; then
		install_pyrefly || warn "could not install pyrefly (Python language server)"
	else
		warn "could not install uv, so pyrefly (Python language server) is skipped"
	fi
	install_rg || warn "could not install ripgrep, which Telescope's live grep uses"
	prune_tools
}

# take_over NAME moves the owner's copy into the backup and marks the path as ours.
# The marker is written right after the move, so an interrupted run can be resumed or undone.
take_over() {
	path=$(target_path "$1")
	printf '%s' "$path" >"$STATE/$1.path"
	[ ! -e "$STATE/$1.ours" ] || return 0
	if exists "$path"; then
		! exists "$BACKUP/$1" || die "both $path and its backup $BACKUP/$1 exist; move one of them away and run this again"
		mkdir -p "$BACKUP" && mv "$path" "$BACKUP/$1" || die "could not move $path into $BACKUP"
		say "  backed up $path"
	fi
	: >"$STATE/$1.ours"
}

# hide NAME moves the owner's copy into the backup without replacing it.
hide() {
	path=$(target_path "$1")
	printf '%s' "$path" >"$STATE/$1.path"
	exists "$path" && ! exists "$BACKUP/$1" || return 0
	mkdir -p "$BACKUP" && mv "$path" "$BACKUP/$1" || die "could not move $path into $BACKUP"
	say "  backed up $path"
}

# give_back NAME removes our copy and restores the owner's one.
give_back() {
	path=$(target_path "$1")
	if [ -e "$STATE/$1.ours" ]; then
		remove "$path"
		rm -f "$STATE/$1.ours"
	fi
	exists "$BACKUP/$1" || return 0
	if exists "$path"; then
		warn "$path appeared while devkit was installed, so the original stays at $BACKUP/$1"
		return 0
	fi
	mkdir -p "$(dirname "$path")" && mv "$BACKUP/$1" "$path" && say "  restored $path"
}

install_configs() {
	step "Installing configs (existing ones are moved to $BACKUP)"
	for name in $TARGETS; do take_over "$name"; done
	# tmux also reads this file, which would override ours.
	hide tmux-xdg
	config=$(target_path nvim-config)
	if exists "$config"; then
		remove "$STATE/previous-config"
		mv "$config" "$STATE/previous-config"
	fi
	mkdir -p "$(dirname "$config")" && cp -R "$ROOT/source/config/nvim" "$config" ||
		die "could not copy the Neovim config to $config"
	cp "$ROOT/source/config/tmux.conf" "$(target_path tmux-conf)" || die "could not write $(target_path tmux-conf)"
	say "  Neovim config: $config"
	say "  tmux config:   $(target_path tmux-conf)"
}

# add_path_block FILE LINE appends a marked block. Copies from before and after the edit
# let uninstall restore the exact original when nothing else changed the file meanwhile.
add_path_block() {
	if [ -f "$1" ] && grep -qF "$BEGIN_MARK" "$1"; then return 0; fi
	if ! exists "$1"; then
		mkdir -p "$(dirname "$1")" && : >"$1" || return 0
		printf '%s\n' "$1" >>"$STATE/created-files"
	fi
	if [ ! -f "$1" ] || [ ! -w "$1" ]; then
		warn "could not add $BIN to PATH in $1"
		return 0
	fi
	index=0
	if [ -f "$STATE/rc-files" ]; then index=$(wc -l <"$STATE/rc-files" | tr -d ' '); fi
	cp "$1" "$STATE/rc-$index.before" || return 0
	newline=''
	if [ -s "$1" ] && [ -n "$(tail -c 1 "$1")" ]; then newline='\n'; fi
	printf "$newline%s\n%s\n%s\n" "$BEGIN_MARK" "$2" "$END_MARK" >>"$1"
	cp "$1" "$STATE/rc-$index.after"
	printf '%s\t%s\n' "$index" "$1" >>"$STATE/rc-files"
	say "  added $BIN to PATH in $1"
}

add_to_path() {
	step "Adding $BIN to PATH"
	line="case \":\$PATH:\" in *:$(quote "$BIN"):*) ;; *) PATH=$(quote "$BIN"):\$PATH; export PATH ;; esac"
	zshrc=${ZDOTDIR:-$HOME}/.zshrc
	shell=${SHELL:-sh}
	case ${shell##*/} in
	zsh) main=$zshrc ;;
	bash)
		main=$HOME/.bashrc
		if [ "$OS" = macos ]; then
			# macOS terminals start login shells, which read the first of these.
			main=$HOME/.profile
			for file in "$HOME/.bash_login" "$HOME/.bash_profile"; do
				if [ -f "$file" ]; then main=$file; fi
			done
		fi
		;;
	fish) main= ;;
	*) main=$HOME/.profile ;;
	esac
	for file in "$main" "$HOME/.profile" "$HOME/.bashrc" "$HOME/.bash_profile" "$zshrc"; do
		[ -n "$file" ] || continue
		if [ "$file" = "$main" ] || [ -f "$file" ]; then add_path_block "$file" "$line"; fi
	done
	if [ "${shell##*/}" = fish ] || have fish || [ -d "$CONFIG_HOME/fish" ]; then
		file=$CONFIG_HOME/fish/conf.d/devkit.fish
		mkdir -p "${file%/*}" && printf '# devkit (sh1n1n-br1ght/setup)\nif not contains -- %s $PATH\n    set -gx PATH %s $PATH\nend\n' \
			"$(fish_quote "$BIN")" "$(fish_quote "$BIN")" >"$file" && say "  added $BIN to PATH in $file"
	fi
}

remove_from_path() {
	if [ -f "$STATE/rc-files" ]; then
		while IFS=$TAB read -r index file; do
			[ -f "$file" ] || continue
			if cmp -s "$file" "$STATE/rc-$index.after"; then
				cat "$STATE/rc-$index.before" >"$file"
			elif grep -qF "$BEGIN_MARK" "$file"; then
				# Edited since install: drop only our block.
				awk -v b="$BEGIN_MARK" -v e="$END_MARK" '$0 == b { skip = 1; next } skip && $0 == e { skip = 0; next } !skip' \
					"$file" >"$WORK/rc" && cat "$WORK/rc" >"$file"
			else
				continue
			fi
			say "  removed devkit from PATH in $file"
		done <"$STATE/rc-files"
	fi
	rm -f "$CONFIG_HOME/fish/conf.d/devkit.fish"
	if [ -f "$STATE/created-files" ]; then
		while IFS= read -r file; do
			if [ -f "$file" ] && ! grep -q '[^[:space:]]' "$file"; then rm -f "$file"; fi
		done <"$STATE/created-files"
	fi
}

write_devkit_command() {
	write_script "$BIN/devkit" "DEVKIT_ROOT=$(quote "$ROOT")
export DEVKIT_ROOT
exec sh $(quote "$ROOT/source/install.sh") \"\$@\""
}

write_commands() {
	mkdir -p "$BIN" "$LIBEXEC"
	write_devkit_command
	if [ -n "${NVIM:-}" ]; then
		# Helper tools (tree-sitter, node, compilers) are visible to Neovim only, and npm
		# (used by Mason) keeps its cache here instead of in the owner's ~/.npm.
		write_script "$BIN/nvim" "PATH=$(quote "$LIBEXEC"):$(quote "$BIN"):\$PATH
npm_config_cache=$(quote "$ROOT/cache/npm")
export PATH npm_config_cache
exec $(quote "$NVIM") \"\$@\""
	fi
}

get_source() {
	SRC=
	case $SCRIPT in
	*/*) here=${SCRIPT%/*} ;;
	*) here=. ;;
	esac
	if [ "$SOURCE_REQUESTED" = 0 ] && [ -f "$SCRIPT" ] && [ -f "$here/config/nvim/init.lua" ] && [ -f "$here/tools.lock" ]; then
		SRC=$(cd "$here" && pwd -P)
	fi
	if [ -z "$SRC" ] || [ "$SRC" = "$(cd "$ROOT/source" 2>/dev/null && pwd -P)" ]; then
		# `devkit update` follows the repository and ref of the current installation.
		if [ -n "$SRC" ] && [ "$SOURCE_REQUESTED" = 0 ] && [ -f "$STATE/installed" ]; then
			REPO=$(sed -n 's/^repo=\([A-Za-z0-9._/-]*\)$/\1/p' "$STATE/installed")
			REF=$(sed -n 's/^ref=\([A-Za-z0-9._/-]*\)$/\1/p' "$STATE/installed")
			[ -n "$REPO" ] && [ -n "$REF" ] || die "unreadable $STATE/installed; run the install command again"
		fi
		url=https://github.com/$REPO/archive/$REF.tar.gz
		say "  downloading $url"
		fetch "$url" "$WORK/source.tar.gz" || die "could not download $url"
		mkdir "$WORK/source" && gzip -dc "$WORK/source.tar.gz" | tar -xf - -C "$WORK/source" || die "could not unpack $url"
		for dir in "$WORK/source"/*/; do
			SRC=${dir%/}
			break
		done
		[ -f "$SRC/config/nvim/init.lua" ] || die "$url does not contain config/nvim"
	fi
	# A private copy lets `devkit uninstall` work offline.
	remove "$ROOT/source.new" && mkdir -p "$ROOT/source.new" &&
		cp -R "$SRC/install.sh" "$SRC/tools.lock" "$SRC/lib" "$SRC/config" "$ROOT/source.new/" &&
		remove "$ROOT/source" && mv "$ROOT/source.new" "$ROOT/source" || die "could not copy the setup files into $ROOT"
	LOCK=$ROOT/source/tools.lock
}

check_legacy() {
	# The previous Python-based version kept an isolated environment here and never
	# touched the owner's configs, so removing it loses nothing of theirs.
	[ -f "$ROOT/.devkit-owner" ] || return 0
	die "$ROOT holds an installation from the previous version of this script.
Remove it first (it never changed your own configs), then run this again:
  rm -rf $(quote "$ROOT") $(quote "$HOME/.local/state/devkit") && rm -f $(quote "$HOME/.local/bin/devkit")"
}

start() {
	# `sudo sh install.sh` with the user's HOME would leave root-owned files in it.
	if [ -n "${SUDO_USER:-}" ] && [ "$(id -u)" = 0 ] && [ "$(ls -ld "$HOME" | awk '{ print $3 }')" != root ]; then
		die "run this as yourself, not with sudo; it asks for sudo itself when it needs a system package"
	fi
	mkdir -p "$ROOT" || die "cannot create $ROOT"
	mkdir "$ROOT/.lock" 2>/dev/null || die "another devkit install or uninstall is running (if not, remove $ROOT/.lock)"
	LOCKED=1
	trap 'finish' EXIT
	trap 'exit 130' INT
	trap 'exit 143' TERM
	trap 'exit 129' HUP
	WORK=$(mktemp -d "${TMPDIR:-/tmp}/devkit.XXXXXX") || die "cannot create a temporary directory"
	mkdir -p "$STATE" || die "cannot create $STATE"
}
finish() {
	if [ -n "${WORK:-}" ]; then rm -rf "$WORK"; fi
	if [ "${LOCKED:-0}" = 1 ]; then rmdir "$ROOT/.lock" 2>/dev/null; fi
}

do_install() {
	check_legacy
	# Directories this installation creates; uninstall removes them again if they are empty.
	# The tree-sitter CLI leaves an empty lock directory in its cache.
	new_dirs=
	for dir in "$HOME/.local" "${ROOT%/*}" "$CONFIG_HOME" "$CONFIG_HOME/tmux" "$DATA_HOME" "$STATE_HOME" "$CACHE_HOME" \
		"$CACHE_HOME/tree-sitter" "$CACHE_HOME/tree-sitter/lock"; do
		exists "$dir" || new_dirs="$new_dirs$dir
"
	done
	start
	if [ ! -f "$STATE/created-dirs" ]; then printf '%s' "$new_dirs" >"$STATE/created-dirs"; fi
	LOG=$STATE/install.log
	: >"$LOG"
	detect_pm
	step "Preparing $REPO ($REF) for $PLATFORM${GLIBC:+, glibc $GLIBC}"
	need tar || die "tar is required"
	need gzip || die "gzip is required"
	get_source
	NVIM=
	if [ "$CONFIG_ONLY" = 0 ]; then
		install_tools
	else
		mkdir -p "$BIN" "$LIBEXEC"
	fi
	install_configs
	write_commands
	add_to_path
	printf 'repo=%s\nref=%s\nplatform=%s\nconfig_only=%s\ninstalled=%s\n' "$REPO" "$REF" "$PLATFORM" "$CONFIG_ONLY" \
		"$(date -u +%Y-%m-%dT%H:%M:%SZ)" >"$STATE/installed"
	if [ "$CONFIG_ONLY" = 0 ]; then
		step "Installing Neovim plugins, language servers and parsers (a few minutes)"
		DEVKIT_BOOTSTRAP=$ROOT/source/lib/bootstrap-nvim.lua
		export DEVKIT_BOOTSTRAP
		PATH=$BIN:$PATH "$BIN/nvim" --headless --cmd 'lua dofile(vim.env.DEVKIT_BOOTSTRAP)' </dev/null >>"$LOG" ||
			die "Neovim plugins were not installed (details in $LOG). Run the installer again to retry, or uninstall with: $BIN/devkit uninstall"
	fi
	say ""
	say "Done. Open a new terminal (or run: export PATH=$(quote "$BIN"):\$PATH) and start nvim."
	if [ -d "$BACKUP" ]; then say "Your previous setup is saved in $BACKUP; 'devkit uninstall' puts it back."; fi
	if [ "$WARNINGS" -gt 0 ]; then say "$WARNINGS warning(s) above; full log: $LOG"; fi
}

do_uninstall() {
	if [ ! -d "$ROOT" ]; then
		say "devkit is not installed (no $ROOT)."
		return 0
	fi
	check_legacy
	start
	step "Removing devkit and restoring the previous setup"
	remove_from_path
	for name in $TARGETS tmux-xdg; do give_back "$name"; done
	if [ -s "$STATE/system-packages" ]; then
		say "  system packages installed for devkit were left in place: $(sort -u "$STATE/system-packages" | tr '\n' ' ')"
	fi
	if [ -d "$BACKUP" ] && [ -n "$(ls -A "$BACKUP" 2>/dev/null)" ]; then
		for item in "$ROOT"/* "$ROOT"/.[!.]*; do
			if exists "$item" && [ "$item" != "$BACKUP" ] && [ "$item" != "$ROOT/.lock" ]; then remove "$item"; fi
		done
		say "Kept $BACKUP because something could not be restored (see the warnings above)."
	else
		created_dirs=
		if [ -f "$STATE/created-dirs" ]; then created_dirs=$(cat "$STATE/created-dirs"); fi
		remove "$ROOT"
		LOCKED=0
		# Deepest first; rmdir leaves any directory that has gained other files.
		printf '%s\n' "$created_dirs" | awk 'NF { print length($0) "\t" $0 }' | sort -rn | cut -f 2- |
			while IFS= read -r dir; do rmdir "$dir" 2>/dev/null; done
	fi
	say "devkit is removed. Open a new terminal so PATH no longer includes it."
}

do_status() {
	if [ ! -f "$STATE/installed" ]; then
		say "devkit is not installed."
		if [ -d "$ROOT" ]; then say "An interrupted installation left files in $ROOT; run install again or uninstall."; fi
		return 0
	fi
	say "devkit is installed in $ROOT"
	sed 's/^/  /' "$STATE/installed"
	for command in "$BIN"/*; do
		case ${command##*/} in
		devkit | uvx) ;;
		tmux) say "  tmux $(version_of "$command" -V)" ;;
		*) say "  ${command##*/} $(version_of "$command" --version)" ;;
		esac
	done
	if [ -d "$BACKUP" ] && [ -n "$(ls -A "$BACKUP" 2>/dev/null)" ]; then
		say "Backed-up originals (restored by 'devkit uninstall'):"
		for name in $TARGETS tmux-xdg; do
			if exists "$BACKUP/$name"; then say "  $(target_path "$name")"; fi
		done
	fi
}

run_windows() {
	have powershell.exe || die "on Windows, run install.ps1 from PowerShell"
	case $ACTION in
	uninstall) action=Uninstall ;;
	status) action=Status ;;
	*) action=Install ;;
	esac
	say "Windows detected; running the PowerShell installer."
	exec powershell.exe -NoProfile -ExecutionPolicy Bypass -Command \
		"& ([scriptblock]::Create((Invoke-RestMethod 'https://raw.githubusercontent.com/$REPO/$REF/install.ps1'))) -Action $action -Ref '$REF' -Repo '$REPO'"
}

main() {
	while [ $# -gt 0 ]; do
		case $1 in
		install | update | --install | --update) ACTION=install ;;
		uninstall | remove | --uninstall) ACTION=uninstall ;;
		status | --status) ACTION=status ;;
		--ref | --repo)
			[ $# -ge 2 ] || die "$1 needs a value"
			case $2 in
			*[!A-Za-z0-9._/-]* | '' | -*) die "invalid value for $1: $2" ;;
			esac
			if [ "$1" = --ref ]; then REF=$2; else REPO=$2; fi
			SOURCE_REQUESTED=1
			shift
			;;
		--config-only) CONFIG_ONLY=1 ;;
		--no-system) NO_SYSTEM=1 ;;
		-h | --help)
			usage
			return 0
			;;
		*) die "unknown argument: $1 (try --help)" ;;
		esac
		shift
	done
	detect_platform
	if [ "$OS" = windows ]; then run_windows; fi
	setup_paths
	case $ACTION in
	install) do_install ;;
	uninstall) do_uninstall ;;
	status) do_status ;;
	esac
}

# One line, so the shell never reads past it, even if this file changes while running.
main "$@"; exit
