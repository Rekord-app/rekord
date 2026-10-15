import Foundation
import AVFoundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import Vision

/// Step screenshots for guides: taken from the screen video shortly **before** each click (the state the
/// person saw, including hover), sensitive text blacked out after local OCR (Apple Vision, nothing leaves
/// the Mac), click marked with a ring. Images are always regenerated from the video, so redactions stay
/// editable; the stored JPEGs never contain the unredacted pixels.
public enum GuideImages {
    /// How long before the click the screenshot is taken.
    public static let leadTime = 0.15
    public static let maxWidth = 1600
    public static let quality = 0.82

    /// Frame of `video` at `time` (seconds), exact (no keyframe snapping).
    public static func frame(of video: URL,at time: Double) async throws -> CGImage {
        let generator = AVAssetImageGenerator(asset: AVURLAsset(url: video))
        generator.requestedTimeToleranceBefore = .zero; generator.requestedTimeToleranceAfter = CMTime(value: 1,timescale: 60)
        generator.appliesPreferredTrackTransform = true
        return try await generator.image(at: CMTime(seconds: max(0,time),preferredTimescale: 600)).image
    }

    /// Sensitive text found by OCR: e-mail addresses, IBANs, phone and card numbers, password dots.
    /// Rects are normalized (origin top-left) and padded a little so no glyph edge stays visible.
    public static func sensitiveRegions(in image: CGImage) throws -> [GuideRedaction] {
        let observations = try TextRecognition.observations(in: image)
        var result: [GuideRedaction] = []
        for observation in observations {
            guard let candidate = observation.topCandidates(1).first else { continue }
            let text = candidate.string
            for match in SensitiveText.matches(in: text) {
                let box = (try? candidate.boundingBox(for: match.range))?.boundingBox ?? observation.boundingBox
                let rect = GuideRect(x: box.minX,y: 1-box.maxY,width: box.width,height: box.height)
                result.append(GuideRedaction(rect: GuideRect(x: rect.x-0.004,y: rect.y-rect.height*0.25,width: rect.width+0.008,height: rect.height*1.5).clipped(),reason: match.reason))
            }
        }
        return result
    }

    /// Final step image: scaled to at most `maxWidth`, redactions filled, click ring drawn.
    public static func render(_ source: CGImage,click: Point?,highlight: GuideRect? = nil,redactions: [GuideRedaction],maxWidth: Int = maxWidth) -> CGImage? {
        let scale = min(1,Double(maxWidth)/Double(source.width))
        let w = max(2,Int(Double(source.width)*scale)), h = max(2,Int(Double(source.height)*scale))
        guard let context = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: 0,space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        context.interpolationQuality = .high
        context.draw(source,in: CGRect(x: 0,y: 0,width: w,height: h))
        func rect(_ r: GuideRect) -> CGRect { CGRect(x: r.x*Double(w),y: (1-r.y-r.height)*Double(h),width: r.width*Double(w),height: r.height*Double(h)) }
        context.setFillColor(CGColor(srgbRed: 0.16,green: 0.17,blue: 0.2,alpha: 1))
        for redaction in redactions where redaction.rect.valid {
            let r = rect(redaction.rect).insetBy(dx: -1,dy: -1)
            context.addPath(CGPath(roundedRect: r,cornerWidth: min(4,r.height/3),cornerHeight: min(4,r.height/3),transform: nil)); context.fillPath()
        }
        // Outline of the clicked element (from its AX frame), unless it is a large area.
        if let highlight, highlight.valid, highlight.width*highlight.height < 0.2, highlight.width > 0.003 {
            let r = rect(highlight).insetBy(dx: -4,dy: -4)
            context.setStrokeColor(CGColor(srgbRed: 1,green: 0.27,blue: 0.2,alpha: 0.9)); context.setLineWidth(max(2.5,Double(w)*0.002))
            context.addPath(CGPath(roundedRect: r,cornerWidth: 6,cornerHeight: 6,transform: nil)); context.strokePath()
        }
        if let click {
            let radius = max(14,Double(w)*0.018), center = CGPoint(x: click.x*Double(w),y: (1-click.y)*Double(h))
            let circle = CGRect(x: center.x-radius,y: center.y-radius,width: radius*2,height: radius*2)
            context.setFillColor(CGColor(srgbRed: 1,green: 0.27,blue: 0.2,alpha: 0.22)); context.fillEllipse(in: circle)
            context.setStrokeColor(CGColor(srgbRed: 1,green: 1,blue: 1,alpha: 0.95)); context.setLineWidth(radius*0.34); context.strokeEllipse(in: circle)
            context.setStrokeColor(CGColor(srgbRed: 1,green: 0.27,blue: 0.2,alpha: 1)); context.setLineWidth(radius*0.2); context.strokeEllipse(in: circle)
        }
        return context.makeImage()
    }

    public static func writeJPEG(_ image: CGImage,to url: URL,quality: Double = quality) throws {
        guard let destination = CGImageDestinationCreateWithURL(url as CFURL,UTType.jpeg.identifier as CFString,1,nil) else { throw GuideImageError.write }
        CGImageDestinationAddImage(destination,image,[kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { throw GuideImageError.write }
    }

    /// Writes `images/step-NN.jpg` for every step. Automatic redaction runs once per step (new steps or
    /// `redetect`); manual redactions are kept. Password fields that were clicked are always covered.
    public static func generate(_ guide: inout Guide,in directory: URL,redetect: Bool = false) async throws {
        let video = directory.appendingPathComponent(guide.video)
        let folder = directory.appendingPathComponent(GuideFile.images,isDirectory: true)
        try FileManager.default.createDirectory(at: folder,withIntermediateDirectories: true)
        var written = Set<String>()
        for i in guide.steps.indices {
            let step = guide.steps[i]
            let frame = try await frame(of: video,at: step.time-leadTime)
            if redetect || step.autoRedacted != true {
                var redactions = step.redactions.filter { $0.reason == "manual" }
                redactions += try sensitiveRegions(in: frame)
                if let element = step.element, element.secure, let r = element.frame, r.valid { redactions.append(GuideRedaction(rect: r.padded(0.05),reason: "password")) }
                guide.steps[i].redactions = redactions
                guide.steps[i].autoRedacted = true
            }
            guard let image = render(frame,click: step.position,highlight: step.element?.secure == true ? nil : step.element?.frame,redactions: guide.steps[i].redactions) else { throw GuideImageError.write }
            let name = String(format: "step-%02d.jpg",i+1)
            try writeJPEG(image,to: folder.appendingPathComponent(name))
            guide.steps[i].image = "\(GuideFile.images)/\(name)"; written.insert(name)
        }
        // Images of deleted or merged steps must not linger (they could hold content the user removed).
        for name in (try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [] where name.hasPrefix("step-") && !written.contains(name) {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(name))
        }
    }
}

public enum GuideImageError: LocalizedError {
    case write
    public var errorDescription: String? { "Schritt-Bild konnte nicht geschrieben werden." }
}
