import SwiftData
import SwiftUI

struct ReaderView: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage(ReaderPreferences.fontSizeKey) private var fontSize = ReaderPreferences.defaultFontSize
    @AppStorage(ReaderPreferences.fontKey) private var fontRaw = ReaderFont.sourceSerif.rawValue
    @AppStorage(ReaderPreferences.spacingKey) private var spacingRaw = ReaderSpacing.normal.rawValue
    @AppStorage(ReaderPreferences.marginsKey) private var marginsRaw = ReaderMargins.normal.rawValue
    @AppStorage(ReaderPreferences.justifiedKey) private var justified = true
    @AppStorage(ReaderPreferences.readerThemeKey) private var themeRaw = ReaderTheme.system.rawValue
    @AppStorage(ReaderPreferences.lastColorKey) private var lastColorRaw = HighlightColor.default.rawValue
    @AppStorage(ReaderPreferences.modeKey) private var modeRaw = ReadingMode.pages.rawValue
    @AppStorage(ReaderPreferences.pageHintShownKey) private var pageHintShown = false

    @Query private var highlights: [Highlight]
    @Query private var bookmarks: [Bookmark]
    @Query(sort: [SortDescriptor(\TagRecord.sortOrder), SortDescriptor(\TagRecord.name)]) private var tagCatalog: [TagRecord]
    @State private var model: ReaderModel
    @State private var editingHighlight: Highlight?
    @State private var highlightToDelete: Highlight?
    @State private var shownNote: NoteContent?
    @State private var contentsTab: ContentsTab?
    @State private var showsSettings = false
    @State private var showsSearch = false
    @State private var showsBookInfo = false
    @State private var bookExport: BookExportItem?
    @State private var scrubValue: Double?
    /// Brightness chosen in the reader; `nil` while untouched (the system value stays).
    @State private var brightness: Double?

    private let initialHighlightID: UUID?

    init(book: StoredBook, files: BookFileStore, initialHighlightID: UUID?) {
        let fingerprint = book.fingerprint
        _highlights = Query(
            filter: #Predicate<Highlight> { $0.bookFingerprint == fingerprint },
            sort: \Highlight.progression
        )
        _bookmarks = Query(
            filter: #Predicate<Bookmark> { $0.bookFingerprint == fingerprint },
            sort: \Bookmark.progression
        )
        _model = State(initialValue: ReaderModel(book: book, files: files))
        self.initialHighlightID = initialHighlightID
    }

    private var theme: ReaderTheme {
        (ReaderTheme(rawValue: themeRaw) ?? .system).resolved(for: colorScheme)
    }

    private var colors: ThemeColors { theme.colors }

    private var style: ReaderStyle {
        ReaderStyle(
            fontSize: CGFloat(fontSize),
            lineSpacing: (ReaderSpacing(rawValue: spacingRaw) ?? .normal).lineHeightMultiple,
            font: ReaderFont(rawValue: fontRaw) ?? .sourceSerif,
            theme: theme,
            justified: justified,
            margins: ReaderMargins(rawValue: marginsRaw) ?? .normal
        )
    }

    private var mode: ReadingMode {
        ReadingMode(rawValue: modeRaw) ?? .pages
    }

    /// Explicit themes set light or dark for the whole reader (status bar, sheets);
    /// "Как в системе" leaves it to the device.
    private var preferredScheme: ColorScheme? {
        guard ReaderTheme(rawValue: themeRaw) != .system else { return nil }
        return theme.isDark ? .dark : .light
    }

    private var textActions: ReaderTextActions {
        ReaderTextActions(
            onSelectionAction: handle,
            onTapHighlight: { id in editingHighlight = highlights.first { $0.id == id } },
            onTapLink: openLink,
            onTapText: {
                model.clearSearchHighlight()
                withAnimation(.easeInOut(duration: 0.2)) { model.chromeVisible.toggle() }
            },
            quickTags: tagCatalog.map(\.name)
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
            Color(uiColor: colors.background).ignoresSafeArea()
            switch model.phase {
            case .loading:
                ProgressView("Открываю книгу…")
                    .foregroundStyle(Color(uiColor: colors.secondary))
            case let .failed(message):
                failure(message)
            case .ready:
                switch mode {
                case .pages:
                    PagedBookView(
                        model: model,
                        style: model.style,
                        decorations: model.decorationsAroundCurrentChapter(for: highlights),
                        numbering: model.pageNumbering,
                        bookmarks: model.bookmarkOffsetsAroundCurrentChapter(bookmarks),
                        navigation: model.navigation,
                        actions: textActions
                    )
                    .ignoresSafeArea()
                case .scroll:
                    ContinuousBookView(
                        model: model,
                        style: model.style,
                        highlights: highlights,
                        decorationsToken: decorationsToken,
                        bookmarks: model.bookmarkOffsets(bookmarks),
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
            if model.chromeVisible, model.isReady { bottomPanel.transition(.move(edge: .bottom).combined(with: .opacity)) }
        }
        .overlay {
            if mode == .pages, model.isReady, !pageHintShown {
                PageZonesHint { withAnimation { pageHintShown = true } }
                    .transition(.opacity)
            }
        }
        // In page mode the status bar stays: hiding it would change the page size and reflow the book.
        .statusBarHidden(mode == .scroll && !model.chromeVisible)
        .preferredColorScheme(preferredScheme)
        .task {
            let initial = initialHighlightID.flatMap { id in highlights.first { $0.id == id } }
            await model.load(style: style, initialHighlight: initial)
        }
        .onChange(of: style) { model.restyle(style) }
        .onChange(of: modeRaw) { model.navigateToCurrentPosition() }
        .onChange(of: brightness) {
            if let brightness { ReaderBrightness.apply(brightness) }
        }
        .onChange(of: scenePhase) {
            // Give the system its brightness back while Chitall is not on screen.
            if scenePhase == .active {
                if let brightness { ReaderBrightness.apply(brightness) }
            } else {
                ReaderBrightness.restore()
            }
        }
        .onDisappear {
            ReaderBrightness.restore()
            try? context.save()
        }
        .sheet(item: $editingHighlight, onDismiss: deletePendingHighlight) { highlight in
            HighlightEditorSheet(highlight: highlight, onDelete: {
                highlightToDelete = highlight
                editingHighlight = nil
            })
        }
        .sheet(item: $shownNote) { note in
            NoteCard(note: note, style: model.style)
        }
        .sheet(isPresented: $showsSearch) {
            BookSearchSheet(model: model) { hit in
                model.go(to: hit)
                showsSearch = false
            }
        }
        .sheet(item: $contentsTab) { tab in
            ContentsSheet(
                model: model,
                highlights: highlights,
                bookmarks: bookmarks,
                initialTab: tab,
                onSelectChapter: { index in
                    model.show(chapter: index)
                    contentsTab = nil
                },
                onSelectEntry: { entry in
                    model.go(toBlock: entry.firstBlock)
                    contentsTab = nil
                },
                onSelectHighlight: { highlight in
                    model.go(to: highlight)
                    contentsTab = nil
                },
                onSelectBookmark: { bookmark in
                    model.go(to: bookmark)
                    contentsTab = nil
                },
                onDeleteBookmark: { bookmark in
                    context.delete(bookmark)
                    try? context.save()
                }
            )
        }
        .sheet(isPresented: $showsSettings) {
            ReaderSettingsView(brightness: $brightness, colors: colors, isDark: theme.isDark)
                .presentationDetents([.height(500), .large])
                .presentationBackground(Color(uiColor: colors.chrome))
        }
        .sheet(isPresented: $showsBookInfo) {
            BookInfoSheet(book: model.storedBook, metadata: model.book?.metadata, highlightCount: highlights.count)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $bookExport) { item in
            ExportSheet(export: item.export)
        }
    }

    // MARK: Bars

    private var topBar: some View {
        HStack(spacing: 14) {
            Button {
                try? context.save()
                dismiss()
            } label: {
                Image(systemName: "chevron.down")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(Color(uiColor: colors.background).opacity(0.7), in: Circle())
            }
            .accessibilityLabel("Закрыть книгу")

            VStack(alignment: .leading, spacing: 1) {
                Text(model.storedBook.title)
                    .font(Typography.serif(.headline, weight: .semibold))
                    .lineLimit(1)
                if !model.storedBook.authors.isEmpty {
                    Text(model.storedBook.authors)
                        .font(.subheadline)
                        .foregroundStyle(Color(uiColor: colors.secondary))
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)

            Menu {
                Button { showsSearch = true } label: { Label("Поиск по книге", systemImage: "magnifyingglass") }
                Button { contentsTab = .chapters } label: { Label("Оглавление", systemImage: "list.bullet") }
                Button { contentsTab = .highlights } label: { Label("Выделения книги", systemImage: "text.quote") }
                Button { contentsTab = .bookmarks } label: { Label("Закладки", systemImage: "bookmark") }
                Button { bookExport = makeBookExport() } label: { Label("Экспорт материалов книги", systemImage: "square.and.arrow.up") }
                    .disabled(highlights.isEmpty)
                Button { showsBookInfo = true } label: { Label("О книге", systemImage: "info.circle") }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
                    .background(Color(uiColor: colors.background).opacity(0.7), in: Circle())
            }
            .accessibilityLabel("Ещё")
            .disabled(!model.isReady)
        }
        .foregroundStyle(Color(uiColor: colors.text))
        .padding(.horizontal, 14)
        .padding(.top, 4)
        .padding(.bottom, 10)
        .background(Color(uiColor: colors.chrome).ignoresSafeArea(edges: .top))
        .overlay(alignment: .bottom) { Rectangle().fill(Color(uiColor: colors.divider)).frame(height: 0.5) }
    }

    private var bottomPanel: some View {
        VStack(spacing: 10) {
            HStack {
                Button { contentsTab = .chapters } label: {
                    Image(systemName: "list.bullet").font(.title3)
                }
                .accessibilityLabel("Оглавление")
                Spacer()
                Text(chapterStatus)
                    .font(.subheadline)
                    .monospacedDigit()
                    .foregroundStyle(Color(uiColor: colors.secondary))
                    .lineLimit(1)
            }

            Slider(
                value: Binding(
                    get: { scrubValue ?? model.storedBook.readingProgress },
                    set: { scrubValue = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if !editing, let value = scrubValue {
                        model.go(toProgression: value)
                        scrubValue = nil
                    }
                }
            )
            .tint(Color(uiColor: colors.accent))
            .background(alignment: .top) { bookmarkMarks }
            .accessibilityLabel("Положение в книге")
            .accessibilityValue(scrubValue.map { MaterialExport.wholePercent($0) } ?? model.progressPercent)

            Text(progressStatus)
                .font(.footnote)
                .monospacedDigit()
                .foregroundStyle(Color(uiColor: colors.secondary))
                .lineLimit(1)

            HStack {
                toolbarButton("text.quote", "Выделения книги") { contentsTab = .highlights }
                Spacer()
                bookmarkButton
                Spacer()
                toolbarButton("textformat.size", "Оформление") { showsSettings = true }
                Spacer()
                toolbarButton("magnifyingglass", "Поиск по книге") { showsSearch = true }
            }
            .padding(.horizontal, 12)
            .padding(.top, 4)
        }
        .foregroundStyle(Color(uiColor: colors.text))
        .padding(.horizontal, 20)
        .padding(.top, 12)
        .padding(.bottom, 6)
        .background(Color(uiColor: colors.chrome).ignoresSafeArea(edges: .bottom))
        .overlay(alignment: .top) { Rectangle().fill(Color(uiColor: colors.divider)).frame(height: 0.5) }
    }

    /// Small ribbons above the slider track where the bookmarks are: the whole book at a glance.
    private var bookmarkMarks: some View {
        GeometryReader { geometry in
            // The track ends half a thumb in from each side of the slider.
            let inset: CGFloat = 14
            let width = max(0, geometry.size.width - 2 * inset)
            ForEach(bookmarks) { bookmark in
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(Color(uiColor: colors.accent))
                    .position(x: inset + width * min(1, max(0, bookmark.progression)), y: 3)
            }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    private var bookmarkButton: some View {
        let marked = model.bookmarkOnScreen(in: bookmarks) != nil
        return toolbarButton(marked ? "bookmark.fill" : "bookmark", marked ? "Убрать закладку" : "Добавить закладку") {
            model.toggleBookmark(in: bookmarks, context: context)
        }
        .foregroundStyle(Color(uiColor: marked ? colors.accent : colors.text))
    }

    private func toolbarButton(_ systemImage: String, _ label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 44, height: 40)
        }
        .accessibilityLabel(label)
    }

    /// "ещё 19 стр." in the chapter (pages) or the chapter title (scroll).
    private var chapterStatus: String {
        if mode == .pages, let status = model.pageStatus, status.chapter == model.chapterIndex {
            let left = status.pageCount - status.page - 1
            return left > 0 ? "ещё \(left) стр. в главе" : "последняя стр. главы"
        }
        return model.currentChapter?.title ?? ""
    }

    /// "стр. 118 из 294 · 44 % книги" or, while dragging the slider, where it will land.
    private var progressStatus: String {
        if let value = scrubValue {
            let chapter = model.chapterTitle(atProgression: value) ?? ""
            return "\(MaterialExport.wholePercent(value)) · \(chapter)"
        }
        let percent = "\(model.progressPercent) от всей книги"
        if mode == .pages, let status = model.pageStatus, let numbering = model.pageNumbering,
           let page = numbering.pageNumber(chapter: status.chapter, page: status.page) {
            return "стр. \(page) из \(numbering.total) · \(percent)"
        }
        return percent
    }

    private func failure(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "book.closed")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color(uiColor: colors.secondary))
            Text(message)
                .font(.callout)
                .multilineTextAlignment(.center)
                .foregroundStyle(Color(uiColor: colors.text))
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
        case let .highlightWithTag(selection, tag):
            let color = HighlightColor(storedValue: lastColorRaw)
            _ = model.createHighlight(for: selection, color: color, tags: [tag], context: context)
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

    private func makeBookExport() -> BookExportItem {
        let filter = MaterialFilter(bookFingerprint: model.storedBook.fingerprint)
        return BookExportItem(export: MaterialExport(
            items: highlights.compactMap { $0.materialItem() },
            exportedAt: .now,
            selectionDescription: filter.summary(bookTitle: model.storedBook.title),
            generator: MaterialExportWriter.generator,
            timeZone: .current
        ))
    }
}

struct BookExportItem: Identifiable {
    let id = UUID()
    let export: MaterialExport
}

