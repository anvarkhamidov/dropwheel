import AppKit
import DropwheelCore
import Observation
import SwiftUI

@MainActor
@Observable
final class WheelModel {
    var kind: WheelKind = .convert
    var items: [WheelItem] = []
    var files: [URL] = []
    var hovered: Int?
    var presented = false
    var flashing: Int?

    var geometry: WheelGeometry { WheelGeometry(count: items.count) }

    /// Подпись под курсором или nil.
    var hoveredLabel: String? {
        guard let h = hovered, h < items.count else { return nil }
        return items[h].label
    }

    /// Сводка по файлам для ступицы, когда ничего не выбрано.
    var filesSummary: String {
        if items.isEmpty { return "Нет вариантов" }
        if files.count > 1 { return "\(files.count) файла" }
        guard let f = files.first else { return "" }
        let values = try? f.resourceValues(forKeys: [.fileSizeKey, .isDirectoryKey])
        if values?.isDirectory == true { return "Папка" }
        return ByteCountFormatter.string(fromByteCount: Int64(values?.fileSize ?? 0), countStyle: .file)
    }

    /// Иконка первого файла для ступицы (как в Finder).
    var fileIcon: NSImage? {
        guard let f = files.first else { return nil }
        return NSWorkspace.shared.icon(forFile: f.path)
    }
}

/// Колесо без подложки: каждая кнопка — отдельное плавающее стекло со своим размытием и тенью.
struct WheelView: View {
    let model: WheelModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var size: CGFloat { Tokens.Wheel.windowSize }

    var body: some View {
        let g = model.geometry
        ZStack {
        // Подложка: прозрачное стекло, которое только размывает фон, без молочной заливки.
        BackdropGlass()
            .frame(width: g.backdropRadius * 2, height: g.backdropRadius * 2)
        GlassGroup {
            ZStack {
                ForEach(Array(model.items.enumerated()), id: \.element.id) { i, item in
                    let active = model.hovered == i || model.flashing == i
                    let lift = active && !reduceMotion ? liftOffset(g, i) : .zero
                    FloatingButton(shape: g.petal(i).offsetBy(dx: size / 2, dy: size / 2), active: active) {
                        SegmentLabel(item: item, active: active, width: g.labelWidth(i))
                            .position(x: size / 2 + g.labelCenter(i).x, y: size / 2 + g.labelCenter(i).y)
                    }
                    .offset(lift)
                    .animation(Tokens.Motion.hover, value: active)
                }
                hub
            }
            .frame(width: size, height: size)
        }
        }
        .frame(width: size, height: size)
        .scaleEffect(model.presented || reduceMotion ? 1 : Tokens.Motion.appearScale)
        .opacity(model.presented ? 1 : 0)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Колесо: \(model.items.count) вариантов")
        .accessibilityValue(model.hoveredLabel ?? "")
    }

    /// Смещение активной кнопки наружу вдоль её оси.
    private func liftOffset(_ g: WheelGeometry, _ i: Int) -> CGSize {
        let a = g.centerAngle(i)
        return CGSize(width: cos(a) * Tokens.Wheel.lift, height: sin(a) * Tokens.Wheel.lift)
    }

    /// Ступица — тоже плавающее стекло: иконка файла и размер, при наведении — название варианта.
    private var hub: some View {
        let d = Tokens.Wheel.hubRadius * 2
        let circle = Path(ellipseIn: CGRect(x: size / 2 - d / 2, y: size / 2 - d / 2, width: d, height: d))
        return FloatingButton(shape: circle, active: false) {
            Group {
                if let label = model.hoveredLabel {
                    Text(label)
                        .font(Tokens.Font.wheelHub)
                        .foregroundStyle(Tokens.Palette.accent)
                        .multilineTextAlignment(.center)
                        .lineLimit(2)
                        .minimumScaleFactor(0.6)
                        .transition(.opacity)
                } else {
                    VStack(spacing: 2) {
                        if let icon = model.fileIcon, !model.items.isEmpty {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: Tokens.Wheel.fileIconSize, height: Tokens.Wheel.fileIconSize)
                        }
                        Text(model.filesSummary)
                            .font(Tokens.Font.wheelHubCaption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .minimumScaleFactor(0.7)
                    }
                    .transition(.opacity)
                }
            }
            .frame(width: d - 10, height: d - 10)
            .position(x: size / 2, y: size / 2)
            .animation(Tokens.Motion.hover, value: model.hoveredLabel)
        }
    }
}

/// Подложка колеса: прозрачное стекло (Liquid Glass .clear) — размывает и чуть преломляет фон,
/// но не красит его. На старых системах — самый лёгкий системный материал.
private struct BackdropGlass: View {
    var body: some View {
        if #available(macOS 26.0, *) {
            Color.clear.glassEffect(.clear, in: Circle())
        } else {
            Circle().fill(.ultraThinMaterial)
        }
    }
}

/// Контейнер для стёкол: на macOS 26+ стёкла в одной группе рендерятся согласованно;
/// spacing меньше зазора между кнопками, поэтому они не сливаются в одну каплю.
private struct GlassGroup<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 4) { content }
        } else {
            content
        }
    }
}

/// Плавающая кнопка: стекло Liquid Glass (macOS 26+) или матовый материал на старых системах.
/// Подпись — содержимое стекла: так она рисуется поверх него и остаётся чёткой.
/// Активная — подкрашена бирюзовым, с плотной заливкой под текстом для контраста и мягким свечением.
private struct FloatingButton<Content: View>: View {
    let shape: Path
    let active: Bool
    @ViewBuilder let content: Content
    @Environment(\.colorScheme) private var scheme

    private var size: CGFloat { Tokens.Wheel.windowSize }

    var body: some View {
        let inner = ZStack {
            if active {
                // Плотная заливка: белая подпись читается на любом фоне под стеклом.
                shape.fill(LinearGradient(colors: [Tokens.Palette.accent.opacity(0.92), Tokens.Palette.accentDeep.opacity(0.95)],
                                          startPoint: .top, endPoint: .bottom))
            }
            content
        }
        .frame(width: size, height: size)

        glassed(inner)
            .shadow(color: active ? Tokens.Palette.accent.opacity(0.45) : Tokens.Shadow.floating.color,
                    radius: active ? Tokens.Shadow.activeGlow : Tokens.Shadow.floating.radius,
                    y: active ? 3 : Tokens.Shadow.floating.y)
    }

    @ViewBuilder private func glassed(_ view: some View) -> some View {
        if #available(macOS 26.0, *) {
            view.glassEffect(active ? .regular.tint(Tokens.Palette.accent) : .regular, in: shape)
        } else {
            view
                .background(shape.fill(.ultraThinMaterial))
                .overlay(
                    shape.stroke(LinearGradient(colors: [Color.white.opacity(scheme == .dark ? 0.25 : 0.8), Color.white.opacity(0.05)],
                                                startPoint: .top, endPoint: .bottom), lineWidth: 1)
                )
        }
    }
}

private struct SegmentLabel: View {
    let item: WheelItem
    let active: Bool
    let width: CGFloat

    var body: some View {
        VStack(spacing: 3) {
            if let symbol = item.symbol {
                Image(systemName: symbol)
                    .font(.system(size: Tokens.Wheel.iconSize, weight: .semibold))
                    .symbolRenderingMode(.hierarchical)
                // Двухсловные подписи переносятся на вторую строку, а не вылезают за кнопку.
                Text(item.label)
                    .font(Tokens.Font.wheelTool)
                    .tracking(Tokens.Font.wheelToolTracking)
                    .lineLimit(2)
                    .multilineTextAlignment(.center)
            } else {
                Text(item.label)
                    .font(Tokens.Font.wheelFormat)
                    .tracking(Tokens.Font.wheelFormatTracking)
                    .lineLimit(1)
            }
        }
        .minimumScaleFactor(0.55)
        .frame(width: width)
        .foregroundStyle(active ? AnyShapeStyle(Tokens.Palette.onAccent) : AnyShapeStyle(.primary))
        .allowsHitTesting(false)
    }
}
