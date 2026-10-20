import AppKit
import SwiftUI

/// Дизайн-токены. В компонентах только эти роли, никаких сырых значений.
enum Tokens {
    enum Palette {
        static func dynamic(_ light: UInt32, _ dark: UInt32) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(hex: dark) : NSColor(hex: light)
            })
        }
        static let bg = dynamic(0xF5F5F7, 0x1E1E20)
        static let surface = dynamic(0xFBFBFC, 0x2C2C2E)
        static let surfaceSunken = dynamic(0xECECEF, 0x18181A)
        static let previewBg = dynamic(0x141414, 0x0B0B0D)
        static let border = dynamic(0xE2E2E6, 0x3A3A3C)
        static let borderInput = dynamic(0x86868B, 0x8E8E93)
        static let text = dynamic(0x1D1D1F, 0xF5F5F7)
        static let textMuted = dynamic(0x636366, 0xA1A1A6)
        static let accent = dynamic(0x0E7C86, 0x3CC9C9)
        static let onAccent = dynamic(0xFFFFFF, 0x06292B)
        /// Нижняя точка градиента активного сегмента: темнее акцента, контраст с onAccent только выше.
        static let accentDeep = dynamic(0x0A626A, 0x2FB3B5)
        static let danger = dynamic(0xC62F2F, 0xFF6B6B)
        static let success = dynamic(0x1F7A4D, 0x4CD08A)
        static let warning = dynamic(0x9A5300, 0xFFB340)
        /// Полупрозрачные роли (цвет и альфа для светлой и тёмной темы).
        static func dynamicAlpha(_ light: (UInt32, CGFloat), _ dark: (UInt32, CGFloat)) -> Color {
            Color(nsColor: NSColor(name: nil) { appearance in
                let (hex, alpha) = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
                return NSColor(hex: hex).withAlphaComponent(alpha)
            })
        }
        /// Подложка неактивной кнопки колеса: стекло на белом окне само по себе почти невидимо.
        static let petalShade = dynamicAlpha((0x1D1D1F, 0.045), (0xFFFFFF, 0.06))
        /// Тонкая обводка кнопки колеса.
        static let petalEdge = dynamicAlpha((0x1D1D1F, 0.10), (0xFFFFFF, 0.16))
    }

    enum Font {
        static let wheelTool = SwiftUI.Font.system(size: 9, weight: .bold, design: .rounded)
        static let wheelHub = SwiftUI.Font.system(size: 12, weight: .semibold, design: .rounded)
        static let wheelHubCaption = SwiftUI.Font.system(size: 10, weight: .medium, design: .rounded).monospacedDigit()
        static let caption = SwiftUI.Font.system(size: 11, weight: .medium)
        static let body = SwiftUI.Font.system(size: 12)
        static let bodyStrong = SwiftUI.Font.system(size: 12, weight: .semibold)
        static let wheelFormat = SwiftUI.Font.system(size: 13, weight: .bold, design: .rounded)
        static let section = SwiftUI.Font.system(size: 13, weight: .semibold)
        static let title = SwiftUI.Font.system(size: 15, weight: .semibold)
        static let display = SwiftUI.Font.system(size: 22, weight: .bold)
        static let mono = SwiftUI.Font.system(size: 12).monospacedDigit()
        static let wheelToolTracking: CGFloat = 0.4
        static let wheelFormatTracking: CGFloat = 0.3
    }

    enum Space {
        static let s1: CGFloat = 4, s2: CGFloat = 8, s3: CGFloat = 12, s4: CGFloat = 16, s5: CGFloat = 20, s6: CGFloat = 24, s7: CGFloat = 32
    }

    enum Radius {
        static let sm: CGFloat = 6, md: CGFloat = 10, segment: CGFloat = 20, window: CGFloat = 16
    }

    enum Wheel {
        /// Граница зоны выбора.
        static let outerRadius: CGFloat = 120
        /// Насколько подложка с размытием шире кнопок.
        static let backdropPadding: CGFloat = 14
        /// Прибавка к радиусу за каждую кнопку сверх семи.
        static let growPerSegment: CGFloat = 6
        static let segmentOuter: CGFloat = 116
        static let segmentInner: CGFloat = 50
        static let hubRadius: CGFloat = 38
        /// Зазор между кнопками: достаточно широкий, чтобы каждая читалась отдельным стеклом.
        static let gap: CGFloat = 10
        /// На сколько активная кнопка «выдвигается» наружу.
        static let lift: CGFloat = 4
        static let fileIconSize: CGFloat = 28
        static let iconSize: CGFloat = 16
        /// Поле окна вокруг колеса: место под тени и анимацию появления.
        static let windowSize: CGFloat = 340
    }

    enum Clipboard {
        static let width: CGFloat = 560
        static let height: CGFloat = 460
        static let rowHeight: CGFloat = 48
        static let thumb: CGFloat = 32
    }

    enum Motion {
        // Колесо открывается клавишей десятки раз в день: появление почти незаметное, выход ещё быстрее.
        static let appear = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.14)
        static let hover = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.1)
        static let dismiss = Animation.timingCurve(0.23, 1, 0.32, 1, duration: 0.09)
        static let appearScale: CGFloat = 0.97
        static let dismissScale: CGFloat = 0.98
    }

    enum Shadow {
        /// Тень каждой плавающей кнопки.
        static let floating = (color: Color.black.opacity(0.18), radius: CGFloat(12), y: CGFloat(6))
        static let activeGlow = CGFloat(14)
        static let segment = (color: Color.black.opacity(0.08), radius: CGFloat(1), y: CGFloat(1))
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}
