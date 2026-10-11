import SwiftData
import SwiftUI

struct ReaderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ReaderPreferences.fontSizeKey) private var fontSize = ReaderPreferences.defaultFontSize
    @AppStorage(ReaderPreferences.lineSpacingKey) private var lineSpacing = ReaderPreferences.defaultLineSpacing
    @AppStorage(ReaderPreferences.lastColorKey) private var lastColorRaw = HighlightColor.default.rawValue
    @AppStorage(ReaderPreferences.modeKey) private var modeRaw = ReadingMode.pages.rawValue
    @AppStorage(ReaderPreferences.pageHintShownKey) private var pageHintShown = false

    @Query private var highlights: [Highlight]
    @State private var model: ReaderModel
    @State private var editingHighlight: Highlight?
    @State private var highlightToDelete: Highlight?
    @State private var shownNote: NoteContent?
    @State private var showsContents = false
    @State private var showsSettings = false
    @State private var showsSearch = false

    private let initialHighlightID: UUID?

    init(book: StoredBook, files: BookFileStore, initialHighlightID: UUID?) {
        let fingerprint = book.fingerprint
        _highlights = Query(
            filter: #Predicate<Highlight> { $0.bookFingerprint == fingerprint },
            sort: \Highlight.progression
        )
        _model = State(initialValue: ReaderModel(book: book, files: files))
        self.initialHighlightID = initialHighlightID
    }

    private var style: ReaderStyle {
        ReaderStyle(fontSize: CGFloat(fontSize), lineSpacing: CGFloat(lineSpacing))
    }

    private var mode: ReadingMode {
        ReadingMode(rawValue: modeRaw) ?? .pages
    }

    private var textActions: ReaderTextActions {
        ReaderTextActions(
            onSelectionAction: handle,
            onTapHighlight: { id in editingHighlight = highlights.first { $0.id == id } },
            onTapLink: openLink,
            onTapText: {
                model.clearSearchHighlight()
                withAnimation(.easeInOut(duration: 0.2)) { model.chromeVisible.toggle() }
            }
        )
    }

    /// Changes whenever something drawn on the text changes: a highlight's colour, thought or
    /// place, or the current search result. Reading the properties here also lets SwiftUI
    /// observe them.
    private var decorationsToken: Int {
        var hasher = Hasher()
        for highlight in highlights {
            hasher.combine(highlight.id)
            hasher.combine(highlight.colorKey)
            hasher.combine(highlight.note.isEmpty)
            hasher.combine(highlight.locatorJSON)
        }
        if let hit = model.searchHighlight {
            hasher.combine(hit.chapter)
            hasher.combine(hit.range.location)
            hasher.combine(hit.range.length)
        }
        return hasher.finalize()
    }

    var body: some View {
        ZStack {
            Palette.background.ignoresSafeArea()
            switch model.phase {
            case .loading:
                ProgressView("Открываю книгу…")
                    .foregroundStyle(Palette.secondaryInk)
            case let .failed(message):
                failure(message)
            case .ready:
                switch mode {
                case .pages:
                    PagedBookView(
                        model: model,
                        styleKey: model.styleKey,
                        decorations: model.decorationsAroundCurrentChapter(for: highlights),
                        navigation: model.navigation,
                        actions: textActions
                    )
                    .ignoresSafeArea()
                case .scroll:
                    ContinuousBookView(
                        model: model,
                        styleKey: model.styleKey,
                        highlights: highlights,
                        decorationsToken: decorationsToken,
                        navigation: model.navigation,
                        actions: textActions
                    )
                    .ignoresSafeArea()
                }
            }
        }
        .overlay(alignment: .top) {
            if model.chromeVisible { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .overlay(alignment: .bottom) {
            if model.chromeVisible, model.isReady { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .overlay {
            if mode == .pages, model.isReady, !pageHintShown {
                PageZonesHint { withAnimation { pageHintShown = true } }
                    .transition(.opacity)
            }
        }
        // In page mode the status bar stays: hiding it would change the page size and reflow the book.
        .statusBarHidden(mode == .scroll && !model.chromeVisible)
        .task {
            let initial = initialHighlightID.flatMap { id in highlights.first { $0.id == id } }
            await model.load(style: style, initialHighlight: initial)
        }
        .onChange(of: fontSize) { model.restyle(style) }
        .onChange(of: lineSpacing) { model.restyle(style) }
        .onChange(of: modeRaw) { model.navigateToCurrentPosition() }
        .onDisappear { try? context.save() }
        .sheet(item: $editingHighlight, onDismiss: deletePendingHighlight) { highlight in
            HighlightEditorSheet(highlight: highlight, onDelete: {
                highlightToDelete = highlight
                editingHighlight = nil
            })
        }
        .sheet(item: $shownNote) { note in
            NoteSheet(note: note)
                .presentationDetents([.medium, .large])
        }
        .sheet(isPresented: $showsSearch) {
            BookSearchSheet(model: model) { hit in
                model.go(to: hit)
                showsSearch = false
            }
        }
        .sheet(isPresented: $showsContents) {
            TableOfContentsView(
                model: model,
                unresolvedCount: model.unresolvedCount(in: highlights),
                onSelectChapter: { index in
                    model.show(chapter: index)
                    showsContents = false
                },
                onSelectEntry: { entry in
                    model.go(toBlock: entry.firstBlock)
                    showsContents = false
                }
            )
        }
        .sheet(isPresented: $showsSettings) {
            ReaderSettingsView()
                .presentationDetents([.height(430)])
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 16) {
            Button {
                try? context.save()
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 36, height: 36)
            }
            .accessibilityLabel("Закрыть книгу")

            VStack(spacing: 2) {
                Text(model.currentChapter?.title ?? model.storedBook.title)
                    .font(Typography.serif(.subheadline, weight: .semibold))
                    .lineLimit(1)
                Text(model.storedBook.title)
                    .font(.caption2)
                    .foregroundStyle(Palette.secondaryInk)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)

            Button { showsSearch = true } label: {
                Image(systemName: "magnifyingglass").frame(width: 32, height: 36)
            }
            .accessibilityLabel("Поиск по книге")
            .disabled(!model.isReady)

            Button { showsContents = true } label: {
                Image(systemName: "list.bullet").frame(width: 32, height: 36)
            }
            .accessibilityLabel("Оглавление")
            .disabled(!model.isReady)

            Button { showsSettings = true } label: {
                Image(systemName: "textformat.size").frame(width: 32, height: 36)
            }
            .accessibilityLabel("Оформление и режим чтения")
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.background.opacity(0.96))
        .overlay(alignment: .bottom) { Divider().background(Palette.divider) }
    }

    private var bottomBar: some View {
        HStack {
            Button { model.showPreviousChapter() } label: {
                Image(systemName: "chevron.left").frame(width: 44, height: 36)
            }
            .disabled(!model.hasPreviousChapter)
            .accessibilityLabel("Предыдущая глава")

            Spacer()
            Text(progressText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Palette.secondaryInk)
            Spacer()

            Button { model.showNextChapter() } label: {
                Image(systemName: "chevron.right").frame(width: 44, height: 36)
            }
            .disabled(!model.hasNextChapter)
            .accessibilityLabel("Следующая глава")
        }
        .foregroundStyle(Palette.ink)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Palette.background.opacity(0.96))
        .overlay(alignment: .top) { Divider().background(Palette.divider) }
    }

    private var progressText: String {
        let percent = Int((model.storedBook.readingProgress * 100).rounded())
        let chapter = "гл. \(model.chapterIndex + 1) из \(model.chapters.count)"
        if mode == .pages, let status = model.pageStatus {
            let left = status.pageCount - status.page - 1
            let rest = left > 0 ? "ещё \(left) стр. в главе" : "последняя стр. главы"
            return "\(chapter) · \(rest) · \(percent) %"
        }
        return "\(chapter) · \(percent) %"
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "book.closed")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Palette.secondaryInk)
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Palette.ink)
            Button("Закрыть") { dismiss() }
                .buttonStyle(.borderedProminent)
        }
        .padding(32)
    }

    // MARK: Actions

    private func handle(_ action: SelectionAction) {
        switch action {
        case let .highlight(selection, color):
            lastColorRaw = color.rawValue
            _ = model.createHighlight(for: selection, color: color, context: context)
        case let .highlightWithThought(selection):
            let color = HighlightColor(storedValue: lastColorRaw)
            editingHighlight = model.createHighlight(for: selection, color: color, context: context)
        case let .open(id):
            editingHighlight = highlights.first { $0.id == id }
        }
    }

    private func openLink(_ url: URL) {
        switch model.target(of: url) {
        case let .note(note):
            shownNote = note
        case let .block(ordinal):
            model.go(toBlock: ordinal)
        case nil:
            break
        }
    }

    private func deletePendingHighlight() {
        guard let highlight = highlightToDelete else { return }
        highlightToDelete = nil
        context.delete(highlight)
        try? context.save()
    }
}

struct NoteSheet: View {
    let note: NoteContent
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                Text(note.text.isEmpty ? "Текст примечания пуст." : note.text)
                    .font(Typography.serif(.body))
                    .foregroundStyle(Palette.ink)
                    .lineSpacing(4)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(20)
            }
            .background(Palette.background)
            .navigationTitle(note.title.isEmpty ? "Примечание" : "Примечание \(note.title)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
