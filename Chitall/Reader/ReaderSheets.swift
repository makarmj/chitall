import SwiftUI

struct TableOfContentsView: View {
    let model: ReaderModel
    let unresolvedCount: Int
    var onSelectChapter: (Int) -> Void
    var onSelectEntry: (TOCEntry) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
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
                if unresolvedCount > 0 {
                    Section {
                        Text("\(RussianPlural.highlights(unresolvedCount)) не найдено в тексте этой версии файла. Они сохранены в «Материалах» с цитатой и источником.")
                            .font(.footnote)
                            .foregroundStyle(Palette.secondaryInk)
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Оглавление")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

struct ReaderSettingsView: View {
    @AppStorage(ReaderPreferences.fontSizeKey) private var fontSize = ReaderPreferences.defaultFontSize
    @AppStorage(ReaderPreferences.lineSpacingKey) private var lineSpacing = ReaderPreferences.defaultLineSpacing
    @AppStorage(ReaderPreferences.themeKey) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(ReaderPreferences.modeKey) private var modeRaw = ReadingMode.pages.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Text("Оформление")
                .font(Typography.serif(.title3, weight: .semibold))

            VStack(alignment: .leading, spacing: 8) {
                Picker("Режим чтения", selection: $modeRaw) {
                    ForEach(ReadingMode.allCases) { mode in
                        Text(mode.title).tag(mode.rawValue)
                    }
                }
                .pickerStyle(.segmented)
                Text(modeRaw == ReadingMode.pages.rawValue
                     ? "Тап по правому краю — вперёд, по левому — назад, по центру — панели."
                     : "Глава листается прокруткой; следующая — кнопкой внизу.")
                    .font(.caption)
                    .foregroundStyle(Palette.secondaryInk)
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Размер шрифта: \(Int(fontSize))")
                    .font(.subheadline)
                HStack(spacing: 14) {
                    Text("A").font(.system(size: 14, design: .serif))
                    Slider(value: $fontSize, in: ReaderPreferences.fontSizeRange, step: 1)
                        .accessibilityLabel("Размер шрифта")
                    Text("A").font(.system(size: 26, design: .serif))
                }
            }

            VStack(alignment: .leading, spacing: 8) {
                Text("Межстрочный интервал: \(lineSpacing, specifier: "%.2f")")
                    .font(.subheadline)
                Slider(value: $lineSpacing, in: ReaderPreferences.lineSpacingRange, step: 0.05)
                    .accessibilityLabel("Межстрочный интервал")
            }

            Picker("Тема", selection: $themeRaw) {
                ForEach(AppTheme.allCases) { theme in
                    Text(theme.title).tag(theme.rawValue)
                }
            }
            .pickerStyle(.segmented)
        }
        .foregroundStyle(Palette.ink)
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Palette.background)
    }
}
