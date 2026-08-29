import AppKit

final class SelectionMarkButton: NSButton {
    let kind: InlineTextMarkKind?
    let isClearAction: Bool
    var isActive = false {
        didSet {
            guard isActive != oldValue else { return }
            needsDisplay = true
        }
    }
    private var hoverTrackingArea: NSTrackingArea?
    private var isHovering = false {
        didSet {
            guard isHovering != oldValue else { return }
            needsDisplay = true
            needsLayout = true
        }
    }

    init(kind: InlineTextMarkKind) {
        self.kind = kind
        isClearAction = false
        super.init(frame: .zero)
        configure()
    }

    init(clearAction: Void) {
        kind = nil
        isClearAction = true
        super.init(frame: .zero)
        configure()
    }

    required init?(coder: NSCoder) {
        kind = nil
        isClearAction = true
        super.init(coder: coder)
        configure()
    }

    override var intrinsicContentSize: NSSize {
        NSSize(width: kind == .underline ? 58 : 46, height: 26)
    }

    override var isEnabled: Bool {
        didSet {
            alphaValue = isEnabled || isClearAction ? 1 : 0.48
            needsDisplay = true
        }
    }

    override func updateLayer() {
        super.updateLayer()
        guard let layer else { return }

        let accent = tintColor
        layer.cornerRadius = bounds.height / 2
        layer.backgroundColor = backgroundColor(accent: accent).cgColor
        layer.borderWidth = isHovering || isActive ? 0 : 0.8
        layer.borderColor = borderColor(accent: accent).cgColor
        layer.shadowColor = accent.cgColor
        layer.shadowOpacity = isHovering ? 0.15 : (isActive ? 0.10 : 0.06)
        layer.shadowRadius = isHovering ? 5 : 3
        layer.shadowOffset = CGSize(width: 0, height: -1)
        let shadowBounds = bounds.insetBy(dx: 1, dy: 1)
        layer.shadowPath = CGPath(
            roundedRect: shadowBounds,
            cornerWidth: shadowBounds.height / 2,
            cornerHeight: shadowBounds.height / 2,
            transform: nil
        )
        attributedTitle = NSAttributedString(
            string: displayTitle,
            attributes: titleAttributes(accent: accent)
        )
    }

    private func backgroundColor(accent: NSColor) -> NSColor {
        if isHovering {
            return isClearAction
                ? ZhijingTheme.importantNSColor.withAlphaComponent(0.90)
                : accent.withAlphaComponent(kind == .highlight ? 0.90 : 0.86)
        }
        if isActive {
            return opaqueTint(kind == .highlight ? 0.48 : 0.18, accent: accent)
        }
        if kind == .highlight {
            return opaqueTint(0.16, accent: accent)
        }
        return NSColor.controlBackgroundColor.withAlphaComponent(0.96)
    }

    /// 低透明度色底叠在选区高亮上会糊掉；混进不透明底色，胶囊在任何背景上都可读。
    private func opaqueTint(
        _ fraction: CGFloat,
        accent: NSColor
    ) -> NSColor {
        NSColor.controlBackgroundColor.blended(
            withFraction: fraction,
            of: accent
        ) ?? accent.withAlphaComponent(fraction)
    }

    private func borderColor(accent: NSColor) -> NSColor {
        if isClearAction && !isEnabled {
            return NSColor.separatorColor.withAlphaComponent(0.78)
        }
        return accent.withAlphaComponent(0.38)
    }

    private func titleAttributes(
        accent: NSColor
    ) -> [NSAttributedString.Key: Any] {
        var attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12, weight: .medium),
                .foregroundColor: titleColor(accent: accent)
        ]
        if kind == .underline {
            attributes[.underlineStyle] = NSUnderlineStyle.single.rawValue
            attributes[.underlineColor] = ZhijingTheme.underlineNSColor
        }
        return attributes
    }

    private func titleColor(accent: NSColor) -> NSColor {
        if isHovering {
            return kind == .highlight
                ? NSColor.black.withAlphaComponent(0.78)
                : .white
        }
        if isClearAction {
            return isEnabled
                ? ZhijingTheme.importantNSColor
                : .secondaryLabelColor
        }
        if kind == .highlight { return .labelColor }
        return accent
    }

    private var tintColor: NSColor {
        guard let kind else { return ZhijingTheme.importantNSColor }
        return switch kind {
        case .highlight: ZhijingTheme.highlightNSColor
        case .important: ZhijingTheme.importantNSColor
        case .concept: ZhijingTheme.conceptNSColor
        case .underline: ZhijingTheme.underlineNSColor
        case .red: .systemRed
        case .orange: .systemOrange
        case .green: .systemGreen
        case .blue: .systemBlue
        }
    }

    private var displayTitle: String {
        guard let kind else { return "清除" }
        return switch kind {
        case .highlight: "荧光"
        case .important: "重要"
        case .concept: "概念"
        case .underline: "下划线"
        case .red: "红"
        case .orange: "橙"
        case .green: "绿"
        case .blue: "蓝"
        }
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
        title = displayTitle
        image = nil
        imagePosition = .noImage
        alignment = .center
        isBordered = false
        bezelStyle = .regularSquare
        focusRingType = .default
        setButtonType(.momentaryChange)
        toolTip = isClearAction
            ? "清除当前文字标记"
            : kind?.accessibilityDescription
        wantsLayer = true
        layer?.masksToBounds = false
        frame.size = intrinsicContentSize
        setAccessibilityLabel(
            isClearAction ? "清除文字标记" : "\(displayTitle)标记"
        )
    }
}
