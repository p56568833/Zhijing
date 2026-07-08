import AppKit
import SwiftUI

struct ResizablePaneDivider: View {
    @Binding var paneWidth: Double
    let range: ClosedRange<Double>
    let dragDirection: Double
    var updatesContinuously = false
    var onDragEnded: ((Double) -> Void)? = nil

    @State private var dragStartWidth: Double?
    @State private var lastDragUpdate: ContinuousClock.Instant?
    @State private var dragPreviewTranslation: CGFloat = 0
    @State private var isHovering = false

    var body: some View {
        ZStack {
            Color.clear
            if dragStartWidth != nil, !updatesContinuously {
                Rectangle()
                    .fill(Color.accentColor.opacity(0.32))
                    .frame(width: 2)
                    .offset(x: dragPreviewTranslation)
                    .allowsHitTesting(false)
            }
            Rectangle()
                .fill(
                    isHovering || dragStartWidth != nil
                        ? Color.accentColor.opacity(0.72)
                        : Color(nsColor: .separatorColor)
                )
                .frame(width: isHovering || dragStartWidth != nil ? 2 : 1)
        }
        .frame(width: 12)
        .frame(maxHeight: .infinity)
        .contentShape(Rectangle())
        .onHover { isHovering in
            self.isHovering = isHovering
            if isHovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .highPriorityGesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? paneWidth
                    dragStartWidth = start
                    dragPreviewTranslation = value.translation.width
                    guard updatesContinuously else { return }
                    let now = ContinuousClock.now
                    if let lastDragUpdate,
                       now - lastDragUpdate < .milliseconds(16) {
                        return
                    }
                    lastDragUpdate = now
                    updateWidth(
                        from: start,
                        translation: value.translation.width
                    )
                }
                .onEnded { value in
                    let start = dragStartWidth ?? paneWidth
                    let finalWidth = updateWidth(
                        from: start,
                        translation: value.translation.width
                    )
                    onDragEnded?(finalWidth)
                    dragStartWidth = nil
                    lastDragUpdate = nil
                    dragPreviewTranslation = 0
                }
        )
        .accessibilityElement()
        .accessibilityLabel("调整分栏宽度")
        .accessibilityHint("左右拖动")
    }

    @discardableResult
    private func updateWidth(from start: Double, translation: CGFloat) -> Double {
        let proposed = start + Double(translation) * dragDirection
        let clamped = min(range.upperBound, max(range.lowerBound, proposed))
        guard paneWidth != clamped else { return clamped }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) {
            paneWidth = clamped
        }
        return clamped
    }
}
