import AppKit
import SwiftUI

struct InlineAnnotationComposerView: View {
    let selectedText: String
    let onSave: (String) -> Void
    let onCancel: () -> Void

    @State private var text = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 13) {
            header
            sourceExcerpt

            NativeAnnotationTextEditor(
                text: $text,
                placeholder: "写下你的判断、问题或修改意图…",
                onSubmit: submit,
                onCancel: onCancel
            )
            .frame(height: 148)
            .background(
                ZhijingTheme.paper,
                in: RoundedRectangle(cornerRadius: 9)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(Color.primary.opacity(0.1))
            }

            footer
        }
        .padding(16)
        .frame(width: 400)
    }

    private var header: some View {
        HStack(spacing: 9) {
            Image(systemName: "text.bubble.fill")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(ZhijingTheme.annotation)
            VStack(alignment: .leading, spacing: 1) {
                Text("批注")
                    .font(.system(size: 14, weight: .semibold))
                Text("保存后显示在当前正文中")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .frame(width: 18, height: 18)
            }
            .buttonStyle(.plain)
            .help("取消")
        }
    }

    private var sourceExcerpt: some View {
        HStack(alignment: .top, spacing: 9) {
            RoundedRectangle(cornerRadius: 1.5)
                .fill(ZhijingTheme.annotation.opacity(0.72))
                .frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                Text("对应原文")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(.secondary)
                Text(excerpt)
                    .font(.caption)
                    .foregroundStyle(.primary.opacity(0.82))
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(
            ZhijingTheme.annotation.opacity(0.055),
            in: RoundedRectangle(cornerRadius: 8)
        )
    }

    private var footer: some View {
        HStack(spacing: 8) {
            Label("正文可见 · 随文稿保存", systemImage: "eye")
                .font(.caption2)
                .foregroundStyle(.secondary)
            Spacer()
            Text("Esc 取消  ·  ⌘↩ 保存")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Button("保存", action: submit)
                .buttonStyle(.borderedProminent)
                .tint(ZhijingTheme.annotation)
                .disabled(trimmedText.isEmpty)
        }
    }

    private var trimmedText: String {
        text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var excerpt: String {
        let compact = selectedText
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard compact.count > 120 else { return compact }
        return String(compact.prefix(120)) + "…"
    }

    private func submit() {
        guard !trimmedText.isEmpty else { return }
        onSave(trimmedText)
    }
}

struct NativeAnnotationTextEditor: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = AnnotationComposerTextView(
            frame: scrollView.contentView.bounds
        )
        textView.delegate = context.coordinator
        textView.string = text
        textView.placeholder = placeholder
        textView.onSubmit = { [weak coordinator = context.coordinator] in
            coordinator?.submit()
        }
        textView.onCancel = { [weak coordinator = context.coordinator] in
            coordinator?.cancel()
        }
        textView.isEditable = true
        textView.isSelectable = true
        textView.isRichText = false
        textView.importsGraphics = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.font = .systemFont(ofSize: 14)
        textView.textColor = .labelColor
        textView.insertionPointColor = .controlAccentColor
        textView.textContainerInset = NSSize(width: 8, height: 8)
        textView.textContainer?.lineFragmentPadding = 3
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.minSize = NSSize(width: 0, height: scrollView.contentSize.height)
        textView.maxSize = NSSize(
            width: CGFloat.greatestFiniteMagnitude,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.containerSize = NSSize(
            width: scrollView.contentSize.width,
            height: CGFloat.greatestFiniteMagnitude
        )
        textView.textContainer?.widthTracksTextView = true
        scrollView.documentView = textView
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let textView = scrollView.documentView as? AnnotationComposerTextView
        else { return }
        textView.placeholder = placeholder
        if !textView.hasMarkedText(), textView.string != text {
            textView.string = text
        }
        textView.needsDisplay = true
    }

    @MainActor
    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: NativeAnnotationTextEditor

        init(parent: NativeAnnotationTextEditor) {
            self.parent = parent
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? AnnotationComposerTextView
            else { return }
            parent.text = textView.string
            textView.needsDisplay = true
        }

        func submit() {
            parent.onSubmit()
        }

        func cancel() {
            parent.onCancel()
        }
    }
}

final class AnnotationComposerTextView: NSTextView {
    var placeholder = "" {
        didSet { needsDisplay = true }
    }
    var onSubmit: (() -> Void)?
    var onCancel: (() -> Void)?
    private var hasRequestedInitialFocus = false

    var shouldDrawPlaceholder: Bool {
        string.isEmpty && !hasMarkedText()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard window != nil, !hasRequestedInitialFocus else { return }
        hasRequestedInitialFocus = true
        DispatchQueue.main.async { [weak self] in
            guard let self, let window = self.window else { return }
            window.makeFirstResponder(self)
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard shouldDrawPlaceholder, !placeholder.isEmpty else { return }
        let origin = textContainerOrigin
        let rect = NSRect(
            x: origin.x + 3,
            y: origin.y + 1,
            width: max(0, bounds.width - origin.x - 14),
            height: 22
        )
        placeholder.draw(
            in: rect,
            withAttributes: [
                .font: font ?? NSFont.systemFont(ofSize: 14),
                .foregroundColor: NSColor.placeholderTextColor
            ]
        )
    }

    override func setMarkedText(
        _ string: Any,
        selectedRange: NSRange,
        replacementRange: NSRange
    ) {
        super.setMarkedText(
            string,
            selectedRange: selectedRange,
            replacementRange: replacementRange
        )
        needsDisplay = true
    }

    override func unmarkText() {
        super.unmarkText()
        needsDisplay = true
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let modifiers = event.modifierFlags.intersection(
            .deviceIndependentFlagsMask
        )
        if modifiers == .command,
           event.keyCode == 36 || event.keyCode == 76 {
            onSubmit?()
            return true
        }
        return super.performKeyEquivalent(with: event)
    }

    override func cancelOperation(_ sender: Any?) {
        onCancel?()
    }
}
