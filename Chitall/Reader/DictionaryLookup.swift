import SwiftUI
import UIKit

/// "Значение" (DECISIONS.md §20): the selected word in the dictionaries of iOS itself,
/// `UIReferenceLibraryViewController`. They are downloaded once and then work offline: no
/// server, no key. Without a Russian dictionary on the iPhone the reader first explains where
/// to get one.
enum DictionaryLookup {
    struct Request: Identifiable, Equatable {
        let id = UUID()
        let term: String
        /// Whether an installed dictionary has an entry for the term.
        let found: Bool
    }

    /// What to show for a term; `hasDefinition` is replaceable in tests (the simulator has no
    /// dictionaries).
    @MainActor
    static func request(
        for term: String,
        hasDefinition: (String) -> Bool = { UIReferenceLibraryViewController.dictionaryHasDefinition(forTerm: $0) }
    ) -> Request {
        // Sentence case is how a word stands at the start of a line; the entry is lower case.
        let found = hasDefinition(term) || hasDefinition(term.lowercased())
        return Request(term: found && !hasDefinition(term) ? term.lowercased() : term, found: found)
    }

    /// Shows the system dictionary card over whatever is on screen. Presented by UIKit itself:
    /// the card has its own "Готово", which SwiftUI state would not hear about.
    @MainActor
    static func present(_ term: String) {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        guard var top = scenes.flatMap(\.windows).first(where: \.isKeyWindow)?.rootViewController else { return }
        while let presented = top.presentedViewController, !presented.isBeingDismissed { top = presented }
        top.present(UIReferenceLibraryViewController(term: term), animated: true)
    }
}

/// No entry for the word: most likely the Russian dictionary is not downloaded yet.
struct MissingDictionaryCard: View {
    let term: String
    let colors: ThemeColors
    let onOpenDictionaries: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .firstTextBaseline) {
                Text("«\(term)»")
                    .font(Typography.serif(.title3, weight: .semibold))
                    .lineLimit(2)
                Spacer(minLength: 12)
                Button { dismiss() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color(uiColor: colors.secondary))
                        .frame(width: 32, height: 32)
                        .background(Color(uiColor: colors.divider), in: Circle())
                }
                .accessibilityLabel("Закрыть")
            }
            Text("В словарях на этом iPhone нет такого слова. Чаще всего просто не скачан русский толковый словарь.")
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 6) {
                Text("Как скачать (один раз, дальше без интернета):")
                    .font(.subheadline.weight(.semibold))
                Text("Настройки → Основные → Словарь → отметьте «Русский». Или нажмите кнопку ниже и в словаре — «Управлять словарями».")
                    .font(.subheadline)
                    .foregroundStyle(Color(uiColor: colors.secondary))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text("Старинного или редкого слова может не быть и в скачанном словаре.")
                .font(.footnote)
                .foregroundStyle(Color(uiColor: colors.secondary))
                .fixedSize(horizontal: false, vertical: true)
            Button {
                onOpenDictionaries() // shown once this card is gone
                dismiss()
            } label: {
                Label("Открыть словари", systemImage: "character.book.closed")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
        }
        .foregroundStyle(Color(uiColor: colors.text))
        .tint(Color(uiColor: colors.accent))
        .padding(22)
        .presentationDetents([.medium])
        .presentationDragIndicator(.visible)
        .presentationBackground(Color(uiColor: colors.chrome))
    }
}
