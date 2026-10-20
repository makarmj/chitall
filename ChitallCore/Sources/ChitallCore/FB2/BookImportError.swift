import Foundation

/// Everything that can go wrong while turning a user's file into a book, with a message
/// the app can show as is.
public enum BookImportError: Error, Equatable, Sendable {
    case emptyFile
    case fileTooLarge(bytes: Int, limit: Int)
    case unsupportedEncoding(String)
    case malformedXML(line: Int, column: Int, reason: String)
    case notFictionBook(rootElement: String)
    case noBody
    case noText
    case archiveWithoutFB2
    case damagedArchive(String)
    case unsupportedArchive(String)
    /// EPUB with encrypted content (Adobe, Apple, Readium LCP…): never decrypted.
    case drmProtected
    /// EPUB whose container or package is broken; the text says what, in Russian.
    case damagedEPUB(String)

    public var userMessage: String {
        switch self {
        case .emptyFile:
            return "Файл пустой."
        case let .fileTooLarge(bytes, limit):
            return "Файл слишком большой: \(bytes / 1_048_576) МБ при пределе \(limit / 1_048_576) МБ."
        case let .unsupportedEncoding(label):
            return "Кодировка «\(label)» не поддерживается. Пересохраните книгу в UTF-8 или windows-1251."
        case let .malformedXML(line, column, _):
            return "Файл повреждён или это не FB2: ошибка XML в строке \(line), позиции \(column)."
        case let .notFictionBook(root):
            return root.isEmpty
                ? "Это не книга FB2."
                : "Это не книга FB2: корневой элемент «\(root)» вместо «FictionBook»."
        case .noBody:
            return "В книге нет текста: отсутствует раздел body."
        case .noText:
            return "В книге нет ни одного абзаца текста."
        case .archiveWithoutFB2:
            return "В архиве нет книги: ни файла .fb2, ни EPUB."
        case .damagedArchive:
            return "Архив повреждён."
        case let .unsupportedArchive(reason):
            return "Этот архив не поддерживается (\(reason)). Распакуйте его в «Файлах» и импортируйте .fb2."
        case .drmProtected:
            return "Книга защищена DRM: её текст зашифрован. Chitall открывает только книги без защиты — "
                + "файлы, купленные без DRM, или свои собственные."
        case let .damagedEPUB(reason):
            return "Файл EPUB повреждён: \(reason)."
        }
    }
}

extension BookImportError: LocalizedError {
    public var errorDescription: String? { userMessage }
}
