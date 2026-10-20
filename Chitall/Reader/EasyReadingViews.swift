import SwiftUI

/// "Где я остановился": shown once when a book reopens at its saved place. The last words
/// read and the last highlight bring the context back before reading on (DECISIONS.md §19).
struct ResumeCard: View {
    let snippet: String
    let lastHighlight: Highlight?
    let style: ReaderStyle
    let onClose: () -> Void

    private var colors: ThemeColors { style.colors }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Где я остановился")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color(uiColor: colors.secondary))
                Spacer()
                Button(action: onClose) {
                    Image(systemName: "xmark")
                        .font(.footnote.weight(.semibold))
                        .frame(width: 32, height: 28)
                }
                .accessibilityLabel("Закрыть")
            }
            Text(snippet)
                .font(style.font.previewFont(size: 16))
                .foregroundStyle(Color(uiColor: colors.text))
                .lineLimit(4)
                .fixedSize(horizontal: false, vertical: true)

            if let highlight = lastHighlight {
                Rectangle().fill(Color(uiColor: colors.divider)).frame(height: 0.5)
                Text("Последнее выделение")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color(uiColor: colors.secondary))
                HStack(alignment: .top, spacing: 10) {
                    RoundedRectangle(cornerRadius: 1.5)
                        .fill(Palette.solid(highlight.color))
                        .frame(width: 3)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(highlight.text)
                            .font(style.font.previewFont(size: 15))
                            .foregroundStyle(Color(uiColor: colors.text))
                            .lineLimit(2)
                        let note = highlight.note.trimmingCharacters(in: .whitespacesAndNewlines)
                        if !note.isEmpty {
                            Text(note)
                                .font(.footnote)
                                .foregroundStyle(Color(uiColor: colors.secondary))
                                .lineLimit(2)
                        }
                    }
                }
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .foregroundStyle(Color(uiColor: colors.text))
        .padding(16)
        .background(Color(uiColor: colors.chrome), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(uiColor: colors.divider), lineWidth: 0.5))
        .shadow(color: .black.opacity(style.theme.isDark ? 0.4 : 0.12), radius: 12, y: 4)
        .contentShape(Rectangle())
        .onTapGesture(perform: onClose)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityHint("Закрыть")
    }
}

/// A quiet reminder at the end of a reading session: no sound, no system notification.
struct SessionBanner: View {
    let minutes: Int
    let colors: ThemeColors
    let onMore: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Вы читаете уже \(minutes) мин")
                .font(.headline)
            Text("Хорошее место для паузы: посмотрите вдаль, подвигайтесь. Или продолжайте, если читается легко.")
                .font(.subheadline)
                .foregroundStyle(Color(uiColor: colors.secondary))
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 12) {
                Button("Ещё \(minutes) мин", action: onMore)
                    .buttonStyle(.borderedProminent)
                Button("Хорошо", action: onClose)
                    .buttonStyle(.bordered)
            }
        }
        .tint(Color(uiColor: colors.accent))
        .foregroundStyle(Color(uiColor: colors.text))
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(uiColor: colors.chrome), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).stroke(Color(uiColor: colors.divider), lineWidth: 0.5))
        .shadow(color: .black.opacity(0.15), radius: 12, y: 4)
    }
}

/// "Аа" with the letter spacing of a preset: the buttons of the letter spacing row.
struct LetterSpacingIcon: View {
    let spacing: ReaderLetterSpacing

    var body: some View {
        Text("Аа")
            .font(.system(size: 17, weight: .medium))
            .tracking(spacing.em * 17 * 2.2) // exaggerated, so the four steps look different
            .fixedSize()
    }
}
