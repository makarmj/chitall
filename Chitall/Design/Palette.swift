import SwiftUI
import UIKit

/// Book-like colors: warm paper in light mode, dark wood in dark mode. All colors are dynamic,
/// so text already rendered into the reader follows a theme switch without re-rendering.
enum Palette {
    static let backgroundUI = dynamic(light: 0xF5EFE3, dark: 0x1C1712)
    static let surfaceUI = dynamic(light: 0xFBF7EF, dark: 0x272019)
    static let inkUI = dynamic(light: 0x2A241E, dark: 0xE8DECD)
    static let secondaryInkUI = dynamic(light: 0x6F655A, dark: 0xA8998A)
    static let accentUI = dynamic(light: 0x8A5A2C, dark: 0xD3A46B)
    static let dividerUI = dynamic(light: 0xE2D8C6, dark: 0x3A3027)
    /// Temporary mark of the search result the reader jumped to.
    static let searchHitUI = UIColor { traits in
        accentUI.resolvedColor(with: traits).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.38 : 0.26)
    }

    static let background = Color(uiColor: backgroundUI)
    static let surface = Color(uiColor: surfaceUI)
    static let ink = Color(uiColor: inkUI)
    static let secondaryInk = Color(uiColor: secondaryInkUI)
    static let accent = Color(uiColor: accentUI)
    static let divider = Color(uiColor: dividerUI)

    /// Solid color of a highlight (swatches, color bars in Materials).
    static func solidUI(_ color: HighlightColor) -> UIColor {
        switch color {
        case .ochre: return dynamic(light: 0xD9A531, dark: 0xD8AE4E)
        case .olive: return dynamic(light: 0x86A043, dark: 0x9DB662)
        case .azure: return dynamic(light: 0x4F93CE, dark: 0x6EA9DB)
        case .cinnabar: return dynamic(light: 0xD5603F, dark: 0xE27D60)
        case .lilac: return dynamic(light: 0x9A79CF, dark: 0xB096DB)
        }
    }

    static func solid(_ color: HighlightColor) -> Color { Color(uiColor: solidUI(color)) }

    /// Translucent background used on highlighted text in the reader.
    static func highlightBackgroundUI(_ color: HighlightColor) -> UIColor {
        let solid = solidUI(color)
        return UIColor { traits in
            solid.resolvedColor(with: traits).withAlphaComponent(traits.userInterfaceStyle == .dark ? 0.34 : 0.36)
        }
    }

    /// Muted cover tones for books without an embedded cover.
    static let coverTones: [Color] = ([0x6B4F3A, 0x4F5D4A, 0x3F4E63, 0x7A3E36, 0x5B4B6B] as [UInt32]).map { Color(uiColor: UIColor(hex: $0)) }

    static func dynamic(light: UInt32, dark: UInt32) -> UIColor {
        UIColor { traits in
            traits.userInterfaceStyle == .dark ? UIColor(hex: dark) : UIColor(hex: light)
        }
    }
}

extension UIColor {
    convenience init(hex: UInt32) {
        self.init(
            red: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1
        )
    }
}

/// App-wide appearance chosen by the user.
enum AppTheme: String, CaseIterable, Identifiable {
    case system
    case paper
    case wood

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: return "Как в системе"
        case .paper: return "Бумага"
        case .wood: return "Дерево"
        }
    }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: return nil
        case .paper: return .light
        case .wood: return .dark
        }
    }
}

enum Typography {
    static func serif(_ style: Font.TextStyle, weight: Font.Weight = .regular) -> Font {
        .system(style, design: .serif).weight(weight)
    }
}

/// Russian date formatting regardless of the device language: the whole UI is Russian.
enum RussianDates {
    static let locale = Locale(identifier: "ru_RU")

    static func relative(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named).locale(locale))
    }

    static func dayAndTime(_ date: Date) -> String {
        date.formatted(Date.FormatStyle(date: .abbreviated, time: .shortened).locale(locale))
    }
}
