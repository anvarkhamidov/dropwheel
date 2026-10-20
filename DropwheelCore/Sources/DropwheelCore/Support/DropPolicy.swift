import AppKit

/// Какую drag-операцию «принимает» колесо.
///
/// Dropwheel ничего не делает с оригиналом, поэтому подходит любая операция, кроме delete. Но AppKit
/// отклоняет drop, если возвращённая операция не входит в маску источника, а Finder сужает маску
/// по модификаторам (⌘ — move/generic, ⌥ — copy, ⌃ — link) — теми же, что открывают колёса.
public enum DropPolicy {
    public static func operation(for mask: NSDragOperation) -> NSDragOperation {
        for op in [NSDragOperation.copy, .link, .generic, .move] where mask.contains(op) { return op }
        return []
    }
}
