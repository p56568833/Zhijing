import AppKit
import SwiftUI

final class InlineDiffDecisionControl: NSView {
    let hunkID: LineDiffHunk.ID
    var onDecision: ((LineDiffHunk.ID, Bool, Double) -> Void)?

    private let rejectButton = NSButton()
    private let acceptButton = NSButton()

    init(hunkID: LineDiffHunk.ID) {
        self.hunkID = hunkID
        super.init(frame: .zero)

        configure(
            rejectButton,
            title: "不同意",
            action: #selector(rejectChange)
        )
        configure(
            acceptButton,
            title: "同意",
            action: #selector(acceptChange)
        )
        addSubview(rejectButton)
        addSubview(acceptButton)
        toolTip = "只处理这一处修改，并立即保存"
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 124, height: 24)
    }

    override func layout() {
        super.layout()
        let gap: CGFloat = 6
        let buttonWidth = (bounds.width - gap) / 2
        rejectButton.frame = NSRect(
            x: 0,
            y: 0,
            width: buttonWidth,
            height: bounds.height
        )
        acceptButton.frame = NSRect(
            x: buttonWidth + gap,
            y: 0,
            width: buttonWidth,
            height: bounds.height
        )
    }

    func setDecision(_ decision: Bool?) {
        rejectButton.state = decision == false ? .on : .off
        acceptButton.state = decision == true ? .on : .off
    }

    private func configure(
        _ button: NSButton,
        title: String,
        action: Selector
    ) {
        button.title = title
        button.target = self
        button.action = action
        button.setButtonType(.pushOnPushOff)
        button.bezelStyle = .rounded
        button.controlSize = .small
        button.font = .systemFont(ofSize: NSFont.smallSystemFontSize)
    }

    @objc private func rejectChange() {
        setDecision(false)
        onDecision?(hunkID, false, viewportFraction())
    }

    @objc private func acceptChange() {
        setDecision(true)
        onDecision?(hunkID, true, viewportFraction())
    }

    private func viewportFraction() -> Double {
        guard let scrollView = enclosingScrollView,
              let documentView = scrollView.documentView else { return 0.5 }
        let visibleBounds = scrollView.contentView.bounds
        guard visibleBounds.height > 0 else { return 0.5 }
        let controlBounds = convert(bounds, to: documentView)
        return Double(max(
            0,
            min(1, (controlBounds.midY - visibleBounds.minY) / visibleBounds.height)
        ))
    }
}

final class InlineDiffTextView: NSTextView {
    var decorations: [InlineDiffDecoration] = [] {
        didSet { needsDisplay = true }
    }
    private var controlAnchors: [InlineDiffControlAnchor] = []
    private var decisionControls: [LineDiffHunk.ID: InlineDiffDecisionControl] = [:]

    override func drawBackground(in rect: NSRect) {
        super.drawBackground(in: rect)
        guard let layoutManager else { return }

        for decoration in decorations {
            let lineRange = effectiveLineRange(for: decoration.range)
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: lineRange,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }

            layoutManager.enumerateLineFragments(
                forGlyphRange: glyphRange
            ) { _, usedRect, _, fragmentGlyphRange, _ in
                let intersection = NSIntersectionRange(glyphRange, fragmentGlyphRange)
                guard intersection.length > 0 else { return }
                let highlightRect = NSRect(
                    x: self.textContainerOrigin.x - 8,
                    y: self.textContainerOrigin.y + usedRect.minY,
                    width: max(
                        0,
                        self.bounds.width - self.textContainerOrigin.x - 10
                    ),
                    height: usedRect.height
                )
                guard highlightRect.intersects(rect) else { return }

                let color: NSColor = decoration.kind == .removed
                    ? .systemRed
                    : .systemGreen
                color.withAlphaComponent(0.075).setFill()
                highlightRect.fill()

                let marker = decoration.kind == .removed ? "−" : "+"
                (marker as NSString).draw(
                    at: NSPoint(
                        x: self.textContainerOrigin.x - 21,
                        y: self.textContainerOrigin.y + usedRect.minY + 3
                    ),
                    withAttributes: [
                        .font: NSFont.monospacedSystemFont(
                            ofSize: 12,
                            weight: .semibold
                        ),
                        .foregroundColor: color.withAlphaComponent(0.9)
                    ]
                )
            }
        }
    }

    override func layout() {
        super.layout()
        layoutDecisionControls()
    }

    func configureDecisionControls(
        anchors: [InlineDiffControlAnchor],
        onDecision: @escaping (LineDiffHunk.ID, Bool, Double) -> Void
    ) {
        controlAnchors = anchors
        let activeIDs = Set(anchors.map(\.hunkID))
        let removedIDs = decisionControls.keys.filter { !activeIDs.contains($0) }
        for id in removedIDs {
            decisionControls[id]?.removeFromSuperview()
            decisionControls[id] = nil
        }

        for anchor in anchors {
            let control = decisionControls[anchor.hunkID] ?? {
                let control = InlineDiffDecisionControl(hunkID: anchor.hunkID)
                addSubview(control)
                decisionControls[anchor.hunkID] = control
                return control
            }()
            control.onDecision = onDecision
            control.setDecision(nil)
        }
        needsLayout = true
    }

    private func layoutDecisionControls() {
        guard let layoutManager, let textContainer else { return }
        layoutManager.ensureLayout(for: textContainer)
        for anchor in controlAnchors {
            guard let control = decisionControls[anchor.hunkID] else { continue }
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: anchor.range,
                actualCharacterRange: nil
            )
            guard glyphRange.location < layoutManager.numberOfGlyphs else { continue }
            let fragment = layoutManager.lineFragmentRect(
                forGlyphAt: glyphRange.location,
                effectiveRange: nil
            )
            let size = control.intrinsicContentSize
            control.frame = NSRect(
                x: max(
                    textContainerOrigin.x,
                    bounds.width - size.width - 22
                ),
                y: textContainerOrigin.y + fragment.minY
                    + max(0, (fragment.height - size.height) / 2),
                width: size.width,
                height: size.height
            )
        }
    }

    private func effectiveLineRange(for range: NSRange) -> NSRange {
        let source = string as NSString
        guard source.length > 0 else { return .init(location: 0, length: 0) }
        let location = min(range.location, source.length - 1)
        return source.lineRange(for: NSRange(location: location, length: 0))
    }
}

struct InlineDiffSourceEditor: NSViewRepresentable {
    let presentation: InlineDiffPresentation
    let proposalID: UUID
    let onDecision: (LineDiffHunk.ID, Bool, Double) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSScrollView()
        scrollView.drawsBackground = true
        scrollView.backgroundColor = ZhijingTheme.paperNSColor
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true

        let textView = InlineDiffTextView(frame: scrollView.contentView.bounds)
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 22, height: 24)
        textView.textContainer?.lineFragmentPadding = 8
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

        let ruler = MarkdownLineNumberRulerView(textView: textView)
        scrollView.verticalRulerView = ruler
        scrollView.hasVerticalRuler = true
        scrollView.rulersVisible = true

        context.coordinator.apply(
            presentation,
            proposalID: proposalID,
            onDecision: onDecision,
            to: textView,
            scrollView: scrollView,
            revealFirstChange: true
        )
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? InlineDiffTextView else {
            return
        }
        context.coordinator.apply(
            presentation,
            proposalID: proposalID,
            onDecision: onDecision,
            to: textView,
            scrollView: scrollView,
            revealFirstChange: context.coordinator.proposalID != proposalID
        )
    }

    @MainActor
    final class Coordinator {
        private(set) var proposalID: UUID?

        func apply(
            _ presentation: InlineDiffPresentation,
            proposalID: UUID,
            onDecision: @escaping (LineDiffHunk.ID, Bool, Double) -> Void,
            to textView: InlineDiffTextView,
            scrollView: NSScrollView,
            revealFirstChange: Bool
        ) {
            let contentChanged = self.proposalID != proposalID
                || textView.string != presentation.text
            let preservedVisibleOrigin = contentChanged && !revealFirstChange
                ? scrollView.contentView.bounds.origin
                : nil
            self.proposalID = proposalID

            if contentChanged {
                textView.string = presentation.text
                MarkdownSourceEditor.Coordinator.applyPlainTextAppearance(to: textView)
                applyControlLineSpacing(
                    presentation.controlAnchors,
                    to: textView
                )
                MarkdownPresentationHighlighter.apply(to: textView)
                applyDiffAttributes(presentation.decorations, to: textView)
                textView.decorations = presentation.decorations
                scrollView.verticalRulerView?.needsDisplay = true
            }

            textView.configureDecisionControls(
                anchors: presentation.controlAnchors,
                onDecision: onDecision
            )

            if let preservedVisibleOrigin {
                DispatchQueue.main.async { [weak textView, weak scrollView] in
                    guard let textView, let scrollView else { return }
                    self.restoreViewport(
                        preservedVisibleOrigin,
                        in: textView,
                        scrollView: scrollView
                    )
                }
            } else if contentChanged, revealFirstChange,
               let range = presentation.firstChangeRange {
                DispatchQueue.main.async { [weak textView, weak scrollView] in
                    guard let textView, let scrollView else { return }
                    self.reveal(range, in: textView, scrollView: scrollView)
                }
            }
        }

        private func restoreViewport(
            _ origin: NSPoint,
            in textView: NSTextView,
            scrollView: NSScrollView
        ) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let maximumY = max(
                0,
                textView.frame.height - scrollView.contentView.bounds.height
            )
            scrollView.contentView.scroll(to: NSPoint(
                x: origin.x,
                y: min(origin.y, maximumY)
            ))
            scrollView.reflectScrolledClipView(scrollView.contentView)
        }

        private func applyControlLineSpacing(
            _ anchors: [InlineDiffControlAnchor],
            to textView: NSTextView
        ) {
            guard let textStorage = textView.textStorage else { return }
            let style = NSMutableParagraphStyle()
            style.minimumLineHeight = 34
            style.maximumLineHeight = 34
            for anchor in anchors where anchor.range.length > 0 {
                textStorage.addAttribute(
                    .paragraphStyle,
                    value: style,
                    range: anchor.range
                )
            }
        }

        private func applyDiffAttributes(
            _ decorations: [InlineDiffDecoration],
            to textView: NSTextView
        ) {
            guard let layoutManager = textView.layoutManager else { return }
            for decoration in decorations where decoration.range.length > 0 {
                let color: NSColor = decoration.kind == .removed
                    ? .systemRed
                    : .systemGreen
                var attributes: [NSAttributedString.Key: Any] = [
                    .foregroundColor: color.withAlphaComponent(0.92)
                ]
                if decoration.kind == .removed {
                    attributes[.strikethroughStyle] = NSUnderlineStyle.single.rawValue
                    attributes[.strikethroughColor] = color.withAlphaComponent(0.8)
                }
                layoutManager.addTemporaryAttributes(
                    attributes,
                    forCharacterRange: decoration.range
                )
            }
        }

        private func reveal(
            _ range: NSRange,
            in textView: NSTextView,
            scrollView: NSScrollView
        ) {
            guard let layoutManager = textView.layoutManager,
                  let textContainer = textView.textContainer else { return }
            layoutManager.ensureLayout(for: textContainer)
            let sourceLength = textView.string.utf16.count
            guard sourceLength > 0 else { return }
            let safeLocation = min(range.location, sourceLength - 1)
            let safeRange = NSRange(
                location: safeLocation,
                length: max(1, min(range.length, sourceLength - safeLocation))
            )
            let glyphRange = layoutManager.glyphRange(
                forCharacterRange: safeRange,
                actualCharacterRange: nil
            )
            let changeRect = layoutManager.boundingRect(
                forGlyphRange: glyphRange,
                in: textContainer
            )
            let clipView = scrollView.contentView
            let targetY = max(
                0,
                textView.textContainerOrigin.y + changeRect.minY
                    - clipView.bounds.height * 0.32
            )
            clipView.scroll(to: NSPoint(x: 0, y: targetY))
            scrollView.reflectScrolledClipView(clipView)
        }
    }
}
