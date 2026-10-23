import AppKit

/// Agent Deck's look (agent-deck `src/renderer/catppuccin.ts`, `styles.css`), for the typed-lookup
/// window, following the system appearance like Deck's "system" theme (Latte / Mocha).
/// Both in the user's Deck tone, Paper (its saved `deck.appearance` says `"tone":"paper"`;
/// I-27: 「亮色配色不是deck米黄色」): cream in light mode, coffee black in dark.
/// Colors resolve per appearance, so a light / dark switch repaints without rebuilding.
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

    // catppuccin.ts `ramps.paper` (light, dark).
    private static let lightText: UInt32 = 0x3C3429
    private static let lightBase: UInt32 = 0xF8EEDB
    private static let darkText: UInt32 = 0xEBE2D3
    private static let darkBase: UInt32 = 0x2B2520

    static let text = dynamic(light: lightText, dark: darkText)
    /// `--text-2` (subtext0).
    static let text2 = dynamic(light: 0x6B6155, dark: 0xAFA698)
    /// `--text-3` (overlay1): hints, labels.
    static let text3 = dynamic(light: 0x92887B, dark: 0x827A6D)
    static let base = dynamic(light: lightBase, dark: darkBase)
    /// Accent: the user's Deck accent is mauve (Latte / Mocha). Only for small touches
    /// (speakers, the model's name, selection), never lines or edges.
    static let accent = dynamic(light: 0x8839EF, dark: 0xCBA6F7)

    /// `--glass-bg`: Deck's base over macOS's frosted material (Full screen, as in the
    /// user's Deck). Deck's window tints it 70 %, but its floating sheets then sit on that
    /// window; over the desktop 70 % hid what's behind (I-26: 「没有毛玻璃效果」), so a lighter
    /// tint in dark. Light takes Deck's 70 %: the material underneath is a cool white, and
    /// any less washes the cream out to grey (I-27).
    static let glassBackground = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return hex(isDark ? darkBase : lightBase, alpha: isDark ? 0.4 : 0.7)
    }

    /// `--fill`: text at 5 %, the light fill that sets a card off the sheet.
    static let fill = NSColor(name: nil) { appearance in
        let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        return hex(isDark ? darkText : lightText, alpha: isDark ? 0.055 : 0.05)
    }

    /// Deck's type: body 13.5 px, labels and meta 12 / 11 px.
    static let bodySize: CGFloat = 13.5

    /// Deck's sizes: sheets 14 px, cards inside them 10 px, gaps 8 px.
    static let sheetRadius: CGFloat = 14
    static let cardRadius: CGFloat = 10
    static let gap: CGFloat = 8
}
