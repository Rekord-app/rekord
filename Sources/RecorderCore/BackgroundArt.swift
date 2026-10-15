import Foundation
import CoreGraphics
import CoreImage

/// Procedural studio wallpaper: a base colour lit by soft glows, optional silky light ribbons, a vignette and fine
/// film grain. The colour field is painted in float precision at low resolution (it has no detail), upscaled, and
/// grain is added before 8-bit quantisation, so the large smooth areas never band — neither on screen nor after
/// YouTube's re-encode. Deterministic: preview and export get identical pixels.
public struct BackgroundArt: Sendable {
    /// Soft light: centre in normalized canvas coordinates (origin top-left, may lie outside), radius relative to
    /// the longer canvas side, strength 0…1.
    public struct Glow: Sendable {
        public var x, y, radius: Double
        public var color: RGB
        public var strength: Double
        public init(_ x: Double,_ y: Double,_ radius: Double,_ color: RGB,_ strength: Double) { self.x = x; self.y = y; self.radius = radius; self.color = color; self.strength = strength }
    }
    /// Light band sweeping across the canvas: centre line from left edge height `from` to right edge height `to`
    /// with an S-bend, thickness relative to the canvas height, colour fading along the band.
    public struct Ribbon: Sendable {
        public var from, to, bend, thickness: Double
        public var color: RGB
        public var fade: RGB
        public var strength: Double
        public init(from: Double,to: Double,bend: Double,thickness: Double,color: RGB,fade: RGB,strength: Double) {
            self.from = from; self.to = to; self.bend = bend; self.thickness = thickness; self.color = color; self.fade = fade; self.strength = strength
        }
    }
    public var base: RGB
    public var glows: [Glow]
    public var ribbons: [Ribbon] = []
    public var vignette = 0.3
    public var grain = 0.05
    public init(base: RGB,glows: [Glow],ribbons: [Ribbon] = [],vignette: Double = 0.3,grain: Double = 0.05) {
        self.base = base; self.glows = glows; self.ribbons = ribbons; self.vignette = vignette; self.grain = grain
    }
    /// Colours for swatches and as the start of a custom gradient.
    public var palette: [RGB] { [base]+glows.sorted { $0.strength > $1.strength }.prefix(2).map(\.color) }

    private static let space = CGColorSpace(name: CGColorSpace.sRGB)!
    private static let context = CIContext(options: [.workingColorSpace: space,.workingFormat: CIFormat.RGBAh,.cacheIntermediates: false])

    /// Renders the wallpaper at the given pixel size.
    public func image(width: Int,height: Int) -> CGImage? {
        guard width > 0, height > 0 else { return nil }
        // 1. Colour field, low resolution, float.
        let long = 720.0, scale = long/Double(max(width,height))
        let fw = max(8,Int((Double(width)*scale).rounded())), fh = max(8,Int((Double(height)*scale).rounded()))
        guard let field = CGContext(data: nil,width: fw,height: fh,bitsPerComponent: 32,bytesPerRow: 0,space: Self.space,
                                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.floatComponents.rawValue | CGBitmapInfo.byteOrder32Little.rawValue) else { return nil }
        let w = Double(fw), h = Double(fh), side = max(w,h)
        field.setFillColor(base.cgColor); field.fill(CGRect(x: 0,y: 0,width: w,height: h))
        for glow in glows { drawGlow(glow,in: field,w: w,h: h,side: side) }
        for ribbon in ribbons { drawRibbon(ribbon,in: field,w: w,h: h) }
        if vignette > 0 { drawVignette(in: field,w: w,h: h) }
        guard let fieldImage = field.makeImage() else { return nil }
        // 2. Silky blur and upscale to the output size.
        let canvas = CGRect(x: 0,y: 0,width: width,height: height)
        var image = CIImage(cgImage: fieldImage).clampedToExtent()
            .applyingGaussianBlur(sigma: side*0.012)
            .transformed(by: CGAffineTransform(scaleX: Double(width)/w,y: Double(height)/h))
        // 3. Film grain: zero-mean luminance noise added before quantisation, sized like 1080p grain at any resolution.
        if grain > 0, let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
            let grainScale = max(1,Double(height)/1080), amount = grain*0.6
            let mono = noise
                .applyingFilter("CIColorClamp",parameters: ["inputMinComponents": CIVector(x: 0,y: 0,z: 0,w: 0),"inputMaxComponents": CIVector(x: 1,y: 1,z: 1,w: 1)])
                .transformed(by: CGAffineTransform(scaleX: grainScale,y: grainScale))
                .applyingFilter("CIColorMatrix",parameters: [
                    "inputRVector": CIVector(x: amount,y: 0,z: 0,w: 0),"inputGVector": CIVector(x: amount,y: 0,z: 0,w: 0),
                    "inputBVector": CIVector(x: amount,y: 0,z: 0,w: 0),"inputAVector": CIVector(x: 0,y: 0,z: 0,w: 0),
                    "inputBiasVector": CIVector(x: -amount/2,y: -amount/2,z: -amount/2,w: 0)])
            image = mono.applyingFilter("CIAdditionCompositing",parameters: [kCIInputBackgroundImageKey: image])
        }
        return Self.context.createCGImage(image.cropped(to: canvas),from: canvas,format: .RGBA8,colorSpace: Self.space)
    }
    private func drawGlow(_ glow: Glow,in ctx: CGContext,w: Double,h: Double,side: Double) {
        // Gaussian falloff approximated with many stops: no visible rim, unlike a linear radial gradient.
        let stops = 16
        var colors: [CGColor] = [], locations: [CGFloat] = []
        for i in 0...stops {
            let t = Double(i)/Double(stops)
            let alpha = i == stops ? 0 : glow.strength*exp(-4.2*t*t)
            colors.append(CGColor(colorSpace: Self.space,components: [glow.color.red,glow.color.green,glow.color.blue,alpha])!)
            locations.append(t)
        }
        guard let gradient = CGGradient(colorsSpace: Self.space,colors: colors as CFArray,locations: locations) else { return }
        // Wide ellipses read as a soft mesh; circles read as spots.
        ctx.saveGState(); ctx.translateBy(x: glow.x*w,y: (1-glow.y)*h); ctx.scaleBy(x: 1.6,y: 1)
        ctx.drawRadialGradient(gradient,startCenter: .zero,startRadius: 0,endCenter: .zero,endRadius: glow.radius*side,options: [])
        ctx.restoreGState()
    }
    private func drawRibbon(_ ribbon: Ribbon,in ctx: CGContext,w: Double,h: Double) {
        // Centre line as a cubic from beyond the left edge to beyond the right edge; the band tapers at both ends.
        func point(_ t: Double,_ offset: Double) -> CGPoint {
            let p0 = (-0.1,ribbon.from), p3 = (1.1,ribbon.to)
            let p1 = (0.3,ribbon.from+ribbon.bend), p2 = (0.7,ribbon.to-ribbon.bend)
            let u = 1-t
            let x = u*u*u*p0.0+3*u*u*t*p1.0+3*u*t*t*p2.0+t*t*t*p3.0
            let y = u*u*u*p0.1+3*u*u*t*p1.1+3*u*t*t*p2.1+t*t*t*p3.1
            let taper = 0.35+0.65*sin(.pi*t)
            return CGPoint(x: x*w,y: (1-(y+offset*taper))*h)
        }
        let path = CGMutablePath(), n = 64, half = ribbon.thickness/2
        path.move(to: point(0,-half))
        for i in 1...n { path.addLine(to: point(Double(i)/Double(n),-half)) }
        for i in stride(from: n,through: 0,by: -1) { path.addLine(to: point(Double(i)/Double(n),half)) }
        path.closeSubpath()
        let colors = [CGColor(colorSpace: Self.space,components: [ribbon.color.red,ribbon.color.green,ribbon.color.blue,ribbon.strength])!,
                      CGColor(colorSpace: Self.space,components: [ribbon.fade.red,ribbon.fade.green,ribbon.fade.blue,ribbon.strength*0.15])!]
        guard let gradient = CGGradient(colorsSpace: Self.space,colors: colors as CFArray,locations: [0,1]) else { return }
        ctx.saveGState(); ctx.addPath(path); ctx.clip()
        ctx.drawLinearGradient(gradient,start: CGPoint(x: 0,y: (1-ribbon.from)*h),end: CGPoint(x: w,y: (1-ribbon.to)*h),options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
        ctx.restoreGState()
    }
    private func drawVignette(in ctx: CGContext,w: Double,h: Double) {
        // Elliptical: darkens the corners, keeps the centre (where the screen sits) untouched.
        let alphas: [CGFloat] = [0,0,CGFloat(vignette*0.55),CGFloat(vignette)]
        let colors = alphas.map { CGColor(colorSpace: Self.space,components: [0,0,0,$0])! }
        guard let gradient = CGGradient(colorsSpace: Self.space,colors: colors as CFArray,locations: [0,0.45,0.8,1]) else { return }
        ctx.saveGState(); ctx.translateBy(x: w/2,y: h/2); ctx.scaleBy(x: w/2*1.42,y: h/2*1.42)
        ctx.drawRadialGradient(gradient,startCenter: .zero,startRadius: 0,endCenter: .zero,endRadius: 1,options: [.drawsAfterEndLocation])
        ctx.restoreGState()
    }
}

/// Rendered wallpapers by preset and size; rendering takes a few tens of milliseconds, frames reuse the result.
public enum BackgroundArtCache {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var images: [String:CGImage] = [:]
    nonisolated(unsafe) private static var order: [String] = []
    public static func image(_ background: Background,width: Int,height: Int) -> CGImage? {
        guard let art = background.art else { return nil }
        let key = "\(background.rawValue)-\(width)x\(height)"
        if let image = lock.withLock({ images[key] }) { return image }
        guard let image = art.image(width: width,height: height) else { return nil }
        lock.withLock {
            images[key] = image; order.append(key)
            while order.count > 12 { images.removeValue(forKey: order.removeFirst()) }
        }
        return image
    }
}
