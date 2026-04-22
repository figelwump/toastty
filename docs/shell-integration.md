# Shell Integration

Toastty's shell integration emits `OSC 2` title sequences so panel headers show live working directories and running commands, even inside multiplexers like `tmux` or `zmx`. For `zsh`, `bash`, and `fish`, Toastty also keeps a Toastty-owned per-pane restore journal while leaving the shell's normal shared history alone.

On restore, Toastty imports that pane's journal into the shell's in-memory history. That means `Up` starts with the last commands from that pane, while reverse-search and normal history traversal can still see the broader shared shell history.

The easiest way to install is either `Toastty > Install Shell Integration…` or the top-bar `Get Started…` flow in Toastty. Both write the snippet and source it from your shell init file automatically. This page covers manual setup for users who manage their own dotfiles.

For automatic installs, Toastty first prefers the live shell executable path
for the current Toastty terminal window when it resolves to `zsh`, `bash`, or
`fish`. If no live terminal shell is available or that path is unsupported,
Toastty falls back to the current process `SHELL`, then the macOS account login
shell.

If you keep shell startup files in version control, the installer is still the easiest way to get the exact current snippet. Install once, keep the managed file under `~/.toastty/shell/`, and version only the `source` line in your shell init file if that matches your workflow.

This is command-history restore only. It does not restore running programs, SSH sessions, REPL state, shell-local variables, or half-typed input.

The managed snippets also restore `TOASTTY_AGENT_SHIM_DIR` to the front of `PATH` when that environment variable is present, so manual `codex`, `claude`, and any configured wrapper executables declared through `manualCommandNames` keep using Toastty's wrappers after shell startup files run.

Source the Toastty snippet after other `PATH`, history, and prompt-hook changes. It does not need to be the literal last line, but anything that rewrites `PATH`, replaces `PROMPT_COMMAND`, or overwrites prompt hooks after it can undo Toastty's shim ordering or prompt-time journal/title hooks.

Shell integration installation is disabled while runtime isolation is enabled, because sandboxed dev/test runs must not rewrite your login shell files.

Existing `tmux` or `zmx` sessions may only need a re-source for title updates. Restored-pane command recall only applies to shells launched after Toastty injects the launch context environment, so older multiplexer sessions usually need a restart.

Toastty does not migrate legacy `history/panes/*.history` files into the new `history/pane-journals/*.journal` format. Shared shell history still remains available immediately, and pane-local recall rebuilds as new commands run in each pane.

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

_toastty_ensure_pane_journal_directory() {
	local pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
	[[ -n "$pane_journal_file" ]] || return 1

	local pane_journal_dir="${pane_journal_file:h}"
	/bin/mkdir -p -- "$pane_journal_dir" 2>/dev/null || return 1
	return 0
}

_toastty_schedule_pane_journal_import_if_needed() {
	[[ "${TOASTTY_LAUNCH_REASON:-}" == "restore" ]] || return
	[[ "${TOASTTY_PANE_JOURNAL_IMPORTED:-}" == "1" ]] && return
	[[ "${TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED:-}" == "1" ]] && return

	typeset -g _TOASTTY_PANE_JOURNAL_IMPORT_PENDING=1
	export TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED=1
}

_toastty_import_pane_journal_if_needed() {
	[[ "${_TOASTTY_PANE_JOURNAL_IMPORT_PENDING:-}" == "1" ]] || return

	local pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
	if [[ -z "$pane_journal_file" || ! -r "$pane_journal_file" ]]; then
		unset _TOASTTY_PANE_JOURNAL_IMPORT_PENDING
		unset TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED
		export TOASTTY_PANE_JOURNAL_IMPORTED=1
		return
	fi

	local entry=""
	while IFS= read -r -d '' entry; do
		print -sr -- "$entry"
	done < "$pane_journal_file"

	unset _TOASTTY_PANE_JOURNAL_IMPORT_PENDING
	unset TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED
	export TOASTTY_PANE_JOURNAL_IMPORTED=1
}

_toastty_initialize_pane_journal() {
	[[ -z ${_TOASTTY_PANE_JOURNAL_INITIALIZED:-} ]] || return

	if _toastty_ensure_pane_journal_directory; then
		_toastty_schedule_pane_journal_import_if_needed
		unset _TOASTTY_PENDING_JOURNAL_ENTRY
	fi

	typeset -g _TOASTTY_PANE_JOURNAL_INITIALIZED=1
}

_toastty_command_should_write_pane_journal() {
	local cmd="$1"
	[[ -n "$cmd" ]] || return 1

	if [[ -o hist_ignore_space ]]; then
		case "$cmd" in
		([[:space:]]*) return 1 ;;
		esac
	fi

	return 0
}

_toastty_append_pending_history_entry_to_journal() {
	local pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
	[[ -n "$pane_journal_file" ]] || return

	(( ${+_TOASTTY_PENDING_JOURNAL_ENTRY} )) || return
	local entry="${_TOASTTY_PENDING_JOURNAL_ENTRY}"

	printf '%s\0' "$entry" >> "$pane_journal_file" 2>/dev/null || return
	unset _TOASTTY_PENDING_JOURNAL_ENTRY
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
	if [[ -n ${_TOASTTY_PANE_JOURNAL_INITIALIZED:-} ]]; then
		_toastty_import_pane_journal_if_needed
		_toastty_append_pending_history_entry_to_journal
	fi
	local cwd="${PWD/#$HOME/~}"
	_toastty_emit_title "$cwd"
}

_toastty_preexec() {
	local entry="$1"
	local cmd="${entry%%$'\n'*}"
	unset _TOASTTY_PENDING_JOURNAL_ENTRY
	_toastty_command_should_write_pane_journal "$entry" && typeset -g _TOASTTY_PENDING_JOURNAL_ENTRY="$entry"
	_toastty_emit_title "$cmd"
}

if [[ -o interactive ]]; then
	_toastty_restore_agent_shim_path
	_toastty_initialize_pane_journal
	if [[ -z ${_TOASTTY_TITLE_HOOKS_INSTALLED:-} ]]; then
		autoload -Uz add-zsh-hook
		add-zsh-hook precmd _toastty_precmd
		add-zsh-hook preexec _toastty_preexec
		typeset -g _TOASTTY_TITLE_HOOKS_INSTALLED=1
	fi
fi
```

Then add this near the end of `~/.zshrc`:

```zsh
source "$HOME/.toastty/shell/toastty-profile-shell-integration.zsh"
```

When `setopt HIST_IGNORE_SPACE` is active, leading-space commands stay out of
the pane journal too.

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

_toastty_ensure_pane_journal_directory() {
	local pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
	[[ -n "$pane_journal_file" ]] || return 1

	local pane_journal_dir="${pane_journal_file%/*}"
	/bin/mkdir -p -- "$pane_journal_dir" 2>/dev/null || return 1
	return 0
}

_toastty_schedule_shared_history_import_if_needed() {
	[[ -z "${_TOASTTY_SHARED_HISTORY_IMPORTED:-}" ]] || return
	_TOASTTY_SHARED_HISTORY_IMPORT_PENDING=1
}

_toastty_schedule_pane_journal_import_if_needed() {
	[[ "${TOASTTY_LAUNCH_REASON:-}" == "restore" ]] || return
	[[ "${TOASTTY_PANE_JOURNAL_IMPORTED:-}" == "1" ]] && return
	[[ "${TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED:-}" == "1" ]] && return

	_TOASTTY_PANE_JOURNAL_IMPORT_PENDING=1
	export TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED=1
}

_toastty_load_shared_history_if_needed() {
	[[ -z "${_TOASTTY_SHARED_HISTORY_IMPORTED:-}" ]] || return

	local histfile="${HISTFILE:-}"
	if [[ -n "$histfile" && -r "$histfile" ]]; then
		builtin history -n "$histfile"
	fi
	_TOASTTY_SHARED_HISTORY_IMPORTED=1
}

_toastty_read_last_history_line() {
	_TOASTTY_LAST_HISTORY_NUMBER=0
	_TOASTTY_LAST_HISTORY_ENTRY=""

	local history_output=""
	history_output=$(LC_ALL=C HISTTIMEFORMAT='' builtin history 1 2>/dev/null)
	[[ -n "$history_output" ]] || return

	local entry="$history_output"
	entry="${entry#"${entry%%[![:space:]]*}"}"
	local history_number="${entry%%[!0-9]*}"
	if [[ -n "$history_number" ]]; then
		entry="${entry#"$history_number"}"
		entry="${entry#"${entry%%[![:space:]]*}"}"
	fi

	_TOASTTY_LAST_HISTORY_NUMBER="${history_number:-0}"
	_TOASTTY_LAST_HISTORY_ENTRY="$entry"
}

_toastty_import_startup_history_if_needed() {
	[[ -n "${_TOASTTY_SHARED_HISTORY_IMPORT_PENDING:-}" || -n "${_TOASTTY_PANE_JOURNAL_IMPORT_PENDING:-}" ]] || return

	unset _TOASTTY_SHARED_HISTORY_IMPORT_PENDING
	_toastty_load_shared_history_if_needed

	[[ -n "${_TOASTTY_PANE_JOURNAL_IMPORT_PENDING:-}" ]] || return
	local pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
	if [[ -z "$pane_journal_file" || ! -r "$pane_journal_file" ]]; then
		unset _TOASTTY_PANE_JOURNAL_IMPORT_PENDING
		unset TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED
		export TOASTTY_PANE_JOURNAL_IMPORTED=1
		return
	fi

	local entry=""
	while IFS= read -r -d '' entry; do
		builtin history -s -- "$entry"
	done < "$pane_journal_file"

	unset _TOASTTY_PANE_JOURNAL_IMPORT_PENDING
	unset TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED
	export TOASTTY_PANE_JOURNAL_IMPORTED=1
}

_toastty_prepare_history_for_prompt_if_needed() {
	[[ -z "${_TOASTTY_PROMPT_HISTORY_READY:-}" ]] || return

	_toastty_import_startup_history_if_needed
	_toastty_read_last_history_line
	_TOASTTY_JOURNAL_LAST_HISTORY_NUMBER="${_TOASTTY_LAST_HISTORY_NUMBER:-0}"
	_TOASTTY_JOURNAL_LAST_HISTORY_ENTRY="${_TOASTTY_LAST_HISTORY_ENTRY:-}"
	_TOASTTY_PROMPT_HISTORY_READY=1
}

_toastty_initialize_pane_journal() {
	[[ -z "${_TOASTTY_PANE_JOURNAL_INITIALIZED:-}" ]] || return

	if _toastty_ensure_pane_journal_directory; then
		_toastty_schedule_shared_history_import_if_needed
		_toastty_schedule_pane_journal_import_if_needed
	fi

	_TOASTTY_PANE_JOURNAL_INITIALIZED=1
}

_toastty_append_last_history_entry_to_journal() {
	local pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
	[[ -n "$pane_journal_file" ]] || return

	# Bash's HISTCMD can stay pinned at 1 in the restored interactive shells
	# Toastty launches on macOS, even while the visible history tail advances.
	_toastty_read_last_history_line
	local current_history_number="${_TOASTTY_LAST_HISTORY_NUMBER:-0}"
	[[ "$current_history_number" =~ ^[0-9]+$ ]] || return
	local last_history_number="${_TOASTTY_JOURNAL_LAST_HISTORY_NUMBER:-0}"
	[[ "$last_history_number" =~ ^[0-9]+$ ]] || last_history_number=0
	(( current_history_number > last_history_number )) || return

	local entry="${_TOASTTY_LAST_HISTORY_ENTRY:-}"
	[[ -n "$entry" ]] || return
	_TOASTTY_JOURNAL_LAST_HISTORY_NUMBER="$current_history_number"
	_TOASTTY_JOURNAL_LAST_HISTORY_ENTRY="$entry"

	printf '%s\0' "$entry" >> "$pane_journal_file" 2>/dev/null || return
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
	if [[ -n "${_TOASTTY_PANE_JOURNAL_INITIALIZED:-}" ]]; then
		_toastty_prepare_history_for_prompt_if_needed
		_toastty_append_last_history_entry_to_journal
	fi
	local cwd="${PWD/#$HOME/~}"
	_toastty_emit_title "$cwd"
}

if [[ $- == *i* ]]; then
	_toastty_restore_agent_shim_path
	_toastty_initialize_pane_journal
	if [[ -z "${_TOASTTY_TITLE_HOOKS_INSTALLED:-}" ]]; then
		PROMPT_COMMAND="_toastty_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
		_TOASTTY_TITLE_HOOKS_INSTALLED=1
	fi
fi
```

Then add this near the end of `~/.bash_profile` on macOS, or `~/.bashrc` if that is the interactive file your Bash sessions already load:

```bash
source "$HOME/.toastty/shell/toastty-profile-shell-integration.bash"
```

The Bash snippet loads the readable `HISTFILE` once per shell before restore-time pane history import, so fresh shells see shared-history search immediately while restored pane-local commands stay at the top of recall.

## Fish

Toastty installs the managed fish snippet at `~/.toastty/shell/toastty-profile-shell-integration.fish` and sources it from `~/.config/fish/config.fish`:

```fish
source "$HOME/.toastty/shell/toastty-profile-shell-integration.fish"
```

The fish snippet uses `fish_prompt`, `fish_preexec`, and `fish_postexec` events to keep pane titles current and maintain the pane-local restore journal.

Fish-specific behavior:

- Commands that start with a leading space are skipped, matching fish's default hidden-from-history behavior.
- If `fish_history` is set to the empty string, Toastty skips pane-journal import and writes for that session.
- Custom `fish_should_add_to_history` filtering is not mirrored yet. Toastty's first fish slice only applies the built-in leading-space and `fish_history=''` checks.

## Other shells

Install an equivalent interactive hook that writes `OSC 2` (`\033]2;...\a`) to `/dev/tty` with the current working directory whenever the prompt returns. If your shell also has a pre-exec hook, emitting the current command there is useful too, but the prompt-time directory title is the important part for profiled multiplexer sessions. Toastty's managed restore-journal wiring is currently provided for `zsh`, `bash`, and `fish` only.

## Related docs

- [README](../README.md)
- [Configuration](configuration.md)
- [Terminal Profiles](terminal-profiles.md)
