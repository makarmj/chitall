import Foundation
import Observation
import SwiftData

enum AppTab: Hashable {
    case library
    case materials
}

struct ReaderRequest: Identifiable {
    let id = UUID()
    let book: StoredBook
    /// Opens the book at this highlight instead of the saved reading position.
    let highlightID: UUID?
}

struct AppAlert: Identifiable {
    let id = UUID()
    let title: String
    let message: String
}

/// App-level navigation and import state shared by the library, the materials and the reader.
@MainActor
@Observable
final class AppCoordinator {
    var selectedTab: AppTab = .library
    var readerRequest: ReaderRequest?
    var alert: AppAlert?
    private(set) var isImporting = false

    let files: BookFileStore
    private let importer: BookImportService

    init(files: BookFileStore) {
        self.files = files
        self.importer = BookImportService(files: files)
    }

    func open(_ book: StoredBook, highlightID: UUID? = nil) {
        readerRequest = ReaderRequest(book: book, highlightID: highlightID)
    }

    func importFiles(_ urls: [URL], context: ModelContext) async {
        guard !urls.isEmpty else { return }
        isImporting = true
        defer { isImporting = false }

        var imported: [StoredBook] = []
        var duplicates: [String] = []
        var failures: [String] = []
        for url in urls {
            do {
                switch try await importer.importFile(at: url, into: context) {
                case let .imported(book): imported.append(book)
                case let .alreadyInLibrary(book): duplicates.append(book.title)
                }
            } catch {
                failures.append("«\(url.lastPathComponent)»: \(BookImportService.message(for: error))")
            }
        }
        selectedTab = .library
        report(imported: imported, duplicates: duplicates, failures: failures)
    }

    func importSampleBook(context: ModelContext) async {
        guard let url = Bundle.main.url(forResource: "chitall-sample", withExtension: "fb2"),
              let data = try? Data(contentsOf: url) else {
            alert = AppAlert(title: "Пробная книга недоступна", message: "Файл примера не найден в приложении.")
            return
        }
        isImporting = true
        defer { isImporting = false }
        do {
            switch try await importer.importData(data, originalFileName: "chitall-sample.fb2", into: context) {
            case let .imported(book), let .alreadyInLibrary(book):
                open(book)
            }
        } catch {
            alert = AppAlert(title: "Не удалось открыть пример", message: BookImportService.message(for: error))
        }
    }

    private func report(imported: [StoredBook], duplicates: [String], failures: [String]) {
        if imported.count == 1, duplicates.isEmpty, failures.isEmpty {
            return // The new book appears at the top of the library; nothing to announce.
        }
        var lines: [String] = []
        if imported.count > 1 { lines.append("Добавлено: \(RussianPlural.books(imported.count)).") }
        if !duplicates.isEmpty { lines.append("Уже в библиотеке: " + duplicates.map { "«\($0)»" }.joined(separator: ", ") + ".") }
        lines.append(contentsOf: failures)
        guard !lines.isEmpty else { return }
        alert = AppAlert(
            title: failures.isEmpty ? "Импорт" : "Не всё удалось импортировать",
            message: lines.joined(separator: "\n\n")
        )
    }
}
