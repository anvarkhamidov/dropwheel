import Foundation

/// Точка входа для колеса конвертации: выбирает движок по категории файла.
public struct Converter: Sendable {
    public let tools: ExternalTools
    public init(tools: ExternalTools) { self.tools = tools }

    /// Конвертирует один файл и возвращает созданные файлы или папки.
    public func convert(_ input: URL, to ext: String, progress: @escaping ProgressHandler) async throws -> [URL] {
        let category = FileCategory.of(input)
        let scratch = try Scratch.dir()
        defer { try? FileManager.default.removeItem(at: scratch) }
        let temp = scratch.appendingPathComponent("out").appendingPathExtension(ext)
        var dest = OutputNamer.sibling(of: input, ext: ext)

        switch category {
        case .image:
            try await ImageEngine(tools: tools).convert(input, to: ext, output: temp)
        case .video, .audio:
            try await MediaEngine(tools: tools).convert(input, to: ext, output: temp, progress: progress)
        case .pdf:
            return try await PDFEngine(tools: tools).convert(input, to: ext, scratch: scratch, progress: progress)
        case .document, .epub:
            let docs = DocumentEngine(tools: tools)
            if ext == "png" || ext == "jpg" {
                // Документ в картинки: рендерим PDF, затем по файлу на страницу.
                let pdf = scratch.appendingPathComponent("render.pdf")
                try await docs.convert(input, to: "pdf", output: pdf, scratch: scratch, progress: progress)
                return try PDFEngine(tools: tools).rasterize(pdf, original: input, ext: ext, progress: progress)
            }
            try await docs.convert(input, to: ext, output: temp, scratch: scratch, progress: progress)
        case .slides:
            return try await OfficeScripting.exportSlides(input, to: ext, scratch: scratch)
        case .spreadsheet:
            try await SheetEngine(tools: tools).convert(input, to: ext, output: temp, scratch: scratch)
        case .subtitle:
            try SubtitleEngine.convert(input, to: ext, output: temp)
        case .archive:
            try await ArchiveEngine.convert(input, to: ext, output: temp, scratch: scratch)
            dest = OutputNamer.unique(in: input.deletingLastPathComponent(), base: ArchiveEngine.baseName(input),
                                      ext: ext == "gz" ? "tar.gz" : ext)
        case .other:
            throw DropwheelError("Этот тип файла не конвертируется")
        }
        guard FileManager.default.fileExists(atPath: temp.path) else { throw DropwheelError("Конвертер не создал файл") }
        return [try Scratch.commit(temp, to: dest)]
    }
}
