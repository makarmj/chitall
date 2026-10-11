import SwiftData
import SwiftUI

/// All highlights across books: search, filters by book, tag and color, export of the selection.
struct MaterialsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppCoordinator.self) private var coordinator
    @Query(sort: \Highlight.createdAt, order: .reverse) private var highlights: [Highlight]
    @Query private var books: [StoredBook]
    @Query(sort: [SortDescriptor(\TagRecord.sortOrder), SortDescriptor(\TagRecord.name)]) private var catalog: [TagRecord]

    @State private var filter = MaterialFilter()
    @State private var path: [UUID] = []
    @State private var exportItem: ExportItem?

    private var filtered: [Highlight] {
        highlights.filter { $0.matches(filter) }
    }

    /// Books that have highlights, including books already removed from the library.
    private var bookOptions: [BookOption] {
        var seen: [String: String] = [:]
        for highlight in highlights where seen[highlight.bookFingerprint] == nil {
            seen[highlight.bookFingerprint] = highlight.bookTitle
        }
        return seen.map { BookOption(fingerprint: $0.key, title: $0.value) }
            .sorted { $0.title.lowercased() < $1.title.lowercased() }
    }

    private var tagOptions: [String] {
        let used = Set(highlights.flatMap(\.tags))
        let ordered = catalog.map(\.name).filter(used.contains)
        return ordered + used.subtracting(ordered).sorted()
    }

    var body: some View {
        NavigationStack(path: $path) {
            Group {
                if highlights.isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Palette.background)
            .navigationTitle("Материалы")
            .searchable(text: $filter.query, prompt: "Цитата, мысль или #тег")
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        exportItem = ExportItem(export: makeExport())
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel("Экспорт")
                    .disabled(filtered.isEmpty)
                }
            }
            .navigationDestination(for: UUID.self) { id in
                if let highlight = highlights.first(where: { $0.id == id }) {
                    MaterialDetailView(
                        highlight: highlight,
                        book: books.first { $0.fingerprint == highlight.bookFingerprint },
                        onOpenInBook: { book in coordinator.open(book, highlightID: highlight.id) },
                        onDelete: { requestDeletion(of: id) }
                    )
                }
            }
            .sheet(item: $exportItem) { item in
                ExportSheet(export: item.export)
            }
        }
    }

    private var content: some View {
        List {
            Section {
                filterBar
                    .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                    .listRowBackground(Color.clear)
                    .listRowSeparator(.hidden)
            }
            if filtered.isEmpty {
                Text("Ничего не найдено. Измените поиск или сбросьте фильтры.")
                    .font(.callout)
                    .foregroundStyle(Palette.secondaryInk)
                    .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(filtered) { highlight in
                        NavigationLink(value: highlight.id) {
                            MaterialCard(highlight: highlight)
                        }
                        .listRowBackground(Palette.surface)
                    }
                } header: {
                    Text(filter.isActive ? "\(RussianPlural.highlights(filtered.count)) из \(highlights.count)" : RussianPlural.highlights(highlights.count))
                        .font(.caption)
                        .foregroundStyle(Palette.secondaryInk)
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    private var filterBar: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                Menu {
                    Button("Все книги") { filter.bookFingerprint = nil }
                    ForEach(bookOptions, id: \.fingerprint) { option in
                        Button(option.title) { filter.bookFingerprint = option.fingerprint }
                    }
                } label: {
                    FilterPill(title: selectedBookTitle ?? "Книга", isActive: filter.bookFingerprint != nil)
                }

                Menu {
                    Button("Все теги") { filter.tag = nil }
                    ForEach(tagOptions, id: \.self) { tag in
                        Button(TagNames.display(tag)) { filter.tag = tag }
                    }
                } label: {
                    FilterPill(title: filter.tag.map(TagNames.display) ?? "Тег", isActive: filter.tag != nil)
                }

                ForEach(HighlightColor.allCases) { color in
                    Button {
                        filter.color = filter.color == color ? nil : color
                    } label: {
                        Circle()
                            .fill(Palette.solid(color))
                            .frame(width: 22, height: 22)
                            .overlay {
                                if filter.color == color {
                                    Circle().stroke(Palette.ink, lineWidth: 2).padding(-3)
                                }
                            }
                            .padding(4)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Цвет \(color.displayName)")
                    .accessibilityAddTraits(filter.color == color ? .isSelected : [])
                }

                if filter.isActive {
                    Button("Сбросить") { filter = MaterialFilter() }
                        .font(.callout)
                }
            }
            .padding(.horizontal, 20)
        }
    }

    private var selectedBookTitle: String? {
        guard let fingerprint = filter.bookFingerprint else { return nil }
        return bookOptions.first { $0.fingerprint == fingerprint }?.title
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "text.quote")
                .font(.system(size: 42, weight: .ultraLight))
                .foregroundStyle(Palette.secondaryInk)
            Text("Пока нет материалов")
                .font(Typography.serif(.title2))
                .foregroundStyle(Palette.ink)
            Text("Выделите фрагмент в книге и выберите «Выделить» или «Мысль…». Цитата, ваша мысль и теги появятся здесь.")
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.secondaryInk)
                .padding(.horizontal, 36)
        }
        .padding(.bottom, 40)
    }

    private func makeExport() -> MaterialExport {
        MaterialExport(
            items: filtered.compactMap { $0.materialItem() },
            exportedAt: .now,
            selectionDescription: filter.summary(bookTitle: selectedBookTitle),
            generator: MaterialExportWriter.generator,
            timeZone: .current
        )
    }

    /// Leaves the detail screen first, then deletes: a pushed view must never read a deleted model.
    private func requestDeletion(of id: UUID) {
        guard let highlight = highlights.first(where: { $0.id == id }) else { return }
        let context = self.context
        if path.last == id { path.removeLast() }
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(450))
            context.delete(highlight)
            try? context.save()
        }
    }
}

private struct ExportItem: Identifiable {
    let id = UUID()
    let export: MaterialExport
}

private struct BookOption: Hashable {
    let fingerprint: String
    let title: String
}

private struct FilterPill: View {
    let title: String
    let isActive: Bool

    var body: some View {
        HStack(spacing: 4) {
            Text(title).lineLimit(1)
            Image(systemName: "chevron.down").font(.caption2.weight(.semibold))
        }
        .font(.callout)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .foregroundStyle(isActive ? Palette.background : Palette.ink)
        .background(isActive ? Palette.accent : Palette.surface, in: Capsule())
        .overlay(Capsule().stroke(Palette.divider, lineWidth: isActive ? 0 : 1))
    }
}

struct MaterialCard: View {
    let highlight: Highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            QuoteBlock(text: highlight.text, color: highlight.color, lineLimit: 6)
            if !highlight.note.isEmpty {
                Text(highlight.note)
                    .font(Typography.serif(.callout).italic())
                    .foregroundStyle(Palette.ink)
                    .lineLimit(4)
                    .padding(.leading, 16)
            }
            if !highlight.tags.isEmpty {
                Text(highlight.tags.map(TagNames.display).joined(separator: "  "))
                    .font(.caption)
                    .foregroundStyle(Palette.accent)
                    .padding(.leading, 16)
            }
            Text("\(highlight.bookTitle) · \(highlight.chapterTitle)")
                .font(.caption2)
                .foregroundStyle(Palette.secondaryInk)
                .lineLimit(1)
                .padding(.leading, 16)
        }
        .padding(.vertical, 6)
    }
}

struct MaterialDetailView: View {
    @Bindable var highlight: Highlight
    let book: StoredBook?
    var onOpenInBook: (StoredBook) -> Void
    var onDelete: () -> Void
    @Environment(\.modelContext) private var context

    var body: some View {
        VStack(spacing: 0) {
            if book == nil {
                Text("Книги больше нет в библиотеке. Импортируйте тот же файл, чтобы снова открыть это место.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryInk)
                    .padding(12)
                    .frame(maxWidth: .infinity)
                    .background(Palette.surface)
            }
            HighlightEditorContent(highlight: highlight, onOpenInBook: openAction, onDelete: onDelete)
        }
        .background(Palette.background)
        .navigationTitle("Выделение")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { try? context.save() }
    }

    private var openAction: (() -> Void)? {
        guard let book else { return nil }
        return { onOpenInBook(book) }
    }
}
