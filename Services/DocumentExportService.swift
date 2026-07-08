import AppKit
import CoreGraphics
import Foundation
import UniformTypeIdentifiers

enum DocumentExportFormat: String, CaseIterable, Sendable {
    case pdf
    case word

    var fileExtension: String {
        switch self {
        case .pdf: "pdf"
        case .word: "docx"
        }
    }

    var displayName: String {
        switch self {
        case .pdf: "PDF"
        case .word: "Word"
        }
    }
}

@MainActor
struct DocumentExportService {
    func presentExport(
        title: String,
        markdown: String,
        format: DocumentExportFormat
    ) throws -> URL? {
        let panel = NSSavePanel()
        panel.title = "导出 \(format.displayName)"
        panel.nameFieldStringValue = "\(sanitizedFilename(title)).\(format.fileExtension)"
        panel.allowedContentTypes = format == .pdf
            ? [.pdf]
            : [UTType(filenameExtension: "docx") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return nil }
        try export(title: title, markdown: markdown, format: format, to: url)
        return url
    }

    func export(
        title: String,
        markdown: String,
        format: DocumentExportFormat,
        to url: URL
    ) throws {
        let document = MarkdownExportRenderer.render(title: title, markdown: markdown)
        switch format {
        case .pdf:
            try writePDF(document, to: url)
        case .word:
            try writeWord(document, title: title, to: url)
        }
    }

    private func writeWord(
        _ document: NSAttributedString,
        title: String,
        to url: URL
    ) throws {
        let data = try document.data(
            from: NSRange(location: 0, length: document.length),
            documentAttributes: [
                .documentType: NSAttributedString.DocumentType.officeOpenXML,
                .title: title,
                .author: "知境",
                .creationTime: Date.now,
            ]
        )
        try data.write(to: url, options: .atomic)
    }

    private func writePDF(
        _ document: NSAttributedString,
        to url: URL
    ) throws {
        let pageSize = CGSize(width: 595, height: 842)
        let margins = NSEdgeInsets(top: 54, left: 62, bottom: 54, right: 62)
        let contentSize = CGSize(
            width: pageSize.width - margins.left - margins.right,
            height: pageSize.height - margins.top - margins.bottom
        )
        guard let consumer = CGDataConsumer(url: url as CFURL) else {
            throw CocoaError(.fileWriteUnknown)
        }
        var mediaBox = CGRect(origin: .zero, size: pageSize)
        guard let context = CGContext(
            consumer: consumer,
            mediaBox: &mediaBox,
            nil
        ) else {
            throw CocoaError(.fileWriteUnknown)
        }

        let textStorage = NSTextStorage(attributedString: document)
        let layoutManager = NSLayoutManager()
        textStorage.addLayoutManager(layoutManager)
        layoutManager.ensureGlyphs(forCharacterRange: NSRange(
            location: 0,
            length: textStorage.length
        ))

        var containers: [NSTextContainer] = []
        var laidOutGlyphs = 0
        repeat {
            let container = NSTextContainer(size: contentSize)
            container.lineFragmentPadding = 0
            layoutManager.addTextContainer(container)
            layoutManager.ensureLayout(for: container)
            let glyphRange = layoutManager.glyphRange(for: container)
            containers.append(container)
            let nextGlyph = NSMaxRange(glyphRange)
            guard nextGlyph > laidOutGlyphs || layoutManager.numberOfGlyphs == 0 else {
                break
            }
            laidOutGlyphs = nextGlyph
        } while laidOutGlyphs < layoutManager.numberOfGlyphs

        for container in containers {
            context.beginPDFPage(nil)
            context.saveGState()
            context.translateBy(
                x: margins.left,
                y: pageSize.height - margins.top
            )
            context.scaleBy(x: 1, y: -1)

            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(
                cgContext: context,
                flipped: true
            )
            let glyphRange = layoutManager.glyphRange(for: container)
            layoutManager.drawBackground(forGlyphRange: glyphRange, at: .zero)
            layoutManager.drawGlyphs(forGlyphRange: glyphRange, at: .zero)
            NSGraphicsContext.restoreGraphicsState()

            context.restoreGState()
            context.endPDFPage()
        }
        context.closePDF()
    }

    private func sanitizedFilename(_ value: String) -> String {
        value.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
    }
}

private enum MarkdownExportRenderer {
    static func render(title: String, markdown: String) -> NSAttributedString {
        let result = NSMutableAttributedString()
        let blocks = MarkdownReadingParser.parse(markdown)

        if !startsWithPrimaryHeading(blocks) {
            append(
                title,
                to: result,
                font: .systemFont(ofSize: 26, weight: .bold),
                spacingBefore: 0,
                spacingAfter: 18
            )
        }

        for block in blocks {
            switch block.kind {
            case .heading(let level):
                let size: CGFloat = switch level {
                case 1: 26
                case 2: 21
                case 3: 17
                default: 15
                }
                append(
                    block.content,
                    to: result,
                    font: .systemFont(
                        ofSize: size,
                        weight: level <= 2 ? .bold : .semibold
                    ),
                    spacingBefore: level == 1 ? 0 : 14,
                    spacingAfter: 8
                )
            case .paragraph:
                append(
                    block.content,
                    to: result,
                    font: .systemFont(ofSize: 12.5),
                    spacingBefore: 0,
                    spacingAfter: 9
                )
            case .quote:
                append(
                    "│  \(block.content)",
                    to: result,
                    font: .systemFont(ofSize: 12.5).italic,
                    color: .darkGray,
                    leftIndent: 12,
                    spacingBefore: 4,
                    spacingAfter: 10
                )
            case .unorderedList(let indentation):
                append(
                    "•  \(block.content)",
                    to: result,
                    font: .systemFont(ofSize: 12.5),
                    leftIndent: CGFloat(indentation) * 18 + 14,
                    firstLineIndent: CGFloat(indentation) * 18,
                    spacingBefore: 0,
                    spacingAfter: 4
                )
            case .orderedList(let marker, let indentation):
                append(
                    "\(marker)  \(block.content)",
                    to: result,
                    font: .systemFont(ofSize: 12.5),
                    leftIndent: CGFloat(indentation) * 18 + 18,
                    firstLineIndent: CGFloat(indentation) * 18,
                    spacingBefore: 0,
                    spacingAfter: 4
                )
            case .code:
                append(
                    block.content,
                    to: result,
                    font: .monospacedSystemFont(ofSize: 10.5, weight: .regular),
                    color: .darkGray,
                    leftIndent: 14,
                    spacingBefore: 6,
                    spacingAfter: 10
                )
            case .divider:
                append(
                    "────────────────────────────────",
                    to: result,
                    font: .systemFont(ofSize: 9),
                    color: .lightGray,
                    spacingBefore: 10,
                    spacingAfter: 10
                )
            case .space:
                result.append(NSAttributedString(string: "\n"))
            }
        }
        return result
    }

    private static func append(
        _ source: String,
        to result: NSMutableAttributedString,
        font: NSFont,
        color: NSColor = .black,
        leftIndent: CGFloat = 0,
        firstLineIndent: CGFloat? = nil,
        spacingBefore: CGFloat,
        spacingAfter: CGFloat
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineSpacing = 3
        paragraph.paragraphSpacingBefore = spacingBefore
        paragraph.paragraphSpacing = spacingAfter
        paragraph.headIndent = leftIndent
        paragraph.firstLineHeadIndent = firstLineIndent ?? leftIndent

        let rendered = inlineMarkdown(source.isEmpty ? " " : source)
        let fullRange = NSRange(location: 0, length: rendered.length)
        rendered.addAttributes(
            [
                .foregroundColor: color,
                .paragraphStyle: paragraph,
            ],
            range: fullRange
        )
        rendered.enumerateAttribute(.font, in: fullRange) { value, range, _ in
            if let existing = value as? NSFont {
                rendered.addAttribute(
                    .font,
                    value: NSFontManager.shared.convert(existing, toSize: font.pointSize),
                    range: range
                )
            } else {
                rendered.addAttribute(.font, value: font, range: range)
            }
        }
        if rendered.length > 0,
           rendered.attribute(.font, at: 0, effectiveRange: nil) == nil {
            rendered.addAttribute(.font, value: font, range: fullRange)
        }
        rendered.append(NSAttributedString(string: "\n"))
        result.append(rendered)
    }

    private static func inlineMarkdown(_ source: String) -> NSMutableAttributedString {
        guard let attributed = try? AttributedString(
            markdown: source,
            options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        ) else {
            return NSMutableAttributedString(string: source)
        }
        return NSMutableAttributedString(attributedString: NSAttributedString(attributed))
    }

    private static func startsWithPrimaryHeading(
        _ blocks: [MarkdownReadingBlock]
    ) -> Bool {
        guard let first = blocks.first else { return false }
        if case .heading(level: 1) = first.kind { return true }
        return false
    }
}

private extension NSFont {
    var italic: NSFont {
        NSFontManager.shared.convert(self, toHaveTrait: .italicFontMask)
    }
}
