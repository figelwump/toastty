# Shell Integration

Toastty's shell integration emits `OSC 2` title sequences so that panel headers show live working directories and running commands, even inside multiplexers like `tmux` or `zmx`.

The easiest way to install is `Toastty > Install Shell Integration…` in Toastty — it writes the snippet and sources it from your shell init file automatically. This page covers manual setup for users who manage their own dotfiles.

The managed snippets also restore `TOASTTY_AGENT_SHIM_DIR` to the front of `PATH` when that environment variable is present, so manual `codex`, `claude`, and any configured wrapper executables declared through `manualCommandNames` keep using Toastty's wrappers after shell startup files run.

Source the Toastty snippet after all other shell startup code that mutates `PATH` such as `nvm`, Homebrew shellenv, `asdf`, `bun`, `pyenv`, or custom path edits. It does not need to be the literal last line, but anything that rewrites `PATH` after it can undo Toastty's shim ordering.

Shell integration installation is disabled while runtime isolation is enabled, because sandboxed dev/test runs must not rewrite your login shell files.

## Zsh

Create `~/.toastty/shell/toastty-profile-shell-integration.zsh`:

```zsh
# Toastty terminal profile shell integration.
# - idle prompt: cwd
# - running command: command
_toastty_restore_agent_shim_path() {
	[[ -n "${TOASTTY_AGENT_SHIM_DIR:-}" ]] || return

	typeset -gaU path
	path=("$TOASTTY_AGENT_SHIM_DIR" "${(@)path:#$TOASTTY_AGENT_SHIM_DIR}")
	export PATH
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
	local cwd="${PWD/#$HOME/~}"
	_toastty_emit_title "$cwd"
}

_toastty_preexec() {
	local cmd="${1%%$'\n'*}"
	_toastty_emit_title "$cmd"
}

if [[ -o interactive ]]; then
	_toastty_restore_agent_shim_path
	if [[ -z ${_TOASTTY_TITLE_HOOKS_INSTALLED:-} ]]; then
		autoload -Uz add-zsh-hook
		add-zsh-hook precmd _toastty_precmd
		add-zsh-hook preexec _toastty_preexec
		typeset -g _TOASTTY_TITLE_HOOKS_INSTALLED=1
	fi
fi
```

Then add this near the end of `~/.zshrc`, after other PATH-changing setup:

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
	local cwd="${PWD/#$HOME/~}"
	_toastty_emit_title "$cwd"
}

if [[ $- == *i* ]]; then
	_toastty_restore_agent_shim_path
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
profiled multiplexer sessions.

## Related docs

- [README](../README.md)
- [Configuration](configuration.md)
- [Terminal Profiles](terminal-profiles.md)
