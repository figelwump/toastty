import Foundation

/// The command a remote client runs over SSH to attach a terminal to the
/// multiplexer session of one host terminal panel.
///
/// The host builds the command from a terminal profile's `remoteAttachCommand`
/// recipe. The client treats it as opaque text and passes it to `ssh` as one
/// argument, so the client's own shell never reads it. The SSH server gives it
/// to the host user's login shell, which may be zsh, bash, or fish. Those
/// shells disagree about backslashes inside single quotes, so a recipe cannot
/// contain a single quote or a backslash; the quoting below is then read the
/// same way by all three.
public enum RemoteTerminalAttachCommand {
    public static let maximumRecipeByteCount = 1024
    public static let maximumWireByteCount = 4096

    public static func isValidRecipe(_ recipe: String) -> Bool {
        let trimmed = recipe.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty == false
            && recipe.utf8.count <= maximumRecipeByteCount
            && recipe.contains("'") == false
            && recipe.contains("\\") == false
            && isSingleLine(recipe)
    }

    /// Returns the command for one panel, or nil when the recipe or the
    /// profile ID could not be passed through a shell unchanged.
    ///
    /// A non-interactive SSH command gets a minimal environment, so the recipe
    /// runs in a login shell to pick up the user's `PATH`, as the profile's
    /// `startupCommand` does in the pane.
    public static func compose(recipe: String, panelID: UUID, profileID: String) -> String? {
        guard isValidRecipe(recipe), isShellSafeIdentifier(profileID) else { return nil }
        let command = "env TOASTTY_PANEL_ID=\(panelID.uuidString)"
            + " TOASTTY_TERMINAL_PROFILE_ID=\(profileID)"
            + " \"$SHELL\" -lc '\(recipe)'"
        return normalizedWireValue(command)
    }

    /// Bounds a command read from, or written to, the wire. An invalid value
    /// becomes nil, which a client shows as "no terminal to attach to".
    public static func normalizedWireValue(_ value: String?) -> String? {
        guard let value,
              value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false,
              value.utf8.count <= maximumWireByteCount,
              isSingleLine(value) else {
            return nil
        }
        return value
    }

    private static func isSingleLine(_ value: String) -> Bool {
        value.unicodeScalars.allSatisfy { scalar in
            CharacterSet.controlCharacters.contains(scalar) == false
                && CharacterSet.newlines.contains(scalar) == false
        }
    }

    private static func isShellSafeIdentifier(_ value: String) -> Bool {
        let allowed = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return value.isEmpty == false
            && value.hasPrefix("-") == false
            && value.unicodeScalars.allSatisfy { allowed.contains($0) }
    }
}
