# Shell Integration

Toastty's shell integration emits `OSC 2` title sequences so that panel headers show live working directories and running commands, even inside multiplexers like `tmux` or `zmx`. For `zsh` and `bash`, it also switches each pane to its own shell history file so restored panes can recall their own commands with `Up`.

The easiest way to install is `Toastty > Install Shell Integration…` in Toastty — it writes the snippet and sources it from your shell init file automatically. This page covers manual setup for users who manage their own dotfiles.

This is command-history restore only. It does not restore running programs, SSH sessions, REPL state, shell-local variables, or half-typed input.

The managed snippets also restore `TOASTTY_AGENT_SHIM_DIR` to the front of `PATH` when that environment variable is present, so manual `codex`, `claude`, and any configured wrapper executables declared through `manualCommandNames` keep using Toastty's wrappers after shell startup files run.

Source the Toastty snippet after all other shell startup code that mutates `PATH` or overrides `HISTFILE`, such as `nvm`, Homebrew shellenv, `asdf`, `bun`, `pyenv`, or custom history setup. It does not need to be the literal last line, but anything that rewrites `PATH` or `HISTFILE` after it can undo Toastty's shim ordering or pane-local history selection.

Shell integration installation is disabled while runtime isolation is enabled, because sandboxed dev/test runs must not rewrite your login shell files.

Existing `tmux` or `zmx` sessions may only need a re-source for title updates. Pane-local history depends on `TOASTTY_PANE_HISTORY_FILE` being present in the shell's launch environment, so older multiplexer sessions usually need a restart before the per-pane history file takes effect.

## Zsh

Create `~/.toastty/shell/toastty-profile-shell-integration.zsh`:

```zsh
# Toastty terminal profile shell integration.
# - idle prompt: cwd
# - running command: command
_toastty_restore_agent_shim_path() {
	local shim_dir="${TOASTTY_AGENT_SHIM_DIR:-}"
	[[ -n "$shim_dir" ]] || return

	typeset -gaU path
	path=("$shim_dir" "${(@)path:#$shim_dir}")
	export PATH
}

_toastty_configure_pane_history() {
	local pane_history_file="${TOASTTY_PANE_HISTORY_FILE:-}"
	[[ -n "$pane_history_file" ]] || return

	local pane_history_dir="${pane_history_file:h}"
	command mkdir -p "$pane_history_dir" 2>/dev/null || return

	if [[ -z ${_TOASTTY_PANE_HISTORY_INITIALIZED:-} ]]; then
		fc -p "$pane_history_file" 2>/dev/null || return
		typeset -g _TOASTTY_PANE_HISTORY_INITIALIZED=1
	fi
}

_toastty_emit_title() {
	[[ -t 1 ]] || return
	[[ -w /dev/tty ]] || return

	local title="$1"
	title="${title//$'\e'/}"
	title="${title//$'\a'/}"
	title="${title//$'\r'/}"
	title="${title//$'\n'/ }"

	printf '\033]2;%s\a' "$title" > /dev/tty
}

_toastty_precmd() {
	if [[ -n ${_TOASTTY_PANE_HISTORY_INITIALIZED:-} ]]; then
		fc -AI
	fi
	local cwd="${PWD/#$HOME/~}"
	_toastty_emit_title "$cwd"
}

_toastty_preexec() {
	local cmd="${1%%$'\n'*}"
	_toastty_emit_title "$cmd"
}

if [[ -o interactive ]]; then
	_toastty_restore_agent_shim_path
	_toastty_configure_pane_history
	if [[ -z ${_TOASTTY_TITLE_HOOKS_INSTALLED:-} ]]; then
		autoload -Uz add-zsh-hook
		add-zsh-hook precmd _toastty_precmd
		add-zsh-hook preexec _toastty_preexec
		typeset -g _TOASTTY_TITLE_HOOKS_INSTALLED=1
	fi
fi
```

Then add this near the end of `~/.zshrc`, after other `PATH` and `HISTFILE` changes:

```zsh
source "$HOME/.toastty/shell/toastty-profile-shell-integration.zsh"
```

## Bash

Create `~/.toastty/shell/toastty-profile-shell-integration.bash`:

```bash
# Toastty terminal profile shell integration.
# Updates the pane title to the current directory whenever the prompt returns.
_toastty_restore_agent_shim_path() {
	local shim_dir="${TOASTTY_AGENT_SHIM_DIR:-}"
	[[ -n "$shim_dir" ]] || return

	local entry=""
	local old_path="${PATH:-}"
	local IFS=':'
	local -a path_entries=()
	read -r -a path_entries <<< "$old_path"

	PATH="$shim_dir"
	for entry in "${path_entries[@]}"; do
		[[ -n "$entry" && "$entry" != "$shim_dir" ]] || continue
		PATH+=":$entry"
	done
	export PATH
}

_toastty_configure_pane_history() {
	local pane_history_file="${TOASTTY_PANE_HISTORY_FILE:-}"
	[[ -n "$pane_history_file" ]] || return

	local pane_history_dir="${pane_history_file%/*}"
	command mkdir -p "$pane_history_dir" 2>/dev/null || return

	if [[ -z "${_TOASTTY_PANE_HISTORY_INITIALIZED:-}" ]]; then
		HISTFILE="$pane_history_file"
		export HISTFILE
		history -c
		history -r "$HISTFILE" 2>/dev/null || true
		_TOASTTY_PANE_HISTORY_INITIALIZED=1
	fi
}

_toastty_emit_title() {
	[[ $- == *i* ]] || return
	[[ -t 1 ]] || return
	[[ -w /dev/tty ]] || return

	local title="$1"
	title="${title//$'\e'/}"
	title="${title//$'\a'/}"
	title="${title//$'\r'/}"
	title="${title//$'\n'/ }"

	printf '\033]2;%s\a' "$title" > /dev/tty
}

_toastty_prompt_command() {
	if [[ -n "${_TOASTTY_PANE_HISTORY_INITIALIZED:-}" ]]; then
		history -a
	fi
	local cwd="${PWD/#$HOME/~}"
	_toastty_emit_title "$cwd"
}

if [[ $- == *i* ]]; then
	_toastty_restore_agent_shim_path
	_toastty_configure_pane_history
	if [[ -z "${_TOASTTY_TITLE_HOOKS_INSTALLED:-}" ]]; then
		PROMPT_COMMAND="_toastty_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
		_TOASTTY_TITLE_HOOKS_INSTALLED=1
	fi
fi
```

Then add this near the end of `~/.bash_profile` on macOS, or `~/.bashrc` if that is the
interactive file your Bash sessions already load:

```bash
source "$HOME/.toastty/shell/toastty-profile-shell-integration.bash"
```

## Other shells

Install an equivalent interactive hook that writes `OSC 2` (`\033]2;...\a`) to
`/dev/tty` with the current working directory whenever the prompt returns. If
your shell also has a pre-exec hook, emitting the current command there is
useful too, but the prompt-time directory title is the important part for
profiled multiplexer sessions. Toastty's managed pane-local history wiring is
currently provided for `zsh` and `bash` only.

## Related docs

- [README](../README.md)
- [Configuration](configuration.md)
- [Terminal Profiles](terminal-profiles.md)
