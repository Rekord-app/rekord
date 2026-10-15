import Foundation
import CoreGraphics
import CoreText
import ImageIO

/// A4 PDF of a guide, drawn with Core Graphics and Core Text (no WebKit, works in the MCP server too).
/// One block per step: number, text, tip/warning, screenshot. A block never splits across pages.
public enum GuidePDF {
    static let page = CGRect(x: 0,y: 0,width: 595.28,height: 841.89)
    static let margin: CGFloat = 46
    static let accent = CGColor(srgbRed: 1,green: 0.27,blue: 0.2,alpha: 1)
    static let ink = CGColor(srgbRed: 0.1,green: 0.11,blue: 0.13,alpha: 1)
    static let muted = CGColor(srgbRed: 0.42,green: 0.44,blue: 0.48,alpha: 1)

    public static func write(_ guide: Guide,directory: URL,to url: URL) throws {
        var box = page
        guard let context = CGContext(url as CFURL,mediaBox: &box,[kCGPDFContextTitle: guide.title,kCGPDFContextCreator: "Rekord"] as CFDictionary) else { throw GuideImageError.write }
        var pageNumber = 0
        var y: CGFloat = 0   // distance from the top of the page
        let width = page.width-2*margin
        func newPage() {
            if pageNumber > 0 { footer(); context.endPDFPage() }
            context.beginPDFPage(nil); pageNumber += 1; y = margin
        }
        func footer() {
            let line = attributed("\(guide.title) · Seite \(pageNumber) · Erstellt mit Rekord",size: 8,color: muted)
            draw(line,at: CGRect(x: margin,y: page.height-margin+18,width: width,height: 12))
        }
        func draw(_ text: NSAttributedString,at rect: CGRect) {
            // rect in top-left coordinates
            let path = CGPath(rect: CGRect(x: rect.minX,y: page.height-rect.maxY,width: rect.width,height: rect.height),transform: nil)
            let frame = CTFramesetterCreateFrame(CTFramesetterCreateWithAttributedString(text),CFRange(location: 0,length: 0),path,nil)
            CTFrameDraw(frame,context)
        }
        func height(_ text: NSAttributedString,width: CGFloat) -> CGFloat {
            CTFramesetterSuggestFrameSizeWithConstraints(CTFramesetterCreateWithAttributedString(text),CFRange(location: 0,length: 0),nil,CGSize(width: width,height: .greatestFiniteMagnitude),nil).height.rounded(.up)+2
        }

        newPage()
        let title = attributed(guide.title,size: 24,weight: true,color: ink)
        let th = height(title,width: width); draw(title,at: CGRect(x: margin,y: y,width: width,height: th)); y += th+6
        let date = DateFormatter(); date.locale = Locale(identifier: "de_DE"); date.dateStyle = .medium
        let meta = attributed(([guide.apps.joined(separator: ", ")].filter { !$0.isEmpty } + ["\(guide.steps.count) Schritte",date.string(from: guide.createdAt)]).joined(separator: " · "),size: 10,color: muted)
        let mh = height(meta,width: width); draw(meta,at: CGRect(x: margin,y: y,width: width,height: mh)); y += mh+10
        if let summary = guide.summary, !summary.isEmpty {
            let s = attributed(summary,size: 11.5,color: ink); let sh = height(s,width: width)
            draw(s,at: CGRect(x: margin,y: y,width: width,height: sh)); y += sh+10
        }
        y += 8

        for (i,step) in guide.steps.enumerated() {
            let textX = margin+34, textWidth = width-34
            let text = attributed(step.text,size: 13,weight: true,color: ink)
            var extras: [NSAttributedString] = []
            if let note = step.note, !note.isEmpty { extras.append(attributed("Tipp: \(note)",size: 10.5,color: muted)) }
            if let warning = step.warning, !warning.isEmpty { extras.append(attributed("Achtung: \(warning)",size: 10.5,color: accent)) }
            var image: CGImage?
            if let path = step.image, let source = CGImageSourceCreateWithURL(directory.appendingPathComponent(path) as CFURL,nil) { image = CGImageSourceCreateImageAtIndex(source,0,nil) }
            let textHeight = max(24,height(text,width: textWidth)) + extras.reduce(0) { $0+height($1,width: textWidth)+3 }
            var imageSize = CGSize.zero
            if let image {
                // Two steps per page: at most 400 × 260 pt (a 16:10 screen is 400 × 250).
                let w = min(textWidth,400), h = w*CGFloat(image.height)/CGFloat(image.width)
                let maxH: CGFloat = 260
                imageSize = h > maxH ? CGSize(width: maxH*CGFloat(image.width)/CGFloat(image.height),height: maxH) : CGSize(width: w,height: h)
            }
            let block = textHeight+(image == nil ? 0 : imageSize.height+10)+22
            if y+block > page.height-margin-10 { newPage() }
            // Number badge
            let badge = CGRect(x: margin,y: page.height-y-24,width: 24,height: 24)
            context.setFillColor(accent); context.fillEllipse(in: badge)
            let number = attributed("\(i+1)",size: 11,weight: true,color: CGColor(gray: 1,alpha: 1),center: true)
            draw(number,at: CGRect(x: margin,y: y+5,width: 24,height: 16))
            let h1 = max(24,height(text,width: textWidth))
            draw(text,at: CGRect(x: textX,y: y+3,width: textWidth,height: h1)); y += h1
            for extra in extras { let eh = height(extra,width: textWidth); draw(extra,at: CGRect(x: textX,y: y,width: textWidth,height: eh)); y += eh+3 }
            if let image {
                y += 8
                let rect = CGRect(x: textX,y: page.height-y-imageSize.height,width: imageSize.width,height: imageSize.height)
                context.saveGState()
                context.addPath(CGPath(roundedRect: rect,cornerWidth: 6,cornerHeight: 6,transform: nil)); context.clip()
                context.interpolationQuality = .high; context.draw(image,in: rect)
                context.restoreGState()
                context.setStrokeColor(CGColor(gray: 0.85,alpha: 1)); context.setLineWidth(0.6)
                context.addPath(CGPath(roundedRect: rect,cornerWidth: 6,cornerHeight: 6,transform: nil)); context.strokePath()
                y += imageSize.height
            }
            y += 22
        }
        footer(); context.endPDFPage(); context.closePDF()
    }

    static func attributed(_ string: String,size: CGFloat,weight: Bool = false,color: CGColor,center: Bool = false) -> NSAttributedString {
        let font = CTFontCreateUIFontForLanguage(weight ? .emphasizedSystem : .system,size,nil) ?? CTFontCreateWithName("Helvetica" as CFString,size,nil)
        var alignment = center ? CTTextAlignment.center : CTTextAlignment.natural
        var spacing: CGFloat = size*0.18
        // The settings keep pointers until CTParagraphStyleCreate: both values must outlive that call.
        let style = withUnsafePointer(to: &alignment) { a in
            withUnsafePointer(to: &spacing) { l in
                let settings = [CTParagraphStyleSetting(spec: .alignment,valueSize: MemoryLayout<CTTextAlignment>.size,value: a),
                                CTParagraphStyleSetting(spec: .lineSpacingAdjustment,valueSize: MemoryLayout<CGFloat>.size,value: l)]
                return CTParagraphStyleCreate(settings,settings.count)
            }
        }
        return NSAttributedString(string: string,attributes: [NSAttributedString.Key(kCTFontAttributeName as String): font,
                                                              NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
                                                              NSAttributedString.Key(kCTParagraphStyleAttributeName as String): style])
    }
}
