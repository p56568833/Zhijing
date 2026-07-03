import AppKit
import SwiftUI

struct ResizablePaneDivider: View {
    @Binding var paneWidth: Double
    let range: ClosedRange<Double>
    let dragDirection: Double

    @State private var dragStartWidth: Double?

    var body: some View {
        ZStack {
            Color.clear
            Divider()
        }
        .frame(width: 8)
        .contentShape(Rectangle())
        .onHover { isHovering in
            if isHovering {
                NSCursor.resizeLeftRight.push()
            } else {
                NSCursor.pop()
            }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    let start = dragStartWidth ?? paneWidth
                    dragStartWidth = start
                    let proposed = start + Double(value.translation.width) * dragDirection
                    paneWidth = min(range.upperBound, max(range.lowerBound, proposed))
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
    }
}
