# Shell Integration

Toastty's shell integration emits `OSC 2` title sequences so that panel headers show live working directories and running commands, even inside multiplexers like `tmux` or `zmx`.

The easiest way to install is `Terminal > Install Shell Integration…` in Toastty — it writes the snippet and sources it from your shell init file automatically. This page covers manual setup for users who manage their own dotfiles.

Shell integration installation is disabled while runtime isolation is enabled, because sandboxed dev/test runs must not rewrite your login shell files.

## Zsh

Create `~/.toastty/shell/toastty-profile-shell-integration.zsh`:

```zsh
# Toastty terminal profile shell integration.
# - idle prompt: cwd
# - running command: command
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

if [[ -o interactive && -z ${_TOASTTY_TITLE_HOOKS_INSTALLED:-} ]]; then
	autoload -Uz add-zsh-hook
	add-zsh-hook precmd _toastty_precmd
	add-zsh-hook preexec _toastty_preexec
	typeset -g _TOASTTY_TITLE_HOOKS_INSTALLED=1
fi
```

Then add this to `~/.zshrc`:

```zsh
source "$HOME/.toastty/shell/toastty-profile-shell-integration.zsh"
```

## Bash

Create `~/.toastty/shell/toastty-profile-shell-integration.bash`:

```bash
# Toastty terminal profile shell integration.
# Updates the pane title to the current directory whenever the prompt returns.
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

if [[ $- == *i* && -z "${_TOASTTY_TITLE_HOOKS_INSTALLED:-}" ]]; then
	PROMPT_COMMAND="_toastty_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
	_TOASTTY_TITLE_HOOKS_INSTALLED=1
fi
```

Then add this to `~/.bash_profile` on macOS, or `~/.bashrc` if that is the
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
- [Terminal Profiles](terminal-profiles.md)
