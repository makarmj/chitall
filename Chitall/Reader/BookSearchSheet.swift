import SwiftUI

/// Whole-book search: results as a list with context, each opens its place in the book.
/// Replaces the system Find bar, which showed matches under the keyboard (first device test).
struct BookSearchSheet: View {
    let model: ReaderModel
    var onSelect: (BookSearch.Hit) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query: String
    @State private var result: BookSearch.Result?
    @State private var isSearching = false
    @State private var isFieldActive = true

    init(model: ReaderModel, onSelect: @escaping (BookSearch.Hit) -> Void) {
        self.model = model
        self.onSelect = onSelect
        _query = State(initialValue: model.lastSearchQuery)
    }

    var body: some View {
        NavigationStack {
            List {
                if let result {
                    if result.hits.isEmpty {
                        Text("Ничего не найдено")
                            .foregroundStyle(Palette.secondaryInk)
                            .listRowBackground(Color.clear)
                    } else {
                        Section {
                            ForEach(result.hits) { hit in
                                Button { onSelect(hit) } label: { row(hit) }
                                    .listRowBackground(Palette.surface)
                            }
                        } header: {
                            Text(result.isTruncated
                                 ? "Показаны первые \(result.hits.count) совпадений"
                                 : "Совпадений: \(result.hits.count)")
                        } footer: {
                            if result.isTruncated {
                                Text("Уточните запрос, чтобы увидеть остальные.")
                            }
                        }
                    }
                } else if isSearching {
                    ProgressView()
                        .frame(maxWidth: .infinity)
                        .listRowBackground(Color.clear)
                } else {
                    Text("Ищется по всей книге, включая примечания. Регистр и «ё/е» не важны.")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryInk)
                        .listRowBackground(Color.clear)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .searchable(text: $query, isPresented: $isFieldActive, placement: .navigationBarDrawer(displayMode: .always), prompt: "Слово или фраза")
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .task(id: query) { await runSearch() }
            .navigationTitle("Поиск по книге")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    private func runSearch() async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        model.lastSearchQuery = query
        guard !trimmed.isEmpty else {
            result = nil
            return
        }
        try? await Task.sleep(for: .milliseconds(250)) // wait until typing pauses
        guard !Task.isCancelled else { return }
        isSearching = true
        let found = await model.search(trimmed)
        guard !Task.isCancelled else { return }
        result = found
        isSearching = false
    }

    private func row(_ hit: BookSearch.Hit) -> some View {
        var snippet = AttributedString(hit.before)
        var match = AttributedString(hit.match)
        match.font = Typography.serif(.body, weight: .bold)
        match.foregroundColor = Palette.accent
        snippet.append(match)
        snippet.append(AttributedString(hit.after))
        return VStack(alignment: .leading, spacing: 4) {
            Text(snippet)
                .font(Typography.serif(.body))
                .foregroundStyle(Palette.ink)
                .lineLimit(3)
            Text(model.chapters.indices.contains(hit.chapterIndex) ? model.chapters[hit.chapterIndex].title : "")
                .font(.caption)
                .foregroundStyle(Palette.secondaryInk)
                .lineLimit(1)
        }
        .padding(.vertical, 2)
    }
}
