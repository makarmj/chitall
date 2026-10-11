import SwiftData
import SwiftUI

struct ReaderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @AppStorage(ReaderPreferences.fontSizeKey) private var fontSize = ReaderPreferences.defaultFontSize
    @AppStorage(ReaderPreferences.lineSpacingKey) private var lineSpacing = ReaderPreferences.defaultLineSpacing
    @AppStorage(ReaderPreferences.lastColorKey) private var lastColorRaw = HighlightColor.default.rawValue

    @Query private var highlights: [Highlight]
    @State private var model: ReaderModel
    @State private var editingHighlight: Highlight?
    @State private var highlightToDelete: Highlight?
    @State private var shownNote: NoteContent?
    @State private var showsContents = false
    @State private var showsSettings = false

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
                if let rendered = model.rendered {
                    BookTextView(
                        content: rendered,
                        decorations: model.decorations(for: highlights),
                        scrollRequest: model.scrollRequest,
                        findRequest: model.findRequest,
                        onSelectionAction: handle,
                        onTapHighlight: { id in editingHighlight = highlights.first { $0.id == id } },
                        onTapLink: openLink,
                        onTapText: { withAnimation(.easeInOut(duration: 0.2)) { model.chromeVisible.toggle() } },
                        onVisibleOffsetChange: { model.saveReadingPosition(atUTF16: $0) }
                    )
                    .ignoresSafeArea(edges: .bottom)
                }
            }
        }
        .overlay(alignment: .top) {
            if model.chromeVisible { topBar.transition(.move(edge: .top).combined(with: .opacity)) }
        }
        .overlay(alignment: .bottom) {
            if model.chromeVisible, model.isReady { bottomBar.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .statusBarHidden(!model.chromeVisible)
        .task {
            let initial = initialHighlightID.flatMap { id in highlights.first { $0.id == id } }
            await model.load(style: style, initialHighlight: initial)
        }
        .onChange(of: fontSize) { model.restyle(style) }
        .onChange(of: lineSpacing) { model.restyle(style) }
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
                .presentationDetents([.height(360)])
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

            Button { model.findRequest = UUID() } label: {
                Image(systemName: "magnifyingglass").frame(width: 32, height: 36)
            }
            .accessibilityLabel("Найти в главе")
            .disabled(!model.isReady)

            Button { showsContents = true } label: {
                Image(systemName: "list.bullet").frame(width: 32, height: 36)
            }
            .accessibilityLabel("Оглавление")
            .disabled(!model.isReady)

            Button { showsSettings = true } label: {
                Image(systemName: "textformat.size").frame(width: 32, height: 36)
            }
            .accessibilityLabel("Оформление текста")
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
        return "Глава \(model.chapterIndex + 1) из \(model.chapters.count) · \(percent) %"
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
        case let .highlight(range, color):
            lastColorRaw = color.rawValue
            _ = model.createHighlight(for: range, color: color, context: context)
        case let .highlightWithThought(range):
            let color = HighlightColor(storedValue: lastColorRaw)
            editingHighlight = model.createHighlight(for: range, color: color, context: context)
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
