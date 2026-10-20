import AppKit
import Carbon.HIToolbox
import DropwheelCore
import Observation

/// История буфера обмена: следит за общим буфером, хранит записи на этом Mac и кладёт выбранную обратно.
/// Пароли и временные данные (помеченные менеджерами паролей) не сохраняются.
@MainActor
@Observable
final class ClipboardHistory {
    private(set) var items: [ClipItem] = []
    private(set) var enabled = false

    @ObservationIgnored let store: ClipboardStore
    /// Общий буфер; в самопроверке — отдельный именованный, чтобы не трогать настоящий.
    @ObservationIgnored let pasteboard: NSPasteboard
    @ObservationIgnored private var timer: Timer?
    @ObservationIgnored private var lastChangeCount = 0
    /// Изменение буфера, которое сделали мы сами (вернули запись) — его не записываем.
    @ObservationIgnored private var ownChangeCount: Int?
    @ObservationIgnored private var hotKey: GlobalHotKey?
    @ObservationIgnored private var thumbnails = NSCache<NSString, NSImage>()
    @ObservationIgnored lazy var panel = ClipboardPanelController(history: self)

    init(directory: URL? = nil, pasteboard: NSPasteboard = .general) {
        self.pasteboard = pasteboard
        lastChangeCount = pasteboard.changeCount
        let dir = directory ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Dropwheel/Clipboard", isDirectory: true)
        store = ClipboardStore(directory: dir)
        items = store.items
    }

    /// Применить настройки: включение, размер истории, горячая клавиша.
    func apply(enabled: Bool, limit: Int, hotKey preset: ClipboardHotKey) {
        store.limit = limit
        items = store.items
        self.enabled = enabled
        if enabled {
            if timer == nil {
                lastChangeCount = pasteboard.changeCount
                // Буфер не присылает уведомлений — опрашиваем счётчик изменений, это дёшево.
                timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.poll() }
                }
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
        hotKey = nil
        if enabled, let modifiers = preset.carbonModifiers {
            hotKey = GlobalHotKey(keyCode: UInt32(kVK_ANSI_V), modifiers: modifiers) { [weak self] in
                self?.panel.toggle()
            }
        }
    }

    func search(_ query: String) -> [ClipItem] { store.search(query) }

    // MARK: - Запись

    func poll() {
        let pb = pasteboard
        guard pb.changeCount != lastChangeCount else { return }
        lastChangeCount = pb.changeCount
        guard enabled, pb.changeCount != ownChangeCount else { return }

        let types = pb.types?.map(\.rawValue) ?? []
        guard !ClipboardStore.shouldIgnore(types: types) else { return }
        let front = NSWorkspace.shared.frontmostApplication
        let source: (id: String?, name: String?) = front?.bundleIdentifier == Bundle.main.bundleIdentifier
            ? (nil, nil) : (front?.bundleIdentifier, front?.localizedName)

        // Порядок важен: файлы, затем текст, и только потом картинка. Текст из Pages или Word
        // часто несёт ещё и картинку-превью, но копировали всё-таки текст.
        if let urls = pb.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL], !urls.isEmpty {
            store.addFiles(urls, source: source)
        } else if let text = pb.string(forType: .string), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            store.addText(text, source: source)
        } else if let tiff = pb.data(forType: .tiff) ?? pb.data(forType: .png) {
            // Большой скриншот кодируется в PNG заметное время — не на главном потоке.
            Task.detached(priority: .utility) {
                guard let rep = NSBitmapImageRep(data: tiff), let png = rep.representation(using: .png, properties: [:]) else { return }
                let (w, h) = (rep.pixelsWide, rep.pixelsHigh)
                await MainActor.run { [weak self] in
                    self?.store.addImage(png: png, width: w, height: h, source: source)
                    self?.items = self?.store.items ?? []
                }
            }
            return
        } else {
            return
        }
        items = store.items
    }

    // MARK: - Действия

    /// Положить запись обратно в буфер; дальше её вставляют обычным ⌘V.
    func copy(_ item: ClipItem) {
        let pb = pasteboard
        pb.clearContents()
        switch item.kind {
        case .text:
            pb.setString(item.text ?? "", forType: .string)
        case .files:
            pb.writeObjects((item.paths ?? []).map { URL(fileURLWithPath: $0) as NSURL })
        case .image:
            if let url = store.imageURL(for: item), let png = try? Data(contentsOf: url) {
                pb.setData(png, forType: .png)
                if let tiff = NSImage(data: png)?.tiffRepresentation { pb.setData(tiff, forType: .tiff) }
            }
        }
        ownChangeCount = pb.changeCount
        lastChangeCount = pb.changeCount
        store.touch(item.id)
        items = store.items
    }

    func togglePin(_ item: ClipItem) {
        store.togglePin(item.id)
        items = store.items
    }

    func remove(_ item: ClipItem) {
        store.remove(item.id)
        items = store.items
    }

    func clear() {
        store.clear()
        thumbnails.removeAllObjects()
        items = store.items
    }

    /// Миниатюра для строки списка: картинка, иконка файла или nil для текста.
    func thumbnail(for item: ClipItem) -> NSImage? {
        let key = item.id.uuidString as NSString
        if let cached = thumbnails.object(forKey: key) { return cached }
        let image: NSImage?
        switch item.kind {
        case .text: image = nil
        case .files: image = item.paths?.first.map { NSWorkspace.shared.icon(forFile: $0) }
        case .image: image = store.imageURL(for: item).flatMap { NSImage(contentsOf: $0) }
        }
        if let image { thumbnails.setObject(image, forKey: key) }
        return image
    }
}
