import AppKit
import SwiftTerm

/// The colour schemes a terminal can wear in dark mode (View → Dark Terminal
/// Colors). Light mode keeps its one palette.
///
/// These set the background, the plain text colour and the 16 ANSI colours.
/// Claude Code draws most of its own colours in 24-bit, picked by its `/theme`,
/// so a scheme here mostly changes the background those colours sit on, and
/// what shells and the `*-ansi` Claude themes look like.
enum DarkTerminalScheme: String, CaseIterable, Identifiable {
    case vsCode, black, oneDark, dracula, tokyoNight, gruvbox, solarized

    static let key = "darkTerminalScheme"

    static var current: DarkTerminalScheme {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .vsCode
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .vsCode: return "VS Code Dark (default)"
        case .black: return "Pure Black"
        case .oneDark: return "One Dark"
        case .dracula: return "Dracula"
        case .tokyoNight: return "Tokyo Night"
        case .gruvbox: return "Gruvbox Dark"
        case .solarized: return "Solarized Dark"
        }
    }

    var background: NSColor { nsColor(hex.background) }
    var foreground: NSColor { nsColor(hex.foreground) }
    var palette: [SwiftTerm.Color] { hex.ansi.map(termColor) }

    private var hex: (background: UInt32, foreground: UInt32, ansi: [UInt32]) {
        switch self {
        case .vsCode:
            return (0x1E1E1E, 0xDEDEDE, [
                0x3C3C3C, 0xCD3131, 0x0DBC79, 0xE5E510, 0x2472C8, 0xBC3FBC, 0x11A8CD, 0xE5E5E5,
                0x666666, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xFFFFFF,
            ])
        case .black:
            return (0x000000, 0xE8E8E8, [
                0x404040, 0xF14C4C, 0x23D18B, 0xF5F543, 0x3B8EEA, 0xD670D6, 0x29B8DB, 0xE5E5E5,
                0x808080, 0xFF6B6B, 0x5AF78E, 0xFFE66D, 0x6AB0FF, 0xF092F0, 0x5CE1FF, 0xFFFFFF,
            ])
        case .oneDark:
            return (0x282C34, 0xABB2BF, [
                0x3F4451, 0xE06C75, 0x98C379, 0xE5C07B, 0x61AFEF, 0xC678DD, 0x56B6C2, 0xD7DAE0,
                0x5C6370, 0xEF7E87, 0xA9D48A, 0xF0CF8C, 0x7CC0F5, 0xD58BE8, 0x6DC8D3, 0xFFFFFF,
            ])
        case .dracula:
            return (0x282A36, 0xF8F8F2, [
                0x44475A, 0xFF5555, 0x50FA7B, 0xF1FA8C, 0xBD93F9, 0xFF79C6, 0x8BE9FD, 0xF8F8F2,
                0x6272A4, 0xFF6E6E, 0x69FF94, 0xFFFFA5, 0xD6ACFF, 0xFF92DF, 0xA4FFFF, 0xFFFFFF,
            ])
        case .tokyoNight:
            return (0x1A1B26, 0xC0CAF5, [
                0x414868, 0xF7768E, 0x9ECE6A, 0xE0AF68, 0x7AA2F7, 0xBB9AF7, 0x7DCFFF, 0xA9B1D6,
                0x565F89, 0xFF8EA4, 0xB4E07E, 0xEFC07F, 0x95B6FA, 0xCBAEF9, 0x97DAFF, 0xC0CAF5,
            ])
        case .gruvbox:
            return (0x282828, 0xEBDBB2, [
                0x3C3836, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0xA89984,
                0x928374, 0xFB4934, 0xB8BB26, 0xFABD2F, 0x83A598, 0xD3869B, 0x8EC07C, 0xEBDBB2,
            ])
        case .solarized:
            return (0x002B36, 0x93A1A1, [
                0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0xEEE8D5,
                // Solarized's own brights are greys; these keep the hues, so
                // "bright green" still reads as green.
                0x586E75, 0xCB4B16, 0x859900, 0xB58900, 0x268BD2, 0x6C71C4, 0x2AA198, 0xFDF6E3,
            ])
        }
    }

}

/// The light-mode counterpart (View → Light Terminal Colors).
enum LightTerminalScheme: String, CaseIterable, Identifiable {
    case white, solarized, eyeCareGreen, sage, gruvbox, paper

    static let key = "lightTerminalScheme"

    static var current: LightTerminalScheme {
        UserDefaults.standard.string(forKey: key).flatMap(Self.init) ?? .white
    }

    var id: String { rawValue }

    var name: String {
        switch self {
        case .white: return "White (default)"
        case .solarized: return "Solarized Light"
        case .eyeCareGreen: return "Eye-Care Green"
        case .sage: return "Sage Green"
        case .gruvbox: return "Gruvbox Light"
        case .paper: return "Paper"
        }
    }

    var background: NSColor { nsColor(hex.background) }
    var foreground: NSColor { nsColor(hex.foreground) }
    var palette: [SwiftTerm.Color] { hex.ansi.map(termColor) }

    /// Tuned for a white background (Tango / Terminal.app light, dimmed).
    private static let defaultANSI: [UInt32] = [
        0x000000, 0xC23621, 0x1A921C, 0xA16A00, 0x2053B3, 0xA638A6, 0x0E848A, 0x8E8E93,
        0x5A5A5A, 0xE34F3B, 0x2EA430, 0xB8860B, 0x3B74D9, 0xC54FC5, 0x17A2A9, 0x3C3C3C,
    ]

    /// On a green page the greens are taken a step darker, or they melt into it.
    private static let greenPageANSI: [UInt32] = [
        0x000000, 0xB3261E, 0x0B6E0E, 0x8A5A00, 0x1D4FA8, 0x942F94, 0x0B6E73, 0x6E6E73,
        0x4A4A4A, 0xD0402E, 0x1B7F1D, 0x9C7208, 0x2E64C6, 0xAD3FAD, 0x0F7F86, 0x2E2E2E,
    ]

    private var hex: (background: UInt32, foreground: UInt32, ansi: [UInt32]) {
        switch self {
        case .white:
            return (0xFFFFFF, 0x212121, Self.defaultANSI)
        case .solarized:
            // Solarized's "white" is the page colour, so it is swapped for a
            // grey that still shows on it; the brights keep their hues.
            return (0xFDF6E3, 0x586E75, [
                0x073642, 0xDC322F, 0x859900, 0xB58900, 0x268BD2, 0xD33682, 0x2AA198, 0x93A1A1,
                0x657B83, 0xCB4B16, 0x859900, 0xB58900, 0x268BD2, 0x6C71C4, 0x2AA198, 0x002B36,
            ])
        case .eyeCareGreen:
            // The classic 护眼 green (#C7EDCC).
            return (0xC7EDCC, 0x1F2A1F, Self.greenPageANSI)
        case .sage:
            // A paler, greyer green for those who find the classic one loud.
            return (0xE4EDDF, 0x22291F, Self.greenPageANSI)
        case .gruvbox:
            return (0xFBF1C7, 0x3C3836, [
                0x3C3836, 0xCC241D, 0x98971A, 0xD79921, 0x458588, 0xB16286, 0x689D6A, 0x7C6F64,
                0x928374, 0x9D0006, 0x79740E, 0xB57614, 0x076678, 0x8F3F71, 0x427B58, 0x282828,
            ])
        case .paper:
            // Warm off-white, like printed paper.
            return (0xF7F3EA, 0x2B2A27, Self.defaultANSI)
        }
    }
}

private func nsColor(_ hex: UInt32) -> NSColor {
    NSColor(calibratedRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
}

private func termColor(_ hex: UInt32) -> SwiftTerm.Color {
    SwiftTerm.Color(red: UInt16((hex >> 16) & 0xFF) * 257,
                    green: UInt16((hex >> 8) & 0xFF) * 257,
                    blue: UInt16(hex & 0xFF) * 257)
}
