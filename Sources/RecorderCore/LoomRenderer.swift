import Foundation
import CoreImage
import CoreGraphics
import CoreVideo

// Loom's plain frame is composed on the GPU while recording, so Stop does not
// start a second frame-by-frame render. Studio keeps the nondestructive renderer.
public final class LoomFrameRenderer: @unchecked Sendable {
    public let width: Int
    public let height: Int
    private let context = CIContext(options: [.cacheIntermediates:false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let cursor: CIImage
    private let background: CIImage
    public init(width: Int = 1920,height: Int = 1080) {
        self.width = width; self.height = height
        let bounds = CGRect(x: 0,y: 0,width: width,height: height)
        background = CIFilter(name: "CILinearGradient",parameters: ["inputPoint0":CIVector(x: 0,y: CGFloat(height)),"inputPoint1":CIVector(x: CGFloat(width),y: 0),"inputColor0":CIColor(red: 0.78,green: 0.78,blue: 0.97),"inputColor1":CIColor(red: 0.97,green: 0.77,blue: 0.85)])!.outputImage!.cropped(to: bounds)
        let ctx = CGContext(data: nil,width: 48,height: 64,bitsPerComponent: 8,bytesPerRow: 192,space: colorSpace,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.translateBy(x: 4,y: 60); ctx.scaleBy(x: 36,y: -36)
        let path = CGMutablePath(); path.move(to: .zero)
        for p in [CGPoint(x: 0.08,y: 1),CGPoint(x: 0.32,y: 0.74),CGPoint(x: 0.53,y: 1.14),CGPoint(x: 0.72,y: 1.04),CGPoint(x: 0.51,y: 0.64),CGPoint(x: 0.87,y: 0.59)] { path.addLine(to: p) }
        path.closeSubpath(); ctx.addPath(path); ctx.setFillColor(CGColor(gray: 1,alpha: 1)); ctx.setStrokeColor(CGColor(gray: 0.08,alpha: 1)); ctx.setLineWidth(0.06); ctx.drawPath(using: .fillStroke)
        cursor = CIImage(cgImage: ctx.makeImage()!)
    }
    public func render(to output: CVPixelBuffer,screen: CVPixelBuffer,camera: CVPixelBuffer?,pointer: Point?,style: Style) {
        let canvas = CGRect(x: 0,y: 0,width: width,height: height)
        var source = CIImage(cvPixelBuffer: screen)
        let crop = style.crop.flatMap { $0.valid ? $0 : nil } ?? CropRect(x: 0,y: 0,width: 1,height: 1)
        if crop != CropRect(x: 0,y: 0,width: 1,height: 1) {
            let full = source.extent
            let rect = CGRect(x: full.width*crop.x,y: full.height*(1-crop.y-crop.height),width: full.width*crop.width,height: full.height*crop.height).integral.intersection(full)
            source = source.cropped(to: rect).transformed(by: CGAffineTransform(translationX: -rect.minX,y: -rect.minY))
        }
        // Within 2 % of the canvas shape the source fills it edge to edge; rounding never leaves hairline bars.
        let fit = CGFloat(width)/source.extent.width,fill = CGFloat(height)/source.extent.height
        let scale = abs(fit/fill-1) < 0.02 ? max(fit,fill) : min(fit,fill)
        let x = (CGFloat(width)-source.extent.width*scale)/2,y = (CGFloat(height)-source.extent.height*scale)/2
        var result = source.transformed(by: CGAffineTransform(scaleX: scale,y: scale)).transformed(by: CGAffineTransform(translationX: x,y: y)).composited(over: background)
        if style.showCursor,let pointer {
            let size = Double(min(width,height))*0.028*style.cursorSize/36
            let local = Point((pointer.x-crop.x)/crop.width,(pointer.y-crop.y)/crop.height)
            let px = x+local.x*source.extent.width*scale, py = y+(1-local.y)*source.extent.height*scale
            let arrow = cursor.transformed(by: CGAffineTransform(scaleX: size,y: size)).transformed(by: CGAffineTransform(translationX: px-4*size,y: py-60*size))
            result = arrow.composited(over: result)
        }
        if style.showCamera,let camera {
            var image = CIImage(cvPixelBuffer: camera)
            if style.mirrorCamera { image = image.transformed(by: CGAffineTransform(a: -1,b: 0,c: 0,d: 1,tx: image.extent.width,ty: 0)) }
            let side = Double(min(width,height))*style.cameraSize
            let cx = min(Double(width)-side/2-8,max(side/2+8,Double(width)*style.cameraPosition.x))
            let cy = Double(height)-min(Double(height)-side/2-8,max(side/2+8,Double(height)*style.cameraPosition.y))
            let box = CGRect(x: cx-side/2,y: cy-side/2,width: side,height: side)
            let fit = max(side/image.extent.width,side/image.extent.height)
            image = image.transformed(by: CGAffineTransform(scaleX: fit,y: fit)).transformed(by: CGAffineTransform(translationX: box.midX-image.extent.width*fit/2,y: box.midY-image.extent.height*fit/2)).cropped(to: box)
            let border = CIFilter(name: "CIRoundedRectangleGenerator",parameters: ["inputExtent":CIVector(cgRect: box.insetBy(dx: -1,dy: -1)),"inputRadius":side/2+1,"inputColor":CIColor.white])!.outputImage!
            let mask = CIFilter(name: "CIRoundedRectangleGenerator",parameters: ["inputExtent":CIVector(cgRect: box),"inputRadius":side/2,"inputColor":CIColor.white])!.outputImage!
            result = border.composited(over: result)
            result = image.applyingFilter("CIBlendWithAlphaMask",parameters: [kCIInputBackgroundImageKey:result,kCIInputMaskImageKey:mask])
        }
        context.render(result.cropped(to: canvas),to: output,bounds: canvas,colorSpace: colorSpace)
    }
}
