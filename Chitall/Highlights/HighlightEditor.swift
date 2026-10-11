import SwiftData
import SwiftUI

/// Sheet wrapper used from the reader.
struct HighlightEditorSheet: View {
    @Bindable var highlight: Highlight
    var onDelete: () -> Void
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            HighlightEditorContent(highlight: highlight, onDelete: onDelete)
                .navigationTitle("Выделение")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Готово") {
                            try? context.save()
                            dismiss()
                        }
                    }
                }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }
}

/// Quote, color, thought, tags and exact provenance of one highlight. Edits apply directly to
/// the SwiftData model (autosaved; saved explicitly when the editor closes).
struct HighlightEditorContent: View {
    @Bindable var highlight: Highlight
    var onOpenInBook: (() -> Void)? = nil
    var onDelete: () -> Void

    @Environment(\.modelContext) private var context
    @Query(sort: [SortDescriptor(\TagRecord.sortOrder), SortDescriptor(\TagRecord.name)]) private var catalog: [TagRecord]
    @State private var newTag = ""
    @State private var confirmsDeletion = false
    @FocusState private var noteFocused: Bool

    private var tagNames: [String] {
        let known = catalog.map(\.name)
        return known + highlight.tags.filter { !known.contains($0) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 26) {
                QuoteBlock(text: highlight.text, color: highlight.color)

                section("Цвет") {
                    HStack(spacing: 14) {
                        ForEach(HighlightColor.allCases) { color in
                            Button {
                                highlight.color = color
                                highlight.touch()
                            } label: {
                                Circle()
                                    .fill(Palette.solid(color))
                                    .frame(width: 30, height: 30)
                                    .overlay {
                                        if highlight.color == color {
                                            Circle().stroke(Palette.ink, lineWidth: 2).padding(-4)
                                        }
                                    }
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel(color.displayName)
                            .accessibilityAddTraits(highlight.color == color ? .isSelected : [])
                        }
                    }
                }

                section("Мысль") {
                    TextEditor(text: $highlight.note)
                        .focused($noteFocused)
                        .font(Typography.serif(.body))
                        .scrollContentBackground(.hidden)
                        .frame(minHeight: 120)
                        .padding(8)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                        .overlay(alignment: .topLeading) {
                            if highlight.note.isEmpty && !noteFocused {
                                Text("Что здесь важно для истории?")
                                    .font(Typography.serif(.body))
                                    .foregroundStyle(Palette.secondaryInk)
                                    .padding(.horizontal, 13)
                                    .padding(.vertical, 16)
                                    .allowsHitTesting(false)
                            }
                        }
                        .onChange(of: highlight.note) { highlight.touch() }
                }

                section("Теги") {
                    FlowLayout(spacing: 8) {
                        ForEach(tagNames, id: \.self) { name in
                            TagChip(name: name, isSelected: highlight.tags.contains(name)) {
                                highlight.toggleTag(name)
                            }
                        }
                    }
                    HStack {
                        TextField("Новый тег, например #рынок", text: $newTag)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                            .onSubmit(addTags)
                        Button("Добавить", action: addTags)
                            .disabled(TagNames.parseList(newTag).isEmpty)
                    }
                    .padding(10)
                    .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
                }

                ProvenanceView(highlight: highlight)

                VStack(alignment: .leading, spacing: 12) {
                    if let onOpenInBook {
                        Button(action: onOpenInBook) {
                            Label("Открыть в книге", systemImage: "book")
                        }
                    }
                    Button(role: .destructive) {
                        confirmsDeletion = true
                    } label: {
                        Label("Удалить выделение", systemImage: "trash")
                    }
                }
            }
            .padding(20)
        }
        .background(Palette.background)
        .confirmationDialog("Удалить выделение?", isPresented: $confirmsDeletion, titleVisibility: .visible) {
            Button("Удалить", role: .destructive, action: onDelete)
            Button("Отмена", role: .cancel) {}
        } message: {
            Text("Цитата, мысль и теги этого выделения будут удалены.")
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title.uppercased())
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Palette.secondaryInk)
            content()
        }
    }

    private func addTags() {
        for name in TagNames.parseList(newTag) {
            TagCatalog.ensure(name, in: context)
            if !highlight.tags.contains(name) { highlight.tags.append(name) }
        }
        highlight.touch()
        newTag = ""
    }
}

struct QuoteBlock: View {
    let text: String
    let color: HighlightColor
    var lineLimit: Int? = nil

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.solid(color))
                .frame(width: 4)
            Text(text)
                .font(Typography.serif(.body))
                .foregroundStyle(Palette.ink)
                .lineSpacing(3)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// Exact provenance: book, chapter, locator, dates — the data the export carries.
struct ProvenanceView: View {
    let highlight: Highlight

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("ИСТОЧНИК")
                .font(.caption.weight(.semibold))
                .tracking(1.2)
                .foregroundStyle(Palette.secondaryInk)
            Text(highlight.bookTitle).font(Typography.serif(.subheadline, weight: .semibold))
            if !highlight.bookAuthors.isEmpty {
                Text(highlight.bookAuthors).font(.footnote)
            }
            Text(highlight.chapterTitle).font(.footnote)
            if let locator = highlight.locator {
                Text(locator.compactDescription)
                    .font(.caption2.monospaced())
                    .textSelection(.enabled)
                Text("\(MaterialExport.percent(locator.progression)) книги · \(Fingerprint.short(locator.book))")
                    .font(.caption2)
            }
            Text("Создано \(RussianDates.dayAndTime(highlight.createdAt))").font(.caption2)
            if highlight.updatedAt.timeIntervalSince(highlight.createdAt) >= 60 {
                Text("Изменено \(RussianDates.dayAndTime(highlight.updatedAt))").font(.caption2)
            }
        }
        .foregroundStyle(Palette.ink)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct TagChip: View {
    let name: String
    let isSelected: Bool
    var action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(TagNames.display(name))
                .font(.callout)
                .padding(.horizontal, 11)
                .padding(.vertical, 6)
                .foregroundStyle(isSelected ? Palette.background : Palette.ink)
                .background(isSelected ? Palette.accent : Palette.surface, in: Capsule())
                .overlay(Capsule().stroke(Palette.divider, lineWidth: isSelected ? 0 : 1))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

/// Wrapping row layout for tag chips.
struct FlowLayout: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var widest: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                y += rowHeight + spacing
                x = 0
                rowHeight = 0
            }
            x += size.width
            widest = max(widest, x)
            x += spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: proposal.width ?? widest, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX
        var y = bounds.minY
        var rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > bounds.minX, x + size.width > bounds.maxX {
                y += rowHeight + spacing
                x = bounds.minX
                rowHeight = 0
            }
            subview.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
