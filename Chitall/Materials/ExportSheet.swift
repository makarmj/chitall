import SwiftUI

/// Prepares Markdown and JSON for the current selection and hands them to the Share Sheet.
struct ExportSheet: View {
    let export: MaterialExport
    @Environment(\.dismiss) private var dismiss
    @State private var files: MaterialExportWriter.Files?
    @State private var errorMessage: String?

    private var bookCount: Int { Set(export.items.map(\.bookFingerprint)).count }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("\(RussianPlural.highlights(export.items.count)) из \(bookCount) \(RussianPlural.form(bookCount, one: "книги", few: "книг", many: "книг"))")
                            .font(Typography.serif(.title3, weight: .semibold))
                        Text("Выборка: \(export.selectionDescription)")
                            .font(.subheadline)
                            .foregroundStyle(Palette.secondaryInk)
                    }

                    Text("В файлах только выделенные цитаты, ваши мысли, теги, цвета и точные ссылки на место в книге. Текст книги вокруг цитат не экспортируется.")
                        .font(.footnote)
                        .foregroundStyle(Palette.secondaryInk)

                    if let files {
                        ShareLink(items: [files.markdown, files.json]) {
                            Label("Поделиться Markdown и JSON", systemImage: "square.and.arrow.up")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)

                        HStack {
                            ShareLink(item: files.markdown) { Label("Только .md", systemImage: "doc.plaintext") }
                            Spacer()
                            ShareLink(item: files.json) { Label("Только .json", systemImage: "curlybraces") }
                        }
                        .font(.callout)

                        Text("ПРЕДПРОСМОТР MARKDOWN")
                            .font(.caption.weight(.semibold))
                            .tracking(1.2)
                            .foregroundStyle(Palette.secondaryInk)
                            .padding(.top, 8)
                        Text(files.markdownText)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(12)
                            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                    } else if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    } else {
                        ProgressView("Готовлю файлы…")
                    }
                }
                .foregroundStyle(Palette.ink)
                .padding(20)
            }
            .background(Palette.background)
            .navigationTitle("Экспорт")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Закрыть") { dismiss() }
                }
            }
            .task {
                do {
                    files = try MaterialExportWriter.write(export)
                } catch {
                    errorMessage = "Не удалось подготовить файлы: \(error.localizedDescription)"
                }
            }
        }
    }
}
