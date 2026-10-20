import CoreGraphics
import Foundation
import Vision

/// Локальное распознавание: QR и штрихкоды, лица и текст (для REDACT).
public enum VisionService {
    /// Содержимое всех кодов на картинке.
    public static func readCodes(_ url: URL) throws -> [String] {
        let image = try ImageEngine.loadCGImage(url, maxPixel: 3000)
        let request = VNDetectBarcodesRequest()
        try VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? []).compactMap(\.payloadStringValue)
    }

    /// Прямоугольники лиц и строк текста в нормализованных координатах (0…1, начало вверху слева).
    public static func detectSensitive(_ image: CGImage, faces: Bool, text: Bool) throws -> [CGRect] {
        var requests: [VNRequest] = []
        let faceRequest = VNDetectFaceRectanglesRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        if faces { requests.append(faceRequest) }
        if text { requests.append(textRequest) }
        guard !requests.isEmpty else { return [] }
        try VNImageRequestHandler(cgImage: image).perform(requests)
        var boxes: [CGRect] = []
        if faces { boxes += (faceRequest.results ?? []).map(\.boundingBox) }
        if text { boxes += (textRequest.results ?? []).map(\.boundingBox) }
        // Vision отдаёт начало координат внизу — переворачиваем и чуть расширяем область.
        return boxes.map { b in
            let pad: CGFloat = 0.01
            return CGRect(x: max(0, b.minX - pad), y: max(0, 1 - b.maxY - pad),
                          width: min(1, b.width + 2 * pad), height: min(1, b.height + 2 * pad))
        }
    }
}
