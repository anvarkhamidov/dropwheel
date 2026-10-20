import DropwheelCore
import SwiftUI

/// Настройки по вкладкам, как в системных приложениях: одним списком окно выходило выше экрана.
/// Окно подстраивает высоту под открытую вкладку.
struct SettingsView: View {
    enum Tab: String, CaseIterable { case general, clipboard, updates, tools }

    @Bindable var settings: SettingsStore
    let coordinator: Coordinator
    @State private var tab: Tab
    @State private var launchAtLogin: Bool
    @State private var autoCheck: Bool
    @State private var autoInstall: Bool
    @State private var confirmClear = false
    @AppStorage(SettingsStore.showMenuBarIconKey) private var showMenuBarIcon = true

    init(coordinator: Coordinator, tab: Tab = .general) {
        self.coordinator = coordinator
        self.settings = coordinator.settings
        _tab = State(initialValue: tab)
        _launchAtLogin = State(initialValue: coordinator.settings.launchAtLogin)
        _autoCheck = State(initialValue: coordinator.updater.automaticallyChecks)
        _autoInstall = State(initialValue: coordinator.updater.automaticallyInstalls)
    }

    var body: some View {
        TabView(selection: $tab) {
            page { general }
                .tabItem { Label("Основные", systemImage: "gearshape") }
                .tag(Tab.general)
            page { clipboard }
                .tabItem { Label("Буфер обмена", systemImage: "list.clipboard") }
                .tag(Tab.clipboard)
            page { updates }
                .tabItem { Label("Обновления", systemImage: "arrow.triangle.2.circlepath") }
                .tag(Tab.updates)
            page { tools }
                .tabItem { Label("Инструменты", systemImage: "wrench.and.screwdriver") }
                .tag(Tab.tools)
        }
    }

    private func page(@ViewBuilder _ content: () -> some View) -> some View {
        Form { content() }
            .formStyle(.grouped)
            .frame(width: 480)
            .fixedSize(horizontal: false, vertical: true)
    }

    @ViewBuilder private var general: some View {
        Section("Клавиши колёс") {
            Picker("Форматы", selection: $settings.convertKey) { keyOptions }
            Picker("Инструменты", selection: $settings.toolsKey) { keyOptions }
            Picker("Действия", selection: $settings.actionsKey) { keyOptions }
            if settings.hasConflict {
                Label("У двух колёс одна клавиша — одно из них не откроется", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(Tokens.Palette.warning)
                    .font(Tokens.Font.caption)
            }
            Text("Начните тянуть файл и коротко нажмите клавишу. Держать её не нужно: колесо открыто, пока вы не отпустите файл.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textMuted)
        }
        Section {
            Toggle("Показывать значок в строке меню", isOn: $showMenuBarIcon)
            Toggle("Показывать результат в Finder", isOn: $settings.revealInFinder)
            Toggle("Запускать при входе в систему", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { _, v in settings.launchAtLogin = v }
            Picker("Терминал для действия TERMINAL", selection: $settings.terminalApp) {
                ForEach(TerminalApp.allCases) { Text($0.title).tag($0) }
            }
        } header: {
            Text("Поведение")
        } footer: {
            if !showMenuBarIcon {
                Text("Колёса и история буфера работают и без значка. Чтобы вернуться в настройки, откройте Dropwheel ещё раз — из «Программ» или через Spotlight.")
                    .font(Tokens.Font.caption)
                    .foregroundStyle(Tokens.Palette.textMuted)
            }
        }
    }

    @ViewBuilder private var clipboard: some View {
        Section {
            Toggle("Сохранять историю буфера обмена", isOn: $settings.clipboardEnabled)
            Picker("Открыть историю", selection: $settings.clipboardHotKey) {
                ForEach(ClipboardHotKey.allCases) { Text($0.title).tag($0) }
            }
            .disabled(!settings.clipboardEnabled)
            Picker("Хранить записей", selection: $settings.clipboardLimit) {
                ForEach(SettingsStore.clipboardLimits, id: \.self) { Text("\($0)").tag($0) }
            }
            .disabled(!settings.clipboardEnabled)
            LabeledContent("Сейчас в истории: \(coordinator.clipboard.items.count)") {
                Button("Очистить…") { confirmClear = true }
                    .disabled(coordinator.clipboard.items.isEmpty)
            }
        } footer: {
            Text("История хранится только на этом Mac. Пароли из менеджеров паролей не сохраняются. Закреплённые записи не удаляются ни по лимиту, ни при очистке.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textMuted)
        }
        .confirmationDialog("Очистить историю буфера обмена?", isPresented: $confirmClear) {
            Button("Очистить", role: .destructive) { coordinator.clipboard.clear() }
        } message: {
            Text("Закреплённые записи останутся.")
        }
    }

    @ViewBuilder private var updates: some View {
        Section {
            Toggle("Проверять обновления раз в день", isOn: $autoCheck)
                .onChange(of: autoCheck) { _, v in coordinator.updater.automaticallyChecks = v }
            Toggle("Устанавливать автоматически", isOn: $autoInstall)
                .onChange(of: autoInstall) { _, v in coordinator.updater.automaticallyInstalls = v }
                .disabled(!autoCheck)
            LabeledContent("Версия \(Bundle.main.shortVersion)") {
                Button("Проверить сейчас") { coordinator.updater.checkForUpdates() }
                    .disabled(!coordinator.updater.canCheck)
            }
        } footer: {
            Text("Новая версия ставится, когда нет активных задач: приложение перезапустится само за секунду.")
                .font(Tokens.Font.caption)
                .foregroundStyle(Tokens.Palette.textMuted)
        }
    }

    @ViewBuilder private var tools: some View {
        Section {
            ToolStatusRow(name: "ffmpeg", detail: "аудио и видео", path: coordinator.tools.ffmpeg?.path)
            ToolStatusRow(name: "cwebp", detail: "запись WebP", path: coordinator.tools.cwebp?.path)
            ToolStatusRow(name: "Pages", detail: "формат .pages", path: coordinator.tools.available.contains(.pages) ? "установлен" : nil)
            ToolStatusRow(name: "Keynote", detail: "PPT/PPTX в PDF и картинки", path: coordinator.tools.available.contains(.keynote) ? "установлен" : nil)
            ToolStatusRow(name: "Numbers", detail: "чтение XLS", path: coordinator.tools.available.contains(.numbers) ? "установлен" : nil)
        }
        Section {
            TextField("Свой путь к ffmpeg", text: $settings.ffmpegPath, prompt: Text("/opt/homebrew/bin/ffmpeg"))
        } footer: {
            if coordinator.tools.ffmpeg == nil || coordinator.tools.cwebp == nil {
                Text("Установить недостающее: brew install ffmpeg webp")
                    .font(Tokens.Font.mono)
                    .textSelection(.enabled)
                    .foregroundStyle(Tokens.Palette.textMuted)
            }
        }
    }

    @ViewBuilder private var keyOptions: some View {
        ForEach(TriggerKey.allCases) { Text($0.title).tag($0) }
    }
}

private struct ToolStatusRow: View {
    let name: String
    let detail: String
    let path: String?

    var body: some View {
        HStack {
            Image(systemName: path == nil ? "xmark.circle" : "checkmark.circle.fill")
                .foregroundStyle(path == nil ? Tokens.Palette.textMuted : Tokens.Palette.success)
            VStack(alignment: .leading) {
                Text(name).font(Tokens.Font.bodyStrong)
                Text(detail).font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
            }
            Spacer()
            Text(path ?? "не найден").font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
                .lineLimit(1).truncationMode(.middle)
        }
        .accessibilityElement(children: .combine)
    }
}

/// Первый запуск: жест в трёх клавишах и состояние зависимостей.
struct OnboardingView: View {
    let coordinator: Coordinator
    let done: () -> Void

    var body: some View {
        let s = coordinator.settings
        VStack(spacing: Tokens.Space.s5) {
            Text("Бросьте файл на колесо").font(Tokens.Font.display).foregroundStyle(Tokens.Palette.text)
            Text("Тяните файл и коротко нажмите клавишу — вокруг курсора появится колесо. Отпустите файл на нужном варианте, и результат ляжет рядом с оригиналом. Если удобнее правый клик — Dropwheel есть и в быстрых действиях Finder.")
                .font(Tokens.Font.body)
                .foregroundStyle(Tokens.Palette.textMuted)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Tokens.Space.s4) {
                KeyCap(glyph: s.convertKey.glyph, caption: "форматы")
                KeyCap(glyph: s.toolsKey.glyph, caption: "инструменты")
                KeyCap(glyph: s.actionsKey.glyph, caption: "действия")
            }
            VStack(alignment: .leading, spacing: Tokens.Space.s2) {
                status(coordinator.tools.ffmpeg != nil, "ffmpeg — аудио и видео")
                status(coordinator.tools.cwebp != nil, "cwebp — запись WebP")
                if coordinator.tools.ffmpeg == nil || coordinator.tools.cwebp == nil {
                    Text("brew install ffmpeg webp").font(Tokens.Font.mono).textSelection(.enabled).foregroundStyle(Tokens.Palette.textMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Tokens.Space.s3)
            .background(Tokens.Palette.surfaceSunken, in: RoundedRectangle(cornerRadius: Tokens.Radius.md))
            Text("Всё происходит на этом Mac. Файлы никуда не отправляются.")
                .font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
            Button("Понятно", action: done)
                .buttonStyle(.borderedProminent)
                .tint(Tokens.Palette.accent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(Tokens.Space.s7)
        .frame(width: 520)
        .background(Tokens.Palette.bg)
    }

    private func status(_ ok: Bool, _ text: String) -> some View {
        Label(text, systemImage: ok ? "checkmark.circle.fill" : "xmark.circle")
            .font(Tokens.Font.body)
            .foregroundStyle(ok ? Tokens.Palette.success : Tokens.Palette.textMuted)
    }
}

struct KeyCap: View {
    let glyph: String
    let caption: String

    var body: some View {
        VStack(spacing: Tokens.Space.s2) {
            Text(glyph)
                .font(.system(size: 22, weight: .medium))
                .foregroundStyle(Tokens.Palette.text)
                .frame(width: 64, height: 56)
                .background(Tokens.Palette.surface, in: RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: Tokens.Radius.md, style: .continuous).strokeBorder(Tokens.Palette.border))
                .shadow(color: Tokens.Shadow.segment.color, radius: 0, y: 2)
            Text(caption).font(Tokens.Font.caption).foregroundStyle(Tokens.Palette.textMuted)
        }
        .accessibilityElement(children: .combine)
    }
}

extension Bundle {
    var shortVersion: String { infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
}
