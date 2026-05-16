import SwiftUI
import AppKit

struct StickyTextEditor: NSViewRepresentable {
    let initialHTML: String
    let onChange: (NSAttributedString) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }

        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .black
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: 4)
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let initialAttr = HTMLNormalizer.attributedString(from: initialHTML)
        textView.textStorage?.setAttributedString(initialAttr)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onChange: onChange) }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        weak var textView: NSTextView?
        let onChange: (NSAttributedString) -> Void

        init(onChange: @escaping (NSAttributedString) -> Void) {
            self.onChange = onChange
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView,
                  let storage = textView.textStorage else { return }
            onChange(NSAttributedString(attributedString: storage))
        }
    }
}
