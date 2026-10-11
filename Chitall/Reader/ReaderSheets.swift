import SwiftUI

enum ContentsTab: String, CaseIterable, Identifiable {
    case chapters
    case bookmarks
    case highlights

    var id: String { rawValue }

    var title: String {
        switch self {
        case .chapters: return "Оглавление"
        case .bookmarks: return "Закладки"
        case .highlights: return "Выделения"
        }
    }
}

/// Table of contents and this book's highlights in one place, each row opens its place.
struct ContentsSheet: View {
    let model: ReaderModel
    let highlights: [Highlight]
    let bookmarks: [Bookmark]
    var onSelectChapter: (Int) -> Void
    var onSelectEntry: (TOCEntry) -> Void
    var onSelectHighlight: (Highlight) -> Void
    var onSelectBookmark: (Bookmark) -> Void
    var onDeleteBookmark: (Bookmark) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var tab: ContentsTab

    init(
        model: ReaderModel,
        highlights: [Highlight],
        bookmarks: [Bookmark],
        initialTab: ContentsTab,
        onSelectChapter: @escaping (Int) -> Void,
        onSelectEntry: @escaping (TOCEntry) -> Void,
        onSelectHighlight: @escaping (Highlight) -> Void,
        onSelectBookmark: @escaping (Bookmark) -> Void,
        onDeleteBookmark: @escaping (Bookmark) -> Void
    ) {
        self.model = model
        self.highlights = highlights
        self.bookmarks = bookmarks
        self.onSelectChapter = onSelectChapter
        self.onSelectEntry = onSelectEntry
        self.onSelectHighlight = onSelectHighlight
        self.onSelectBookmark = onSelectBookmark
        self.onDeleteBookmark = onDeleteBookmark
        _tab = State(initialValue: initialTab)
    }

    var body: some View {
        NavigationStack {
            List {
                switch tab {
                case .chapters: chapterRows
                case .bookmarks: bookmarkRows
                case .highlights: highlightRows
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Раздел", selection: $tab) {
                        ForEach(ContentsTab.allCases) { tab in
                            Text(tab.title).tag(tab)
                        }
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 300)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var chapterRows: some View {
        ForEach(model.chapters) { chapter in
            Section {
                Button {
                    onSelectChapter(chapter.index)
                } label: {
                    HStack {
                        Text(chapter.title)
                            .font(Typography.serif(.body, weight: chapter.index == model.chapterIndex ? .semibold : .regular))
                            .foregroundStyle(chapter.isNotes ? Palette.secondaryInk : Palette.ink)
                        Spacer()
                        if let numbering = model.pageNumbering, let page = numbering.pageNumber(chapter: chapter.index, page: 0) {
                            Text("\(page)")
                                .font(.caption)
                                .monospacedDigit()
                                .foregroundStyle(Palette.secondaryInk)
                        }
                        if chapter.index == model.chapterIndex {
                            Image(systemName: "bookmark.fill")
                                .font(.caption)
                                .foregroundStyle(Palette.accent)
                                .accessibilityLabel("Текущая глава")
                        }
                    }
                }
                ForEach(chapter.tableOfContents) { entry in
                    Button {
                        onSelectEntry(entry)
                    } label: {
                        Text(entry.title)
                            .font(Typography.serif(.subheadline))
                            .foregroundStyle(Palette.secondaryInk)
                            .padding(.leading, CGFloat(entry.depth) * 14)
                    }
                }
            }
        }
        let unresolved = model.unresolvedCount(in: highlights)
        if unresolved > 0 {
            Section {
                Text("\(RussianPlural.highlights(unresolved)) не найдено в тексте этой версии файла. Они сохранены в «Материалах» с цитатой и источником.")
                    .font(.footnote)
                    .foregroundStyle(Palette.secondaryInk)
            }
        }
    }

    @ViewBuilder
    private var bookmarkRows: some View {
        if bookmarks.isEmpty {
            Text("Закладок пока нет. Нажмите на значок закладки внизу, чтобы отметить страницу.")
                .font(.callout)
                .foregroundStyle(Palette.secondaryInk)
                .listRowBackground(Color.clear)
        } else {
            Section {
                ForEach(bookmarks) { bookmark in
                    Button {
                        onSelectBookmark(bookmark)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(bookmark.snippet.isEmpty ? "Закладка" : "«\(bookmark.snippet)…»")
                                .font(Typography.serif(.body))
                                .foregroundStyle(Palette.ink)
                                .lineLimit(2)
                            Text("\(bookmark.chapterTitle) · \(MaterialExport.percent(bookmark.progression)) · \(RussianDates.dayAndTime(bookmark.createdAt))")
                                .font(.caption)
                                .foregroundStyle(Palette.secondaryInk)
                                .lineLimit(1)
                        }
                        .padding(.vertical, 2)
                    }
                    .buttonStyle(.plain)
                }
                .onDelete { offsets in
                    for index in offsets { onDeleteBookmark(bookmarks[index]) }
                }
            }
        }
    }

    @ViewBuilder
    private var highlightRows: some View {
        if highlights.isEmpty {
            Text("В этой книге пока нет выделений. Выделите фрагмент и выберите «Выделить» или «Мысль…».")
                .font(.callout)
                .foregroundStyle(Palette.secondaryInk)
                .listRowBackground(Color.clear)
        } else {
            Section(RussianPlural.highlights(highlights.count)) {
                ForEach(highlights) { highlight in
                    Button {
                        onSelectHighlight(highlight)
                    } label: {
                        VStack(alignment: .leading, spacing: 6) {
                            QuoteBlock(text: highlight.text, color: highlight.color, lineLimit: 4)
                            if !highlight.note.isEmpty {
                                Text(highlight.note)
                                    .font(Typography.serif(.callout).italic())
                                    .foregroundStyle(Palette.ink)
                                    .lineLimit(3)
                                    .padding(.leading, 16)
                            }
                            HStack {
                                Text(highlight.chapterTitle)
                                    .lineLimit(1)
                                Spacer()
                                if !highlight.tags.isEmpty {
                                    Text(highlight.tags.map(TagNames.display).joined(separator: " "))
                                        .foregroundStyle(Palette.accent)
                                        .lineLimit(1)
                                }
                            }
                            .font(.caption)
                            .foregroundStyle(Palette.secondaryInk)
                            .padding(.leading, 16)
                        }
                        .padding(.vertical, 4)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

/// Shown once in page mode: where to tap. Any tap closes it.
struct PageZonesHint: View {
    var onDismiss: () -> Void

    var body: some View {
        GeometryReader { geometry in
            let edge = geometry.size.width * TextFragmentView.turnZoneFraction
            ZStack {
                Color.black.opacity(0.45)
                HStack(spacing: 0) {
                    zone("Назад", systemImage: "chevron.left", divider: true).frame(width: edge)
                    zone("Панели", systemImage: "rectangle.topthird.inset.filled", divider: true).frame(maxWidth: .infinity)
                    zone("Вперёд", systemImage: "chevron.right", divider: false).frame(width: edge)
                }
                VStack {
                    Spacer()
                    Text("Свайп тоже листает. Долгое нажатие — выделить текст.\nНажмите, чтобы начать читать.")
                        .font(.footnote)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.white)
                        .padding(.bottom, geometry.safeAreaInsets.bottom + 40)
                }
            }
        }
        .ignoresSafeArea()
        .contentShape(Rectangle())
        .onTapGesture(perform: onDismiss)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Закрыть подсказку")
    }

    private func zone(_ title: String, systemImage: String, divider: Bool) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage).font(.title2)
            Text(title).font(Typography.serif(.headline))
        }
        .foregroundStyle(.white)
        .frame(maxHeight: .infinity)
        .overlay(alignment: .trailing) {
            if divider { Rectangle().fill(.white.opacity(0.35)).frame(width: 1) }
        }
    }
}

/// Reading settings in the spirit of good e-readers: brightness, page theme, font, size,
/// spacing, margins, alignment, mode. Every change applies immediately.
struct ReaderSettingsView: View {
    @Binding var brightness: Double?
    @AppStorage(ReaderPreferences.fontSizeKey) private var fontSize = ReaderPreferences.defaultFontSize
    @AppStorage(ReaderPreferences.fontKey) private var fontRaw = ReaderFont.sourceSerif.rawValue
    @AppStorage(ReaderPreferences.spacingKey) private var spacingRaw = ReaderSpacing.normal.rawValue
    @AppStorage(ReaderPreferences.marginsKey) private var marginsRaw = ReaderMargins.normal.rawValue
    @AppStorage(ReaderPreferences.justifiedKey) private var justified = true
    @AppStorage(ReaderPreferences.readerThemeKey) private var themeRaw = ReaderTheme.system.rawValue
    @AppStorage(ReaderPreferences.modeKey) private var modeRaw = ReadingMode.pages.rawValue

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                brightnessRow
                themeRow
                fontRow
                HStack(spacing: 28) {
                    spacingRow
                    Spacer(minLength: 0)
                    marginsRow
                }
                Toggle("По ширине, с переносами", isOn: $justified)
                Picker("Режим чтения", selection: $modeRaw) {
                    ForEach(ReadingMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(modeRaw == ReadingMode.pages.rawValue
                     ? "Страницы: тап у правого края — вперёд, у левого — назад, в центре — панели. Свайп тоже листает."
                     : "Прокрутка: вся книга одной лентой, главы идут подряд.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(22)
        }
    }

    private var brightnessRow: some View {
        HStack(spacing: 14) {
            Image(systemName: "sun.min")
            Slider(
                value: Binding(get: { brightness ?? ReaderBrightness.current }, set: { brightness = $0 }),
                in: 0.02...1
            )
            .accessibilityLabel("Яркость")
            Image(systemName: "sun.max")
        }
        .font(.title3)
    }

    private var themeRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(ReaderTheme.allCases) { theme in
                    let colors = theme.colors
                    let selected = themeRaw == theme.rawValue
                    Button {
                        themeRaw = theme.rawValue
                    } label: {
                        Text(theme.title)
                            .font(.callout)
                            .padding(.horizontal, 16)
                            .padding(.vertical, 10)
                            .foregroundStyle(Color(uiColor: theme == .system ? .label : colors.text))
                            .background(
                                theme == .system ? AnyShapeStyle(Color.clear) : AnyShapeStyle(Color(uiColor: colors.background)),
                                in: Capsule()
                            )
                            .overlay(Capsule().stroke(selected ? Color.accentColor : Color.secondary.opacity(0.4), lineWidth: selected ? 2 : 1))
                    }
                    .buttonStyle(.plain)
                    .accessibilityAddTraits(selected ? .isSelected : [])
                }
            }
            .padding(.vertical, 2)
        }
    }

    private var fontRow: some View {
        HStack(spacing: 16) {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ReaderFont.available) { font in
                        let selected = fontRaw == font.rawValue
                        Button {
                            fontRaw = font.rawValue
                        } label: {
                            Text(font.title)
                                .font(font.previewFont(size: 17))
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? Color.accentColor : Color.secondary.opacity(0.3), lineWidth: selected ? 2 : 1))
                        }
                        .buttonStyle(.plain)
                        .accessibilityAddTraits(selected ? .isSelected : [])
                    }
                }
                .padding(.vertical, 2)
            }
            HStack(spacing: 0) {
                Button {
                    fontSize = max(ReaderPreferences.fontSizeRange.lowerBound, fontSize - 1)
                } label: {
                    Image(systemName: "minus").frame(width: 48, height: 40)
                }
                .accessibilityLabel("Уменьшить шрифт")
                Divider().frame(height: 26)
                Button {
                    fontSize = min(ReaderPreferences.fontSizeRange.upperBound, fontSize + 1)
                } label: {
                    Image(systemName: "plus").frame(width: 48, height: 40)
                }
                .accessibilityLabel("Увеличить шрифт")
            }
            .overlay(Capsule().stroke(Color.secondary.opacity(0.4), lineWidth: 1))
            .accessibilityValue("\(Int(fontSize))")
        }
    }

    private var spacingRow: some View {
        HStack(spacing: 6) {
            ForEach(ReaderSpacing.allCases) { spacing in
                let selected = spacingRaw == spacing.rawValue
                Button {
                    spacingRaw = spacing.rawValue
                } label: {
                    LinesIcon(gap: spacing == .compact ? 3 : spacing == .normal ? 5 : 7)
                        .frame(width: 40, height: 34)
                        .opacity(selected ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spacing.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var marginsRow: some View {
        HStack(spacing: 6) {
            ForEach(ReaderMargins.allCases) { margins in
                let selected = marginsRaw == margins.rawValue
                Button {
                    marginsRaw = margins.rawValue
                } label: {
                    MarginsIcon(inset: margins == .narrow ? 3 : margins == .normal ? 6 : 9)
                        .frame(width: 34, height: 34)
                        .opacity(selected ? 1 : 0.45)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(margins.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }
}

/// Three lines with a given gap: the line spacing presets.
private struct LinesIcon: View {
    let gap: CGFloat

    var body: some View {
        VStack(spacing: gap) {
            ForEach(0..<3, id: \.self) { _ in
                Capsule().frame(height: 2)
            }
        }
        .padding(.horizontal, 4)
    }
}

/// A page with text lines inset by the margin preset.
private struct MarginsIcon: View {
    let inset: CGFloat

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 3).stroke(lineWidth: 1.5)
            VStack(spacing: 4) {
                ForEach(0..<4, id: \.self) { _ in
                    Capsule().frame(height: 1.5)
                }
            }
            .padding(.horizontal, inset)
        }
    }
}

/// Book details from the FB2 description.
struct BookInfoSheet: View {
    let book: StoredBook
    let metadata: BookMetadata?
    let highlightCount: Int
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Text(book.title).font(Typography.serif(.title3, weight: .semibold))
                    if !book.authors.isEmpty { Text(book.authors) }
                    if let series = book.seriesName {
                        Text(book.seriesNumber.map { "\(series), № \($0)" } ?? series)
                            .foregroundStyle(Palette.secondaryInk)
                    }
                }
                if let annotation = metadata?.annotation ?? book.annotation, !annotation.isEmpty {
                    Section("Аннотация") {
                        Text(annotation).font(Typography.serif(.body))
                    }
                }
                Section("Файл") {
                    LabeledContent("Имя", value: book.originalFileName)
                    LabeledContent("Размер", value: ByteCountFormatter.string(fromByteCount: Int64(book.fileSize), countStyle: .file))
                    if let language = book.language { LabeledContent("Язык", value: language) }
                    LabeledContent("Глав", value: "\(book.chapterCount)")
                    LabeledContent("Выделений", value: "\(highlightCount)")
                    LabeledContent("Отпечаток", value: Fingerprint.short(book.fingerprint))
                }
            }
            .navigationTitle("О книге")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}
