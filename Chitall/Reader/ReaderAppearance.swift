import CoreText
import SwiftUI
import UIKit

/// Colours of the reading surface. Independent of the app theme: you can keep the library
/// light and read on black, as in most readers.
enum ReaderTheme: String, CaseIterable, Identifiable {
    case white
    case paper
    case gray
    case black
    case wood
    case system

    var id: String { rawValue }

    var title: String {
        switch self {
        case .white: return "Белый"
        case .paper: return "Бумага"
        case .gray: return "Серый"
        case .black: return "Чёрный"
        case .wood: return "Дерево"
        case .system: return "Как в системе"
        }
    }

    /// `system` follows the device: paper by day, wood at night.
    func resolved(for scheme: ColorScheme) -> ReaderTheme {
        guard self == .system else { return self }
        return scheme == .dark ? .wood : .paper
    }

    var isDark: Bool {
        switch self {
        case .gray, .black, .wood: return true
        case .white, .paper, .system: return false
        }
    }

    var colors: ThemeColors {
        switch self {
        case .white:
            return ThemeColors(background: 0xFFFFFF, text: 0x1F1F1F, secondary: 0x6E6E73, accent: 0x8A5A2C, chrome: 0xF6F6F6, divider: 0xE3E3E3)
        case .paper, .system:
            return ThemeColors(background: 0xF5EFE3, text: 0x2A241E, secondary: 0x6F655A, accent: 0x8A5A2C, chrome: 0xEFE7D8, divider: 0xE0D5C1)
        case .gray:
            return ThemeColors(background: 0x4A4A4D, text: 0xE8E8E8, secondary: 0xB4B4B8, accent: 0xE0B57A, chrome: 0x3F3F42, divider: 0x5C5C60)
        case .black:
            return ThemeColors(background: 0x000000, text: 0xD4D4D4, secondary: 0x8E8E93, accent: 0xD3A46B, chrome: 0x111111, divider: 0x2A2A2A)
        case .wood:
            return ThemeColors(background: 0x1C1712, text: 0xE8DECD, secondary: 0xA8998A, accent: 0xD3A46B, chrome: 0x231C16, divider: 0x3A3027)
        }
    }
}

struct ThemeColors {
    let background: UIColor
    let text: UIColor
    let secondary: UIColor
    let accent: UIColor
    let chrome: UIColor
    let divider: UIColor

    init(background: UInt32, text: UInt32, secondary: UInt32, accent: UInt32, chrome: UInt32, divider: UInt32) {
        self.background = UIColor(hex: background)
        self.text = UIColor(hex: text)
        self.secondary = UIColor(hex: secondary)
        self.accent = UIColor(hex: accent)
        self.chrome = UIColor(hex: chrome)
        self.divider = UIColor(hex: divider)
    }
}

/// Book fonts. All of them have Cyrillic; a missing family falls back to the system serif.
/// Source Serif 4 is bundled with the app (Adobe, SIL Open Font License 1.1, see Resources/Fonts):
/// the closest open font to the text face of Claude, which itself is not licensed for apps.
enum ReaderFont: String, CaseIterable, Identifiable {
    case sourceSerif
    case newYork
    case ptSerif
    case georgia
    case ptSans
    case sanFrancisco

    var id: String { rawValue }

    var title: String {
        switch self {
        case .sourceSerif: return "Source Serif"
        case .newYork: return "New York"
        case .ptSerif: return "PT Serif"
        case .georgia: return "Georgia"
        case .ptSans: return "PT Sans"
        case .sanFrancisco: return "SF Pro"
        }
    }

    /// Family name for `UIFontDescriptor`, `nil` for the system designs.
    var familyName: String? {
        switch self {
        case .newYork, .sanFrancisco: return nil
        case .sourceSerif: return "Source Serif 4"
        case .ptSerif: return "PT Serif"
        case .georgia: return "Georgia"
        case .ptSans: return "PT Sans"
        }
    }

    /// Fonts actually installed on this device (system designs always are).
    static var available: [ReaderFont] { allCases.filter(\.isInstalled) }

    var isInstalled: Bool {
        guard let familyName else { return true }
        return UIFont.familyNames.contains(familyName)
    }

    func font(size: CGFloat, weight: UIFont.Weight = .regular, traits: UIFontDescriptor.SymbolicTraits = []) -> UIFont {
        // A family missing on this iOS falls back to the book serif, never to a random font.
        guard isInstalled else { return ReaderFont.newYork.font(size: size, weight: weight, traits: traits) }
        var traits = traits
        let descriptor: UIFontDescriptor
        if let familyName {
            // Named families have no weight axis here: anything heavier than regular is bold.
            if weight.rawValue > UIFont.Weight.regular.rawValue { traits.insert(.traitBold) }
            descriptor = UIFontDescriptor(fontAttributes: [.family: familyName])
        } else {
            let base = UIFont.systemFont(ofSize: size, weight: weight).fontDescriptor
            descriptor = self == .newYork ? (base.withDesign(.serif) ?? base) : base
        }
        var styled = descriptor
        if !traits.isEmpty, let withTraits = descriptor.withSymbolicTraits(descriptor.symbolicTraits.union(traits)) {
            styled = withTraits
        }
        return UIFont(descriptor: styled, size: size)
    }

    /// Font for the settings preview.
    func previewFont(size: CGFloat) -> Font {
        Font(font(size: size) as CTFont)
    }
}

enum ReaderSpacing: String, CaseIterable, Identifiable {
    case compact
    case normal
    case relaxed

    var id: String { rawValue }

    var lineHeightMultiple: CGFloat {
        switch self {
        case .compact: return 1.2
        case .normal: return 1.4
        case .relaxed: return 1.65
        }
    }

    var title: String {
        switch self {
        case .compact: return "Плотный интервал"
        case .normal: return "Обычный интервал"
        case .relaxed: return "Свободный интервал"
        }
    }
}

enum ReaderMargins: String, CaseIterable, Identifiable {
    case narrow
    case normal
    case wide

    var id: String { rawValue }

    var points: CGFloat {
        switch self {
        case .narrow: return 14
        case .normal: return 24
        case .wide: return 38
        }
    }

    var title: String {
        switch self {
        case .narrow: return "Узкие поля"
        case .normal: return "Обычные поля"
        case .wide: return "Широкие поля"
        }
    }
}

/// Everything the attributed text and the page layout depend on.
struct ReaderStyle: Equatable {
    var fontSize: CGFloat
    var lineSpacing: CGFloat
    var font: ReaderFont = .newYork
    /// Already resolved: never `.system`.
    var theme: ReaderTheme = .paper
    var justified = true
    var margins: ReaderMargins = .normal
    /// Book language for hyphenation (FB2 `lang`).
    var language = "ru"

    var key: String {
        "\(fontSize)|\(lineSpacing)|\(font.rawValue)|\(theme.rawValue)|\(justified)|\(margins.rawValue)|\(language)"
    }

    var colors: ThemeColors { theme.colors }
}

/// Screen brightness for reading. The original value comes back when the reader closes or
/// the app goes to the background.
@MainActor
enum ReaderBrightness {
    private static var original: CGFloat?

    static var screen: UIScreen? {
        UIApplication.shared.connectedScenes.compactMap { ($0 as? UIWindowScene)?.screen }.first
    }

    static func apply(_ value: Double) {
        guard let screen else { return }
        if original == nil { original = screen.brightness }
        screen.brightness = CGFloat(max(0.02, min(1, value)))
    }

    static func restore() {
        guard let original, let screen else { return }
        screen.brightness = original
        self.original = nil
    }

    static var current: Double {
        Double(screen?.brightness ?? 0.5)
    }
}
