import AppKit

final class SelectionAnnotationButton: NSButton {
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        configure()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        configure()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: 50, height: 26)
    }

    override func updateLayer() {
        super.updateLayer()
        guard let layer else { return }

        let orange = ZhijingTheme.annotationNSColor
        layer.cornerRadius = bounds.height / 2
        layer.backgroundColor = (
            isHovering
                ? orange
                : NSColor.controlBackgroundColor.withAlphaComponent(0.96)
        ).cgColor
        layer.borderWidth = isHovering ? 0 : 0.8
        layer.borderColor = orange.withAlphaComponent(0.38).cgColor
        layer.shadowColor = NSColor.black.cgColor
        layer.shadowOpacity = isHovering ? 0.18 : 0.11
        layer.shadowRadius = isHovering ? 5 : 3.5
        layer.shadowOffset = CGSize(width: 0, height: -1)
        let shadowBounds = bounds.insetBy(dx: 1, dy: 1)
        layer.shadowPath = CGPath(
            roundedRect: shadowBounds,
            cornerWidth: shadowBounds.height / 2,
            cornerHeight: shadowBounds.height / 2,
            transform: nil
        )
        attributedTitle = NSAttributedString(
            string: "批注",
            attributes: [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: isHovering ? NSColor.white : orange
            ]
        )
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea {
            removeTrackingArea(hoverTrackingArea)
        }
        let area = NSTrackingArea(
            rect: .zero,
            options: [
                .inVisibleRect,
                .activeInKeyWindow,
                .mouseEnteredAndExited
            ],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        isHovering = true
        NSCursor.pointingHand.set()
    }

    override func mouseExited(with event: NSEvent) {
        isHovering = false
        NSCursor.arrow.set()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }

    private func configure() {
        title = "批注"
        image = nil
        imagePosition = .noImage
        alignment = .center
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .default
        setButtonType(.momentaryChange)
        toolTip = "在选中文字旁添加批注（⇧⌘M）"
        wantsLayer = true
        layer?.masksToBounds = false
        frame.size = intrinsicContentSize
        setAccessibilityLabel("添加批注")
    }
}
