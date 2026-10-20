import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins

/// Операции над фото для окон инструментов. Всё на Core Image, результат — CGImage.
public enum ImageOps {
    static let context = CIContext(options: [.cacheIntermediates: false])

    public static func render(_ image: CIImage, extent: CGRect? = nil) -> CGImage? {
        context.createCGImage(image, from: extent ?? image.extent, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
    }

    // MARK: Правка фото

    public struct Adjustments: Equatable, Sendable {
        public var exposure: Double = 0      // EV, -3…3
        public var brightness: Double = 0    // -100…100
        public var contrast: Double = 0      // -100…100
        public var highlights: Double = 0    // -100…100
        public var shadows: Double = 0       // -100…100
        public var saturation: Double = 0    // -100…100
        public var vibrance: Double = 0      // -100…100
        public var temperature: Double = 0   // -100…100 (холоднее…теплее)
        public var tint: Double = 0          // -100…100
        public var sharpness: Double = 0     // 0…100
        public var clarity: Double = 0       // 0…100
        public var dehaze: Double = 0        // 0…100
        public var noiseReduction: Double = 0 // 0…100
        public var grain: Double = 0         // 0…100
        public var vignette: Double = 0      // 0…100
        public init() {}
        public var isIdentity: Bool { self == Adjustments() }
    }

    public static func adjust(_ input: CIImage, _ a: Adjustments) -> CIImage {
        var img = input
        if a.exposure != 0 {
            let f = CIFilter.exposureAdjust(); f.inputImage = img; f.ev = Float(a.exposure); img = f.outputImage ?? img
        }
        if a.brightness != 0 || a.contrast != 0 || a.saturation != 0 {
            let f = CIFilter.colorControls(); f.inputImage = img
            f.brightness = Float(a.brightness / 400)
            f.contrast = Float(1 + a.contrast / 200)
            f.saturation = Float(1 + a.saturation / 100)
            img = f.outputImage ?? img
        }
        if a.highlights != 0 || a.shadows != 0 {
            let f = CIFilter.highlightShadowAdjust(); f.inputImage = img
            f.highlightAmount = Float(1 - max(0, -a.highlights) / 100 + max(0, a.highlights) / 200)
            f.shadowAmount = Float(a.shadows / 100)
            img = f.outputImage ?? img
        }
        if a.vibrance != 0 {
            let f = CIFilter.vibrance(); f.inputImage = img; f.amount = Float(a.vibrance / 100); img = f.outputImage ?? img
        }
        if a.temperature != 0 || a.tint != 0 {
            let f = CIFilter.temperatureAndTint(); f.inputImage = img
            f.neutral = CIVector(x: 6500, y: 0)
            f.targetNeutral = CIVector(x: CGFloat(6500 + a.temperature * 30), y: CGFloat(a.tint))
            img = f.outputImage ?? img
        }
        if a.dehaze > 0 {
            // Дымка: поднимаем локальный контраст и чуть насыщенность, опускаем «вуаль» в тенях.
            let f = CIFilter.unsharpMask(); f.inputImage = img; f.radius = 60; f.intensity = Float(a.dehaze / 120); img = f.outputImage ?? img
            let c = CIFilter.colorControls(); c.inputImage = img; c.saturation = Float(1 + a.dehaze / 400); c.brightness = Float(-a.dehaze / 1000)
            img = c.outputImage ?? img
        }
        if a.clarity > 0 {
            let f = CIFilter.unsharpMask(); f.inputImage = img; f.radius = 20; f.intensity = Float(a.clarity / 150); img = f.outputImage ?? img
        }
        if a.noiseReduction > 0 {
            let f = CIFilter.noiseReduction(); f.inputImage = img
            f.noiseLevel = Float(a.noiseReduction / 2000); f.sharpness = 0.4
            img = f.outputImage ?? img
        }
        if a.sharpness > 0 {
            let f = CIFilter.sharpenLuminance(); f.inputImage = img; f.sharpness = Float(a.sharpness / 50); f.radius = 1.5; img = f.outputImage ?? img
        }
        if a.vignette > 0 {
            let f = CIFilter.vignette(); f.inputImage = img; f.intensity = Float(a.vignette / 50); f.radius = 1.5; img = f.outputImage ?? img
        }
        if a.grain > 0 {
            let noise = CIFilter.randomGenerator().outputImage!.cropped(to: img.extent)
            let mono = CIFilter.colorControls(); mono.inputImage = noise; mono.saturation = 0; mono.contrast = 1.2
            let fade = CIFilter.colorMatrix(); fade.inputImage = mono.outputImage
            let k = CGFloat(a.grain / 600)
            fade.rVector = CIVector(x: k, y: 0, z: 0, w: 0); fade.gVector = CIVector(x: 0, y: k, z: 0, w: 0); fade.bVector = CIVector(x: 0, y: 0, z: k, w: 0)
            fade.biasVector = CIVector(x: -k / 2, y: -k / 2, z: -k / 2, w: 0)
            let blend = CIFilter.additionCompositing(); blend.inputImage = fade.outputImage; blend.backgroundImage = img
            img = blend.outputImage?.cropped(to: input.extent) ?? img
        }
        return img.cropped(to: input.extent)
    }

    // MARK: Кроп

    /// `rect` — в пикселях исходника, начало вверху слева.
    public static func crop(_ image: CGImage, to rect: CGRect) -> CGImage? {
        let r = rect.integral.intersection(CGRect(x: 0, y: 0, width: image.width, height: image.height))
        guard r.width >= 1, r.height >= 1 else { return nil }
        return image.cropping(to: r)
    }

    /// Масштаб до точных размеров.
    public static func resize(_ image: CGImage, to size: CGSize) -> CGImage? {
        let w = max(1, Int(size.width)), h = max(1, Int(size.height))
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage()
    }

    // MARK: Фон

    public enum Fill: Equatable, Sendable {
        case solid(r: Double, g: Double, b: Double)
        case gradient([(Double, Double, Double)], angle: Double)
        case image(URL, blur: Double)

        public static func == (a: Fill, b: Fill) -> Bool { String(describing: a) == String(describing: b) }
    }

    public struct Frame: Sendable {
        public var fill: Fill = .solid(r: 1, g: 1, b: 1)
        public var aspect: CGFloat? = nil       // ширина/высота холста; nil — по картинке
        public var padding: CGFloat = 0.08       // доля от длинной стороны картинки
        public var cornerRadius: CGFloat = 0.03  // доля от короткой стороны картинки
        public var shadow: CGFloat = 0.5         // 0…1
        public init() {}
    }

    /// Картинка на холсте с фоном, отступом, скруглением и тенью.
    public static func frame(_ image: CGImage, _ f: Frame) throws -> CGImage {
        let iw = CGFloat(image.width), ih = CGFloat(image.height)
        let pad = max(iw, ih) * f.padding
        var cw = iw + 2 * pad, ch = ih + 2 * pad
        if let aspect = f.aspect, aspect > 0 {
            if cw / ch < aspect { cw = ch * aspect } else { ch = cw / aspect }
        }
        guard let ctx = CGContext(data: nil, width: Int(cw), height: Int(ch), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw DropwheelError("Слишком большой холст")
        }
        let canvas = CGRect(x: 0, y: 0, width: cw, height: ch)
        switch f.fill {
        case let .solid(r, g, b):
            ctx.setFillColor(CGColor(srgbRed: r, green: g, blue: b, alpha: 1)); ctx.fill(canvas)
        case let .gradient(stops, angle):
            let colors = stops.map { CGColor(srgbRed: $0.0, green: $0.1, blue: $0.2, alpha: 1) } as CFArray
            if let grad = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB), colors: colors, locations: nil) {
                let rad = angle * .pi / 180, len = hypot(cw, ch) / 2
                let c = CGPoint(x: cw / 2, y: ch / 2)
                ctx.drawLinearGradient(grad, start: CGPoint(x: c.x - cos(rad) * len, y: c.y - sin(rad) * len),
                                       end: CGPoint(x: c.x + cos(rad) * len, y: c.y + sin(rad) * len), options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
            }
        case let .image(url, blur):
            var bg = CIImage(cgImage: try ImageEngine.loadCGImage(url, maxPixel: Int(max(cw, ch))))
            // Заполнение с обрезкой по центру.
            let s = max(cw / bg.extent.width, ch / bg.extent.height)
            bg = bg.transformed(by: CGAffineTransform(scaleX: s, y: s))
            bg = bg.transformed(by: CGAffineTransform(translationX: (cw - bg.extent.width) / 2 - bg.extent.minX, y: (ch - bg.extent.height) / 2 - bg.extent.minY))
            if blur > 0 { bg = bg.clampedToExtent().applyingGaussianBlur(sigma: blur * max(cw, ch) / 100).cropped(to: canvas) }
            if let cg = render(bg, extent: canvas) { ctx.draw(cg, in: canvas) }
        }
        let rect = CGRect(x: (cw - iw) / 2, y: (ch - ih) / 2, width: iw, height: ih)
        let radius = min(iw, ih) * f.cornerRadius
        let path = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
        if f.shadow > 0 {
            ctx.saveGState()
            ctx.setShadow(offset: CGSize(width: 0, height: -max(iw, ih) * 0.01 * f.shadow), blur: max(iw, ih) * 0.04 * f.shadow,
                          color: CGColor(gray: 0, alpha: 0.35 * f.shadow))
            ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fillPath()
            ctx.restoreGState()
        }
        ctx.saveGState()
        ctx.addPath(path); ctx.clip()
        ctx.draw(image, in: rect)
        ctx.restoreGState()
        guard let out = ctx.makeImage() else { throw DropwheelError("Не удалось собрать изображение") }
        return out
    }

    // MARK: Редакция

    public enum RedactStyle: String, CaseIterable, Sendable { case solid, blur, pixelate }

    /// Области — в нормализованных координатах (0…1, начало вверху слева).
    public static func redact(_ image: CGImage, regions: [CGRect], style: RedactStyle, color: CGColor = CGColor(gray: 0, alpha: 1)) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        let src = CIImage(cgImage: image)
        var covered: CIImage
        switch style {
        case .solid: covered = CIImage(color: CIColor(cgColor: color)).cropped(to: src.extent)
        case .blur: covered = src.clampedToExtent().applyingGaussianBlur(sigma: max(w, h) / 60).cropped(to: src.extent)
        case .pixelate:
            let f = CIFilter.pixellate(); f.inputImage = src.clampedToExtent(); f.scale = Float(max(w, h) / 50)
            covered = f.outputImage?.cropped(to: src.extent) ?? src
        }
        var mask = CIImage(color: .black).cropped(to: src.extent)
        for r in regions {
            // Core Image: начало внизу.
            let rect = CGRect(x: r.minX * w, y: (1 - r.maxY) * h, width: r.width * w, height: r.height * h)
            mask = CIImage(color: .white).cropped(to: rect).composited(over: mask)
        }
        let blend = CIFilter.blendWithMask()
        blend.inputImage = covered; blend.backgroundImage = src; blend.maskImage = mask
        return blend.outputImage.flatMap { render($0, extent: src.extent) }
    }

    // MARK: Аннотации

    public struct Annotation: Identifiable, Equatable, Sendable {
        public enum Kind: String, CaseIterable, Sendable { case arrow, rectangle, ellipse, line, text, number, highlight, pen }
        public let id = UUID()
        public var kind: Kind
        /// Точки в нормализованных координатах (0…1, начало вверху слева). Для фигур — два угла.
        public var points: [CGPoint]
        public var color: [Double] = [0.94, 0.24, 0.18]
        public var width: Double = 0.006      // доля от длинной стороны
        public var text: String = ""
        public var number: Int = 1
        public init(kind: Kind, points: [CGPoint]) { self.kind = kind; self.points = points }
        public static func == (a: Annotation, b: Annotation) -> Bool { a.id == b.id && a.points == b.points && a.text == b.text && a.color == b.color && a.width == b.width }
    }

    public static func annotate(_ image: CGImage, _ items: [Annotation]) -> CGImage? {
        let w = CGFloat(image.width), h = CGFloat(image.height)
        guard let ctx = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // Переходим в систему «начало вверху».
        ctx.translateBy(x: 0, y: h); ctx.scaleBy(x: 1, y: -1)
        let ns = NSGraphicsContext(cgContext: ctx, flipped: true)
        NSGraphicsContext.saveGraphicsState(); NSGraphicsContext.current = ns
        defer { NSGraphicsContext.restoreGraphicsState() }
        let long = max(w, h)
        for a in items {
            let color = CGColor(srgbRed: a.color[0], green: a.color[1], blue: a.color[2], alpha: 1)
            let pts = a.points.map { CGPoint(x: $0.x * w, y: $0.y * h) }
            let lw = max(1, a.width * long)
            ctx.setStrokeColor(color); ctx.setFillColor(color); ctx.setLineWidth(lw); ctx.setLineCap(.round); ctx.setLineJoin(.round)
            switch a.kind {
            case .rectangle where pts.count >= 2:
                ctx.stroke(CGRect(p1: pts[0], p2: pts[1]))
            case .ellipse where pts.count >= 2:
                ctx.strokeEllipse(in: CGRect(p1: pts[0], p2: pts[1]))
            case .line where pts.count >= 2:
                ctx.strokeLineSegments(between: [pts[0], pts[1]])
            case .arrow where pts.count >= 2:
                let (p, q) = (pts[0], pts[1])
                let ang = atan2(q.y - p.y, q.x - p.x), head = lw * 4.5
                ctx.strokeLineSegments(between: [p, CGPoint(x: q.x - cos(ang) * head * 0.6, y: q.y - sin(ang) * head * 0.6)])
                ctx.move(to: q)
                ctx.addLine(to: CGPoint(x: q.x - head * cos(ang - .pi / 7), y: q.y - head * sin(ang - .pi / 7)))
                ctx.addLine(to: CGPoint(x: q.x - head * cos(ang + .pi / 7), y: q.y - head * sin(ang + .pi / 7)))
                ctx.closePath(); ctx.fillPath()
            case .highlight where pts.count >= 2:
                ctx.setFillColor(color.copy(alpha: 0.35)!); ctx.fill(CGRect(p1: pts[0], p2: pts[1]))
            case .pen where pts.count >= 2:
                ctx.addLines(between: pts); ctx.strokePath()
            case .text where !pts.isEmpty:
                let font = NSFont.systemFont(ofSize: lw * 6, weight: .semibold)
                (a.text as NSString).draw(at: pts[0], withAttributes: [.font: font, .foregroundColor: NSColor(cgColor: color) ?? .red])
            case .number where !pts.isEmpty:
                let r = lw * 4
                ctx.fillEllipse(in: CGRect(x: pts[0].x - r, y: pts[0].y - r, width: 2 * r, height: 2 * r))
                let s = "\(a.number)" as NSString
                let font = NSFont.systemFont(ofSize: r * 1.1, weight: .bold)
                let size = s.size(withAttributes: [.font: font])
                s.draw(at: CGPoint(x: pts[0].x - size.width / 2, y: pts[0].y - size.height / 2), withAttributes: [.font: font, .foregroundColor: NSColor.white])
            default: break
            }
        }
        return ctx.makeImage()
    }

    // MARK: Коллаж

    public enum CollageLayout: String, CaseIterable, Sendable { case grid, row, column, featured }

    public struct Collage: Sendable {
        public var layout: CollageLayout = .grid
        public var width: CGFloat = 2400
        public var height: CGFloat = 2400
        public var spacing: CGFloat = 0.01     // доля ширины
        public var corner: CGFloat = 0.01
        public var background: (Double, Double, Double) = (1, 1, 1)
        public init() {}
    }

    /// Ячейки коллажа (в пикселях холста, начало вверху слева).
    public static func cells(count n: Int, _ c: Collage) -> [CGRect] {
        guard n > 0 else { return [] }
        let gap = c.width * c.spacing
        let W = c.width, H = c.height
        func grid(cols: Int, rows: Int, in r: CGRect, take: Int) -> [CGRect] {
            let cw = (r.width - gap * CGFloat(cols + 1)) / CGFloat(cols), ch = (r.height - gap * CGFloat(rows + 1)) / CGFloat(rows)
            return (0..<take).map { i in
                CGRect(x: r.minX + gap + CGFloat(i % cols) * (cw + gap), y: r.minY + gap + CGFloat(i / cols) * (ch + gap), width: cw, height: ch)
            }
        }
        let all = CGRect(x: 0, y: 0, width: W, height: H)
        switch c.layout {
        case .row: return grid(cols: n, rows: 1, in: all, take: n)
        case .column: return grid(cols: 1, rows: n, in: all, take: n)
        case .grid:
            let cols = Int(ceil(sqrt(Double(n)))), rows = Int(ceil(Double(n) / Double(cols)))
            return grid(cols: cols, rows: rows, in: all, take: n)
        case .featured:
            guard n > 1 else { return grid(cols: 1, rows: 1, in: all, take: 1) }
            let big = CGRect(x: gap, y: gap, width: W * 0.62 - gap * 1.5, height: H - 2 * gap)
            let side = CGRect(x: big.maxX, y: 0, width: W - big.maxX, height: H)
            return [big] + grid(cols: 1, rows: n - 1, in: CGRect(x: side.minX - gap / 2, y: 0, width: side.width + gap / 2, height: H), take: n - 1)
        }
    }

    public static func collage(_ images: [CGImage], _ c: Collage) -> CGImage? {
        guard let ctx = CGContext(data: nil, width: Int(c.width), height: Int(c.height), bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.setFillColor(CGColor(srgbRed: c.background.0, green: c.background.1, blue: c.background.2, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: c.width, height: c.height))
        for (img, cell) in zip(images, cells(count: images.count, c)) {
            // Ячейка в CG-координатах (начало внизу).
            let r = CGRect(x: cell.minX, y: c.height - cell.maxY, width: cell.width, height: cell.height)
            let s = max(r.width / CGFloat(img.width), r.height / CGFloat(img.height))
            let dw = CGFloat(img.width) * s, dh = CGFloat(img.height) * s
            ctx.saveGState()
            let radius = min(r.width, r.height) * c.corner * 4
            ctx.addPath(CGPath(roundedRect: r, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
            ctx.interpolationQuality = .high
            ctx.draw(img, in: CGRect(x: r.midX - dw / 2, y: r.midY - dh / 2, width: dw, height: dh))
            ctx.restoreGState()
        }
        return ctx.makeImage()
    }
}

extension CGRect {
    init(p1: CGPoint, p2: CGPoint) {
        self.init(x: min(p1.x, p2.x), y: min(p1.y, p2.y), width: abs(p2.x - p1.x), height: abs(p2.y - p1.y))
    }
}
