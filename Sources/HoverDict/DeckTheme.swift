import AppKit

/// Agent Deck's look (agent-deck `src/renderer/catppuccin.ts`, `styles.css`), for the typed-lookup
/// window: Catppuccin accents on Deck's Warm neutrals (ivory paper in light mode, a warm black
/// in dark — not Catppuccin's blue-grays), following the system appearance like Deck's
/// "system" theme (Latte / Mocha). Colors resolve per appearance, so a light / dark switch
/// repaints without rebuilding.
enum DeckTheme {

    private static func dynamic(light: UInt32, dark: UInt32) -> NSColor {
        NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return hex(isDark ? dark : light)
        }
    }

    static func hex(_ value: UInt32, alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((value >> 16) & 0xFF) / 255,
                green: CGFloat((value >> 8) & 0xFF) / 255,
                blue: CGFloat(value & 0xFF) / 255,
                alpha: alpha)
    }

    // Warm ramp (catppuccin.ts `warmLight` / `warmDark`).
    static let text = dynamic(light: 0x3D3A33, dark: 0xE8E3D6)
    /// `--text-2` (subtext0).
    static let text2 = dynamic(light: 0x6E685C, dark: 0xADA799)
    /// `--text-3` (overlay1): hints, labels.
    static let text3 = dynamic(light: 0x968F80, dark: 0x7F7B72)
    static let base = dynamic(light: 0xFAF9F5, dark: 0x262624)
    /// Accent: the user's Deck accent is mauve (Latte / Mocha). Only for small touches.
    static let accent = dynamic(light: 0x8839EF, dark: 0xCBA6F7)

    /// `--sheet-bg` in Glass: base at 78 % over the frosted window.
    static let sheetBackground = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return hex(isDark ? 0x262624 : 0xFAF9F5, alpha: 0.78)
    }

    /// `--fill`: text at 5 %, the light fill that sets a card off the sheet.
    static let fill = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return hex(isDark ? 0xE8E3D6 : 0x3D3A33, alpha: isDark ? 0.055 : 0.05)
    }

    /// Deck's sizes: sheets 14 px, cards inside them 10 px, gaps 8 px.
    static let sheetRadius: CGFloat = 14
    static let cardRadius: CGFloat = 10
    static let gap: CGFloat = 8
}
