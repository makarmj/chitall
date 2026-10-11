import SwiftUI
import UIKit

/// Continuous (scrolling) reading mode: one chapter in one read-only, selectable
/// `UITextView`. It gives the system selection (handles, magnifier, Copy, Look Up, Translate)
/// and exact `NSRange`s — see DECISIONS.md §1.
struct BookTextView: UIViewRepresentable {
    var content: RenderedChapter
    var decorations: [HighlightDecoration]
    var navigation: NavigationRequest?
    var actions: ReaderTextActions
    var onVisibleOffsetChange: (Int, Int) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeUIView(context: Context) -> ReaderTextView {
        let view = ReaderTextView(scrollable: true)
        view.delegate = context.coordinator
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.handleTap(_:)))
        tap.delegate = context.coordinator
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: ReaderTextView, context: Context) {
        context.coordinator.parent = self
        context.coordinator.update(view)
    }

    static func dismantleUIView(_ view: ReaderTextView, coordinator: Coordinator) {
        // Save the position once more when the reader closes, outside of the view update.
        guard view.textStorage.length > 0 else { return }
        let chapter = coordinator.parent.content.chapterIndex
        let offset = view.firstVisibleOffset()
        let report = coordinator.parent.onVisibleOffsetChange
        DispatchQueue.main.async { report(chapter, offset) }
    }

    @MainActor
    final class Coordinator: NSObject, UITextViewDelegate, UIGestureRecognizerDelegate {
        var parent: BookTextView
        private var contentID: String?
        private var chapterIndex: Int?
        private var appliedDecorations: [HighlightDecoration] = []
        private var handledNavigation: UUID?

        init(parent: BookTextView) {
            self.parent = parent
        }

        // MARK: Updates from SwiftUI

        func update(_ view: ReaderTextView) {
            var offsetToKeep: Int?
            if parent.content.id != contentID {
                // Same chapter in a new typography: keep the first visible character in place.
                if contentID != nil, chapterIndex == parent.content.chapterIndex {
                    offsetToKeep = view.firstVisibleOffset()
                }
                view.attributedText = parent.content.attributed
                contentID = parent.content.id
                chapterIndex = parent.content.chapterIndex
                appliedDecorations = []
            }

            if parent.decorations != appliedDecorations {
                DecorationPainter.apply(parent.decorations, to: view.textStorage, chapterOffset: 0)
                appliedDecorations = parent.decorations
            }

            if let request = parent.navigation, request.id != handledNavigation, request.chapter == parent.content.chapterIndex {
                handledNavigation = request.id
                scheduleScroll(view, to: request.utf16Offset, placement: request.placement)
            } else if let offsetToKeep {
                scheduleScroll(view, to: offsetToKeep, placement: .top)
            }
        }

        private func scheduleScroll(_ view: ReaderTextView, to offset: Int, placement: NavigationRequest.Placement, attempt: Int = 0) {
            DispatchQueue.main.async { [weak view] in
                guard let view else { return }
                // SwiftUI may not have laid the view out yet on the very first update.
                if view.bounds.width < 1, attempt < 10 {
                    self.scheduleScroll(view, to: offset, placement: placement, attempt: attempt + 1)
                    return
                }
                view.scroll(toUTF16: offset, placement: placement)
            }
        }

        // MARK: Edit menu and links

        func textView(_ textView: UITextView, editMenuForTextIn range: NSRange, suggestedActions: [UIMenuElement]) -> UIMenu? {
            guard range.length > 0 else { return nil }
            return ReaderEditMenu.make(
                for: ChapterRange(chapter: parent.content.chapterIndex, range: range),
                decorations: appliedDecorations,
                suggestedActions: suggestedActions,
                perform: { [weak self] action in self?.parent.actions.onSelectionAction(action) },
                clearSelection: { [weak textView] in textView?.selectedRange = NSRange(location: range.location, length: 0) }
            )
        }

        func textView(_ textView: UITextView, primaryActionFor textItem: UITextItem, defaultAction: UIAction) -> UIAction? {
            ReaderLinks.primaryAction(for: textItem, defaultAction: defaultAction) { [weak self] url in
                self?.parent.actions.onTapLink(url)
            }
        }

        func textView(_ textView: UITextView, menuConfigurationFor textItem: UITextItem, defaultMenu: UIMenu) -> UITextItem.MenuConfiguration? {
            nil // No link preview menu for internal chitall-note: URLs.
        }

        // MARK: Taps on highlights and on the page

        @objc func handleTap(_ gesture: UITapGestureRecognizer) {
            guard gesture.state == .ended, let view = gesture.view as? ReaderTextView else { return }
            guard view.selectedRange.length == 0 else { return } // the tap only dismisses a selection
            guard let index = view.characterIndex(at: gesture.location(in: view)) else {
                parent.actions.onTapText()
                return
            }
            if view.textStorage.attribute(.link, at: index, effectiveRange: nil) != nil { return }
            if let decoration = DecorationPainter.highlight(at: index, in: appliedDecorations) {
                parent.actions.onTapHighlight(decoration.id)
            } else {
                parent.actions.onTapText()
            }
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
            true
        }

        func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldRequireFailureOf other: UIGestureRecognizer) -> Bool {
            // Wait for the text view's double tap (word selection) to fail before treating a tap as ours.
            guard let tap = other as? UITapGestureRecognizer else { return false }
            return tap.numberOfTapsRequired > 1 && other.view === gestureRecognizer.view
        }

        // MARK: Reading position

        func scrollViewDidEndDragging(_ scrollView: UIScrollView, willDecelerate decelerate: Bool) {
            if !decelerate { reportVisibleOffset(of: scrollView) }
        }

        func scrollViewDidEndDecelerating(_ scrollView: UIScrollView) {
            reportVisibleOffset(of: scrollView)
        }

        func scrollViewDidEndScrollingAnimation(_ scrollView: UIScrollView) {
            reportVisibleOffset(of: scrollView)
        }

        private func reportVisibleOffset(of scrollView: UIScrollView) {
            guard let view = scrollView as? ReaderTextView, view.textStorage.length > 0 else { return }
            parent.onVisibleOffsetChange(parent.content.chapterIndex, view.firstVisibleOffset())
        }
    }
}
