import Foundation

/// Очищает HTML от всего, что системный импортёр может загрузить из сети.
public enum OfflineHTML {
    static let rules: [(String, String)] = [
        // Активное и встраиваемое содержимое убираем целиком.
        ("(?is)<script\\b.*?</script>", ""),
        ("(?is)<(iframe|object|embed|video|audio|source|track)\\b.*?(</\\1>|/?>)", ""),
        ("(?is)<link\\b[^>]*>", ""),
        ("(?is)<meta\\b[^>]*http-equiv[^>]*>", ""),
        ("(?is)<base\\b[^>]*>", ""),
        // Картинки с удалённым адресом (http, https, протокол-относительные).
        ("(?is)<img\\b[^>]*\\bsrc\\s*=\\s*[\"']?\\s*(https?:|//)[^>]*>", ""),
        // srcset и фоновые атрибуты.
        ("(?is)\\s(srcset|background|poster|lowsrc|dynsrc)\\s*=\\s*(\"[^\"]*\"|'[^']*'|[^\\s>]+)", ""),
        // CSS: @import и url(...) с удалённым адресом.
        ("(?is)@import[^;]*;", ""),
        ("(?is)url\\(\\s*[\"']?\\s*(https?:|//)[^)]*\\)", "none"),
    ]

    public static func sanitize(_ html: String) -> String {
        var s = html
        for (pattern, replacement) in rules {
            s = s.replacingOccurrences(of: pattern, with: replacement, options: .regularExpression)
        }
        return s
    }
}

/// Решает, писать ли значение ячейки числом. Строки с ведущим нулём (007, индексы, артикулы)
/// и слишком длинные числа остаются текстом, чтобы не потерять данные.
public enum CellValue {
    public static func number(_ raw: String) -> Double? {
        let v = raw.trimmingCharacters(in: .whitespaces)
        guard v.range(of: "^-?(0|[1-9][0-9]{0,14})([.,][0-9]+)?$", options: .regularExpression) != nil else { return nil }
        return Double(v.replacingOccurrences(of: ",", with: "."))
    }

    /// Число без «.0» для целых.
    public static func format(_ d: Double) -> String {
        d == d.rounded() && abs(d) < 1e15 ? String(Int64(d)) : String(d)
    }
}
