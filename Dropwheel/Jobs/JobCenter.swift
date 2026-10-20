import AppKit
import Observation
import DropwheelCore

@MainActor
@Observable
final class JobItem: Identifiable {
    enum Status: Equatable { case queued, running, done, failed(String), cancelled }

    let id = UUID()
    let title: String
    let files: [URL]
    var status: Status = .queued
    var progress: Double?
    var completed = 0
    var outputs: [URL] = []
    /// Короткий итог для мгновенных инструментов (например, содержимое QR).
    var note: String?
    /// Внешние команды задачи (ffmpeg, cwebp…) — для «Скопировать команду».
    var commands: [String] = []
    @ObservationIgnored var task: Task<Void, Never>?

    init(title: String, files: [URL]) {
        self.title = title
        self.files = files
    }

    var subtitle: String {
        if files.count > 1 {
            return status == .running ? "\(min(completed + 1, files.count)) из \(files.count)" : "\(files.count) файлов"
        }
        return files.first?.lastPathComponent ?? ""
    }
}

/// Очередь задач: не больше двух тяжёлых одновременно, остальные ждут.
actor Gate {
    private var free: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []
    init(_ n: Int) { free = n }
    func enter() async {
        if free > 0 { free -= 1; return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func leave() {
        if waiters.isEmpty { free += 1 } else { waiters.removeFirst().resume() }
    }
}

/// Ссылка на задачу для кода, которому нужно дописать итог (note) после запуска.
@MainActor
final class JobRef: @unchecked Sendable {
    var job: JobItem?
}

@MainActor
@Observable
final class JobCenter {
    var jobs: [JobItem] = []
    /// Последняя внешняя команда любой задачи — пункт меню «Скопировать последнюю команду».
    var lastCommand: String?
    @ObservationIgnored var tools: () -> ExternalTools = { ExternalTools.discover() }
    @ObservationIgnored var revealInFinder: () -> Bool = { true }
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let gate = Gate(2)

    /// Идёт ли сейчас конвертация: обновление не перезапускает приложение посреди задачи.
    var isBusy: Bool { jobs.contains { $0.status == .queued || $0.status == .running } }

    /// Общая обёртка: прогресс, статус, отмена, reveal в Finder.
    /// `work` выполняется вне главного потока и получает колбэк прогресса.
    @discardableResult
    func run(_ title: String, files: [URL], reveal: Bool = true,
             _ work: @escaping @Sendable (_ progress: @escaping @Sendable (Int, Double?) -> Void) async throws -> [URL]) -> JobItem {
        let job = JobItem(title: title, files: files)
        jobs.append(job)
        onChange?()
        let gate = self.gate
        let recorder = CommandRecorder()
        job.task = Task { [weak self] in
            await gate.enter()
            let progress: @Sendable (Int, Double?) -> Void = { done, p in
                Task { @MainActor in
                    job.completed = done
                    job.progress = p.map { (Double(done) + $0) / Double(max(files.count, 1)) }
                }
            }
            do {
                // Отменили, пока задача ждала очереди, — не запускаем вовсе.
                try Task.checkCancellation()
                job.status = .running
                // Тяжёлая работа — в detached-задаче, чтобы не занимать главный поток.
                // Detached не наследует отмену, поэтому пробрасываем её вручную.
                // TaskLocal не наследуется detached-задачей, поэтому журнал задаём внутри неё.
                let worker = Task.detached(priority: .userInitiated) {
                    try await CommandLog.$recorder.withValue(recorder) { try await work(progress) }
                }
                let outputs = try await withTaskCancellationHandler {
                    try await worker.value
                } onCancel: {
                    worker.cancel()
                }
                if Task.isCancelled {
                    // Отмена пришла в последний момент: результат уже записан, но пользователь его не хочет.
                    outputs.forEach { try? FileManager.default.removeItem(at: $0) }
                    throw CancellationError()
                }
                job.outputs = outputs
                job.progress = 1
                job.status = .done
                if reveal, self?.revealInFinder() == true, !outputs.isEmpty {
                    NSWorkspace.shared.activateFileViewerSelecting(outputs)
                }
                self?.finish(job, after: job.note == nil ? 1.2 : 6)
            } catch is CancellationError {
                job.status = .cancelled
                self?.finish(job, after: 0)
            } catch {
                job.status = .failed(error.localizedDescription)
                NSLog("Dropwheel: \(title) — ошибка: \(error.localizedDescription)")
            }
            job.commands = recorder.commands
            if let last = recorder.commands.last { self?.lastCommand = last }
            await gate.leave()
        }
        return job
    }

    func cancel(_ job: JobItem) {
        if case .running = job.status { job.task?.cancel() }
        else if job.status == .queued { job.task?.cancel() }
        else { remove(job) }
    }

    func remove(_ job: JobItem) {
        jobs.removeAll { $0.id == job.id }
        onChange?()
    }

    private func finish(_ job: JobItem, after delay: TimeInterval) {
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            self.remove(job)
        }
    }

    // MARK: Конвертация

    func convert(_ files: [URL], to option: FormatOption) {
        let tools = self.tools()
        run("Конвертация в \(option.label)", files: files) { progress in
            var outputs: [URL] = []
            for (i, file) in files.enumerated() {
                try Task.checkCancellation()
                progress(i, 0)
                outputs += try await Converter(tools: tools).convert(file, to: option.ext) { p in progress(i, p) }
            }
            return outputs
        }
    }
}
