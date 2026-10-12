#!/bin/sh
# Lifecycle tests for install.sh in throwaway HOME directories (no network: --config-only).
#   sh tests/test_install.sh
# Each case seeds an "owner" setup, installs, reinstalls, uninstalls, and checks that
# every original file comes back byte for byte.

set -u
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
TESTS_RUN=0
FAILURES=0
SHELL_UNDER_TEST=${TEST_SHELL:-sh}

fail() {
	printf 'FAIL [%s]: %s\n' "$CASE" "$*" >&2
	FAILURES=$((FAILURES + 1))
}

new_home() {
	CASE=$1
	TESTS_RUN=$((TESTS_RUN + 1))
	SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/devkit-test.XXXXXX")
	H=$SANDBOX/home
	mkdir -p "$H"
}

run() {
	# A clean environment: only the sandbox HOME and a plain shell.
	env -i HOME="$H" PATH="$PATH" SHELL="${TEST_LOGIN_SHELL:-/bin/zsh}" TMPDIR="${TMPDIR:-/tmp}" \
		"$SHELL_UNDER_TEST" "$REPO_DIR/install.sh" "$@" >"$SANDBOX/out" 2>&1
}

seed_owner() {
	mkdir -p "$H/.config/nvim/lua" "$H/.local/share/nvim/lazy/plugin" "$H/.local/state/nvim/shada" \
		"$H/.cache/nvim" "$H/.config/tmux"
	printf 'print("owner config")\n' >"$H/.config/nvim/init.lua"
	printf 'return {}\n' >"$H/.config/nvim/lua/owner.lua"
	printf 'owner plugin\n' >"$H/.local/share/nvim/lazy/plugin/init.lua"
	printf 'history\n' >"$H/.local/state/nvim/shada/main.shada"
	printf 'cache\n' >"$H/.cache/nvim/luac"
	printf 'set -g prefix C-a\n' >"$H/.tmux.conf"
	printf 'set -g status off\n' >"$H/.config/tmux/tmux.conf"
	printf 'export OWNER=1' >"$H/.zshrc" # no trailing newline on purpose
	printf 'alias ll="ls -l"\n' >"$H/.bashrc"
	cp -R "$H" "$SANDBOX/original"
}

same_tree() {
	diff -r "$1" "$2" >/dev/null 2>&1 || fail "$3 differs from the original"
}

check_installed() {
	[ -f "$H/.config/nvim/init.lua" ] && cmp -s "$H/.config/nvim/init.lua" "$REPO_DIR/config/nvim/init.lua" ||
		fail "Neovim config was not installed"
	cmp -s "$H/.tmux.conf" "$REPO_DIR/config/tmux.conf" || fail "tmux.conf was not installed"
	[ -x "$H/.local/share/devkit/bin/devkit" ] || fail "devkit command is missing"
	[ ! -e "$H/.config/tmux/tmux.conf" ] || fail "the owner's XDG tmux.conf still overrides ours"
}

case_round_trip() {
	new_home "owner setup round trip"
	seed_owner
	run install --config-only || fail "install failed: $(cat "$SANDBOX/out")"
	check_installed
	[ -f "$H/.local/share/devkit/backup/nvim-config/init.lua" ] || fail "owner config not in backup"
	cmp -s "$H/.local/share/devkit/backup/tmux-xdg" "$SANDBOX/original/.config/tmux/tmux.conf" || fail "XDG tmux.conf not in backup"
	grep -q 'devkit/bin' "$H/.zshrc" || fail ".zshrc has no PATH block"
	grep -q 'devkit/bin' "$H/.bashrc" || fail ".bashrc has no PATH block"
	grep -q '^export OWNER=1$' "$H/.zshrc" || fail ".zshrc lost its last line"
	# zsh must see the devkit commands on PATH after reading .zshrc.
	if command -v zsh >/dev/null 2>&1; then
		found=$(env -i HOME="$H" PATH=/usr/bin:/bin zsh -c '. "$HOME/.zshrc"; command -v devkit' 2>/dev/null)
		[ "$found" = "$H/.local/share/devkit/bin/devkit" ] || fail "zsh does not find devkit on PATH (got '$found')"
	fi

	printf 'my edit\n' >>"$H/.config/nvim/init.lua"
	run install --config-only || fail "reinstall failed: $(cat "$SANDBOX/out")"
	check_installed
	[ "$(grep -c 'devkit (sh1n1n-br1ght/setup)' "$H/.zshrc")" = 1 ] || fail "reinstall duplicated the PATH block"
	grep -q 'my edit' "$H/.local/share/devkit/state/previous-config/init.lua" || fail "reinstall dropped local edits"
	run status || fail "status failed"
	grep -q 'devkit is installed' "$SANDBOX/out" || fail "status does not report the installation"

	run uninstall || fail "uninstall failed: $(cat "$SANDBOX/out")"
	same_tree "$SANDBOX/original" "$H" "home directory after uninstall"
	[ ! -e "$H/.local/share/devkit" ] || fail "devkit directory left behind"
	rm -rf "$SANDBOX"
}

case_empty_machine() {
	new_home "machine without any config"
	cp -R "$H" "$SANDBOX/original"
	TEST_LOGIN_SHELL=/bin/bash run install --config-only || fail "install failed: $(cat "$SANDBOX/out")"
	check_installed
	[ -f "$H/.bashrc" ] || [ -f "$H/.profile" ] || fail "no shell startup file got the PATH block"
	run uninstall || fail "uninstall failed: $(cat "$SANDBOX/out")"
	same_tree "$SANDBOX/original" "$H" "home directory after uninstall"
	rm -rf "$SANDBOX"
}

case_symlinked_config() {
	new_home "config symlinked from a dotfiles repo"
	mkdir -p "$H/dotfiles/nvim" "$H/.config"
	printf 'print("dotfiles")\n' >"$H/dotfiles/nvim/init.lua"
	ln -s "$H/dotfiles/nvim" "$H/.config/nvim"
	cp -R "$H" "$SANDBOX/original"
	run install --config-only || fail "install failed: $(cat "$SANDBOX/out")"
	check_installed
	same_tree "$SANDBOX/original/dotfiles" "$H/dotfiles" "dotfiles repo while installed"
	run uninstall || fail "uninstall failed: $(cat "$SANDBOX/out")"
	[ -L "$H/.config/nvim" ] && [ "$(readlink "$H/.config/nvim")" = "$H/dotfiles/nvim" ] || fail "symlink not restored"
	rm -rf "$SANDBOX"
}

case_interrupted_install() {
	new_home "install interrupted after the backup move"
	seed_owner
	# State left by a run killed between moving the config and recording it.
	mkdir -p "$H/.local/share/devkit/backup" "$H/.local/share/devkit/state"
	mv "$H/.config/nvim" "$H/.local/share/devkit/backup/nvim-config"
	run install --config-only || fail "resumed install failed: $(cat "$SANDBOX/out")"
	check_installed
	run uninstall || fail "uninstall failed: $(cat "$SANDBOX/out")"
	same_tree "$SANDBOX/original" "$H" "home directory after uninstall"
	rm -rf "$SANDBOX"
}

case_owner_file_created_while_installed() {
	new_home "owner recreates a hidden file while installed"
	seed_owner
	run install --config-only || fail "install failed: $(cat "$SANDBOX/out")"
	printf 'new owner file\n' >"$H/.config/tmux/tmux.conf"
	run uninstall || fail "uninstall failed: $(cat "$SANDBOX/out")"
	grep -q 'appeared while devkit was installed' "$SANDBOX/out" || fail "no warning about the conflicting file"
	[ "$(cat "$H/.config/tmux/tmux.conf")" = "new owner file" ] || fail "new owner file was overwritten"
	cmp -s "$H/.local/share/devkit/backup/tmux-xdg" "$SANDBOX/original/.config/tmux/tmux.conf" || fail "original not kept in backup"
	same_tree "$SANDBOX/original/.config/nvim" "$H/.config/nvim" "Neovim config after uninstall"
	rm -rf "$SANDBOX"
}

case_previous_version() {
	new_home "installation from the previous version"
	mkdir -p "$H/.local/share/devkit"
	printf 'devkit-v2\n' >"$H/.local/share/devkit/.devkit-owner"
	if run install --config-only; then fail "install should stop"; fi
	grep -q 'previous version' "$SANDBOX/out" || fail "no explanation: $(cat "$SANDBOX/out")"
	[ ! -e "$H/.config/nvim" ] || fail "install changed configs anyway"
	rm -rf "$SANDBOX"
}

case_round_trip
case_empty_machine
case_symlinked_config
case_interrupted_install
case_owner_file_created_while_installed
case_previous_version

printf '%s cases, %s failures (%s)\n' "$TESTS_RUN" "$FAILURES" "$SHELL_UNDER_TEST"
[ "$FAILURES" = 0 ]
