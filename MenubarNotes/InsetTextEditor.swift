import AppKit
import SwiftUI

/// A plain-text editor that insets its text symmetrically without moving the
/// scroll view's frame, so the scrollbar stays flush against the container's
/// trailing edge. SwiftUI's `TextEditor` can't do this: `.padding`,
/// `.contentMargins`, and `.safeAreaInset` all shrink the whole scroll view
/// (scrollbar included), not just the text layout.
struct InsetTextEditor: NSViewRepresentable {
    @Binding var text: String
    var font: NSFont
    var horizontalInset: CGFloat
    var isFocused: Binding<Bool>

    func makeNSView(context: Context) -> NSScrollView {
        let textView = FocusTrackingTextView()
        textView.delegate = context.coordinator
        textView.isRichText = false
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.font = font
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: horizontalInset, height: 0)
        textView.textContainer?.lineFragmentPadding = 0
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.string = text
        textView.onFocusChange = { focused in
            if isFocused.wrappedValue != focused {
                isFocused.wrappedValue = focused
            }
        }

        let scrollView = NSScrollView()
        scrollView.documentView = textView
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true

        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? FocusTrackingTextView else { return }

        if textView.string != text {
            textView.string = text
        }
        if textView.font != font {
            textView.font = font
        }
        textView.textContainerInset = NSSize(width: horizontalInset, height: 0)

        if isFocused.wrappedValue, textView.window?.firstResponder !== textView {
            textView.window?.makeFirstResponder(textView)
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: InsetTextEditor

        init(_ parent: InsetTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
        }
    }
}

/// Reports first-responder transitions so SwiftUI's `@FocusState` can stay in
/// sync with an `NSTextView` that lives outside SwiftUI's own focus system.
private final class FocusTrackingTextView: NSTextView {
    var onFocusChange: ((Bool) -> Void)?

    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            onFocusChange?(true)
        }
        return result
    }

    override func resignFirstResponder() -> Bool {
        let result = super.resignFirstResponder()
        if result {
            onFocusChange?(false)
        }
        return result
    }
}
