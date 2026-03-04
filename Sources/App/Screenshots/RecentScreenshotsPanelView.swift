import AppKit
import SwiftUI

struct RecentScreenshotsPanelView: View {
    @ObservedObject var store: RecentScreenshotsStore

    var body: some View {
        Group {
            switch store.status {
            case .idle, .loading, .ready:
                if store.items.isEmpty {
                    panelMessage(
                        title: "No recent screenshots",
                        body: "Take a system screenshot to populate this panel."
                    )
                } else {
                    screenshotList
                }

            case .missingDirectory(let path):
                panelMessage(
                    title: "Screenshot folder missing",
                    body: path
                )

            case .unreadableDirectory(let path):
                panelMessage(
                    title: "Cannot read screenshot folder",
                    body: path
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(ToastyTheme.surfaceBackground)
        .accessibilityIdentifier("screenshots.panel")
    }

    private var screenshotList: some View {
        ScrollView {
            VStack(spacing: 8) {
                ForEach(Array(store.items.enumerated()), id: \.element.id) { index, item in
                    RecentScreenshotRow(
                        item: item,
                        index: index
                    )
                }
            }
            .padding(10)
        }
    }

    private func panelMessage(title: String, body: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(ToastyTheme.fontMonoHeader)
                .foregroundStyle(ToastyTheme.primaryText)
            Text(body)
                .font(ToastyTheme.fontSubtext)
                .foregroundStyle(ToastyTheme.inactiveText)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .padding(12)
    }
}

private struct RecentScreenshotRow: View {
    let item: RecentScreenshotItem
    let index: Int

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            thumbnail

            VStack(alignment: .leading, spacing: 3) {
                Text(item.displayName)
                    .font(ToastyTheme.fontSubtext)
                    .foregroundStyle(ToastyTheme.primaryText)
                    .lineLimit(1)
                    .truncationMode(.middle)

                Text(item.capturedAt, format: .dateTime.month().day().hour().minute().second())
                    .font(ToastyTheme.fontWorkspaceSubtitle)
                    .foregroundStyle(ToastyTheme.inactiveText)
            }

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 8)
        .background(ToastyTheme.elevatedBackground)
        .overlay(
            Rectangle()
                .stroke(ToastyTheme.hairline, lineWidth: 1)
        )
        .contentShape(Rectangle())
        .onDrag {
            NSItemProvider(object: item.fileURL as NSURL)
        }
        .accessibilityIdentifier("screenshots.row.\(index)")
    }

    @ViewBuilder
    private var thumbnail: some View {
        if let image = NSImage(contentsOf: item.fileURL) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: 76, height: 46)
                .clipped()
                .overlay(
                    Rectangle()
                        .stroke(ToastyTheme.hairline, lineWidth: 1)
                )
        } else {
            Rectangle()
                .fill(ToastyTheme.chromeBackground)
                .frame(width: 76, height: 46)
                .overlay(
                    Image(systemName: "photo")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(ToastyTheme.inactiveText)
                )
                .overlay(
                    Rectangle()
                        .stroke(ToastyTheme.hairline, lineWidth: 1)
                )
        }
    }
}
