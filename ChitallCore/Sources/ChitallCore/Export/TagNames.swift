/// Tag names are stored without `#`, lowercased, with inner whitespace replaced by `_`,
/// so `#Тайна`, `тайна` and ` #ТАЙНА ` are the same tag.
public enum TagNames {
    public static let defaults = ["место", "свет", "звук", "предмет", "персонаж", "тайна", "конфликт", "реплика", "кадр"]
    public static let maximumLength = 40

    public static func normalize(_ raw: String) -> String? {
        var name = raw.trimmingLeadingHashesAndWhitespace()
        guard !name.isEmpty else { return nil }
        name = name.lowercased()
        var result = ""
        var lastWasSeparator = false
        for character in name {
            if character.isWhitespace {
                if !lastWasSeparator, !result.isEmpty { result.append("_") }
                lastWasSeparator = true
            } else if character == "," || character == "#" {
                continue
            } else {
                result.append(character)
                lastWasSeparator = false
            }
        }
        while result.hasSuffix("_") { result.removeLast() }
        guard !result.isEmpty else { return nil }
        return String(result.prefix(maximumLength))
    }

    /// Parses user input like `#тайна #кадр, старый город` into distinct normalized names.
    /// `#` and `,` separate tags; plain spaces inside a tag without `#` are kept as `_`.
    public static func parseList(_ input: String) -> [String] {
        var names: [String] = []
        let pieces = input.split(whereSeparator: { $0 == "," || $0 == "#" || $0 == "\n" })
        for piece in pieces {
            guard let name = normalize(String(piece)), !names.contains(name) else { continue }
            names.append(name)
        }
        return names
    }

    /// Distinct normalized names, in first-seen order.
    public static func normalizeAll(_ names: [String]) -> [String] {
        var result: [String] = []
        for name in names {
            guard let normalized = normalize(name), !result.contains(normalized) else { continue }
            result.append(normalized)
        }
        return result
    }

    public static func display(_ name: String) -> String { "#" + name }
}

extension String {
    fileprivate func trimmingLeadingHashesAndWhitespace() -> String {
        var scalars = Substring(self)
        while let first = scalars.first, first.isWhitespace || first == "#" { scalars.removeFirst() }
        while let last = scalars.last, last.isWhitespace { scalars.removeLast() }
        return String(scalars)
    }
}
