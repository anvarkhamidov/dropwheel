import AppKit
import CoreImage
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Конвертация и обработка растровых изображений.
public struct ImageEngine: Sendable {
    public let tools: ExternalTools
    public init(tools: ExternalTools) { self.tools = tools }

    static func utType(for ext: String) -> UTType? {
        switch ext {
        case "jpg": return .jpeg
        case "png": return .png
        case "heic": return .heic
        case "tiff": return .tiff
        case "avif": return UTType("public.avif")
        case "bmp": return .bmp
        case "gif": return .gif
        default: return nil
        }
    }

    /// Загружает картинку как CGImage, учитывая EXIF-ориентацию. SVG и прочее идёт через NSImage.
    public static func loadCGImage(_ url: URL, maxPixel: Int? = nil) throws -> CGImage {
        if let src = CGImageSourceCreateWithURL(url as CFURL, nil), CGImageSourceGetCount(src) > 0 {
            var opts: [CFString: Any] = [
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceShouldCacheImmediately: true,
            ]
            if let maxPixel {
                opts[kCGImageSourceThumbnailMaxPixelSize] = maxPixel
            } else if let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
                      let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int {
                opts[kCGImageSourceThumbnailMaxPixelSize] = max(w, h)
            }
            if let img = CGImageSourceCreateThumbnailAtIndex(src, 0, opts as CFDictionary) { return img }
        }
        guard let ns = NSImage(contentsOf: url) else { throw DropwheelError("Не удалось прочитать изображение \(url.lastPathComponent)") }
        var rect = CGRect(origin: .zero, size: ns.size)
        if url.pathExtension.lowercased() == "svg" {
            // Векторный вход растеризуем с запасом по разрешению.
            let scale = max(1, 2048 / max(ns.size.width, ns.size.height, 1))
            rect.size = CGSize(width: ns.size.width * scale, height: ns.size.height * scale)
        }
        guard let cg = ns.cgImage(forProposedRect: &rect, context: nil, hints: nil) else {
            throw DropwheelError("Не удалось прочитать изображение \(url.lastPathComponent)")
        }
        return cg
    }

    public static func pixelSize(_ url: URL) -> CGSize? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any],
              let w = props[kCGImagePropertyPixelWidth] as? Int, let h = props[kCGImagePropertyPixelHeight] as? Int else { return nil }
        let o = props[kCGImagePropertyOrientation] as? Int ?? 1
        return o >= 5 ? CGSize(width: h, height: w) : CGSize(width: w, height: h)
    }

    /// Запись CGImage в нужный формат. `quality` 0…1 для форматов с потерями.
    public func write(_ image: CGImage, to url: URL, ext: String, quality: Double = 0.9, metadata: [CFString: Any]? = nil) async throws {
        switch ext {
        case "webp":
            guard let cwebp = tools.cwebp else { throw DropwheelError("Для WebP нужен cwebp: brew install webp") }
            let dir = try Scratch.dir()
            let png = dir.appendingPathComponent("in.png")
            try Self.writeImageIO(image, to: png, type: .png, quality: 1, metadata: nil)
            try await ProcessRunner.run(cwebp, ["-quiet", "-q", String(Int(quality * 100)), "-metadata", "icc", png.path, "-o", url.path])
            try? FileManager.default.removeItem(at: dir)
        case "pdf":
            let doc = PDFDocument()
            let ns = NSImage(cgImage: image, size: CGSize(width: image.width, height: image.height))
            guard let page = PDFPage(image: ns) else { throw DropwheelError("Не удалось собрать PDF") }
            doc.insert(page, at: 0)
            guard doc.write(to: url) else { throw DropwheelError("Не удалось записать PDF") }
        default:
            guard let type = Self.utType(for: ext) else { throw DropwheelError("Формат \(ext.uppercased()) не поддерживается") }
            try Self.writeImageIO(image, to: url, type: type, quality: quality, metadata: metadata)
        }
    }

    static func writeImageIO(_ image: CGImage, to url: URL, type: UTType, quality: Double, metadata: [CFString: Any]?) throws {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil) else {
            throw DropwheelError("Система не умеет записывать \(type.preferredFilenameExtension?.uppercased() ?? type.identifier)")
        }
        var props: [CFString: Any] = metadata ?? [:]
        props[kCGImageDestinationLossyCompressionQuality] = quality
        props[kCGImagePropertyOrientation] = 1 // ориентация уже применена к пикселям
        var img = image
        if type == .jpeg || type == .bmp, image.alphaInfo != .none, image.alphaInfo != .noneSkipLast, image.alphaInfo != .noneSkipFirst {
            img = flatten(image) ?? image
        }
        CGImageDestinationAddImage(dest, img, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw DropwheelError("Не удалось записать файл") }
    }

    /// Убирает альфу на белом фоне (для JPEG/BMP).
    static func flatten(_ image: CGImage) -> CGImage? {
        let w = image.width, h = image.height
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(gray: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    /// Метаданные оригинала без ориентации и размеров (их пишет кодек).
    static func carriedMetadata(_ url: URL) -> [CFString: Any]? {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              var props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return nil }
        for k in [kCGImagePropertyOrientation, kCGImagePropertyPixelWidth, kCGImagePropertyPixelHeight, kCGImagePropertyDepth] {
            props.removeValue(forKey: k)
        }
        return props
    }

    public func convert(_ input: URL, to ext: String, output: URL) async throws {
        let image = try Self.loadCGImage(input)
        try await write(image, to: output, ext: ext, metadata: Self.carriedMetadata(input))
    }

    /// Несколько изображений → один PDF, страница на картинку.
    public func makePDF(_ inputs: [URL], output: URL, progress: @escaping ProgressHandler) throws {
        let doc = PDFDocument()
        for (i, url) in inputs.enumerated() {
            let cg = try Self.loadCGImage(url)
            let ns = NSImage(cgImage: cg, size: CGSize(width: cg.width, height: cg.height))
            guard let page = PDFPage(image: ns) else { continue }
            doc.insert(page, at: doc.pageCount)
            progress(Double(i + 1) / Double(inputs.count))
        }
        guard doc.pageCount > 0, doc.write(to: output) else { throw DropwheelError("Не удалось собрать PDF") }
    }

    /// Масштаб по длинной стороне.
    public static func resized(_ image: CGImage, maxSide: Int) -> CGImage {
        let longest = max(image.width, image.height)
        guard longest > maxSide, maxSide > 0 else { return image }
        let scale = Double(maxSide) / Double(longest)
        let w = Int(Double(image.width) * scale), h = Int(Double(image.height) * scale)
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: image.colorSpace ?? CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return image }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }
}
