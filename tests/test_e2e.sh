#!/bin/sh
# Full install, update, checks and uninstall in a throwaway HOME. Downloads everything.
#   sh tests/test_e2e.sh
# TEST_PATH limits which system tools the installer can see (default: the current PATH).
# DEVKIT_EXPECT=plugins relaxes the editor checks (see tests/check_editor.lua).
# DEVKIT_TEST_REF=<pushed commit> (and DEVKIT_TEST_REPO) runs the installer the way the
# one-liner does: piped into sh, downloading that commit from GitHub.

set -u
REPO_DIR=$(cd "$(dirname "$0")/.." && pwd -P)
SANDBOX=$(mktemp -d "${TMPDIR:-/tmp}/devkit-e2e.XXXXXX")
H=$SANDBOX/home
BIN=$H/.local/share/devkit/bin

fail() {
	printf 'FAIL: %s\n' "$*" >&2
	for log in "$H/.local/share/devkit/state/install.log" "$H/.local/state/nvim/mason.log"; do
		if [ -f "$log" ]; then
			printf '\n--- last lines of %s\n' "$log" >&2
			tail -n 60 "$log" >&2
		fi
	done
	printf 'sandbox kept for inspection: %s\n' "$SANDBOX" >&2
	exit 1
}

as_owner() {
	env -i HOME="$H" PATH="${TEST_PATH:-$PATH}" SHELL=/bin/sh TMPDIR="${TMPDIR:-/tmp}" TERM=xterm-256color \
		DEVKIT_EXPECT="${DEVKIT_EXPECT:-}" "$@"
}

install() {
	if [ -n "${DEVKIT_TEST_REF:-}" ]; then
		as_owner sh -s -- --ref "$DEVKIT_TEST_REF" --repo "${DEVKIT_TEST_REPO:-sh1n1n-br1ght/setup}" <"$REPO_DIR/install.sh"
	else
		as_owner sh "$REPO_DIR/install.sh"
	fi
}

# The machine owner's own setup, which must come back unchanged.
mkdir -p "$H/.config/nvim" "$H/.local/share/nvim/lazy/owner-plugin" "$H/.local/state/nvim"
printf 'print("owner config")\n' >"$H/.config/nvim/init.lua"
printf 'owner plugin\n' >"$H/.local/share/nvim/lazy/owner-plugin/init.lua"
printf 'owner history\n' >"$H/.local/state/nvim/main.shada"
printf 'set -g prefix C-a\n' >"$H/.tmux.conf"
printf 'export OWNER=1\n' >"$H/.profile"
cp -R "$H" "$SANDBOX/original"

started=$(date +%s)
install || fail "install failed"
printf 'install took %ss\n' "$(($(date +%s) - started))"
started=$(date +%s)
install || fail "second install (update) failed"
printf 'update took %ss\n' "$(($(date +%s) - started))"
[ "$(grep -c 'devkit (sh1n1n-br1ght/setup)' "$H/.profile")" = 1 ] || fail "the update duplicated the PATH block"

as_owner "$BIN/nvim" --headless -c "lua dofile('$REPO_DIR/tests/check_editor.lua')" || fail "editor checks failed"
if [ "${DEVKIT_EXPECT:-}" != plugins ]; then
	as_owner "$BIN/nvim" --headless -i NONE -c "lua dofile('$REPO_DIR/tests/nvim_completion.lua')" ||
		fail "Python import completion test failed"
	as_owner "$BIN/nvim" --headless -n -i NONE -c "lua dofile('$REPO_DIR/tests/python_imports.lua')" ||
		fail "completion in import lists offers more than the module's members"
	as_owner "$BIN/nvim" --headless -n -i NONE -c "lua dofile('$REPO_DIR/tests/python_indent.lua')" ||
		fail "Python brackets are not indented like black formats them"
fi
if [ -x "$BIN/tmux" ]; then
	as_owner "$BIN/tmux" -L devkit-test -f "$H/.tmux.conf" new-session -d 'sleep 5' || fail "tmux cannot start a session"
	[ "$(as_owner "$BIN/tmux" -L devkit-test show-options -gv mode-keys)" = vi ] || fail "tmux did not load the config"
	as_owner "$BIN/tmux" -L devkit-test kill-server
fi
[ "$(as_owner sh -c '. "$HOME/.profile"; command -v nvim')" = "$BIN/nvim" ] || fail "a login shell does not find devkit's nvim"
python=$(awk -F '\t' '$1 == "python" { print $2; exit }' "$REPO_DIR/tools.lock")
[ "$(as_owner sh -c '. "$HOME/.profile"; command -v python3')" = "$BIN/python3" ] || fail "a login shell does not find devkit's python3"
[ "$(as_owner "$BIN/python3" -c 'import sys; print("%d.%d" % sys.version_info[:2])')" = "$python" ] ||
	fail "devkit's python3 is not Python $python"
as_owner "$BIN/devkit" status || fail "status failed"

as_owner "$BIN/devkit" uninstall || fail "uninstall failed"
diff -r "$SANDBOX/original" "$H" || fail "the home directory differs from the original after uninstall"
rm -rf "$SANDBOX"
printf 'end-to-end test passed\n'
