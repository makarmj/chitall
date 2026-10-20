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
                            Text("\(bookmark.chapterTitle) · \(MaterialExport.wholePercent(bookmark.progression)) · \(RussianDates.dayAndTime(bookmark.createdAt))")
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

/// A footnote as a card from the bottom, as in Yandex Books: the reader's page colours and book
/// font, a large number, a close button, as tall as the note (long notes scroll).
struct NoteCard: View {
    let note: NoteContent
    let style: ReaderStyle
    @Environment(\.dismiss) private var dismiss
    @State private var contentHeight: CGFloat = 160

    private var colors: ThemeColors { style.colors }

    private var number: String {
        let title = note.title.trimmingCharacters(in: .whitespacesAndNewlines)
        return title.isEmpty ? "Примечание" : title
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .firstTextBaseline) {
                    Text(number)
                        .font(style.font.previewFont(size: style.fontSize * (number.count > 6 ? 1.2 : 1.7), weight: .semibold))
                        .foregroundStyle(Color(uiColor: colors.accent))
                        .lineLimit(2)
                    Spacer(minLength: 12)
                    Button { dismiss() } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 14, weight: .bold))
                            .foregroundStyle(Color(uiColor: colors.secondary))
                            .frame(width: 32, height: 32)
                            .background(Color(uiColor: colors.divider), in: Circle())
                    }
                    .accessibilityLabel("Закрыть сноску")
                }
                Text(note.text.isEmpty ? "Текст примечания пуст." : note.text)
                    .font(style.font.previewFont(size: max(15, style.fontSize * 0.95)))
                    .foregroundStyle(Color(uiColor: colors.text))
                    .lineSpacing(style.fontSize * 0.25)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.horizontal, 22)
            .padding(.top, 22)
            .padding(.bottom, 12)
            .onGeometryChange(for: CGFloat.self) { $0.size.height } action: { contentHeight = $0 }
        }
        .scrollBounceBehavior(.basedOnSize)
        .presentationDetents([.height(min(contentHeight + 12, 560)), .large])
        .presentationDragIndicator(.visible)
        .presentationCornerRadius(22)
        .presentationBackground(Color(uiColor: colors.background))
        .environment(\.colorScheme, style.theme.isDark ? .dark : .light)
    }
}

/// Reading settings in the spirit of good e-readers: brightness, page theme, font, size,
/// spacing, margins, alignment, mode. Every change applies immediately.
///
/// Drawn in the reader theme's own colours: on "Чёрный" or "Дерево" the panel is dark even
/// when the app (and so the sheet) is light, and every label must stay readable on it.
struct ReaderSettingsView: View {
    @Binding var brightness: Double?
    let colors: ThemeColors
    let isDark: Bool
    @AppStorage(ReaderPreferences.fontSizeKey) private var fontSize = ReaderPreferences.defaultFontSize
    @AppStorage(ReaderPreferences.fontKey) private var fontRaw = ReaderFont.sourceSerif.rawValue
    @AppStorage(ReaderPreferences.spacingKey) private var spacingRaw = ReaderSpacing.normal.rawValue
    @AppStorage(ReaderPreferences.marginsKey) private var marginsRaw = ReaderMargins.normal.rawValue
    @AppStorage(ReaderPreferences.justifiedKey) private var justified = true
    @AppStorage(ReaderPreferences.readerThemeKey) private var themeRaw = ReaderTheme.system.rawValue
    @AppStorage(ReaderPreferences.modeKey) private var modeRaw = ReadingMode.pages.rawValue
    @AppStorage(ReaderPreferences.letterSpacingKey) private var letterSpacingRaw = ReaderLetterSpacing.normal.rawValue
    @AppStorage(ReaderPreferences.easyReadingPreviousKey) private var easyReadingPrevious = ""
    @AppStorage(ReaderPreferences.focusRulerKey) private var focusRuler = false
    @AppStorage(ReaderPreferences.cleanScreenKey) private var cleanScreen = false
    @AppStorage(ReaderPreferences.resumeCardKey) private var resumeCard = true
    @AppStorage(ReaderPreferences.sessionMinutesKey) private var sessionMinutes = 0

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                brightnessRow
                easyReadingRow
                themeRow
                fontRow
                HStack(spacing: 20) {
                    spacingRow
                    Spacer(minLength: 0)
                    marginsRow
                }
                letterSpacingRow
                Toggle("По ширине, с переносами", isOn: $justified)
                Picker("Режим чтения", selection: $modeRaw) {
                    ForEach(ReadingMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(modeRaw == ReadingMode.pages.rawValue
                     ? "Страницы: тап у правого края — вперёд, у левого — назад, в центре — панели. Свайп тоже листает."
                     : "Прокрутка: вся книга одной лентой, главы идут подряд. Закладка отмечает строку вверху экрана: значок заполнен, пока она на экране, а сами закладки видны на полях и над ползунком.")
                    .font(.caption)
                    .foregroundStyle(secondary)
                concentrationSection
            }
            .padding(22)
        }
        .foregroundStyle(ink)
        .tint(accent)
        .environment(\.colorScheme, isDark ? .dark : .light)
    }

    private var ink: Color { Color(uiColor: colors.text) }
    private var secondary: Color { Color(uiColor: colors.secondary) }
    private var accent: Color { Color(uiColor: colors.accent) }
    private var outline: Color { Color(uiColor: colors.secondary).opacity(0.45) }

    // MARK: Easy reading

    private var easySettings: EasyReading.Settings {
        EasyReading.Settings(
            justified: justified,
            letterSpacing: ReaderLetterSpacing(rawValue: letterSpacingRaw) ?? .normal,
            spacing: ReaderSpacing(rawValue: spacingRaw) ?? .normal,
            theme: ReaderTheme(rawValue: themeRaw) ?? .system
        )
    }

    private func apply(_ settings: EasyReading.Settings) {
        justified = settings.justified
        letterSpacingRaw = settings.letterSpacing.rawValue
        spacingRaw = settings.spacing.rawValue
        themeRaw = settings.theme.rawValue
    }

    private var easyReading: Binding<Bool> {
        Binding(
            get: { EasyReading.isOn(easySettings) },
            set: { on in
                if on {
                    easyReadingPrevious = EasyReading.encode(easySettings)
                    apply(EasyReading.applied(to: easySettings))
                } else {
                    apply(EasyReading.restored(from: EasyReading.decode(easyReadingPrevious), current: easySettings))
                }
            }
        )
    }

    private var easyReadingRow: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle(isOn: easyReading) {
                Label("Лёгкое чтение", systemImage: "eyeglasses")
                    .font(.body.weight(.semibold))
            }
            Text("Шире буквы и строки, текст по левому краю без переносов, мягкий фон. Каждую часть можно подстроить ниже; шрифты Andika и OpenDyslexic — в ряду шрифтов.")
                .font(.caption)
                .foregroundStyle(secondary)
        }
    }

    private var letterSpacingRow: some View {
        HStack(spacing: 6) {
            Text("Между буквами")
                .font(.subheadline)
            Spacer(minLength: 8)
            ForEach(ReaderLetterSpacing.allCases) { spacing in
                let selected = letterSpacingRaw == spacing.rawValue
                Button {
                    letterSpacingRaw = spacing.rawValue
                } label: {
                    LetterSpacingIcon(spacing: spacing)
                        .foregroundStyle(selected ? accent : ink)
                        .frame(minWidth: 44, minHeight: 34)
                        .opacity(selected ? 1 : 0.55)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(spacing.title)
                .accessibilityAddTraits(selected ? .isSelected : [])
            }
        }
    }

    private var concentrationSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Внимание")
                .font(.headline)
            optionToggle(
                "Линейка фокуса", isOn: $focusRuler,
                hint: modeRaw == ReadingMode.scroll.rawValue
                    ? "Абзац у линии чтения ярче, остальное приглушено. Линейка идёт за прокруткой."
                    : "Работает в режиме «Прокрутка»: абзац у линии чтения ярче, остальное приглушено."
            )
            optionToggle(
                "Чистый экран", isOn: $cleanScreen,
                hint: "Панели прячутся, как только вы листаете; тап в центр — показать. Без названия главы над текстом и строки статуса."
            )
            optionToggle(
                "Где я остановился", isOn: $resumeCard,
                hint: "При открытии книги — последние прочитанные строки и последнее выделение."
            )
            VStack(alignment: .leading, spacing: 8) {
                Text("Напомнить о паузе")
                Picker("Напомнить о паузе", selection: $sessionMinutes) {
                    Text("Нет").tag(0)
                    Text("10 мин").tag(10)
                    Text("15 мин").tag(15)
                    Text("20 мин").tag(20)
                    Text("30 мин").tag(30)
                }
                .pickerStyle(.segmented)
                Text("Тихая карточка в книге, без звука и уведомлений. Время до конца главы считается по вашему темпу чтения.")
                    .font(.caption)
                    .foregroundStyle(secondary)
            }
        }
        .padding(.top, 6)
    }

    private func optionToggle(_ title: String, isOn: Binding<Bool>, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: isOn)
            Text(hint)
                .font(.caption)
                .foregroundStyle(secondary)
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
                            .overlay(Capsule().stroke(selected ? accent : outline, lineWidth: selected ? 2 : 1))
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
                    ForEach(fontOrder) { font in
                        let selected = fontRaw == font.rawValue
                        Button {
                            fontRaw = font.rawValue
                        } label: {
                            Text(font.title)
                                .font(font.previewFont(size: 17))
                                .foregroundStyle(ink)
                                .padding(.horizontal, 12)
                                .padding(.vertical, 8)
                                .overlay(RoundedRectangle(cornerRadius: 10).stroke(selected ? accent : outline, lineWidth: selected ? 2 : 1))
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
                Rectangle().fill(outline).frame(width: 1, height: 26)
                Button {
                    fontSize = min(ReaderPreferences.fontSizeRange.upperBound, fontSize + 1)
                } label: {
                    Image(systemName: "plus").frame(width: 48, height: 40)
                }
                .accessibilityLabel("Увеличить шрифт")
            }
            .overlay(Capsule().stroke(outline, lineWidth: 1))
            .accessibilityValue("\(Int(fontSize))")
        }
    }

    /// With easy reading on, its fonts come first in the row.
    private var fontOrder: [ReaderFont] {
        let fonts = ReaderFont.available
        guard EasyReading.isOn(easySettings) else { return fonts }
        return fonts.filter(\.isEasyReadingFont) + fonts.filter { !$0.isEasyReadingFont }
    }

    private var spacingRow: some View {
        HStack(spacing: 6) {
            ForEach(ReaderSpacing.allCases) { spacing in
                let selected = spacingRaw == spacing.rawValue
                Button {
                    spacingRaw = spacing.rawValue
                } label: {
                    LinesIcon(gap: spacing == .compact ? 3 : spacing == .normal ? 5 : spacing == .relaxed ? 7 : 9)
                        .foregroundStyle(selected ? accent : ink)
                        .frame(width: 36, height: 34)
                        .opacity(selected ? 1 : 0.55)
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
                        .foregroundStyle(selected ? accent : ink)
                        .frame(width: 32, height: 34)
                        .opacity(selected ? 1 : 0.55)
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
