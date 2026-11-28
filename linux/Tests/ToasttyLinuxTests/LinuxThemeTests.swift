import Testing
@testable import ToasttyLinuxUI

@Suite("Linux host CSS")
@MainActor
struct LinuxThemeTests {
    @Test func legacyGTKReceivesSymbolicColorsInsteadOfCustomProperties() {
        let css = LinuxTheme.legacyCSS(LinuxTheme.css)
        #expect(css.contains("@define-color toastty_working #e8a635;"))
        #expect(css.contains("@define-color toastty_done #7cc47f;"))
        #expect(css.contains("border-radius: 12px;"))
        #expect(css.contains("alpha(@toastty_approval, 0.22)"))
        #expect(css.contains("shade(@success_bg_color, 0.65)"))
        #expect(css.contains("var(--") == false)
        #expect(css.contains("color-mix(") == false)
        #expect(css.contains(":root") == false)
    }

    @Test func legacyGTKResolvesReferencesInOtherStyleProviders() {
        let css = ".panel { color: var(--toastty-terminal-fg); background: color-mix(in srgb, var(--popover-bg-color) 96%, transparent); }"
        #expect(LinuxTheme.legacyCSS(css) == ".panel { color: @toastty_terminal_fg; background: alpha(@popover_bg_color, 0.96); }")
    }
}
