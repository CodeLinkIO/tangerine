import CoreGraphics
import Foundation
import Vision

/// On-device OCR shared by image → TXT, Copy Text and scanned-PDF extraction.
public enum TextRecognition {
    /// Recognizes text in reading order, one line per observation.
    public static func recognize(_ image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let observations = request.results ?? []
        // Vision returns normalized boxes with a bottom-left origin; sort top-to-bottom, then left-to-right.
        let sorted = observations.sorted { a, b in
            let dy = a.boundingBox.midY - b.boundingBox.midY
            if abs(dy) > min(a.boundingBox.height, b.boundingBox.height) / 2 { return dy > 0 }
            return a.boundingBox.minX < b.boundingBox.minX
        }
        return sorted.compactMap { $0.topCandidates(1).first?.string }.joined(separator: "\n")
    }
}
