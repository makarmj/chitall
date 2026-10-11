import Foundation

/// Human-readable export: book → chapter → quote, thought, tags, provenance.
/// Format: docs/export-format.md.
public enum MarkdownExporter {
    public static func render(_ export: MaterialExport) -> String {
        var lines: [String] = []
        let groups = export.groupedByBook
        lines.append("# Материалы Chitall")
        lines.append("")
        lines.append("- Экспорт: \(MaterialExport.dateTime(export.exportedAt, export.timeZone)) (\(export.timeZone.identifier))")
        lines.append("- Выборка: \(export.selectionDescription)")
        lines.append("- Выделений: \(export.items.count), книг: \(groups.count)")

        if export.items.isEmpty {
            lines.append("")
            lines.append("Нет материалов для экспорта.")
        }

        for group in groups {
            lines.append("")
            lines.append("---")
            lines.append("")
            lines.append("## \(oneLine(group.title.isEmpty ? "Без названия" : group.title))")
            if !group.authors.isEmpty {
                lines.append("")
                lines.append("*\(oneLine(group.authors))*")
            }

            var currentChapter: Int?
            for item in group.items {
                if item.chapterIndex != currentChapter {
                    currentChapter = item.chapterIndex
                    lines.append("")
                    lines.append("### \(oneLine(item.chapterTitle.isEmpty ? "Глава \(item.chapterIndex + 1)" : item.chapterTitle))")
                }
                lines.append("")
                lines.append(contentsOf: quoteLines(item.text))
                let note = item.note.trimmingCharacters(in: .whitespacesAndNewlines)
                if !note.isEmpty {
                    lines.append("")
                    let noteLines = note.components(separatedBy: "\n").map(escapeLineStart)
                    lines.append("**Мысль.** " + noteLines.joined(separator: "  \n"))
                }
                lines.append("")
                if !item.tags.isEmpty {
                    lines.append("- Теги: " + item.tags.map(TagNames.display).joined(separator: " "))
                }
                lines.append("- Цвет: \(item.color.displayName)")
                lines.append("- Создано: \(MaterialExport.dateTime(item.createdAt, export.timeZone))")
                if item.updatedAt.timeIntervalSince(item.createdAt) >= 60 {
                    lines.append("- Изменено: \(MaterialExport.dateTime(item.updatedAt, export.timeZone))")
                }
                lines.append("- Место: `\(item.locator.format.rawValue) \(Fingerprint.short(item.locator.book)) \(item.locator.compactDescription)`, \(MaterialExport.percent(item.locator.progression)) книги")
            }
        }
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func quoteLines(_ text: String) -> [String] {
        let paragraphs = text.components(separatedBy: "\n")
        var lines: [String] = []
        for (index, paragraph) in paragraphs.enumerated() {
            if index > 0 { lines.append(">") }
            lines.append("> " + escapeLineStart(paragraph))
        }
        return lines
    }

    /// Prevents a line of book text or a note from turning into a heading, list or quote.
    static func escapeLineStart(_ line: String) -> String {
        guard let first = line.first else { return line }
        if "#>-+*=|".contains(first) { return "\\" + line }
        let digits = line.prefix { $0.isASCII && $0.isNumber }
        if !digits.isEmpty {
            let rest = line.dropFirst(digits.count)
            if rest.hasPrefix(".") || rest.hasPrefix(")") {
                return digits + "\\" + rest
            }
        }
        return line
    }

    static func oneLine(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
    }
}
