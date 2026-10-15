import AppKit
import CoreImage
// Rekord app icon, rendered once as a 1024 px master (with film grain on the tile) and downscaled for every size.
// Usage: swift scripts/make-icon.swift <dir.iconset> [hardware|pulse|signal] && iconutil -c icns <dir.iconset> -o Resources/AppIcon.icns
let destination = CommandLine.arguments[1]
let variant = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "hardware"
try FileManager.default.createDirectory(atPath: destination,withIntermediateDirectories: true)
let space = CGColorSpace(name: CGColorSpace.sRGB)!
func color(_ r: Double,_ g: Double,_ b: Double,_ a: Double = 1) -> CGColor { CGColor(colorSpace: space,components: [r,g,b,a])! }
func gradient(_ stops: [(Double,CGColor)]) -> CGGradient {
    CGGradient(colorsSpace: space,colors: stops.map(\.1) as CFArray,locations: stops.map { CGFloat($0.0) })!
}
/// macOS-style continuous-corner tile.
func squircle(_ rect: CGRect) -> CGPath {
    let path = CGMutablePath(), a = rect.width/2, b = rect.height/2, n = 5.0
    for i in 0..<720 {
        let t = Double(i)/720*2*Double.pi, c = cos(t), s = sin(t)
        let p = CGPoint(x: rect.midX+a*(c < 0 ? -1 : 1)*pow(abs(c),2/n),y: rect.midY+b*(s < 0 ? -1 : 1)*pow(abs(s),2/n))
        if i == 0 { path.move(to: p) } else { path.addLine(to: p) }
    }
    path.closeSubpath(); return path
}
func circle(_ r: Double,_ c: CGPoint = CGPoint(x: 512,y: 512)) -> CGRect { CGRect(x: c.x-r,y: c.y-r,width: 2*r,height: 2*r) }
let centre = CGPoint(x: 512,y: 512)
let tile = CGRect(x: 100,y: 100,width: 824,height: 824), shape = squircle(tile)

/// Red glass record dot: deep body, light falling in from the top left, warm bounce light at the bottom,
/// crisp crescent highlight and a soft bloom around it.
func drawDot(_ ctx: CGContext,radius r: Double,bloom: Double) {
    let rect = circle(r)
    ctx.saveGState(); ctx.setShadow(offset: .zero,blur: bloom,color: color(1,0.12,0.2,0.9))
    ctx.setFillColor(color(0.9,0.08,0.16)); ctx.fillEllipse(in: rect); ctx.restoreGState()
    ctx.saveGState(); ctx.addEllipse(in: rect); ctx.clip()
    ctx.drawRadialGradient(gradient([(0,color(1,0.42,0.42)),(0.45,color(0.97,0.12,0.2)),(1,color(0.52,0.0,0.07))]),
                           startCenter: CGPoint(x: 512-r*0.3,y: 512+r*0.35),startRadius: 0,endCenter: centre,endRadius: r*1.08,options: [.drawsAfterEndLocation])
    // Bounce light inside the lower rim.
    ctx.drawRadialGradient(gradient([(0,color(1,0.45,0.35,0.55)),(1,color(1,0.45,0.35,0))]),
                           startCenter: CGPoint(x: 512,y: 512-r*0.95),startRadius: 0,endCenter: CGPoint(x: 512,y: 512-r*0.95),endRadius: r*0.75,options: [])
    // Thin dark rim for definition.
    ctx.restoreGState()
    ctx.setStrokeColor(color(0.35,0,0.05,0.6)); ctx.setLineWidth(r*0.025); ctx.strokeEllipse(in: rect.insetBy(dx: r*0.0125,dy: r*0.0125))
    // Crescent highlight: an ellipse in the upper half, fading downwards.
    ctx.saveGState(); ctx.addEllipse(in: rect); ctx.clip()
    let hl = CGRect(x: 512-r*0.62,y: 512+r*0.12,width: r*1.24,height: r*0.8)
    ctx.addEllipse(in: hl); ctx.clip()
    ctx.drawLinearGradient(gradient([(0,color(1,1,1,0.62)),(1,color(1,1,1,0))]),start: CGPoint(x: 512,y: hl.maxY),end: CGPoint(x: 512,y: hl.minY+r*0.12),options: [])
    ctx.restoreGState()
}
/// Tile with drop shadow, body gradient, top edge highlight.
func drawTile(_ ctx: CGContext,top: CGColor,bottom: CGColor,edge: Double = 0.22) {
    ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0,height: -16),blur: 34,color: color(0,0,0,0.5))
    ctx.addPath(shape); ctx.setFillColor(bottom); ctx.fillPath(); ctx.restoreGState()
    ctx.saveGState(); ctx.addPath(shape); ctx.clip()
    ctx.drawLinearGradient(gradient([(0,top),(1,bottom)]),start: CGPoint(x: 512,y: 924),end: CGPoint(x: 512,y: 100),options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
    ctx.restoreGState()
    // Edge light: bright along the top, invisible at the bottom.
    ctx.saveGState(); ctx.addPath(shape); ctx.setLineWidth(5); ctx.replacePathWithStrokedPath(); ctx.clip()
    ctx.drawLinearGradient(gradient([(0,color(1,1,1,edge)),(0.5,color(1,1,1,0.03)),(1,color(1,1,1,0.06))]),start: CGPoint(x: 512,y: 924),end: CGPoint(x: 512,y: 100),options: [])
    ctx.restoreGState()
}

func render() -> CGImage {
    let ctx = CGContext(data: nil,width: 1024,height: 1024,bitsPerComponent: 16,bytesPerRow: 0,space: space,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    switch variant {
    case "pulse":
        // Live: black tile, red light spilling from the dot, broadcast rings.
        drawTile(ctx,top: color(0.1,0.09,0.1),bottom: color(0.02,0.02,0.03))
        ctx.saveGState(); ctx.addPath(shape); ctx.clip()
        ctx.drawRadialGradient(gradient([(0,color(1,0.1,0.2,0.32)),(1,color(1,0.1,0.2,0))]),startCenter: centre,startRadius: 0,endCenter: centre,endRadius: 420,options: [])
        for (r,a) in [(238.0,0.5),(310.0,0.26),(382.0,0.12)] {
            ctx.setStrokeColor(color(1,0.25,0.3,a)); ctx.setLineWidth(7); ctx.strokeEllipse(in: circle(r))
        }
        ctx.restoreGState()
        drawDot(ctx,radius: 160,bloom: 80)
    case "signal":
        // Bold: crimson tile, white machined ring, red dot – reads instantly on light and dark Docks.
        drawTile(ctx,top: color(1,0.33,0.36),bottom: color(0.7,0.04,0.14),edge: 0.45)
        ctx.saveGState(); ctx.addPath(shape); ctx.clip()
        ctx.drawRadialGradient(gradient([(0,color(1,0.75,0.6,0.35)),(1,color(1,0.75,0.6,0))]),startCenter: CGPoint(x: 300,y: 860),startRadius: 0,endCenter: CGPoint(x: 300,y: 860),endRadius: 600,options: [])
        ctx.restoreGState()
        ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0,height: -10),blur: 26,color: color(0.35,0,0.06,0.55))
        ctx.setFillColor(color(1,1,1)); ctx.fillEllipse(in: circle(250)); ctx.restoreGState()
        ctx.saveGState(); ctx.addEllipse(in: circle(250)); ctx.clip()
        ctx.drawLinearGradient(gradient([(0,color(1,1,1)),(1,color(0.86,0.87,0.9))]),start: CGPoint(x: 512,y: 762),end: CGPoint(x: 512,y: 262),options: [])
        ctx.restoreGState()
        ctx.setFillColor(color(0.2,0.02,0.05,0.25)); ctx.fillEllipse(in: circle(196))
        drawDot(ctx,radius: 186,bloom: 18)
    default:
        // Hardware: graphite tile, machined aluminium bezel, recessed glass record button.
        drawTile(ctx,top: color(0.22,0.22,0.25),bottom: color(0.06,0.06,0.08))
        ctx.saveGState(); ctx.addPath(shape); ctx.clip()
        ctx.drawRadialGradient(gradient([(0,color(1,0.1,0.2,0.22)),(1,color(1,0.1,0.2,0))]),startCenter: centre,startRadius: 0,endCenter: centre,endRadius: 380,options: [])
        ctx.restoreGState()
        // Bezel: conic metal with a dark outer groove and a bright inner chamfer.
        ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0,height: -12),blur: 24,color: color(0,0,0,0.6))
        ctx.setFillColor(color(0.5,0.5,0.53)); ctx.fillEllipse(in: circle(262)); ctx.restoreGState()
        ctx.saveGState(); ctx.addEllipse(in: circle(262)); ctx.clip()
        // Conic metal: brightness around the ring, drawn as thin wedges.
        let stops: [(Double,Double)] = [(0,0.93),(0.18,0.45),(0.36,0.84),(0.52,0.36),(0.7,0.9),(0.86,0.42),(1,0.93)]
        for i in 0..<720 {
            let t = Double(i)/720, a0 = t*2*Double.pi+Double.pi/4, a1 = a0+2*Double.pi/720*1.6
            let j = stops.lastIndex { $0.0 <= t } ?? 0, k = min(j+1,stops.count-1)
            let f = stops[k].0 > stops[j].0 ? (t-stops[j].0)/(stops[k].0-stops[j].0) : 0
            let v = stops[j].1+(stops[k].1-stops[j].1)*(0.5-0.5*cos(f*Double.pi))
            ctx.move(to: centre); ctx.addArc(center: centre,radius: 270,startAngle: a0,endAngle: a1,clockwise: false); ctx.closePath()
            ctx.setFillColor(color(v,v,v*1.02+0.01)); ctx.fillPath()
        }
        ctx.restoreGState()
        ctx.setStrokeColor(color(0,0,0,0.45)); ctx.setLineWidth(4); ctx.strokeEllipse(in: circle(260))
        // Recess the button sits in.
        ctx.saveGState(); ctx.addEllipse(in: circle(214)); ctx.clip()
        ctx.drawLinearGradient(gradient([(0,color(0.01,0.01,0.02)),(1,color(0.14,0.14,0.16))]),start: CGPoint(x: 512,y: 726),end: CGPoint(x: 512,y: 298),options: [])
        ctx.restoreGState()
        ctx.setStrokeColor(color(1,1,1,0.35)); ctx.setLineWidth(3); ctx.strokeEllipse(in: circle(216))
        drawDot(ctx,radius: 178,bloom: 36)
    }
    return ctx.makeImage()!
}

// Fine grain on the master (only visible at large sizes; keeps gradients from banding).
var master = CIImage(cgImage: render())
if let noise = CIFilter(name: "CIRandomGenerator")?.outputImage {
    let grain = noise.cropped(to: master.extent).applyingFilter("CIColorMatrix",parameters: [
        "inputRVector": CIVector(x: 0.035,y: 0,z: 0,w: 0),"inputGVector": CIVector(x: 0.035,y: 0,z: 0,w: 0),"inputBVector": CIVector(x: 0.035,y: 0,z: 0,w: 0),
        "inputAVector": CIVector(x: 0,y: 0,z: 0,w: 0),"inputBiasVector": CIVector(x: -0.0175,y: -0.0175,z: -0.0175,w: 0)])
    // Grain only where the icon is opaque.
    let masked = grain.applyingFilter("CIBlendWithAlphaMask",parameters: [kCIInputBackgroundImageKey: CIImage.empty(),kCIInputMaskImageKey: master])
    master = masked.applyingFilter("CIAdditionCompositing",parameters: [kCIInputBackgroundImageKey: master])
}
let ci = CIContext(options: [.workingColorSpace: space,.workingFormat: CIFormat.RGBAh])
for (points,scale) in [(16,1),(16,2),(32,1),(32,2),(128,1),(128,2),(256,1),(256,2),(512,1),(512,2)] {
    let size = points*scale, factor = Double(size)/1024
    let scaled = factor == 1 ? master : master.applyingFilter("CILanczosScaleTransform",parameters: [kCIInputScaleKey: factor,kCIInputAspectRatioKey: 1])
    let image = ci.createCGImage(scaled,from: CGRect(x: 0,y: 0,width: size,height: size),format: .RGBA8,colorSpace: space)!
    let name = "icon_\(points)x\(points)\(scale == 2 ? "@2x" : "").png"
    try NSBitmapImageRep(cgImage: image).representation(using: .png,properties: [:])!.write(to: URL(fileURLWithPath: destination).appendingPathComponent(name))
}
