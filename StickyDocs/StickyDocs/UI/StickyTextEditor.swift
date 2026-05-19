import SwiftUI
import AppKit

final class StickyNSTextView: NSTextView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command else {
            return super.performKeyEquivalent(with: event)
        }
        switch event.charactersIgnoringModifiers {
        case "b": toggleBold(nil); return true
        case "i": toggleItalic(nil); return true
        case "u": toggleUnderline(nil); return true
        default: return super.performKeyEquivalent(with: event)
        }
    }

    @objc func toggleBold(_ sender: Any?) { applyTrait(.boldFontMask) }
    @objc func toggleItalic(_ sender: Any?) { applyTrait(.italicFontMask) }
    @objc func toggleUnderline(_ sender: Any?) { toggleUnderlineTrait() }

    private func applyTrait(_ trait: NSFontTraitMask) {
        let range = selectedRange()
        let fm = NSFontManager.shared

        func toggled(_ font: NSFont) -> NSFont {
            let has = fm.traits(of: font).contains(trait)
            return has ? fm.convert(font, toNotHaveTrait: trait) : fm.convert(font, toHaveTrait: trait)
        }

        if range.length == 0 {
            var attrs = typingAttributes
            let font = (attrs[.font] as? NSFont) ?? NSFont.systemFont(ofSize: 14)
            attrs[.font] = toggled(font)
            typingAttributes = attrs
            return
        }

        guard let storage = textStorage else { return }
        storage.beginEditing()
        storage.enumerateAttribute(.font, in: range, options: []) { value, subrange, _ in
            let font = (value as? NSFont) ?? NSFont.systemFont(ofSize: 14)
            storage.addAttribute(.font, value: toggled(font), range: subrange)
        }
        storage.endEditing()
        didChangeText()
    }

    private func toggleUnderlineTrait() {
        let range = selectedRange()
        if range.length == 0 {
            var attrs = typingAttributes
            let current = (attrs[.underlineStyle] as? Int) ?? 0
            attrs[.underlineStyle] = current == 0 ? NSUnderlineStyle.single.rawValue : 0
            typingAttributes = attrs
            return
        }
        guard let storage = textStorage else { return }
        let current = storage.attribute(.underlineStyle, at: range.location, effectiveRange: nil) as? Int ?? 0
        let newValue: Int = current == 0 ? NSUnderlineStyle.single.rawValue : 0
        storage.beginEditing()
        storage.addAttribute(.underlineStyle, value: newValue, range: range)
        storage.endEditing()
        didChangeText()
    }
}

struct StickyTextEditor: NSViewRepresentable {
    // Bound to the sticky's current HTML. Re-applied by updateNSView when the
    // store changes underneath us (e.g. a pull pulled in a remote edit) so
    // long as the user isn't actively typing in this text view.
    let html: String
    let onChange: (NSAttributedString) -> Void

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder

        let contentSize = scrollView.contentSize
        let layoutManager = NSLayoutManager()
        let textContainer = NSTextContainer(containerSize: NSSize(width: contentSize.width, height: CGFloat.greatestFiniteMagnitude))
        textContainer.widthTracksTextView = true
        layoutManager.addTextContainer(textContainer)
        let storage = NSTextStorage()
        storage.addLayoutManager(layoutManager)

        let textView = StickyNSTextView(frame: .zero, textContainer: textContainer)
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        scrollView.documentView = textView

        textView.isRichText = true
        textView.allowsUndo = true
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.font = NSFont.systemFont(ofSize: 14)
        textView.textColor = .black
        textView.backgroundColor = .clear
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 8, height: 0)
        scrollView.drawsBackground = false
        scrollView.backgroundColor = .clear

        let initialAttr = HTMLNormalizer.attributedString(from: html)
        textView.textStorage?.setAttributedString(initialAttr)
        textView.delegate = context.coordinator
        context.coordinator.textView = textView
        return scrollView
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        guard let textView = nsView.documentView as? NSTextView,
              let storage = textView.textStorage else { return }
        // Don't clobber while the user is actively typing in this field.
        // (Window-key + first-responder is the precise check — we want
        // Sync Now triggered from the menu bar, which steals key, to still
        // refresh a sticky the user was looking at.)
        if textView.window?.isKeyWindow == true,
           textView.window?.firstResponder === textView {
            return
        }
        let currentHTML = HTMLNormalizer.html(from: NSAttributedString(attributedString: storage))
        if currentHTML == html { return }
        let newAttr = HTMLNormalizer.attributedString(from: html)
        storage.setAttributedString(newAttr)
    }

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
