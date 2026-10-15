import Vision
import CoreGraphics

public struct RecognizedLine {
    public let text: String
    public let box: CGRect
}
public enum TextRecognition {
    public static func observations(in image: CGImage, fast: Bool = false, languages: [String] = ["de-DE", "en-US"]) throws -> [VNRecognizedTextObservation] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = fast ? .fast : .accurate
        request.recognitionLanguages = languages; request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return request.results ?? []
    }
    public static func recognizeText(in image: CGImage, fast: Bool = false) throws -> [RecognizedLine] {
        try observations(in: image, fast: fast).compactMap { observation in
            observation.topCandidates(1).first.map { RecognizedLine(text: $0.string, box: observation.boundingBox) }
        }
    }
}
