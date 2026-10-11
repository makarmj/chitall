/// Highlight colors. The raw value is stored and exported; the name is what people read.
public enum HighlightColor: String, Codable, Sendable, CaseIterable, Identifiable {
    case ochre
    case olive
    case azure
    case cinnabar
    case lilac

    public static let `default`: HighlightColor = .ochre

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .ochre: return "охра"
        case .olive: return "олива"
        case .azure: return "лазурь"
        case .cinnabar: return "киноварь"
        case .lilac: return "сирень"
        }
    }

    /// Unknown stored values (from a newer version) fall back to the default color.
    public init(storedValue: String) {
        self = HighlightColor(rawValue: storedValue) ?? .default
    }
}
