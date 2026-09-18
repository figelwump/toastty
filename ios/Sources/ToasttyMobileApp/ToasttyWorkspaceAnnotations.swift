import RemoteProtocol
import SwiftUI

/// The desktop sidebar's chip colors, derived from the host's resolved base
/// color with the shared palette rule.
struct ToasttyAnnotationChipColors {
    let foreground: Color
    let background: Color
    let border: Color

    init(color: String) {
        let baseHex = WorkspaceAnnotationChipPalette.baseHex(fromColor: color)
            ?? WorkspaceAnnotationChipPalette.fallbackBaseHex
        let foregroundHex = WorkspaceAnnotationChipPalette.readableForegroundHex(forBase: baseHex)
        foreground = Self.color(foregroundHex)
        background = Self.color(baseHex, opacity: WorkspaceAnnotationChipPalette.backgroundAlpha)
        border = Self.color(foregroundHex, opacity: WorkspaceAnnotationChipPalette.borderAlpha)
    }

    private static func color(_ hex: UInt32, opacity: Double = 1) -> Color {
        Color(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}

enum ToasttyAnnotationChipSize {
    /// Home headers: sidebar-sized chips.
    case compact
    /// The workspace page's chip block.
    case regular
}

struct ToasttyAnnotationChip: View {
    let annotation: RemoteWorkspaceAnnotation
    let size: ToasttyAnnotationChipSize

    var body: some View {
        let colors = ToasttyAnnotationChipColors(color: annotation.color)
        let shape = RoundedRectangle(
            cornerRadius: ToasttyDesignTokens.chipCornerRadius,
            style: .continuous
        )
        HStack(spacing: 3) {
            Text(annotation.text)
                .lineLimit(1)
                .truncationMode(.tail)
            if annotation.url != nil {
                Image(systemName: "arrow.up.right")
                    .font(.caption2.weight(.semibold))
                    .imageScale(.small)
            }
        }
        .font(size == .compact ? .caption2.weight(.medium) : .caption.weight(.medium))
        .foregroundStyle(colors.foreground)
        .padding(.horizontal, size == .compact ? 6 : 8)
        .padding(.vertical, size == .compact ? 3 : 4)
        .background(colors.background, in: shape)
        .overlay { shape.strokeBorder(colors.border, lineWidth: 1) }
    }
}

enum ToasttyWorkspaceAnnotationAccessibility {
    /// Matches the desktop sidebar's `key: text` spoken form.
    static func label(for annotation: RemoteWorkspaceAnnotation) -> String {
        "\(annotation.key): \(annotation.text)"
    }
}

/// Wraps whole chips onto new lines before truncating any of them; a chip
/// wider than `maximumItemWidth` or the available width truncates.
struct ToasttyChipFlowLayout: Layout {
    var spacing: CGFloat
    var lineSpacing: CGFloat
    var maximumItemWidth: CGFloat?

    private struct Line {
        var items: [(index: Int, size: CGSize)] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache _: inout ()) -> CGSize {
        let lines = lines(availableWidth: proposal.width, subviews: subviews)
        let height = lines.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, lines.count - 1))
        return CGSize(width: lines.map(\.width).max() ?? 0, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal _: ProposedViewSize, subviews: Subviews, cache _: inout ()) {
        var y = bounds.minY
        for line in lines(availableWidth: bounds.width, subviews: subviews) {
            var x = bounds.minX
            for item in line.items {
                subviews[item.index].place(
                    at: CGPoint(x: x, y: y + (line.height - item.size.height) / 2),
                    anchor: .topLeading,
                    proposal: ProposedViewSize(width: item.size.width, height: nil)
                )
                x += item.size.width + spacing
            }
            y += line.height + lineSpacing
        }
    }

    private func lines(availableWidth rawWidth: CGFloat?, subviews: Subviews) -> [Line] {
        let availableWidth = rawWidth.flatMap { $0.isFinite ? max(0, $0) : nil }
        let widthCap = [availableWidth, maximumItemWidth].compactMap { $0 }.min()
        var lines: [Line] = []
        var current = Line()
        for (index, subview) in subviews.enumerated() {
            let idealWidth = subview.sizeThatFits(.unspecified).width
            let proposedWidth = widthCap.map { min(idealWidth, $0) } ?? idealWidth
            let measured = subview.sizeThatFits(ProposedViewSize(width: proposedWidth, height: nil))
            let size = CGSize(width: min(measured.width, proposedWidth), height: measured.height)
            if !current.items.isEmpty, let availableWidth,
               current.width + spacing + size.width > availableWidth {
                lines.append(current)
                current = Line()
            }
            current.width += (current.items.isEmpty ? 0 : spacing) + size.width
            current.height = max(current.height, size.height)
            current.items.append((index, size))
        }
        if !current.items.isEmpty { lines.append(current) }
        return lines
    }
}

/// Display-only chips under a home workspace title. The header row is already
/// a link to the workspace, so these carry no actions of their own; the
/// header folds their text into its accessibility label.
struct ToasttyWorkspaceHeaderAnnotations: View {
    let annotations: [RemoteWorkspaceAnnotation]
    // The sidebar's 160pt cap at the default text size, scaled so larger
    // Dynamic Type sizes keep the same share of the text visible.
    @ScaledMetric(relativeTo: .caption2) private var maximumChipWidth: CGFloat = 160

    var body: some View {
        ToasttyChipFlowLayout(spacing: 5, lineSpacing: 5, maximumItemWidth: maximumChipWidth) {
            ForEach(annotations) { annotation in
                ToasttyAnnotationChip(annotation: annotation, size: .compact)
            }
        }
        .accessibilityHidden(true)
    }
}

/// The workspace page's full chip list. Chips with a link open it in the
/// in-app browser sheet that browser panel previews use.
struct ToasttyWorkspaceAnnotationBlock: View {
    let annotations: [RemoteWorkspaceAnnotation]
    @State private var openedLink: OpenedLink?
    private static let lineSpacing: CGFloat = 6

    private struct OpenedLink: Identifiable {
        let id = UUID()
        let title: String
        let url: URL
    }

    var body: some View {
        ToasttyChipFlowLayout(spacing: 6, lineSpacing: Self.lineSpacing, maximumItemWidth: nil) {
            ForEach(annotations) { annotation in
                chip(annotation)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(ToasttyDesignTokens.raisedSurface, in: RoundedRectangle(
            cornerRadius: ToasttyDesignTokens.cardCornerRadius, style: .continuous
        ))
        .overlay {
            RoundedRectangle(cornerRadius: ToasttyDesignTokens.cardCornerRadius, style: .continuous)
                .stroke(ToasttyDesignTokens.border, lineWidth: 1)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("toastty-workspace-annotations")
        .sheet(item: $openedLink) { link in
            ToasttyWebLinkSheet(title: link.title, url: link.url)
        }
    }

    @ViewBuilder
    private func chip(_ annotation: RemoteWorkspaceAnnotation) -> some View {
        if let url = annotation.url {
            Button {
                openedLink = OpenedLink(title: annotation.text, url: url)
            } label: {
                ToasttyAnnotationChip(annotation: annotation, size: .regular)
                    // Extends the tap target into half the gap on each side
                    // without changing the chip's layout size, so adjacent
                    // rows never claim each other's taps.
                    .padding(.vertical, Self.lineSpacing / 2)
                    .contentShape(Rectangle())
                    .padding(.vertical, -Self.lineSpacing / 2)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(ToasttyWorkspaceAnnotationAccessibility.label(for: annotation)), link")
            .accessibilityHint("Opens the link in a browser sheet")
            .accessibilityIdentifier("toastty-workspace-annotation-\(annotation.key)")
        } else {
            ToasttyAnnotationChip(annotation: annotation, size: .regular)
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(ToasttyWorkspaceAnnotationAccessibility.label(for: annotation))
                .accessibilityIdentifier("toastty-workspace-annotation-\(annotation.key)")
        }
    }
}

/// A web link opened from local metadata rather than a Mac-side preview.
struct ToasttyWebLinkSheet: View {
    @Environment(\.dismiss) private var dismiss
    let title: String
    let url: URL

    var body: some View {
        NavigationStack {
            ToasttyWebURLPreview(url: url)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(ToasttyDesignTokens.background)
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Close", systemImage: "xmark") { dismiss() }
                            .accessibilityIdentifier("toastty-preview-close")
                    }
                }
        }
        .presentationDetents([.large])
        .presentationDragIndicator(.visible)
    }
}
