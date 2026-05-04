import CoreState
import Darwin
import Foundation

enum ProfileShellIntegrationShell: CaseIterable, Equatable, Sendable {
    static let defaultPaneJournalEntryCount = 5_000
    static let paneJournalCompactionInterval = 250

    case zsh
    case bash
    case fish

    var displayName: String {
        switch self {
        case .zsh:
            return "Zsh"
        case .bash:
            return "Bash"
        case .fish:
            return "Fish"
        }
    }

    var managedSnippetFileName: String {
        switch self {
        case .zsh:
            return "toastty-profile-shell-integration.zsh"
        case .bash:
            return "toastty-profile-shell-integration.bash"
        case .fish:
            return "toastty-profile-shell-integration.fish"
        }
    }

    var managedSnippetRelativePath: String {
        ".toastty/shell/\(managedSnippetFileName)"
    }

    var defaultInitFileName: String {
        switch self {
        case .zsh:
            return ".zshrc"
        case .bash:
            return ".bash_profile"
        case .fish:
            return ".config/fish/config.fish"
        }
    }

    var candidateInitFileNames: [String] {
        switch self {
        case .zsh:
            return [".zshrc"]
        case .bash:
            return [".bash_profile", ".profile"]
        case .fish:
            return [".config/fish/config.fish"]
        }
    }

    var sourceLine: String {
        "source \"$HOME/\(managedSnippetRelativePath)\""
    }

    var managedSnippetContents: String {
        switch self {
        case .zsh:
            return """
            # Toastty terminal profile shell integration.
            # - idle prompt: cwd
            # - running command: command
            _toastty_restore_agent_shim_path() {
            \tlocal shim_dir="${TOASTTY_AGENT_SHIM_DIR:-}"
            \t[[ -n "$shim_dir" ]] || return

            \ttypeset -gaU path
            \tpath=("$shim_dir" "${(@)path:#$shim_dir}")
            \texport PATH
            }

            _toastty_ensure_pane_journal_directory() {
            \tlocal pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
            \t[[ -n "$pane_journal_file" ]] || return 1

            \tlocal pane_journal_dir="${pane_journal_file:h}"
            \t/bin/mkdir -p -- "$pane_journal_dir" 2>/dev/null || return 1
            \treturn 0
            }

            _toastty_compact_pane_journal() {
            \tlocal pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
            \t[[ -n "$pane_journal_file" && -r "$pane_journal_file" ]] || return

            \tlocal -a entries=()
            \tlocal entry=""
            \twhile IFS= read -r -d '' entry; do
            \t\tentries+=("$entry")
            \tdone < "$pane_journal_file"

            \tlocal total_entries=${#entries[@]}
            \tlocal max_entries=\(Self.defaultPaneJournalEntryCount)
            \t(( total_entries > max_entries )) || return

            \tlocal start_index=$(( total_entries - max_entries + 1 ))
            \tlocal temp_file="${pane_journal_file}.tmp.$$"
            \t: > "$temp_file" || return

            \tlocal index
            \tfor (( index = start_index; index <= total_entries; ++index )); do
            \t\tprintf '%s\\0' "${entries[index]}" >> "$temp_file" || {
            \t\t\t/bin/rm -f -- "$temp_file"
            \t\t\treturn
            \t\t}
            \tdone

            \t/bin/mv -f -- "$temp_file" "$pane_journal_file" 2>/dev/null || /bin/rm -f -- "$temp_file"
            }

            _toastty_schedule_pane_journal_import_if_needed() {
            \t[[ "${TOASTTY_LAUNCH_REASON:-}" == "restore" ]] || return
            \t[[ "${TOASTTY_PANE_JOURNAL_IMPORTED:-}" == "1" ]] && return
            \t[[ "${TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED:-}" == "1" ]] && return

            \ttypeset -g _TOASTTY_PANE_JOURNAL_IMPORT_PENDING=1
            \t# Export the scheduled state so nested restore shells spawned before the first
            \t# prompt do not re-import the same pane journal ahead of the parent shell.
            \texport TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED=1
            }

            _toastty_import_pane_journal_if_needed() {
            \t[[ "${_TOASTTY_PANE_JOURNAL_IMPORT_PENDING:-}" == "1" ]] || return

            \tlocal pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
            \tif [[ -z "$pane_journal_file" || ! -r "$pane_journal_file" ]]; then
            \t\tunset _TOASTTY_PANE_JOURNAL_IMPORT_PENDING
            \t\tunset TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED
            \t\texport TOASTTY_PANE_JOURNAL_IMPORTED=1
            \t\treturn
            \tfi

            \tlocal entry=""
            \twhile IFS= read -r -d '' entry; do
            \t\tprint -sr -- "$entry"
            \tdone < "$pane_journal_file"
            \tunset _TOASTTY_PANE_JOURNAL_IMPORT_PENDING
            \tunset TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED
            \texport TOASTTY_PANE_JOURNAL_IMPORTED=1
            }

            _toastty_initialize_pane_journal() {
            \t[[ -z ${_TOASTTY_PANE_JOURNAL_INITIALIZED:-} ]] || return

            \tif _toastty_ensure_pane_journal_directory; then
            \t\t_toastty_compact_pane_journal
            \t\t_toastty_schedule_pane_journal_import_if_needed
            \t\t# Re-sourcing can leave shell-local state behind; clear it before hooks install.
            \t\tunset _TOASTTY_PENDING_JOURNAL_ENTRY
            \tfi
            \ttypeset -g _TOASTTY_PANE_JOURNAL_INITIALIZED=1
            }

            _toastty_command_should_write_pane_journal() {
            \tlocal cmd="$1"
            \t[[ -n "$cmd" ]] || return 1

            \tif [[ -o hist_ignore_space ]]; then
            \t\tcase "$cmd" in
            \t\t([[:space:]]*) return 1 ;;
            \t\tesac
            \tfi

            \treturn 0
            }

            _toastty_append_pending_history_entry_to_journal() {
            \tlocal pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
            \tif [[ -z "$pane_journal_file" ]]; then
            \t\treturn
            \tfi

            \tif (( ! ${+_TOASTTY_PENDING_JOURNAL_ENTRY} )); then
            \t\treturn
            \tfi

            \tlocal entry="${_TOASTTY_PENDING_JOURNAL_ENTRY}"

            \tif ! printf '%s\\0' "$entry" >> "$pane_journal_file" 2>/dev/null; then
            \t\treturn
            \tfi

            \tunset _TOASTTY_PENDING_JOURNAL_ENTRY
            \ttypeset -g _TOASTTY_PANE_JOURNAL_WRITE_COUNT="$(( ${_TOASTTY_PANE_JOURNAL_WRITE_COUNT:-0} + 1 ))"
            \tif (( _TOASTTY_PANE_JOURNAL_WRITE_COUNT % \(Self.paneJournalCompactionInterval) == 0 )); then
            \t\t_toastty_compact_pane_journal
            \tfi
            }

            _toastty_emit_title() {
            \t[[ -t 1 ]] || return
            \t[[ -w /dev/tty ]] || return

            \tlocal title="$1"
            \ttitle="${title//$'\\e'/}"
            \ttitle="${title//$'\\a'/}"
            \ttitle="${title//$'\\r'/}"
            \ttitle="${title//$'\\n'/ }"

            \tprintf '\\033]2;%s\\a' "$title" > /dev/tty
            }

            _toastty_precmd() {
            \tif [[ -n ${_TOASTTY_PANE_JOURNAL_INITIALIZED:-} ]]; then
            \t\t_toastty_import_pane_journal_if_needed
            \t\t_toastty_append_pending_history_entry_to_journal
            \tfi
            \tlocal cwd="${PWD/#$HOME/~}"
            \t_toastty_emit_title "$cwd"
            }

            _toastty_preexec() {
            \tlocal entry="$1"
            \t# Keep multiline commands intact in the journal; titles use the first line.
            \tlocal cmd="${entry%%$'\\n'*}"

            \tunset _TOASTTY_PENDING_JOURNAL_ENTRY
            \tif _toastty_command_should_write_pane_journal "$entry"; then
            \t\ttypeset -g _TOASTTY_PENDING_JOURNAL_ENTRY="$entry"
            \tfi
            \t_toastty_emit_title "$cmd"
            }

            if [[ -o interactive ]]; then
            \t_toastty_restore_agent_shim_path
            \t_toastty_initialize_pane_journal
            \tif [[ -z ${_TOASTTY_TITLE_HOOKS_INSTALLED:-} ]]; then
            \t\tautoload -Uz add-zsh-hook
            \t\tadd-zsh-hook precmd _toastty_precmd
            \t\tadd-zsh-hook preexec _toastty_preexec
            \t\ttypeset -g _TOASTTY_TITLE_HOOKS_INSTALLED=1
            \tfi
            fi
            """
        case .bash:
            return """
            # Toastty terminal profile shell integration.
            # Updates the pane title to the current directory whenever the prompt returns.
            _toastty_restore_agent_shim_path() {
            \tlocal shim_dir="${TOASTTY_AGENT_SHIM_DIR:-}"
            \t[[ -n "$shim_dir" ]] || return

            \tlocal entry=""
            \tlocal old_path="${PATH:-}"
            \tlocal IFS=':'
            \tlocal -a path_entries=()
            \tread -r -a path_entries <<< "$old_path"

            \tPATH="$shim_dir"
            \tfor entry in "${path_entries[@]}"; do
            \t\t[[ -n "$entry" && "$entry" != "$shim_dir" ]] || continue
            \t\tPATH+=":$entry"
            \tdone
            \texport PATH
            }

            _toastty_ensure_pane_journal_directory() {
            \tlocal pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
            \t[[ -n "$pane_journal_file" ]] || return 1

            \tlocal pane_journal_dir="${pane_journal_file%/*}"
            \t/bin/mkdir -p -- "$pane_journal_dir" 2>/dev/null || return 1
            \treturn 0
            }

            _toastty_compact_pane_journal() {
            \tlocal pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
            \t[[ -n "$pane_journal_file" && -r "$pane_journal_file" ]] || return

            \tlocal -a entries=()
            \tlocal entry=""
            \twhile IFS= read -r -d '' entry; do
            \t\tentries+=("$entry")
            \tdone < "$pane_journal_file"

            \tlocal total_entries="${#entries[@]}"
            \tlocal max_entries=\(Self.defaultPaneJournalEntryCount)
            (( total_entries > max_entries )) || return

            \tlocal start_index=$(( total_entries - max_entries ))
            \tlocal temp_file="${pane_journal_file}.tmp.$$"
            \t: > "$temp_file" || return

            \tlocal index
            \tfor (( index = start_index; index < total_entries; ++index )); do
            \t\tprintf '%s\\0' "${entries[index]}" >> "$temp_file" || {
            \t\t\t/bin/rm -f -- "$temp_file"
            \t\t\treturn
            \t\t}
            \tdone

            \t/bin/mv -f -- "$temp_file" "$pane_journal_file" 2>/dev/null || /bin/rm -f -- "$temp_file"
            }

            _toastty_schedule_shared_history_import_if_needed() {
            \t[[ -z "${_TOASTTY_SHARED_HISTORY_IMPORTED:-}" ]] || return
            \t_TOASTTY_SHARED_HISTORY_IMPORT_PENDING=1
            }

            _toastty_schedule_pane_journal_import_if_needed() {
            \t[[ "${TOASTTY_LAUNCH_REASON:-}" == "restore" ]] || return
            \t[[ "${TOASTTY_PANE_JOURNAL_IMPORTED:-}" == "1" ]] && return
            \t[[ "${TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED:-}" == "1" ]] && return

            \t_TOASTTY_PANE_JOURNAL_IMPORT_PENDING=1
            \t# Export the scheduled state so nested restore shells spawned before the first
            \t# prompt do not re-import the same pane journal ahead of the parent shell.
            \texport TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED=1
            }

            _toastty_load_shared_history_if_needed() {
            \t[[ -z "${_TOASTTY_SHARED_HISTORY_IMPORTED:-}" ]] || return

            \tlocal histfile="${HISTFILE:-}"
            \tif [[ -n "$histfile" && -r "$histfile" ]]; then
            \t\tbuiltin history -n "$histfile"
            \tfi
            \t_TOASTTY_SHARED_HISTORY_IMPORTED=1
            }

            _toastty_read_last_history_line() {
            \t_TOASTTY_LAST_HISTORY_NUMBER=0
            \t_TOASTTY_LAST_HISTORY_ENTRY=""

            \tlocal history_output=""
            \thistory_output=$(LC_ALL=C HISTTIMEFORMAT='' builtin history 1 2>/dev/null)
            \t[[ -n "$history_output" ]] || return

            \tlocal entry="$history_output"
            \tentry="${entry#"${entry%%[![:space:]]*}"}"
            \tlocal history_number="${entry%%[!0-9]*}"
            \tif [[ -n "$history_number" ]]; then
            \t\tentry="${entry#"$history_number"}"
            \t\tentry="${entry#"${entry%%[![:space:]]*}"}"
            \tfi

            \t_TOASTTY_LAST_HISTORY_NUMBER="${history_number:-0}"
            \t_TOASTTY_LAST_HISTORY_ENTRY="$entry"
            }

            _toastty_import_startup_history_if_needed() {
            \t[[ -n "${_TOASTTY_SHARED_HISTORY_IMPORT_PENDING:-}" || -n "${_TOASTTY_PANE_JOURNAL_IMPORT_PENDING:-}" ]] || return

            \tunset _TOASTTY_SHARED_HISTORY_IMPORT_PENDING
            \t_toastty_load_shared_history_if_needed

            \t[[ -n "${_TOASTTY_PANE_JOURNAL_IMPORT_PENDING:-}" ]] || return
            \tlocal pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
            \tif [[ -z "$pane_journal_file" || ! -r "$pane_journal_file" ]]; then
            \t\tunset _TOASTTY_PANE_JOURNAL_IMPORT_PENDING
            \t\tunset TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED
            \t\texport TOASTTY_PANE_JOURNAL_IMPORTED=1
            \t\treturn
            \tfi

            \tlocal entry=""
            \twhile IFS= read -r -d '' entry; do
            \t\tbuiltin history -s -- "$entry"
            \tdone < "$pane_journal_file"

            \tunset _TOASTTY_PANE_JOURNAL_IMPORT_PENDING
            \tunset TOASTTY_PANE_JOURNAL_IMPORT_SCHEDULED
            \texport TOASTTY_PANE_JOURNAL_IMPORTED=1
            }

            _toastty_prepare_history_for_prompt_if_needed() {
            \t[[ -z "${_TOASTTY_PROMPT_HISTORY_READY:-}" ]] || return

            \t_toastty_import_startup_history_if_needed
            \t_toastty_read_last_history_line
            \t_TOASTTY_JOURNAL_LAST_HISTORY_NUMBER="${_TOASTTY_LAST_HISTORY_NUMBER:-0}"
            \t_TOASTTY_JOURNAL_LAST_HISTORY_ENTRY="${_TOASTTY_LAST_HISTORY_ENTRY:-}"
            \t_TOASTTY_PROMPT_HISTORY_READY=1
            }

            _toastty_initialize_pane_journal() {
            \t[[ -z "${_TOASTTY_PANE_JOURNAL_INITIALIZED:-}" ]] || return

            \tif _toastty_ensure_pane_journal_directory; then
            \t\t_toastty_compact_pane_journal
            \t\t_toastty_schedule_shared_history_import_if_needed
            \t\t_toastty_schedule_pane_journal_import_if_needed
            \tfi
            \t_TOASTTY_PANE_JOURNAL_INITIALIZED=1
            }

            _toastty_append_last_history_entry_to_journal() {
            \tlocal pane_journal_file="${TOASTTY_PANE_JOURNAL_FILE:-}"
            \tif [[ -z "$pane_journal_file" ]]; then
            \t\treturn
            \tfi

            \t# Bash's HISTCMD can remain pinned at 1 in the restored interactive shells
            \t# Toastty launches on macOS, even when the visible history tail advances.
            \t# Use the actual history line number from `history 1` as the append gate.
            \t_toastty_read_last_history_line
            \tlocal current_history_number="${_TOASTTY_LAST_HISTORY_NUMBER:-0}"
            \tif [[ ! "$current_history_number" =~ ^[0-9]+$ ]]; then
            \t\treturn
            \tfi
            \tlocal last_history_number="${_TOASTTY_JOURNAL_LAST_HISTORY_NUMBER:-0}"
            \t[[ "$last_history_number" =~ ^[0-9]+$ ]] || last_history_number=0
            \tif (( current_history_number <= last_history_number )); then
            \t\treturn
            \tfi

            \tlocal entry="${_TOASTTY_LAST_HISTORY_ENTRY:-}"
            \tif [[ -z "$entry" ]]; then
            \t\treturn
            \tfi

            \t_TOASTTY_JOURNAL_LAST_HISTORY_NUMBER="$current_history_number"
            \t_TOASTTY_JOURNAL_LAST_HISTORY_ENTRY="$entry"

            \tif ! printf '%s\\0' "$entry" >> "$pane_journal_file" 2>/dev/null; then
            \t\treturn
            \tfi

            \t_TOASTTY_PANE_JOURNAL_WRITE_COUNT="$(( ${_TOASTTY_PANE_JOURNAL_WRITE_COUNT:-0} + 1 ))"
            \tif (( _TOASTTY_PANE_JOURNAL_WRITE_COUNT % \(Self.paneJournalCompactionInterval) == 0 )); then
            \t\t_toastty_compact_pane_journal
            \tfi
            }

            _toastty_emit_title() {
            \t[[ $- == *i* ]] || return
            \t[[ -t 1 ]] || return
            \t[[ -w /dev/tty ]] || return

            \tlocal title="$1"
            \ttitle="${title//$'\\e'/}"
            \ttitle="${title//$'\\a'/}"
            \ttitle="${title//$'\\r'/}"
            \ttitle="${title//$'\\n'/ }"

            \tprintf '\\033]2;%s\\a' "$title" > /dev/tty
            }

            _toastty_prompt_command() {
            \tif [[ -n "${_TOASTTY_PANE_JOURNAL_INITIALIZED:-}" ]]; then
            \t\t_toastty_prepare_history_for_prompt_if_needed
            \t\t_toastty_append_last_history_entry_to_journal
            \tfi
            \tlocal cwd="${PWD/#$HOME/~}"
            \t_toastty_emit_title "$cwd"
            }

            if [[ $- == *i* ]]; then
            \t_toastty_restore_agent_shim_path
            \t_toastty_initialize_pane_journal
            \tif [[ -z "${_TOASTTY_TITLE_HOOKS_INSTALLED:-}" ]]; then
            \t\tPROMPT_COMMAND="_toastty_prompt_command${PROMPT_COMMAND:+;$PROMPT_COMMAND}"
            \t\t_TOASTTY_TITLE_HOOKS_INSTALLED=1
            \tfi
            fi
            """
        case .fish:
            return """
            # Toastty terminal profile shell integration.
            # - idle prompt: cwd
            # - running command: command
            if not status --is-interactive
            \treturn
            end

            function _toastty_restore_agent_shim_path
            \tset --local shim_dir "$TOASTTY_AGENT_SHIM_DIR"
            \ttest -n "$shim_dir"; or return

            \tset --local updated_path "$shim_dir"
            \tfor entry in $PATH
            \t\ttest -n "$entry"; or continue
            \t\ttest "$entry" = "$shim_dir"; and continue
            \t\tset updated_path $updated_path "$entry"
            \tend
            \tset --export PATH $updated_path
            end

            function _toastty_ensure_pane_journal_directory
            \tset --local pane_journal_file "$TOASTTY_PANE_JOURNAL_FILE"
            \ttest -n "$pane_journal_file"; or return 1

            \tset --local pane_journal_dir (/usr/bin/dirname "$pane_journal_file")
            \ttest -n "$pane_journal_dir"; or return 1

            \t/bin/mkdir -p -- "$pane_journal_dir" 2>/dev/null; or return 1
            \treturn 0
            end

            function _toastty_make_pane_journal_snapshot --argument-names output_path
            \tset --local pane_journal_file "$TOASTTY_PANE_JOURNAL_FILE"
            \ttest -n "$pane_journal_file"; or return 1
            \ttest -r "$pane_journal_file"; or return 1

            \t/usr/bin/perl -0777 -ne 's/[^\\0]*\\z//s unless /\\0\\z/s; print' -- "$pane_journal_file" > "$output_path" 2>/dev/null
            \tor begin
            \t\t/bin/rm -f -- "$output_path"
            \t\treturn 1
            \tend
            \treturn 0
            end

            function _toastty_compact_pane_journal
            \tset --local pane_journal_file "$TOASTTY_PANE_JOURNAL_FILE"
            \ttest -n "$pane_journal_file"; or return
            \ttest -r "$pane_journal_file"; or return

            \tset --local snapshot_path (/usr/bin/mktemp "$pane_journal_file.snapshot.XXXXXX" 2>/dev/null)
            \ttest -n "$snapshot_path"; or return
            \t_toastty_make_pane_journal_snapshot "$snapshot_path"; or begin
            \t\t/bin/rm -f -- "$snapshot_path"
            \t\treturn
            \tend

            \tset --local entries
            \twhile read --null --local entry
            \t\tset entries $entries "$entry"
            \tend < "$snapshot_path"
            \t/bin/rm -f -- "$snapshot_path"

            \tset --local total_entries (count $entries)
            \tset --local max_entries \(Self.defaultPaneJournalEntryCount)
            \ttest $total_entries -gt $max_entries; or return

            \tset --local start_index (math "$total_entries - $max_entries + 1")
            \tset --local temp_file "$pane_journal_file.tmp.$fish_pid"
            \tprintf '' > "$temp_file"; or return

            \tfor index in (seq $start_index $total_entries)
            \t\tprintf '%s\\0' "$entries[$index]" >> "$temp_file"
            \t\tor begin
            \t\t\t/bin/rm -f -- "$temp_file"
            \t\t\treturn
            \t\tend
            \tend

            \t/bin/mv -f -- "$temp_file" "$pane_journal_file" 2>/dev/null
            \tor /bin/rm -f -- "$temp_file"
            end

            function _toastty_fish_history_file_path
            \tset --local history_session "$fish_history"
            \ttest -n "$history_session"; or set history_session fish
            \ttest "$history_session" = "default"; and set history_session fish

            \tset --local data_home "$XDG_DATA_HOME"
            \ttest -n "$data_home"; or set data_home "$HOME/.local/share"
            \ttest -n "$data_home"; or return 1

            \tprintf '%s/fish/%s_history\\n' "$data_home" "$history_session"
            end

            function _toastty_import_pane_journal_if_needed
            \ttest "$TOASTTY_LAUNCH_REASON" = "restore"; or return
            \ttest "$TOASTTY_PANE_JOURNAL_IMPORTED" = "1"; and return

            \tif set -q fish_history; and test -z "$fish_history"
            \t\treturn
            \tend

            \tset --local pane_journal_file "$TOASTTY_PANE_JOURNAL_FILE"
            \ttest -n "$pane_journal_file"; or return
            \ttest -r "$pane_journal_file"; or return

            \tset --local snapshot_path (/usr/bin/mktemp "$pane_journal_file.snapshot.XXXXXX" 2>/dev/null)
            \ttest -n "$snapshot_path"; or return
            \t_toastty_make_pane_journal_snapshot "$snapshot_path"; or begin
            \t\t/bin/rm -f -- "$snapshot_path"
            \t\treturn
            \tend

            \tset --local history_file (_toastty_fish_history_file_path 2>/dev/null)
            \tset --local history_file_existed 0
            \tset --local history_snapshot_path
            \tif test -n "$history_file" -a -e "$history_file"
            \t\tset history_file_existed 1
            \t\tset history_snapshot_path (/usr/bin/mktemp "$history_file.snapshot.XXXXXX" 2>/dev/null)
            \t\tif test -n "$history_snapshot_path"
            \t\t\t/bin/cp -p -- "$history_file" "$history_snapshot_path" 2>/dev/null
            \t\t\tor begin
            \t\t\t\t/bin/rm -f -- "$history_snapshot_path"
            \t\t\t\tset --erase history_snapshot_path
            \t\t\tend
            \t\tend
            \tend

            \twhile read --null --local entry
            \t\tbuiltin history append -- "$entry"
            \tend < "$snapshot_path"
            \t/bin/rm -f -- "$snapshot_path"

            \tif test "$history_file_existed" = "1"
            \t\tif test -n "$history_snapshot_path" -a -r "$history_snapshot_path"
            \t\t\t/bin/mv -f -- "$history_snapshot_path" "$history_file" 2>/dev/null
            \t\t\tor /bin/rm -f -- "$history_snapshot_path"
            \t\tend
            \telse if test -n "$history_file"
            \t\t/bin/rm -f -- "$history_file" "$history_snapshot_path"
            \tend
            end

            function _toastty_initialize_pane_journal
            \tset -q _TOASTTY_PANE_JOURNAL_INITIALIZED; and return

            \tif _toastty_ensure_pane_journal_directory
            \t\t_toastty_compact_pane_journal
            \t\t_toastty_import_pane_journal_if_needed
            \tend

            \ttest "$TOASTTY_LAUNCH_REASON" = "restore"
            \tand set --global --export TOASTTY_PANE_JOURNAL_IMPORTED 1

            \tset --global _TOASTTY_PANE_JOURNAL_INITIALIZED 1
            end

            function _toastty_command_should_write_pane_journal --argument-names cmd
            \ttest -n "$cmd"; or return 1

            \tif set -q fish_history; and test -z "$fish_history"
            \t\treturn 1
            \tend

            \tstring match -qr '^ ' -- "$cmd"; and return 1
            \treturn 0
            end

            function _toastty_append_pending_history_entry_to_journal
            \tset -q _TOASTTY_PENDING_JOURNAL_ENTRY; or return

            \tset --local pane_journal_file "$TOASTTY_PANE_JOURNAL_FILE"
            \ttest -n "$pane_journal_file"; or begin
            \t\tset --erase _TOASTTY_PENDING_JOURNAL_ENTRY
            \t\treturn
            \tend

            \tprintf '%s\\0' "$_TOASTTY_PENDING_JOURNAL_ENTRY" >> "$pane_journal_file" 2>/dev/null
            \tor begin
            \t\tset --erase _TOASTTY_PENDING_JOURNAL_ENTRY
            \t\treturn
            \tend

            \tset --erase _TOASTTY_PENDING_JOURNAL_ENTRY

            \tset --local write_count 0
            \tset -q _TOASTTY_PANE_JOURNAL_WRITE_COUNT
            \tand set write_count $_TOASTTY_PANE_JOURNAL_WRITE_COUNT
            \tset write_count (math "$write_count + 1")
            \tset --global _TOASTTY_PANE_JOURNAL_WRITE_COUNT $write_count

            \tset --local compaction_interval \(Self.paneJournalCompactionInterval)
            \ttest $compaction_interval -gt 0; or return
            \ttest (math "$write_count % $compaction_interval") -eq 0
            \tand _toastty_compact_pane_journal
            end

            function _toastty_emit_title --argument-names title
            \ttest -t 1; or return
            \ttest -w /dev/tty; or return

            \tset --local sanitized_title "$title"
            \tset sanitized_title (string replace -a -- (printf '\\033') '' -- "$sanitized_title")
            \tset sanitized_title (string replace -a -- (printf '\\a') '' -- "$sanitized_title")
            \tset sanitized_title (string replace -a -- (printf '\\r') '' -- "$sanitized_title")
            \tset sanitized_title (string replace -a -- (printf '\\n') ' ' -- "$sanitized_title")

            \tprintf '\\033]2;%s\\a' "$sanitized_title" > /dev/tty
            end

            function _toastty_on_fish_prompt --on-event fish_prompt
            \t_toastty_emit_title (prompt_pwd)
            end

            function _toastty_on_fish_preexec --on-event fish_preexec --argument-names cmd
            \tset --erase _TOASTTY_PENDING_JOURNAL_ENTRY
            \t_toastty_emit_title "$cmd"

            \t_toastty_command_should_write_pane_journal "$cmd"
            \tand set --global _TOASTTY_PENDING_JOURNAL_ENTRY "$cmd"
            end

            function _toastty_on_fish_postexec --on-event fish_postexec --argument-names cmd
            \t_toastty_append_pending_history_entry_to_journal
            end

            _toastty_restore_agent_shim_path
            _toastty_initialize_pane_journal
            """
        }
    }

    func preferredInitFileURL(homeDirectoryURL: URL, fileManager: FileManager) -> URL {
        switch self {
        case .zsh:
            return homeDirectoryURL.appendingPathComponent(defaultInitFileName)
        case .bash:
            let candidates = [".bash_profile", ".profile"]
            for candidate in candidates {
                let candidateURL = homeDirectoryURL.appendingPathComponent(candidate)
                var isDirectory = ObjCBool(false)
                if fileManager.fileExists(atPath: candidateURL.path, isDirectory: &isDirectory),
                   isDirectory.boolValue == false {
                    return candidateURL
                }
            }
            return homeDirectoryURL.appendingPathComponent(defaultInitFileName)
        case .fish:
            // Keep fish on the existing installer model by sourcing Toastty's managed
            // snippet from config.fish instead of introducing a fish-only conf.d flow.
            return homeDirectoryURL.appendingPathComponent(defaultInitFileName)
        }
    }

    func candidateInitFileURLs(homeDirectoryURL: URL) -> [URL] {
        candidateInitFileNames.map { homeDirectoryURL.appendingPathComponent($0) }
    }
}

struct ProfileShellIntegrationInstallPlan: Equatable, Sendable {
    let shell: ProfileShellIntegrationShell
    let initFileURL: URL
    let managedSnippetURL: URL

    var sourceLine: String {
        shell.sourceLine
    }
}

struct ProfileShellIntegrationInstallStatus: Equatable, Sendable {
    let plan: ProfileShellIntegrationInstallPlan
    let needsManagedSnippetWrite: Bool
    let needsInitFileUpdate: Bool
    let createsInitFile: Bool

    var isInstalled: Bool {
        needsManagedSnippetWrite == false && needsInitFileUpdate == false
    }
}

struct ProfileShellIntegrationInstallResult: Equatable, Sendable {
    let plan: ProfileShellIntegrationInstallPlan
    let updatedManagedSnippet: Bool
    let updatedInitFile: Bool
    let createdInitFile: Bool
}

enum ProfileShellIntegrationInstallerError: LocalizedError, Equatable, Sendable {
    case unsupportedShell(shellPath: String?)
    case runtimeHomeUnsupported(path: String)
    case unableToReadFile(path: String, reason: String)
    case unableToWriteFile(path: String, reason: String)

    var errorDescription: String? {
        switch self {
        case .unsupportedShell(let shellPath):
            let resolvedShell = shellPath?.isEmpty == false ? shellPath! : "unknown"
            return """
            Toastty can install shell integration for zsh, bash, and fish only. Detected shell: \(resolvedShell)

            For other shells, add an equivalent OSC 2 title hook manually in your shell init file.
            """
        case .runtimeHomeUnsupported(let path):
            return """
            Shell integration is disabled while Toastty is running with runtime isolation enabled at \(path).

            Sandboxed dev/test runs must not rewrite your login shell files.
            """
        case .unableToReadFile(let path, let reason):
            return "Unable to read \(path): \(reason)"
        case .unableToWriteFile(let path, let reason):
            return "Unable to write \(path): \(reason)"
        }
    }
}

enum ProfileShellIntegrationResolvedShellSource: String, Sendable {
    case debugOverride = "debug_override"
    case preferredShellPath = "preferred_shell_path"
    case liveTerminalShell = "live_terminal_shell"
    case environmentShell = "environment_shell"
    case loginShell = "login_shell"
}

private struct ProfileShellIntegrationResolvedShellPath: Equatable, Sendable {
    let path: String
    let source: ProfileShellIntegrationResolvedShellSource
}

final class ProfileShellIntegrationInstaller {
    private static let managedSourceCommentLines = [
        "# Added by Toastty terminal profile shell integration",
        "# Keep this near the end of this file, after other PATH, history, and prompt-hook changes,",
        "# so Toastty can restore its shim directory and prompt-time title/journal hooks.",
    ]
    #if DEBUG
    static let debugAllowRealInstallEnvironmentKey = "TOASTTY_DEBUG_ALLOW_REAL_SHELL_INTEGRATION_INSTALL"
    #endif

    private let fileManager: FileManager
    private let homeDirectoryURL: URL
    private let environment: [String: String]
    private let shellPathProvider: (() -> String?)?
    private let preferredShellPath: String?
    private let preferredShellSource: ProfileShellIntegrationResolvedShellSource

    init(
        homeDirectoryPath: String? = nil,
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        shellPathProvider: (() -> String?)? = nil,
        preferredShellPath: String? = nil,
        preferredShellSource: ProfileShellIntegrationResolvedShellSource = .preferredShellPath
    ) {
        self.fileManager = fileManager
        if let homeDirectoryPath {
            homeDirectoryURL = URL(fileURLWithPath: homeDirectoryPath, isDirectory: true)
        } else {
            homeDirectoryURL = fileManager.homeDirectoryForCurrentUser
        }
        self.environment = environment
        self.shellPathProvider = shellPathProvider
        self.preferredShellPath = preferredShellPath
        self.preferredShellSource = preferredShellSource
    }

    func installationPlan() throws -> ProfileShellIntegrationInstallPlan {
        let runtimePaths = ToasttyRuntimePaths.resolve(
            homeDirectoryPath: homeDirectoryURL.path,
            environment: environment
        )
        if let runtimeHomeURL = runtimePaths.runtimeHomeURL,
           Self.debugAllowsRealInstall(environment: environment) == false {
            throw ProfileShellIntegrationInstallerError.runtimeHomeUnsupported(path: runtimeHomeURL.path)
        }

        let loginShellPath = Self.loginShellPath()
        let defaultShellResolution = Self.resolvedShell(
            environment: environment,
            loginShellPath: loginShellPath,
            preferredShellPath: preferredShellPath,
            preferredShellSource: preferredShellSource
        )
        let customShellPath = shellPathProvider?()
        let shellPath = customShellPath ?? defaultShellResolution?.path
        guard let shell = Self.detectedShell(from: shellPath) else {
            ToasttyLog.warning(
                "Shell integration detection did not resolve to a supported shell",
                category: .bootstrap,
                metadata: Self.shellResolutionMetadata(
                    environment: environment,
                    loginShellPath: loginShellPath,
                    preferredShellPath: preferredShellPath,
                    preferredShellSource: preferredShellPath == nil ? nil : preferredShellSource,
                    defaultShellResolution: defaultShellResolution,
                    customShellPath: customShellPath,
                    resolvedShellPath: shellPath,
                    resolvedShell: nil
                )
            )
            throw ProfileShellIntegrationInstallerError.unsupportedShell(shellPath: shellPath)
        }

        ToasttyLog.info(
            "Resolved shell integration target shell",
            category: .bootstrap,
            metadata: Self.shellResolutionMetadata(
                environment: environment,
                loginShellPath: loginShellPath,
                preferredShellPath: preferredShellPath,
                preferredShellSource: preferredShellPath == nil ? nil : preferredShellSource,
                defaultShellResolution: defaultShellResolution,
                customShellPath: customShellPath,
                resolvedShellPath: shellPath,
                resolvedShell: shell
            )
        )

        return ProfileShellIntegrationInstallPlan(
            shell: shell,
            initFileURL: shell.preferredInitFileURL(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager),
            managedSnippetURL: homeDirectoryURL.appendingPathComponent(shell.managedSnippetRelativePath)
        )
    }

    func install() throws -> ProfileShellIntegrationInstallResult {
        try install(plan: installationPlan())
    }

    func refreshManagedSnippetIfInstalled() throws -> Bool {
        var updated = false

        for shell in ProfileShellIntegrationShell.allCases {
            let plan = ProfileShellIntegrationInstallPlan(
                shell: shell,
                initFileURL: shell.preferredInitFileURL(homeDirectoryURL: homeDirectoryURL, fileManager: fileManager),
                managedSnippetURL: homeDirectoryURL.appendingPathComponent(shell.managedSnippetRelativePath)
            )
            guard try shouldRefreshManagedSnippet(for: plan) else {
                continue
            }

            try ensureDirectoryExists(at: plan.managedSnippetURL.deletingLastPathComponent())
            if try writeManagedSnippet(for: plan) {
                updated = true
            }
        }

        return updated
    }

    func installationStatus() throws -> ProfileShellIntegrationInstallStatus {
        try installationStatus(plan: installationPlan())
    }

    func installationStatus(
        plan: ProfileShellIntegrationInstallPlan
    ) throws -> ProfileShellIntegrationInstallStatus {
        let initFileExists = fileManager.fileExists(atPath: plan.initFileURL.path)
        let initFileContents = try readFileIfPresent(at: plan.initFileURL)
        let managedSnippetContents = try readFileIfPresent(at: plan.managedSnippetURL)

        return ProfileShellIntegrationInstallStatus(
            plan: plan,
            needsManagedSnippetWrite: managedSnippetContents != expectedManagedSnippetContents(for: plan),
            needsInitFileUpdate: contents(initFileContents, referencesManagedSnippetFor: plan) == false,
            createsInitFile: initFileExists == false
        )
    }

    func install(plan: ProfileShellIntegrationInstallPlan) throws -> ProfileShellIntegrationInstallResult {
        try ensureDirectoryExists(at: plan.managedSnippetURL.deletingLastPathComponent())
        let updatedManagedSnippet = try writeManagedSnippet(for: plan)
        let initFileUpdate = try installSourceLine(for: plan)

        return ProfileShellIntegrationInstallResult(
            plan: plan,
            updatedManagedSnippet: updatedManagedSnippet,
            updatedInitFile: initFileUpdate.updated,
            createdInitFile: initFileUpdate.created
        )
    }

    private func shouldRefreshManagedSnippet(
        for plan: ProfileShellIntegrationInstallPlan
    ) throws -> Bool {
        if fileManager.fileExists(atPath: plan.managedSnippetURL.path) {
            return true
        }

        for initFileURL in plan.shell.candidateInitFileURLs(homeDirectoryURL: homeDirectoryURL) {
            let initFileContents = try readFileIfPresent(at: initFileURL)
            if contents(initFileContents, referencesManagedSnippetFor: plan) {
                return true
            }
        }

        return false
    }

    static func resolvedShellPath(
        environment: [String: String],
        loginShellPath: String?,
        preferredShellPath: String? = nil,
        preferredShellSource: ProfileShellIntegrationResolvedShellSource = .preferredShellPath
    ) -> String? {
        resolvedShell(
            environment: environment,
            loginShellPath: loginShellPath,
            preferredShellPath: preferredShellPath,
            preferredShellSource: preferredShellSource
        )?.path
    }

    private static func resolvedShell(
        environment: [String: String],
        loginShellPath: String?,
        preferredShellPath: String?,
        preferredShellSource: ProfileShellIntegrationResolvedShellSource
    ) -> ProfileShellIntegrationResolvedShellPath? {
        if let debugShellPath = debugShellPathOverride(environment: environment) {
            return ProfileShellIntegrationResolvedShellPath(
                path: debugShellPath,
                source: .debugOverride
            )
        }

        let normalizedPreferredShellPath = normalizedShellPath(from: preferredShellPath)
        if let normalizedPreferredShellPath,
           detectedShell(from: normalizedPreferredShellPath) != nil {
            return ProfileShellIntegrationResolvedShellPath(
                path: normalizedPreferredShellPath,
                source: preferredShellSource
            )
        }

        let environmentShellPath = normalizedShellPath(from: environment["SHELL"])
        if let environmentShellPath,
           detectedShell(from: environmentShellPath) != nil {
            return ProfileShellIntegrationResolvedShellPath(
                path: environmentShellPath,
                source: .environmentShell
            )
        }

        if let loginShellPath = normalizedShellPath(from: loginShellPath) {
            return ProfileShellIntegrationResolvedShellPath(
                path: loginShellPath,
                source: .loginShell
            )
        }

        return nil
    }

    static func debugRealInstallBypassNotice(environment: [String: String]) -> String? {
        guard debugAllowsRealInstall(environment: environment),
              ToasttyRuntimePaths.resolve(environment: environment).runtimeHomeURL != nil else {
            return nil
        }

        return """
        Debug override active: Toastty will install shell integration into your real shell files even though runtime isolation is enabled for this app run.
        """
    }

    private static func loginShellPath() -> String? {
        guard let passwdEntry = getpwuid(getuid()),
              let shellPointer = passwdEntry.pointee.pw_shell else {
            return nil
        }

        let shellPath = String(cString: shellPointer)
        return shellPath.isEmpty ? nil : shellPath
    }

    private static func detectedShell(from shellPath: String?) -> ProfileShellIntegrationShell? {
        guard let shellPath, shellPath.isEmpty == false else { return nil }
        let shellName = URL(fileURLWithPath: shellPath).lastPathComponent
        let normalizedShellName = shellName.hasPrefix("-")
            ? String(shellName.dropFirst()).lowercased()
            : shellName.lowercased()

        if normalizedShellName.hasPrefix("zsh") {
            return .zsh
        }
        if normalizedShellName.hasPrefix("bash") {
            return .bash
        }
        if normalizedShellName.hasPrefix("fish") {
            return .fish
        }
        return nil
    }

    private static func isEnabledFlag(_ rawValue: String?) -> Bool {
        switch rawValue?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "1", "true", "yes", "on":
            return true
        default:
            return false
        }
    }

    private static func debugAllowsRealInstall(environment: [String: String]) -> Bool {
        #if DEBUG
        return isEnabledFlag(environment[debugAllowRealInstallEnvironmentKey])
        #else
        return false
        #endif
    }

    private static func debugShellPathOverride(environment: [String: String]) -> String? {
        #if DEBUG
        guard debugAllowsRealInstall(environment: environment) else {
            return nil
        }
        return GhosttyDebugLoginShellOverride.normalizedShellPath(
            from: environment[GhosttyDebugLoginShellOverride.environmentKey]
        )
        #else
        return nil
        #endif
    }

    private static func normalizedShellPath(from rawValue: String?) -> String? {
        guard let trimmed = rawValue?.trimmingCharacters(in: .whitespacesAndNewlines),
              trimmed.isEmpty == false else {
            return nil
        }
        return trimmed
    }

    private static func shellResolutionMetadata(
        environment: [String: String],
        loginShellPath: String?,
        preferredShellPath: String?,
        preferredShellSource: ProfileShellIntegrationResolvedShellSource?,
        defaultShellResolution: ProfileShellIntegrationResolvedShellPath?,
        customShellPath: String?,
        resolvedShellPath: String?,
        resolvedShell: ProfileShellIntegrationShell?
    ) -> [String: String] {
        let debugShellPath = debugShellPathOverride(environment: environment)
        let environmentShellPath = normalizedShellPath(from: environment["SHELL"])
        let normalizedLoginShellPath = normalizedShellPath(from: loginShellPath)
        let normalizedPreferredShellPath = normalizedShellPath(from: preferredShellPath)
        let normalizedCustomShellPath = normalizedShellPath(from: customShellPath)

        var metadata: [String: String] = [
            "resolved_shell_source": shellResolutionSource(
                resolvedShellPath: resolvedShellPath,
                defaultShellResolution: defaultShellResolution,
                customShellPath: normalizedCustomShellPath
            ),
            "resolved_shell_supported": resolvedShell == nil ? "false" : "true",
        ]

        if let resolvedShellPath {
            metadata["resolved_shell_path"] = resolvedShellPath
        }
        if let resolvedShell {
            metadata["resolved_shell"] = resolvedShell.displayName.lowercased()
        }
        if let debugShellPath {
            metadata["debug_shell_path"] = debugShellPath
        }
        if let normalizedCustomShellPath {
            metadata["custom_shell_path"] = normalizedCustomShellPath
            metadata["custom_shell_supported"] = detectedShell(from: normalizedCustomShellPath) == nil
                ? "false"
                : "true"
        }
        if let normalizedPreferredShellPath {
            metadata["preferred_shell_path"] = normalizedPreferredShellPath
            metadata["preferred_shell_supported"] = detectedShell(from: normalizedPreferredShellPath) == nil
                ? "false"
                : "true"
        }
        if let preferredShellSource {
            metadata["preferred_shell_source"] = preferredShellSource.rawValue
        }
        if let environmentShellPath {
            metadata["environment_shell_path"] = environmentShellPath
            metadata["environment_shell_supported"] = detectedShell(from: environmentShellPath) == nil
                ? "false"
                : "true"
        }
        if let normalizedLoginShellPath {
            metadata["login_shell_path"] = normalizedLoginShellPath
            metadata["login_shell_supported"] = detectedShell(from: normalizedLoginShellPath) == nil
                ? "false"
                : "true"
        }

        return metadata
    }

    private static func shellResolutionSource(
        resolvedShellPath: String?,
        defaultShellResolution: ProfileShellIntegrationResolvedShellPath?,
        customShellPath: String?
    ) -> String {
        if customShellPath == resolvedShellPath {
            return "custom_provider"
        }
        if let defaultShellResolution,
           defaultShellResolution.path == resolvedShellPath {
            return defaultShellResolution.source.rawValue
        }
        switch resolvedShellPath {
        case .some:
            return "custom_provider"
        case .none:
            return "none"
        }
    }

    private func ensureDirectoryExists(at directoryURL: URL) throws {
        do {
            try fileManager.createDirectory(at: directoryURL, withIntermediateDirectories: true)
        } catch {
            throw ProfileShellIntegrationInstallerError.unableToWriteFile(
                path: directoryURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func writeManagedSnippet(for plan: ProfileShellIntegrationInstallPlan) throws -> Bool {
        let managedContents = expectedManagedSnippetContents(for: plan)
        do {
            if fileManager.fileExists(atPath: plan.managedSnippetURL.path) {
                let existingContents = try String(contentsOf: plan.managedSnippetURL, encoding: .utf8)
                if existingContents == managedContents {
                    return false
                }
            }

            try managedContents.write(to: plan.managedSnippetURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            throw ProfileShellIntegrationInstallerError.unableToWriteFile(
                path: plan.managedSnippetURL.path,
                reason: error.localizedDescription
            )
        }
    }

    private func expectedManagedSnippetContents(for plan: ProfileShellIntegrationInstallPlan) -> String {
        plan.shell.managedSnippetContents.appending("\n")
    }

    private func installSourceLine(
        for plan: ProfileShellIntegrationInstallPlan
    ) throws -> (updated: Bool, created: Bool) {
        let initFileURL = plan.initFileURL
        let initFileExisted = fileManager.fileExists(atPath: initFileURL.path)

        let existingContents: String
        if initFileExisted {
            do {
                existingContents = try String(contentsOf: initFileURL, encoding: .utf8)
            } catch {
                throw ProfileShellIntegrationInstallerError.unableToReadFile(
                    path: initFileURL.path,
                    reason: error.localizedDescription
                )
            }
        } else {
            existingContents = ""
        }

        if contents(existingContents, referencesManagedSnippetFor: plan) {
            return (updated: false, created: false)
        }

        let separator: String
        if existingContents.isEmpty {
            separator = ""
        } else if existingContents.hasSuffix("\n") {
            separator = "\n"
        } else {
            separator = "\n\n"
        }

        let updatedContents = existingContents
            + separator
            + Self.managedSourceCommentLines.joined(separator: "\n")
            + "\n"
            + plan.sourceLine
            + "\n"

        do {
            try ensureDirectoryExists(at: initFileURL.deletingLastPathComponent())
            try updatedContents.write(to: initFileURL, atomically: true, encoding: .utf8)
        } catch {
            throw ProfileShellIntegrationInstallerError.unableToWriteFile(
                path: initFileURL.path,
                reason: error.localizedDescription
            )
        }

        return (updated: true, created: initFileExisted == false)
    }

    private func contents(
        _ contents: String,
        referencesManagedSnippetFor plan: ProfileShellIntegrationInstallPlan
    ) -> Bool {
        let fileName = plan.managedSnippetURL.lastPathComponent
        let markers = [
            plan.sourceLine,
            plan.managedSnippetURL.path,
            "$HOME/.toastty/shell/\(fileName)",
            "~/.toastty/shell/\(fileName)",
        ]

        return contents
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.isEmpty == false && $0.hasPrefix("#") == false }
            .contains { line in
                markers.contains(where: line.contains)
            }
    }

    private func readFileIfPresent(at fileURL: URL) throws -> String {
        guard fileManager.fileExists(atPath: fileURL.path) else {
            return ""
        }

        do {
            return try String(contentsOf: fileURL, encoding: .utf8)
        } catch {
            throw ProfileShellIntegrationInstallerError.unableToReadFile(
                path: fileURL.path,
                reason: error.localizedDescription
            )
        }
    }
}
