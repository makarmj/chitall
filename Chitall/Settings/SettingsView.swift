import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(AppCoordinator.self) private var coordinator
    @AppStorage(ReaderPreferences.themeKey) private var themeRaw = AppTheme.system.rawValue
    @AppStorage(ReaderPreferences.fontSizeKey) private var fontSize = ReaderPreferences.defaultFontSize
    @AppStorage(ReaderPreferences.readerThemeKey) private var readerThemeRaw = ReaderTheme.system.rawValue
    @AppStorage(ReaderPreferences.modeKey) private var modeRaw = ReadingMode.pages.rawValue
    @Query private var books: [StoredBook]
    @Query private var highlights: [Highlight]
    @Query private var tags: [TagRecord]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Тема приложения", selection: $themeRaw) {
                        ForEach(AppTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    Picker("Тема страницы", selection: $readerThemeRaw) {
                        ForEach(ReaderTheme.allCases) { theme in
                            Text(theme.title).tag(theme.rawValue)
                        }
                    }
                    Picker("Режим чтения", selection: $modeRaw) {
                        ForEach(ReadingMode.allCases) { mode in
                            Text(mode.title).tag(mode.rawValue)
                        }
                    }
                    Stepper(value: $fontSize, in: ReaderPreferences.fontSizeRange, step: 1) {
                        Text("Размер шрифта: \(Int(fontSize))")
                    }
                } header: {
                    Text("Оформление")
                } footer: {
                    Text("Шрифт, интервал, поля и яркость — в книге, кнопка «Aa».")
                }

                Section("Теги") {
                    NavigationLink {
                        TagListView()
                    } label: {
                        LabeledContent("Список тегов", value: "\(tags.count)")
                    }
                }

                Section {
                    LabeledContent("Книги", value: "\(books.count)")
                    LabeledContent("Выделения", value: "\(highlights.count)")
                    LabeledContent("Файлы книг", value: ByteCountFormatter.string(fromByteCount: Int64(coordinator.files.usedBytes()), countStyle: .file))
                } header: {
                    Text("Данные")
                } footer: {
                    Text("Книги, выделения и заметки хранятся только на этом устройстве. Нет аккаунта, сети и аналитики. Импортируйте только свои DRM-free файлы.")
                }

                Section("О приложении") {
                    LabeledContent("Версия", value: MaterialExportWriter.generator)
                    NavigationLink("Шрифт Source Serif 4") {
                        LicenseTextView(
                            title: "Source Serif 4",
                            text: Bundle.main.url(forResource: "SourceSerif4-OFL", withExtension: "txt")
                                .flatMap { try? String(contentsOf: $0, encoding: .utf8) }
                                ?? "© Adobe. SIL Open Font License 1.1."
                        )
                    }
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background)
            .navigationTitle("Настройки")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Готово") { dismiss() }
                }
            }
        }
    }
}

/// Text of a bundled licence (fonts are distributed under the SIL Open Font License).
struct LicenseTextView: View {
    let title: String
    let text: String

    var body: some View {
        ScrollView {
            Text(text)
                .font(.footnote.monospaced())
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
    }
}

struct TagListView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\TagRecord.sortOrder), SortDescriptor(\TagRecord.name)]) private var tags: [TagRecord]
    @State private var newTag = ""

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("Новый тег", text: $newTag)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onSubmit(add)
                    Button("Добавить", action: add)
                        .disabled(TagNames.parseList(newTag).isEmpty)
                }
            }
            Section {
                ForEach(tags) { tag in
                    HStack {
                        Text(TagNames.display(tag.name))
                        Spacer()
                        if tag.isBuiltIn {
                            Text("встроенный")
                                .font(.caption)
                                .foregroundStyle(Palette.secondaryInk)
                        }
                    }
                }
                .onDelete { offsets in
                    for index in offsets { context.delete(tags[index]) }
                    try? context.save()
                }
            } footer: {
                Text("Удаление тега из списка не снимает его с уже отмеченных выделений.")
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background)
        .navigationTitle("Теги")
    }

    private func add() {
        for name in TagNames.parseList(newTag) {
            TagCatalog.ensure(name, in: context)
        }
        try? context.save()
        newTag = ""
    }
}
