import AppKit
import DropwheelCore
import SwiftUI

/// Открывает окно инструмента. Каждое окно — отдельный NSWindow без стандартного заголовка.
@MainActor
final class ToolPresenter {
    private unowned let coordinator: Coordinator
    private var windows: [NSWindow] = []

    init(coordinator: Coordinator) { self.coordinator = coordinator }

    func open(_ tool: ToolDef, files: [URL]) {
        let ctx = ToolContext(tool: tool, files: files, jobs: coordinator.jobs, tools: coordinator.tools)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 600, height: 560),
                              styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        window.titleVisibility = .hidden
        window.titlebarAppearsTransparent = true
        [.closeButton, .miniaturizeButton, .zoomButton].forEach { window.standardWindowButton($0)?.isHidden = true }
        window.isMovableByWindowBackground = true
        window.isReleasedWhenClosed = false
        window.title = tool.label.capitalized
        ctx.close = { [weak self, weak window] in
            window?.close()
            self?.windows.removeAll { $0 === window }
        }
        window.contentView = NSHostingView(rootView: Self.view(for: ctx))
        window.center()
        windows.append(window)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    static func view(for ctx: ToolContext) -> AnyView {
        let category = FileCategory.of(ctx.file)
        switch ctx.tool.id {
        case Tools.compress.id: return AnyView(CompressTool(ctx: ctx))
        case Tools.metadata.id: return AnyView(MetadataTool(ctx: ctx))
        case Tools.editImage.id: return AnyView(EditPhotoTool(ctx: ctx))
        case Tools.annotate.id: return AnyView(AnnotateTool(ctx: ctx))
        case Tools.addBackground.id: return AnyView(AddBackgroundTool(ctx: ctx))
        case Tools.cropImage.id: return AnyView(CropImageTool(ctx: ctx))
        case Tools.redactImage.id: return AnyView(RedactImageTool(ctx: ctx))
        case Tools.collage.id: return AnyView(CollageTool(ctx: ctx))
        case Tools.trimVideo.id, Tools.trimAudio.id: return AnyView(TrimTool(ctx: ctx, isAudio: category == .audio))
        case Tools.cropVideo.id: return AnyView(CropVideoTool(ctx: ctx))
        case Tools.speed.id: return AnyView(SpeedTool(ctx: ctx))
        case Tools.snapshot.id: return AnyView(SnapshotTool(ctx: ctx))
        case Tools.splitVideo.id: return AnyView(SplitVideoTool(ctx: ctx))
        case Tools.redactVideo.id: return AnyView(RedactVideoTool(ctx: ctx))
        case Tools.joinVideos.id: return AnyView(JoinVideosTool(ctx: ctx))
        case Tools.normalize.id: return AnyView(NormalizeTool(ctx: ctx))
        case Tools.visualize.id: return AnyView(VisualizerTool(ctx: ctx))
        case Tools.channels.id: return AnyView(ChannelsTool(ctx: ctx))
        case Tools.bleep.id: return AnyView(BleepTool(ctx: ctx))
        case Tools.mergePDFs.id: return AnyView(MergePDFsTool(ctx: ctx))
        case Tools.organizePDF.id: return AnyView(OrganizePDFTool(ctx: ctx))
        case Tools.splitPDF.id: return AnyView(SplitPDFTool(ctx: ctx))
        default:
            return AnyView(ToolChrome(title: ctx.tool.label.capitalized, canSave: false, close: ctx.close, save: {}) {
                Text("Этот инструмент не поддерживается для выбранных файлов").foregroundStyle(Tokens.Palette.textMuted)
            })
        }
    }
}
