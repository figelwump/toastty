# Workspace Tab Visual Design

## Current State

Tabs are variable-width, sized to content. Each tab is a horizontal pill: 11pt medium monospaced text, 10pt horizontal padding, 22pt tall inside a 30pt tab bar. Selected tabs get a subtle background lift (`0x1A1A1A` on `0x111111`) and a 1pt border. Unselected tabs are visually invisible until hovered. Unread state is a 5pt orange dot to the left of the title.

### Problems

1. **Variable width causes layout instability.** Tab titles are derived from the focused panel's process (`zsh`, `vim`, `npm run dev`, `python3`). As the user works, titles change and the entire tab bar reflows — tabs shift horizontally, making click targets unpredictable.
2. **Tabs are visually too subtle.** Unselected tabs have no background, border, or shape — they're just floating text. There's no strong visual affordance that these are discrete, clickable objects.
3. **No visual hierarchy between selected and unselected.** The only difference is a barely-perceptible background shift (from transparent to `0x1A1A1A` on a `0x111111` background). At a glance, it's hard to tell which tab is active.
4. **No close affordance.** No way to close a tab without a menu or keyboard shortcut.
5. **No position/shortcut hint.** Tabs support `⌘1`/`⌘2`/`⌘3` switching but nothing in the tab itself communicates this.

---

## Proposal

### 1. Fixed-Width Tabs

All tabs use a fixed width regardless of title content.

| Constant | Value | Rationale |
|---|---|---|
| `tabWidth` | **140pt** | Wide enough to show ~15-16 monospaced chars before truncation. Narrow enough to fit 6-7 tabs in a typical 1000pt content area before scrolling. |
| `tabHeight` | **26pt** (up from 22) | Slightly more breathing room for the text + close button. |
| `tabBarHeight` | **34pt** (up from 30) | Accommodate the taller tabs + vertical padding. |

Truncation remains tail-mode. The tooltip (`.help`) already shows the full title on hover.

**Why 140pt:** Terminal process names are short (`zsh`, `vim`, `node`, `python3`), but tab titles can also include directory context like `~/projects/toastty`. 140pt is a sweet spot — enough to be informative, compact enough to not waste space. For reference, Safari tabs compress to ~120pt minimum and Chrome/Arc tabs sit around 180-240pt at rest, but those show page titles which are much longer than terminal process names.

**Alternative considered: min/max width.** A flexible width with `minWidth: 100, maxWidth: 180` would adapt better to short vs. long titles, but still causes layout shifts as titles change. The stability win from fixed width outweighs the space efficiency of flexible width. If we later want more adaptability, a better path is fixed width with a smarter truncation strategy (e.g., showing the last path component instead of truncating the full string).

### 2. Visual Design

#### Shape: Rounded Pill (Current Direction, Refined)

Keep the rounded rectangle shape but make it more present:

```
Selected tab:
┌─────────────────────┐
│  zsh — toastty  ⌘1  │  ← primary text, badge right-aligned
└─────────────────────┘
   background: 0x222222 (warmer/lighter lift)
   border: 0x333333, 1pt
   no accent bar — elevation only

Unselected tab:
┌─────────────────────┐
│  vim            ⌘2   │  ← muted text
└─────────────────────┘
   background: 0x161616 (slight fill, not invisible)
   border: 0x1F1F1F, 1pt (hairline, just enough to define the shape)
   bottom edge: none

Unselected + unread:
┌─────────────────────┐
│  ●  npm run dev ⌘3   │  ← muted text, #5BA08A unread dot
└─────────────────────┘
   background: 0x161618 (very subtle cool tint)
   border: 0x1F2522
```

#### Key Visual Changes

**a) Unselected tabs get a visible background.**
Currently invisible — just floating text. Give them a subtle fill (`0x161616`) and hairline border (`0x1F1F1F`) so they read as discrete objects. The selected tab should be clearly brighter/elevated above these.

**b) Selected indicator: elevation only, no accent bar.**
The selected tab relies on three stacked signals: brighter background (`0x222222` vs `0x161616`), primary text color (`0xE8E4DF` vs `0x888888`), and stronger border (`0x333333` vs `0x1F1F1F`). No accent bottom bar — the app already uses accent bars on focused panel headers, and duplicating that language on tabs would create competing "I'm active" signals. Uniform 6pt corner radius on all four corners.

**c) Close button on hover.**
A small `×` (10x10pt hit area) that appears on the trailing edge of a tab on hover, replacing the trailing padding. Clicking it closes the tab. Not visible at rest to keep things clean.

```
At rest:          │  zsh — toastty      ⌘1  │
On hover:         │  zsh — toastty       ×  │   ← × replaces badge
```

**d) Shortcut badge (right-aligned).**
Show the `⌘N` tab-selection shortcut as a right-aligned suffix. Use muted text (`0x888888` on selected, `0x555555` on unselected) at 9pt so it doesn't compete with the title. Show it for every shortcut-addressable tab, which today means tabs 1-9 to match the current app-level `⌘digit` tab-selection behavior. Tabs 10+ show no badge until a wider shortcut range is intentionally added. On hover, the badge is replaced by the close button `×`.

These badges describe **tab selection within the active workspace**. They do not replace the existing sidebar/workspace `⌥digit` switching model.

```
│  zsh — toastty  ⌘1  │
│  vim            ⌘2   │
│  npm run dev    ⌘3   │
│  python3        ⌘4   │
│  tab ten            │   ← no badge after 9
```

**e) Unread state refinement.**
Use the unified unread color `#5BA08A` for the dot (matching panel header unread treatments). Apply a very subtle cool tint to the background (`0x161618`) and border (`0x1F2522`). This makes unread tabs noticeable at a peripheral glance without being distracting, and stays consistent with the unread color used elsewhere in the app.

The tab unread indicator is a rollup of panel-level unread state — it stays lit as long as any panel within the tab has unread content (`tab.unreadPanelIDs` is non-empty). The user must read all unread panels in that tab for the dot to clear.

#### Color Palette (New/Changed)

| Token | Hex | Usage |
|---|---|---|
| `tabSelectedBackground` | `0x222222` | Selected tab fill |
| `tabSelectedBorder` | `0x333333` | Selected tab border |
| `tabUnselectedBackground` | `0x161616` | Unselected tab fill |
| `tabUnselectedBorder` | `0x1F1F1F` | Unselected tab hairline |
| `tabUnreadBackground` | `0x161618` | Unread tab cool tint |
| `tabUnreadBorder` | `0x1F2522` | Unread tab border |
| `tabUnreadDot` | `0x5BA08A` | Unread indicator dot (unified) |
| `tabCloseButton` | `0x888888` | Close × on hover |
| `tabCloseButtonHover` | `0xCCCCCC` | Close × on hover of the × itself |
| `tabShortcutText` | `0x888888` | ⌘N suffix text (selected) |
| `tabShortcutTextMuted` | `0x555555` | ⌘N suffix text (unselected) |

#### Typography

| Element | Spec |
|---|---|
| Tab title | 11pt medium monospaced (unchanged) |
| Shortcut badge | 9pt regular monospaced, `tabShortcutText` color |

#### Spacing (within a 140pt fixed-width tab)

```
│ 10pt │ title (fills remaining) │ 5pt │ trailing slot │ 10pt │
│ 10pt │ title (fills remaining) │ 5pt │     ⌘1        │ 10pt │
│ 10pt │ title (fills remaining) │ 5pt │      ×        │ 10pt │   ← on hover, × replaces badge
│ 10pt │ title (fills remaining) │ 5pt │               │ 10pt │   ← no badge (tab 10+)
```

The badge and close affordance should share the same fixed trailing slot width so the title does not jitter when hover swaps `⌘N` for `×`.

### 3. Interaction

| Interaction | Behavior |
|---|---|
| Click | Select tab |
| Hover | Show close button, lighten background slightly |
| ⌘1 ... ⌘9 | Switch to tab by position |
| ⌘T | New tab |
| ⌘W | Close current tab (existing) |
| Hover close × | Close that specific tab |

### 4. Motion (Follow-up)

- Tab selection change: crossfade background/border colors, 150ms ease-in-out.
- Close button appear/disappear: opacity fade, 100ms.
- Tab close: the closing tab shrinks to zero width while remaining tabs slide to fill, 200ms ease-out. Prevents jarring layout snaps.
- New tab: slides in from the right, 200ms ease-out.

### 5. Edge Cases

- **Single tab:** Tab bar stays hidden (existing behavior). No change.
- **Many tabs (>7):** Horizontal scroll kicks in (existing). Fixed width ensures consistent scroll behavior. Consider a subtle fade/gradient on the trailing edge to hint at scrollable content.
- **Very long title:** Truncated with `...` at the fixed width. Tooltip shows full title.
- **Empty/default title:** Falls back to "Tab" (existing behavior).
- **10+ tabs:** Tabs 1-9 show `⌘digit` badges. Tabs 10+ do not show badges until the shortcut model expands.
- **Tab bar overflow indicator:** Follow-up polish. When tabs overflow the visible area, add a subtle gradient fade on the scroll edge (leading/trailing as applicable) so the user knows there are more tabs.

---

## Implementation Sequence

1. **Fixed width + height constants** — Add to `ToastyTheme`, apply `.frame(width:)` to tab button. Adjust bar height.
2. **Unselected tab background** — Give unselected tabs the `0x161616` fill and hairline border.
3. **Selected elevation** — Brighter background + stronger border on selected tab (no accent bar).
4. **Shortcut badges** — Add right-aligned `⌘N` suffix for every shortcut-addressable tab (currently 1-9), with no badge after that.
5. **Close button on hover** — Add hover state tracking and conditional close `×`.
6. **Unread tint** — Apply cool background tint to unread tabs.

Steps 1-6 are the core visual upgrade. Animations and overflow fade are follow-up polish after the base redesign is validated.

---

## Implementation Plan

### Files to Modify

| File | Changes |
|------|---------|
| `Sources/App/Theme.swift` | Add dimension constants, color tokens, badge font, and a fixed trailing slot width. Update `workspaceTabBarHeight` from 30→34. |
| `Sources/App/DisplayShortcutConfig.swift` | Add a shared `⌘digit` tab-selection label helper and shared max-count constant so badge rendering and shortcut handling stay aligned. |
| `Sources/App/ToasttyApp.swift` | Update `DisplayShortcutInterceptor` to consume the shared tab-selection shortcut limit instead of a private duplicate constant. |
| `Sources/App/WorkspaceView.swift` | Rewrite `workspaceTabButton`, update `workspaceTabBar`, add `workspaceTabTrailingContent` helper, and add `@State hoveredTabID`. |
| `Tests/App/DisplayShortcutConfigTests.swift` | Add coverage for `⌘digit` tab-selection labels and the supported badge range. |
| `Tests/App/DisplayShortcutInterceptorTests.swift` | Keep tab-selection shortcut parsing aligned with the shared 1-9 range. |

No new files. No reducer/action/Core changes — all existing actions (`selectWorkspaceTab`, `closeWorkspaceTab`, `createWorkspaceTab`) are reused.

### Phase 1: Theme Constants

**Theme.swift** — update and add constants:

1. Update `workspaceTabBarHeight` from `30` to `34`
2. Add dimension constants:
   - `workspaceTabWidth: CGFloat = 140`
   - `workspaceTabHeight: CGFloat = 26`
   - `workspaceTabCornerRadius: CGFloat = 6`
   - `workspaceTabTrailingSlotWidth: CGFloat = 24`
3. Add color tokens for each tab state:
   - **Selected**: bg `0x222222`, border `0x333333`
   - **Unselected**: bg `0x161616`, border `0x1F1F1F`, text `0x888888`
   - **Hover**: bg `0x1C1C1C`, border `0x2A2A2A`, text `0xB8B8B8`
   - **Unread**: bg `0x161618`, border `0x1F2522`, text `0xB8B8B8`, dot `0x5BA08A`
   - **Badge**: selected text `0x888888`, unselected text `0x555555`
   - **Close button**: bg `0x2A2A2A`, text `0x888888`
4. Add `fontWorkspaceTabBadge = Font.system(size: 9, weight: .regular, design: .monospaced)`

### Phase 1.5: Shared Shortcut Labels

Avoid duplicating badge logic in theme or view code.

1. Add a shared tab-selection shortcut constant to `DisplayShortcutConfig`
   - `maxWorkspaceTabSelectionShortcutCount = 9`
2. Add a helper:
   - `workspaceTabSelectionShortcutLabel(for number: Int) -> String?`
   - Returns `⌘1 ... ⌘9`
3. Update `DisplayShortcutInterceptor` to read the same max-count constant instead of keeping a private `maxWorkspaceTabShortcutCount`

This keeps the rendered badge range aligned with the actual `⌘digit` tab-selection behavior.

### Phase 2: Tab Bar and Tab Button

**WorkspaceView.swift** — the main visual overhaul.

#### 2a. Add hover state

```swift
@State private var hoveredTabID: UUID?
```

Follows the existing pattern from `SidebarView` (`@State private var hoveredPanelID: UUID?` + `.onHover`).

#### 2b. Update `workspaceTabBar(for:)`

- Change `ForEach(workspace.orderedTabs)` to `ForEach(Array(workspace.orderedTabs.enumerated()), id: \.element.id)` to get the tab index for badge display
- Pass `index: Int` to `workspaceTabButton`
- Adjust vertical padding from 5→4 to center the 26pt tab in 34pt bar

#### 2c. Rewrite `workspaceTabButton`

**Critical: avoid nested buttons.** The current implementation wraps everything in a `Button`. But we need a close `Button` inside the tab. Nested buttons cause tap conflicts in SwiftUI.

**Solution:** Use the `contentShape(Rectangle()) + onTapGesture` pattern (already used for panel tap targets at WorkspaceView line 726) for the outer tab selection, and a real `Button` for the inner close:

```swift
private func workspaceTabButton(
    workspaceID: UUID,
    tab: WorkspaceTabState,
    index: Int,
    isSelected: Bool
) -> some View {
    let hasUnread = !tab.unreadPanelIDs.isEmpty
    let isHovered = hoveredTabID == tab.id

    // Resolve colors: selected > hover > unread > unselected
    let (bg, border, text) = resolveTabColors(
        isSelected: isSelected, isHovered: isHovered, hasUnread: hasUnread
    )

    return HStack(spacing: 0) {
        // Leading: optional unread dot + title
        HStack(spacing: 5) {
            if hasUnread {
                Circle()
                    .fill(ToastyTheme.workspaceTabUnreadDot)
                    .frame(width: 5, height: 5)
            }
            Text(tab.displayTitle)
                .font(ToastyTheme.fontWorkspaceTab)
                .foregroundStyle(text)
                .lineLimit(1)
                .truncationMode(.tail)
        }

        Spacer(minLength: 4)

        // Trailing: close button on hover, or ⌘N badge
        workspaceTabTrailingContent(
            workspaceID: workspaceID, tab: tab,
            index: index, isSelected: isSelected, isHovered: isHovered
        )
        .frame(width: ToastyTheme.workspaceTabTrailingSlotWidth, alignment: .trailing)
    }
    .padding(.horizontal, 10)
    .frame(width: ToastyTheme.workspaceTabWidth, height: ToastyTheme.workspaceTabHeight)
    .background(bg, in: RoundedRectangle(cornerRadius: ToastyTheme.workspaceTabCornerRadius))
    .overlay(
        RoundedRectangle(cornerRadius: ToastyTheme.workspaceTabCornerRadius)
            .stroke(border, lineWidth: 1)
    )
    .contentShape(Rectangle())
    .onTapGesture {
        _ = store.send(.selectWorkspaceTab(workspaceID: workspaceID, tabID: tab.id))
    }
    .onHover { hovering in
        if hovering { hoveredTabID = tab.id }
        else if hoveredTabID == tab.id { hoveredTabID = nil }
    }
    .animation(.easeInOut(duration: 0.15), value: isSelected)
    .animation(.easeOut(duration: 0.12), value: isHovered)
    .help(tab.displayTitle)
    .accessibilityIdentifier("workspace.tab.\(tab.id.uuidString)")
}
```

#### 2d. Add color resolution helper

Small helper to keep the tab button readable:

```swift
private func resolveTabColors(
    isSelected: Bool, isHovered: Bool, hasUnread: Bool
) -> (background: Color, border: Color, text: Color) {
    if isSelected {
        return (.workspaceTabSelectedBackground, .workspaceTabSelectedBorder, .primaryText)
    } else if isHovered {
        return (.workspaceTabHoverBackground, .workspaceTabHoverBorder, .workspaceTabHoverText)
    } else if hasUnread {
        return (.workspaceTabUnreadBackground, .workspaceTabUnreadBorder, .workspaceTabUnreadText)
    } else {
        return (.workspaceTabUnselectedBackground, .workspaceTabUnselectedBorder, .workspaceTabUnselectedText)
    }
}
```

#### 2e. Add trailing content helper

```swift
@ViewBuilder
private func workspaceTabTrailingContent(
    workspaceID: UUID, tab: WorkspaceTabState,
    index: Int, isSelected: Bool, isHovered: Bool
) -> some View {
    if isHovered {
        // Close × replaces badge on hover
        Button {
            hoveredTabID = nil
            _ = store.send(.closeWorkspaceTab(workspaceID: workspaceID, tabID: tab.id))
        } label: {
            Text("\u{2715}")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(ToastyTheme.workspaceTabCloseText)
                .frame(width: 16, height: 16)
                .background(ToastyTheme.workspaceTabCloseBackground, in: RoundedRectangle(cornerRadius: 4))
        }
        .buttonStyle(.plain)
        .transition(.opacity)
    } else if let shortcutLabel = DisplayShortcutConfig.workspaceTabSelectionShortcutLabel(for: index + 1) {
        Text(shortcutLabel)
            .font(ToastyTheme.fontWorkspaceTabBadge)
            .foregroundStyle(
                isSelected ? ToastyTheme.workspaceTabBadgeSelectedText : ToastyTheme.workspaceTabBadgeUnselectedText
            )
            .transition(.opacity)
    }
}
```

### Phase 3: Validation

1. **Build**: `ARCH="$(uname -m)"; xcodebuild -workspace toastty.xcworkspace -scheme ToasttyApp -configuration Debug -destination "platform=macOS,arch=${ARCH}" -derivedDataPath Derived build`
2. **Full gate**: `./scripts/automation/check.sh`
3. **Smoke automation** (both modes):
   ```
   TUIST_DISABLE_GHOSTTY=1 ./scripts/automation/smoke-ui.sh
   ./scripts/automation/smoke-ui.sh
   ```
4. **Shortcut hints**: `./scripts/automation/shortcut-hints-smoke.sh`
5. **Foreground hover validation**: isolated dev run + `peekaboo` (or `scripts/remote/gui-validate.sh` if local focus theft is undesirable) to confirm hover close affordance, tab-bar collapse, and no stray click-through when closing from 2 tabs down to 1

#### Test Scenarios
- **1 tab**: Tab bar hidden (existing guard unchanged)
- **2 tabs**: Bar appears, both tabs show `⌘1`/`⌘2`, hover shows ×
- **4 tabs**: 4th tab shows `⌘4`
- **9 tabs**: 9th tab shows `⌘9`
- **10+ tabs**: 10th tab has no badge, close × still works on hover
- **Unread**: Non-selected tab with unread panels shows green dot + tinted bg
- **Close 2nd-to-last tab**: Tab bar disappears with no crash or stray click-through under the pointer
- **Scroll overflow**: Many tabs scroll horizontally

### Stretch (separate follow-up)

Tab open/close animations (shrink+slide on close, slide-in on new). These interact with ScrollView in potentially janky ways on macOS SwiftUI — implement and test separately after the base redesign lands.

Tab bar overflow fade / scroll-edge gradient. Treat this as separate polish for the same reason: it depends on final fixed-width layout behavior and should be tuned after the base redesign is stable.
