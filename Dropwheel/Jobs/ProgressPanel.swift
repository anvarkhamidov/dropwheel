import AppKit
import SwiftUI

/// Маленькая плавающая панель задач в правом верхнем углу. Не крадёт фокус.
@MainActor
final class ProgressPanelController {
    private let panel: NSPanel
    private let center: JobCenter

    init(center: JobCenter) {
        self.center = center
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 80),
                        styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.level = .floating
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        let host = NSHostingView(rootView: ProgressList(center: center))
        host.sizingOptions = [.preferredContentSize]
        panel.contentView = host
        center.onChange = { [weak self] in self?.update() }
    }

    func update() {
        guard !center.jobs.isEmpty else { panel.orderOut(nil); return }
        DispatchQueue.main.async { [self] in
            panel.layoutIfNeeded()
            let size = panel.contentView?.fittingSize ?? NSSize(width: 320, height: 80)
            if let screen = NSScreen.main {
                let f = screen.visibleFrame
                panel.setFrame(NSRect(x: f.maxX - size.width - 16, y: f.maxY - size.height - 16, width: size.width, height: size.height), display: true)
            }
            panel.orderFrontRegardless()
        }
    }
}

struct ProgressList: View {
    let center: JobCenter

    var body: some View {
        VStack(spacing: Tokens.Space.s2) {
            ForEach(center.jobs) { job in
                JobRow(job: job, cancel: { center.cancel(job) })
            }
        }
        .padding(Tokens.Space.s3)
        .frame(width: 320)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: Tokens.Radius.window, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.window, style: .continuous).strokeBorder(Tokens.Palette.border))
        .onChange(of: center.jobs.count) { center.onChange?() }
    }
}

private struct JobRow: View {
    let job: JobItem
    let cancel: () -> Void
    @State private var showDetails = false

    var body: some View {
        HStack(alignment: .top, spacing: Tokens.Space.s3) {
            icon
                .frame(width: 28, height: 28)
            VStack(alignment: .leading, spacing: Tokens.Space.s1) {
                Text(job.title).font(Tokens.Font.bodyStrong).foregroundStyle(Tokens.Palette.text)
                Text(job.subtitle).font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
                    .lineLimit(1).truncationMode(.middle)
                switch job.status {
                case .queued:
                    Text("Ожидает").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
                case .running:
                    if let p = job.progress { ProgressView(value: p).tint(Tokens.Palette.accent) }
                    else { ProgressView().progressViewStyle(.linear).tint(Tokens.Palette.accent) }
                case .done:
                    Text(job.note ?? "Готово").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.success)
                        .lineLimit(3).textSelection(.enabled)
                case .failed(let message):
                    Text(showDetails ? message : (message.components(separatedBy: "\n").first ?? message))
                        .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.danger)
                        .textSelection(.enabled)
                    HStack(spacing: Tokens.Space.s3) {
                        if message.contains("\n") {
                            Button(showDetails ? "Скрыть подробности" : "Показать подробности") { showDetails.toggle() }
                                .buttonStyle(.link).font(Tokens.Font.caption)
                        }
                        if let cmd = job.commands.last {
                            Button("Скопировать команду") { copyToClipboard(cmd) }
                                .buttonStyle(.link).font(Tokens.Font.caption)
                                .help(cmd)
                        }
                    }
                case .cancelled:
                    Text("Отменено").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
                }
            }
            Spacer(minLength: 0)
            Button(action: cancel) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold))
                    .frame(width: 20, height: 20)
                    .background(Tokens.Palette.surfaceSunken, in: Circle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Tokens.Palette.textMuted)
            .help(isActive ? "Отменить" : "Закрыть")
            .accessibilityLabel(isActive ? "Отменить задачу \(job.title)" : "Закрыть")
        }
    }

    private var isActive: Bool { job.status == .running || job.status == .queued }

    @ViewBuilder private var icon: some View {
        switch job.status {
        case .done: Image(systemName: "checkmark.circle.fill").font(.system(size: 22)).foregroundStyle(Tokens.Palette.success)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 20)).foregroundStyle(Tokens.Palette.danger)
        default:
            if let f = job.files.first { Image(nsImage: NSWorkspace.shared.icon(forFile: f.path)).resizable() }
        }
    }
}
