import ConversationUI
import SwiftUI
import ToasttyMobileDomain
import UIKit

extension ToastyIcon.Palette {
    /// The iPhone's colors for Toasty: its status colors, and amber steam.
    @MainActor static let phone = ToastyIcon.Palette(
        outline: ToasttyDesignTokens.mutedText,
        steam: ToasttyDesignTokens.amber,
        unreadDot: ToasttyDesignTokens.color(for: .ready),
        needsApprovalDot: ToasttyDesignTokens.color(for: .needsApproval),
        needsApprovalHalo: ToasttyDesignTokens.color(for: .needsApproval).opacity(0.22),
        errorDot: ToasttyDesignTokens.color(for: .error)
    )
}

/// What the Coordinator tab's item shows.
enum ToasttyCoordinatorTabPresentation {
    static let title = "Coordinator"

    /// Toasty's gray outline, which the tab bar tints.
    @MainActor static let tabImage = ToastyIcon.outlineTemplateImage(pointSize: 25, lineWidthScale: 1.15)

    /// The tab's badge while the tab is not on screen: unread output, an
    /// approval or an error, as the Mac's coordinator row marks them. The
    /// system badge is always red, so its text tells the states apart.
    static func badge(_ mark: MobileCoordinatorMark?, isOnScreen: Bool) -> String? {
        guard isOnScreen == false, let mark, mark.callsForUser else { return nil }
        return switch mark {
        case .unread: "New"
        case .needsApproval: "!"
        case .error: "Error"
        case .notRunning, .quiet, .working: nil
        }
    }
}

/// The coordinator chat's title: the golden Toasty, with steam while the
/// coordinator works, and its name.
struct ToasttyCoordinatorTitle: View {
    let mark: MobileCoordinatorMark

    var body: some View {
        HStack(spacing: 7) {
            ToastyIcon(
                style: .golden,
                size: 17,
                status: mark == .working ? .working : .none,
                palette: .phone,
                badgeRingColor: ToasttyDesignTokens.elevatedSurface
            )
            Text(ToasttyCoordinatorTabPresentation.title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(ToasttyDesignTokens.primaryText)
                .lineLimit(1)
                .accessibilityAddTraits(.isHeader)
                .accessibilityIdentifier("toastty-mobile-coordinator-title")
        }
    }
}

/// The Coordinator tab while its workspace lists no session: the
/// coordinator does not run, or it is starting. The Mac starts it; the
/// phone cannot.
struct ToasttyCoordinatorUnavailableView: View {
    let isLive: Bool

    var body: some View {
        VStack(spacing: 18) {
            ToastyIcon(
                style: .golden,
                size: 64,
                palette: .phone,
                badgeRingColor: ToasttyDesignTokens.background
            )
            .padding(.top, 8)
            VStack(spacing: 8) {
                Text("The coordinator is not running")
                    .font(.headline)
                    .foregroundStyle(ToasttyDesignTokens.primaryText)
                    .multilineTextAlignment(.center)
                    .accessibilityIdentifier("toastty-mobile-coordinator-not-running")
                Text(isLive
                     ? "It may be starting. The coordinator starts on your Mac: choose Open Coordinator in the Agent menu."
                     : "Your Mac is not connected. The coordinator starts on your Mac: choose Open Coordinator in the Agent menu.")
                    .font(.subheadline)
                    .foregroundStyle(ToasttyDesignTokens.secondaryText)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(ToasttyDesignTokens.background)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .principal) {
                ToasttyCoordinatorTitle(mark: .notRunning)
            }
        }
        .toolbarBackground(ToasttyDesignTokens.elevatedSurface, for: .navigationBar)
    }
}
