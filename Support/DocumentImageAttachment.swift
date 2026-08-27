import AppKit

/// 粘贴图片到文稿：把剪贴板里的图片存到文稿同级的 assets 文件夹，
/// 并在光标处插入相对路径的 Markdown 图片引用。
enum DocumentImageAttachment {
    struct Payload: Equatable {
        let pngData: Data
        let fileName: String
    }

    /// 从剪贴板提取图片数据，统一转成 PNG。
    static func payload(from pasteboard: NSPasteboard, now: Date = .now) -> Payload? {
        let types = pasteboard.types ?? []
        guard types.contains(.png) || types.contains(.tiff) else { return nil }

        let pngData: Data?
        if let directPNG = pasteboard.data(forType: .png) {
            pngData = directPNG
        } else if let tiffData = pasteboard.data(forType: .tiff),
                  let image = NSImage(data: tiffData),
                  let rep = image.representations.compactMap({ $0 as? NSBitmapImageRep }).first
                  ?? tiffRepresentation(for: image) {
            pngData = rep.representation(using: .png, properties: [:])
        } else {
            pngData = nil
        }
        guard let pngData, !pngData.isEmpty else { return nil }

        return Payload(
            pngData: pngData,
            fileName: "image-\(fileNameTimestamp(from: now))-\(randomSuffix()).png"
        )
    }

    /// 图片统一存放在文稿所在文件夹的 assets 子文件夹。
    static func assetsFolder(for documentURL: URL) -> URL {
        documentURL.deletingLastPathComponent().appending(path: "assets")
    }

    static func save(
        _ payload: Payload,
        forDocumentAt documentURL: URL
    ) throws -> URL {
        let folder = assetsFolder(for: documentURL)
        try FileManager.default.createDirectory(
            at: folder,
            withIntermediateDirectories: true
        )
        let destination = folder.appending(path: payload.fileName)
        try payload.pngData.write(to: destination, options: .atomic)
        return destination
    }

    /// 生成的引用相对于文稿本身，例如 "assets/image-20260827-171230-a1b2.png"。
    static func markdownLink(for savedURL: URL, documentURL: URL) -> String {
        let folderName = assetsFolder(for: documentURL).lastPathComponent
        return "![\(savedURL.deletingPathExtension().lastPathComponent)](\(folderName)/\(savedURL.lastPathComponent))"
    }

    private static func tiffRepresentation(for image: NSImage) -> NSBitmapImageRep? {
        guard let tiff = image.tiffRepresentation else { return nil }
        return NSBitmapImageRep(data: tiff)
    }

    private static func fileNameTimestamp(from date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: date)
    }

    private static func randomSuffix() -> String {
        String(format: "%04x", Int.random(in: 0..<0x10000))
    }
}
