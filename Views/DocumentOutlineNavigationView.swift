import SwiftUI

struct DocumentOutlineNavigationView: View {
    let items: [DocumentOutlineItem]
    let selectedItemID: String?
    let onSelect: (DocumentOutlineItem) -> Void

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                    DocumentOutlineNavigationRow(
                        index: index,
                        item: item,
                        isSelected: selectedItemID == item.id,
                        action: { onSelect(item) }
                    )
                    .padding(.top, item.level == 1 && index > 0 ? 9 : 0)
                }
            }
            .padding(.horizontal, 9)
            .padding(.top, 8)
            .padding(.bottom, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct DocumentOutlineEmptyState: View {
    let isSubtitle: Bool
    let returnToLibrary: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            Spacer(minLength: 24)

            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(ZhijingTheme.accent.opacity(0.075))
                        .frame(width: 52, height: 52)
                    Image(systemName: isSubtitle ? "captions.bubble" : "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundStyle(ZhijingTheme.accent)
                }

                VStack(spacing: 5) {
                    Text(isSubtitle ? "字幕没有标题层级" : "这篇文稿还没有标题")
                        .font(.system(size: 14, weight: .semibold))
                    Text(description)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                        .frame(maxWidth: 190)
                }

                Button("返回文库", action: returnToLibrary)
                    .buttonStyle(.borderless)
                    .font(.caption.weight(.medium))
            }

            Spacer(minLength: 40)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var description: String {
        isSubtitle
            ? "SRT 会保持原格式，不会为了生成大纲改写内容。"
            : "使用 # 到 ###### 创建标题后，这里会自动生成导航。"
    }
}

private struct DocumentOutlineNavigationRow: View {
    let index: Int
    let item: DocumentOutlineItem
    let isSelected: Bool
    let action: () -> Void

    @State private var isHovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Text((index + 1).formatted(.number.precision(.integerLength(2))))
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(
                        isSelected
                            ? ZhijingTheme.accent
                            : Color(nsColor: .tertiaryLabelColor)
                    )
                    .frame(width: 20, alignment: .trailing)

                Text(item.title)
                    .font(font)
                    .foregroundStyle(
                        isSelected || item.level <= 2
                            ? Color.primary
                            : Color.secondary
                    )
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                Spacer(minLength: 0)

                if isSelected {
                    Circle()
                        .fill(ZhijingTheme.accent)
                        .frame(width: 5, height: 5)
                        .transition(.scale.combined(with: .opacity))
                }
            }
            .padding(.leading, indentation)
            .padding(.trailing, 10)
            .padding(.vertical, verticalPadding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(RoundedRectangle(cornerRadius: 8))
        }
        .buttonStyle(OutlineNavigationButtonStyle())
        .onHover { isHovering = $0 }
        .animation(.easeOut(duration: 0.16), value: isHovering)
        .animation(.snappy(duration: 0.22), value: isSelected)
        .help("跳转到第 \(item.line) 行")
        .accessibilityLabel("\(item.title)，第 \(item.line) 行")
    }

    private var indentation: CGFloat {
        CGFloat(max(0, min(item.level - 1, 4))) * 10 + 8
    }

    private var verticalPadding: CGFloat {
        item.level == 1 ? 9 : 7
    }

    private var font: Font {
        switch item.level {
        case 1: .system(size: 13, weight: .semibold)
        case 2: .system(size: 12.5, weight: .medium)
        default: .system(size: 12, weight: .regular)
        }
    }

    private var background: Color {
        if isSelected { return ZhijingTheme.accent.opacity(0.095) }
        if isHovering { return Color.primary.opacity(0.045) }
        return .clear
    }
}

private struct OutlineNavigationButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .opacity(configuration.isPressed ? 0.82 : 1)
            .animation(.easeOut(duration: 0.1), value: configuration.isPressed)
    }
}
