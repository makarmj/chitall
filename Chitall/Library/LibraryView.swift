import SwiftData
import SwiftUI
import UIKit

struct LibraryView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppCoordinator.self) private var coordinator
    @Query private var books: [StoredBook]
    @Query private var highlights: [Highlight]
    @State private var showsImporter = false
    @State private var showsSettings = false
    @State private var bookToDelete: StoredBook?

    private var sortedBooks: [StoredBook] {
        books.sorted { $0.recencyDate > $1.recencyDate }
    }

    private var highlightCounts: [String: Int] {
        Dictionary(grouping: highlights, by: \.bookFingerprint).mapValues(\.count)
    }

    var body: some View {
        NavigationStack {
            Group {
                if books.isEmpty {
                    emptyState
                } else {
                    bookList
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
            .navigationTitle("Библиотека")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button { showsSettings = true } label: {
                        Image(systemName: "gearshape")
                    }
                    .accessibilityLabel("Настройки")
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showsImporter = true } label: {
                        Image(systemName: "plus")
                    }
                    .accessibilityLabel("Импортировать книгу")
                }
            }
            .fileImporter(
                isPresented: $showsImporter,
                allowedContentTypes: BookFileTypes.importable,
                allowsMultipleSelection: true
            ) { result in
                switch result {
                case let .success(urls):
                    Task { await coordinator.importFiles(urls, context: context) }
                case let .failure(error):
                    coordinator.alert = AppAlert(title: "Не удалось открыть файл", message: error.localizedDescription)
                }
            }
            .confirmationDialog(
                deletionTitle,
                isPresented: Binding(get: { bookToDelete != nil }, set: { if !$0 { bookToDelete = nil } }),
                titleVisibility: .visible,
                presenting: bookToDelete
            ) { book in
                let count = highlightCounts[book.fingerprint] ?? 0
                if count > 0 {
                    Button("Удалить книгу, оставить материалы") { delete(book, keepMaterials: true) }
                    Button("Удалить вместе с материалами", role: .destructive) { delete(book, keepMaterials: false) }
                } else {
                    Button("Удалить книгу", role: .destructive) { delete(book, keepMaterials: false) }
                }
                Button("Отмена", role: .cancel) {}
            } message: { book in
                let count = highlightCounts[book.fingerprint] ?? 0
                if count > 0 {
                    Text("С книгой связано \(RussianPlural.highlights(count)). Их можно оставить: в «Материалах» сохранятся цитаты, мысли, теги и источник.")
                } else {
                    Text("Файл книги будет удалён с устройства.")
                }
            }
            .sheet(isPresented: $showsSettings) {
                SettingsView()
            }
        }
    }

    private var deletionTitle: String {
        bookToDelete.map { "Удалить «\($0.title)»?" } ?? ""
    }

    private var bookList: some View {
        List {
            ForEach(sortedBooks) { book in
                Button {
                    coordinator.open(book)
                } label: {
                    BookRow(book: book, files: coordinator.files, highlightCount: highlightCounts[book.fingerprint] ?? 0)
                }
                .buttonStyle(.plain)
                .listRowBackground(Palette.background)
                .swipeActions(edge: .trailing) {
                    Button { bookToDelete = book } label: {
                        Label("Удалить", systemImage: "trash")
                    }
                    .tint(.red)
                }
                .contextMenu {
                    Button { coordinator.open(book) } label: { Label("Читать", systemImage: "book") }
                    Button(role: .destructive) { bookToDelete = book } label: { Label("Удалить…", systemImage: "trash") }
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    private var emptyState: some View {
        VStack(spacing: 18) {
            Image(systemName: "book.closed")
                .font(.system(size: 46, weight: .ultraLight))
                .foregroundStyle(Palette.secondaryInk)
            Text("Здесь будут ваши книги")
                .font(Typography.serif(.title2))
                .foregroundStyle(Palette.ink)
            Text("Импортируйте свой DRM-free файл EPUB, FB2 или FB2.ZIP из «Файлов». Книга и заметки хранятся только на этом устройстве.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.secondaryInk)
                .padding(.horizontal, 32)
            Button {
                showsImporter = true
            } label: {
                Text("Импортировать книгу")
                    .frame(maxWidth: 240)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            Button("Открыть пробную книгу") {
                Task { await coordinator.importSampleBook(context: context) }
            }
            .font(.callout)
        }
        .padding(.bottom, 40)
    }

    private func delete(_ book: StoredBook, keepMaterials: Bool) {
        do {
            try LibraryActions.delete(book, keepMaterials: keepMaterials, context: context, files: coordinator.files)
        } catch {
            coordinator.alert = AppAlert(title: "Не удалось удалить книгу", message: error.localizedDescription)
        }
        bookToDelete = nil
    }
}

struct BookRow: View {
    let book: StoredBook
    let files: BookFileStore
    let highlightCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            BookCover(book: book, files: files)
                .frame(width: 62, height: 92)
            VStack(alignment: .leading, spacing: 5) {
                Text(book.title)
                    .font(Typography.serif(.headline, weight: .semibold))
                    .foregroundStyle(Palette.ink)
                    .lineLimit(3)
                if !book.authors.isEmpty {
                    Text(book.authors)
                        .font(Typography.serif(.subheadline))
                        .foregroundStyle(Palette.secondaryInk)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Text(statusLine)
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private var statusLine: String {
        var parts: [String] = []
        if let opened = book.lastOpenedAt {
            parts.append("Читали \(RussianDates.relative(opened))")
            parts.append("\(Int((book.readingProgress * 100).rounded())) %")
        } else {
            parts.append("Ещё не открывали")
        }
        if highlightCount > 0 { parts.append(RussianPlural.highlights(highlightCount)) }
        return parts.joined(separator: " · ")
    }
}

/// Embedded cover if the book has one, otherwise a calm typographic placeholder.
struct BookCover: View {
    let book: StoredBook
    let files: BookFileStore

    var body: some View {
        Group {
            if let name = book.coverFileName, let image = CoverCache.image(at: files.coverURL(named: name)) {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                placeholder
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .shadow(color: .black.opacity(0.18), radius: 2, x: 0, y: 1)
        .accessibilityHidden(true)
    }

    private var placeholder: some View {
        let tones = Palette.coverTones
        let seed = book.fingerprint.unicodeScalars.reduce(0) { ($0 &+ Int($1.value)) % 997 }
        return ZStack {
            tones[seed % tones.count]
            RoundedRectangle(cornerRadius: 2)
                .stroke(Color.white.opacity(0.35), lineWidth: 0.6)
                .padding(5)
            VStack(spacing: 4) {
                Text(book.title)
                    .font(.system(size: 9, weight: .semibold, design: .serif))
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                if !book.authors.isEmpty {
                    Text(book.authors)
                        .font(.system(size: 7, design: .serif))
                        .lineLimit(2)
                        .multilineTextAlignment(.center)
                }
            }
            .foregroundStyle(Color.white.opacity(0.92))
            .padding(9)
        }
    }
}

@MainActor
enum CoverCache {
    private static let cache = NSCache<NSURL, UIImage>()

    static func image(at url: URL) -> UIImage? {
        if let cached = cache.object(forKey: url as NSURL) { return cached }
        guard let image = UIImage(contentsOfFile: url.path) else { return nil }
        cache.setObject(image, forKey: url as NSURL)
        return image
    }
}
