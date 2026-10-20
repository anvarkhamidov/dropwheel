import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

/// Чтение, правка и удаление метаданных: фото (EXIF/GPS/TIFF/IPTC), медиа (теги контейнера), PDF (свойства документа).
public struct MetadataEngine: Sendable {
    public struct Field: Identifiable, Hashable, Sendable {
        public var id: String { group + "." + key }
        public let group: String
        public let key: String
        public var value: String
        public let editable: Bool
    }

    public let tools: ExternalTools
    public init(tools: ExternalTools) { self.tools = tools }

    public func read(_ url: URL) async throws -> [Field] {
        switch FileCategory.of(url) {
        case .image: return Self.readImage(url)
        case .video, .audio: return try await readMedia(url)
        case .pdf: return try Self.readPDF(url)
        default: return Self.readFile(url)
        }
    }

    // MARK: Файл

    static func readFile(_ url: URL) -> [Field] {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: url.path)) ?? [:]
        var out: [Field] = []
        if let size = attrs[.size] as? Int64 { out.append(Field(group: "Файл", key: "Размер", value: ByteCountFormatter.string(fromByteCount: size, countStyle: .file), editable: false)) }
        let df = DateFormatter(); df.dateStyle = .medium; df.timeStyle = .short
        if let d = attrs[.creationDate] as? Date { out.append(Field(group: "Файл", key: "Создан", value: df.string(from: d), editable: false)) }
        if let d = attrs[.modificationDate] as? Date { out.append(Field(group: "Файл", key: "Изменён", value: df.string(from: d), editable: false)) }
        if let type = UTType(filenameExtension: url.pathExtension)?.localizedDescription { out.append(Field(group: "Файл", key: "Тип", value: type, editable: false)) }
        return out
    }

    // MARK: Фото

    static let editableImageKeys: [(CFString, CFString, String)] = [
        (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFMake, "Производитель"),
        (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFModel, "Модель"),
        (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFArtist, "Автор"),
        (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFCopyright, "Права"),
        (kCGImagePropertyTIFFDictionary, kCGImagePropertyTIFFImageDescription, "Описание"),
        (kCGImagePropertyExifDictionary, kCGImagePropertyExifDateTimeOriginal, "Дата съёмки"),
        (kCGImagePropertyExifDictionary, kCGImagePropertyExifLensModel, "Объектив"),
        (kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLatitude, "Широта"),
        (kCGImagePropertyGPSDictionary, kCGImagePropertyGPSLongitude, "Долгота"),
    ]

    static func groupName(_ dict: CFString) -> String {
        switch dict {
        case kCGImagePropertyTIFFDictionary: return "Камера"
        case kCGImagePropertyExifDictionary: return "Съёмка"
        case kCGImagePropertyGPSDictionary: return "Место"
        case kCGImagePropertyIPTCDictionary: return "IPTC"
        default: return dict as String
        }
    }

    static func readImage(_ url: URL) -> [Field] {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] else { return readFile(url) }
        var out = readFile(url)
        if let w = props[kCGImagePropertyPixelWidth], let h = props[kCGImagePropertyPixelHeight] {
            out.append(Field(group: "Изображение", key: "Размер", value: "\(w) × \(h)", editable: false))
        }
        var seen = Set<String>()
        for (dict, key, title) in editableImageKeys {
            let d = props[dict] as? [CFString: Any]
            var value = d?[key].map { "\($0)" } ?? ""
            if dict == kCGImagePropertyGPSDictionary, !value.isEmpty {
                let ref = d?[key == kCGImagePropertyGPSLatitude ? kCGImagePropertyGPSLatitudeRef : kCGImagePropertyGPSLongitudeRef] as? String
                if ref == "S" || ref == "W" { value = "-" + value }
            }
            out.append(Field(group: groupName(dict), key: title, value: value, editable: true))
            seen.insert("\(dict).\(key)")
        }
        // Остальное — только для чтения.
        for dict in [kCGImagePropertyExifDictionary, kCGImagePropertyTIFFDictionary, kCGImagePropertyGPSDictionary, kCGImagePropertyIPTCDictionary] {
            guard let d = props[dict] as? [CFString: Any] else { continue }
            for (k, v) in d.sorted(by: { ($0.key as String) < ($1.key as String) }) where !seen.contains("\(dict).\(k)") {
                if v is [String: Any] || v is Data { continue }
                out.append(Field(group: groupName(dict), key: k as String, value: "\(v)", editable: false))
            }
        }
        return out
    }

    /// Новый файл рядом: с изменёнными полями или вовсе без метаданных.
    public func writeImage(_ url: URL, changes: [String: String], stripAll: Bool) throws -> URL {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil), let type = CGImageSourceGetType(src) else {
            throw DropwheelError("Не удалось прочитать изображение")
        }
        var props: [CFString: Any] = [:]
        if stripAll {
            // Пустые словари удаляют блоки при копировании; GPS и Exif уходят целиком.
            props[kCGImagePropertyExifDictionary] = kCFNull
            props[kCGImagePropertyGPSDictionary] = kCFNull
            props[kCGImagePropertyTIFFDictionary] = kCFNull
            props[kCGImagePropertyIPTCDictionary] = kCFNull
            props[kCGImageMetadataShouldExcludeXMP] = true
            props[kCGImageMetadataShouldExcludeGPS] = true
        } else {
            let existing = CGImageSourceCopyPropertiesAtIndex(src, 0, nil) as? [CFString: Any] ?? [:]
            var dicts: [CFString: [CFString: Any]] = [:]
            for (dict, key, title) in Self.editableImageKeys {
                guard let value = changes[title] else { continue }
                var d = dicts[dict] ?? (existing[dict] as? [CFString: Any] ?? [:])
                if value.isEmpty { d.removeValue(forKey: key) }
                else if dict == kCGImagePropertyGPSDictionary, let num = Double(value.replacingOccurrences(of: ",", with: ".")) {
                    d[key] = abs(num)
                    let isLat = key == kCGImagePropertyGPSLatitude
                    d[isLat ? kCGImagePropertyGPSLatitudeRef : kCGImagePropertyGPSLongitudeRef] = isLat ? (num < 0 ? "S" : "N") : (num < 0 ? "W" : "E")
                } else { d[key] = value }
                dicts[dict] = d
            }
            for (k, v) in dicts { props[k] = v }
        }
        return try Staged.file(beside: OutputNamer.sibling(of: url, ext: url.pathExtension, suffix: stripAll ? "без метаданных" : "изменён")) { out in
            guard let dest = CGImageDestinationCreateWithURL(out as CFURL, type, 1, nil) else { throw DropwheelError("Формат не поддерживает запись") }
            if stripAll {
                // Перекодирование пикселей без копирования свойств — надёжно убирает всё скрытое.
                let img = try ImageEngine.loadCGImage(url)
                CGImageDestinationAddImage(dest, img, [kCGImageDestinationLossyCompressionQuality: 0.95] as CFDictionary)
            } else {
                CGImageDestinationAddImageFromSource(dest, src, 0, props as CFDictionary)
            }
            guard CGImageDestinationFinalize(dest) else { throw DropwheelError("Не удалось записать файл") }
        }
    }

    // MARK: Медиа

    func readMedia(_ url: URL) async throws -> [Field] {
        guard let probe = tools.ffprobe else { return Self.readFile(url) }
        let json = try await ProcessRunner.run(probe, ["-v", "error", "-print_format", "json", "-show_format", "-show_streams", "-show_chapters", url.path])
        guard let obj = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any] else { return Self.readFile(url) }
        var out = Self.readFile(url)
        let format = obj["format"] as? [String: Any] ?? [:]
        if let d = Double(format["duration"] as? String ?? "") {
            out.append(Field(group: "Медиа", key: "Длительность", value: Self.clock(d), editable: false))
        }
        if let br = Int(format["bit_rate"] as? String ?? "") { out.append(Field(group: "Медиа", key: "Битрейт", value: "\(br / 1000) кбит/с", editable: false)) }
        let tags = format["tags"] as? [String: Any] ?? [:]
        for key in Self.mediaEditable {
            let v = tags.first { $0.key.lowercased() == key }?.value
            out.append(Field(group: "Теги", key: key, value: v.map { "\($0)" } ?? "", editable: true))
        }
        for (k, v) in tags.sorted(by: { $0.key < $1.key }) where !Self.mediaEditable.contains(k.lowercased()) {
            out.append(Field(group: "Теги", key: k, value: "\(v)", editable: false))
        }
        for (i, s) in (obj["streams"] as? [[String: Any]] ?? []).enumerated() {
            let type = s["codec_type"] as? String ?? "?"
            let group = "Дорожка \(i + 1) (\(type == "video" ? "видео" : type == "audio" ? "звук" : type))"
            out.append(Field(group: group, key: "Кодек", value: s["codec_long_name"] as? String ?? s["codec_name"] as? String ?? "", editable: false))
            if let w = s["width"], let h = s["height"] { out.append(Field(group: group, key: "Кадр", value: "\(w) × \(h)", editable: false)) }
            if let ch = s["channels"] { out.append(Field(group: group, key: "Каналы", value: "\(ch)", editable: false)) }
            if let sr = s["sample_rate"] { out.append(Field(group: group, key: "Частота", value: "\(sr) Гц", editable: false)) }
            for (k, v) in (s["tags"] as? [String: Any] ?? [:]).sorted(by: { $0.key < $1.key }) {
                out.append(Field(group: group, key: k, value: "\(v)", editable: false))
            }
        }
        for (i, c) in (obj["chapters"] as? [[String: Any]] ?? []).enumerated() {
            let title = (c["tags"] as? [String: Any])?["title"] as? String ?? "Глава \(i + 1)"
            let start = Double(c["start_time"] as? String ?? "") ?? 0
            out.append(Field(group: "Главы", key: Self.clock(start), value: title, editable: false))
        }
        return out
    }

    public static let mediaEditable = ["title", "artist", "album", "date", "genre", "comment"]

    public func writeMedia(_ url: URL, changes: [String: String], stripAll: Bool, progress: @escaping ProgressHandler) async throws -> URL {
        var args: [String] = ["-map", "0", "-c", "copy"]
        if stripAll {
            args += ["-map_metadata", "-1", "-map_chapters", "-1", "-fflags", "+bitexact", "-flags:v", "+bitexact", "-flags:a", "+bitexact"]
        } else {
            for (k, v) in changes { args += ["-metadata", "\(k)=\(v)"] }
        }
        let dest = OutputNamer.sibling(of: url, ext: url.pathExtension, suffix: stripAll ? "без метаданных" : "изменён")
        let scratch = try Scratch.dir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent("out").appendingPathExtension(url.pathExtension)
        try await MediaEngine(tools: tools).process(url, output: temp, args: args, progress: progress)
        return try Scratch.commit(temp, to: dest)
    }

    // MARK: PDF

    static let pdfKeys: [(PDFDocumentAttribute, String)] = [
        (.titleAttribute, "Название"), (.authorAttribute, "Автор"), (.subjectAttribute, "Тема"),
        (.keywordsAttribute, "Ключевые слова"), (.creatorAttribute, "Создано в"), (.producerAttribute, "Сохранено в"),
    ]

    static func readPDF(_ url: URL) throws -> [Field] {
        let doc = try PDFEngine.open(url)
        var out = readFile(url)
        out.append(Field(group: "Документ", key: "Страниц", value: "\(doc.pageCount)", editable: false))
        let attrs = doc.documentAttributes ?? [:]
        for (k, title) in pdfKeys {
            var value = ""
            if let v = attrs[k] { value = (v as? [String])?.joined(separator: ", ") ?? "\(v)" }
            out.append(Field(group: "Свойства", key: title, value: value, editable: true))
        }
        return out
    }

    public func writePDF(_ url: URL, changes: [String: String], stripAll: Bool) throws -> URL {
        let doc = try PDFEngine.open(url)
        var attrs: [AnyHashable: Any] = stripAll ? [:] : (doc.documentAttributes ?? [:])
        if !stripAll {
            for (k, title) in Self.pdfKeys {
                guard let v = changes[title] else { continue }
                if v.isEmpty { attrs.removeValue(forKey: k) }
                else { attrs[k] = k == .keywordsAttribute ? v.components(separatedBy: ",").map { $0.trimmingCharacters(in: .whitespaces) } : v }
            }
        } else {
            attrs[PDFDocumentAttribute.creatorAttribute] = ""
            attrs[PDFDocumentAttribute.producerAttribute] = ""
        }
        doc.documentAttributes = attrs
        return try Staged.file(beside: OutputNamer.sibling(of: url, ext: "pdf", suffix: stripAll ? "без метаданных" : "изменён")) {
            guard doc.write(to: $0) else { throw DropwheelError("Не удалось записать PDF") }
        }
    }

    static func clock(_ s: Double) -> String {
        let t = Int(s.rounded())
        return t >= 3600 ? String(format: "%d:%02d:%02d", t / 3600, (t / 60) % 60, t % 60) : String(format: "%d:%02d", t / 60, t % 60)
    }
}
