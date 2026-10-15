import Foundation
import CoreGraphics
import CoreVideo
import CoreImage

public struct FrameLayout {
    public let canvas: CGRect
    public let screen: CGRect
    public init(width: Int, height: Int, sourceWidth: Int, sourceHeight: Int, padding: Double) {
        canvas = CGRect(x: 0, y: 0, width: width, height: height)
        let available = canvas.insetBy(dx: Double(min(width,height))*padding, dy: Double(min(width,height))*padding)
        let fit = min(available.width/Double(max(1,sourceWidth)), available.height/Double(max(1,sourceHeight)))
        let w = Double(sourceWidth)*fit, h = Double(sourceHeight)*fit
        screen = CGRect(x: (Double(width)-w)/2, y: (Double(height)-h)/2, width: w, height: h)
    }
}
public final class FrameRenderer: @unchecked Sendable {
    public let project: Project
    /// The project after cropping; all drawing uses this view.
    private let view: Project
    public let motion: MotionTrack
    private let ci = CIContext(options: [.cacheIntermediates: false])
    private let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
    private let backgroundImage: CGImage?
    private let baseLock = NSLock()
    private var baseCache: (width: Int,height: Int,layers: Layers)?
    public init(project: Project,backgroundImage: CGImage? = nil) {
        self.project = project
        view = project.applyingCrop()
        motion = MotionTrack(samples: view.pointer, smoothing: view.style.smoothing)
        if let backgroundImage,let backdrop = view.style.backdrop,backdrop.blur > 0 {
            let source = CIImage(cgImage: backgroundImage)
            let blurred = source.clampedToExtent().applyingFilter("CIGaussianBlur",parameters: [kCIInputRadiusKey: backdrop.blur*Double(min(backgroundImage.width,backgroundImage.height))]).cropped(to: source.extent)
            self.backgroundImage = CIContext(options: [.cacheIntermediates:false]).createCGImage(blurred,from: source.extent)
        } else { self.backgroundImage = backgroundImage }
    }
    /// Wraps a decoded frame without copying. Recordings are captured in sRGB, so pixel
    /// values pass through unchanged; other formats fall back to a Core Image conversion.
    public func cgImage(from buffer: CVPixelBuffer) -> CGImage? {
        guard CVPixelBufferGetPixelFormatType(buffer) == kCVPixelFormatType_32BGRA, !CVPixelBufferIsPlanar(buffer),
              CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else {
            let image = CIImage(cvPixelBuffer: buffer)
            return ci.createCGImage(image, from: image.extent, format: .BGRA8, colorSpace: colorSpace)
        }
        guard let base = CVPixelBufferGetBaseAddress(buffer) else { CVPixelBufferUnlockBaseAddress(buffer, .readOnly); return nil }
        let width = CVPixelBufferGetWidth(buffer), height = CVPixelBufferGetHeight(buffer), stride = CVPixelBufferGetBytesPerRow(buffer)
        let retained = Unmanaged.passRetained(buffer).toOpaque()
        guard let provider = CGDataProvider(dataInfo: retained, data: base, size: stride*height, releaseData: { info, _, _ in
            guard let info else { return }
            let buffer = Unmanaged<CVPixelBuffer>.fromOpaque(info).takeRetainedValue()
            CVPixelBufferUnlockBaseAddress(buffer, .readOnly)
        }) else { Unmanaged<CVPixelBuffer>.fromOpaque(retained).release(); CVPixelBufferUnlockBaseAddress(buffer, .readOnly); return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: stride, space: colorSpace,
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
    /// The recorded frame limited to the project's crop (a view onto the same pixels, no copy).
    private func cropped(_ screen: CGImage) -> CGImage {
        guard let crop = project.style.crop else { return screen }
        let rect = CGRect(x: crop.x*Double(screen.width),y: crop.y*Double(screen.height),width: crop.width*Double(screen.width),height: crop.height*Double(screen.height)).integral
        return screen.cropping(to: rect) ?? screen
    }
    public func image(screen: CGImage, camera: CGImage?, time: Double, width: Int, height: Int) -> CGImage? {
        let screen = cropped(screen)
        guard let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        draw(in: ctx, screen: screen, camera: camera, time: time, width: width, height: height)
        return ctx.makeImage()
    }
    public func render(to buffer: CVPixelBuffer, screen: CGImage, camera: CGImage?, time: Double) -> Bool {
        let screen = cropped(screen)
        let w = CVPixelBufferGetWidth(buffer), h = CVPixelBufferGetHeight(buffer)
        // Motion-blurred frames are composed on the GPU straight into the output buffer; pointer and camera follow on the CPU.
        var precomposed = false
        if let composite = blurredComposite(screen: screen,time: time,width: w,height: h) {
            ci.render(composite,to: buffer,bounds: CGRect(x: 0,y: 0,width: w,height: h),colorSpace: colorSpace)
            precomposed = true
        }
        CVPixelBufferLockBaseAddress(buffer, []); defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let ctx = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: w, height: h, bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: colorSpace, bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue) else { return false }
        draw(in: ctx, screen: screen, camera: camera, time: time, width: w, height: h, precomposed: precomposed)
        return true
    }
    /// Background plus the shutter-averaged card as one Core Image graph, or nil when the frame has no card motion.
    private func blurredComposite(screen: CGImage,time: Double,width: Int,height: Int) -> CIImage? {
        let layout = FrameLayout(width: width, height: height, sourceWidth: view.width, sourceHeight: view.height, padding: view.style.padding)
        let state = Motion.camera(at: time, zooms: view.zooms, pointer: motion)
        guard let shutter = motionBlurSamples(time: time,rect: layout.screen,state: state,canvas: CGSize(width: width,height: height)),
              let layers = cachedLayers(width: width,height: height) else { return nil }
        let canvasSize = CGSize(width: width,height: height)
        let drawn = cardRect(layout.screen,state,time: time,canvas: canvasSize), targets = shutter.map { cardRect(layout.screen,$0.state ?? state,time: $0.time,canvas: canvasSize) }
        // Once the blur spans several pixels, a half-resolution card is indistinguishable and 4× cheaper to draw.
        let travel = max(hypot(targets.first!.minX-targets.last!.minX,targets.first!.minY-targets.last!.minY),hypot(targets.first!.maxX-targets.last!.maxX,targets.first!.maxY-targets.last!.maxY))
        let detail = travel > 6 ? 0.5 : 1.0
        let w = Int((Double(width)*detail).rounded()), h = Int((Double(height)*detail).rounded())
        guard let cardContext = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w*4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        cardContext.translateBy(x: 0, y: Double(h)); cardContext.scaleBy(x: detail, y: -detail)
        drawCard(in: cardContext,image: screen,layers: layers,rect: layout.screen,drawn: drawn,state: state,unit: Double(min(width,height)),forceZoomed: true)
        guard let still = cardContext.makeImage(),
              let card = averagedCard(CIImage(cgImage: still).transformed(by: CGAffineTransform(scaleX: Double(width)/Double(w),y: Double(height)/Double(h))),from: drawn,to: targets,height: Double(height)) else { return nil }
        return card.composited(over: CIImage(cgImage: layers.background)).cropped(to: layout.canvas)
    }
    private func draw(in ctx: CGContext, screen image: CGImage, camera: CGImage?, time: Double, width: Int, height: Int, precomposed: Bool = false) {
        let style = view.style
        let layout = FrameLayout(width: width, height: height, sourceWidth: view.width, sourceHeight: view.height, padding: style.padding)
        let canvas = layout.canvas, rect = layout.screen
        let unit = Double(min(width,height))
        ctx.saveGState(); defer { ctx.restoreGState() }
        let state = Motion.camera(at: time, zooms: view.zooms, pointer: motion)
        let canvasSize = CGSize(width: width,height: height)
        let drawn = cardRect(rect,state,time: time,canvas: canvasSize)
        let factor = drawn.width/rect.width
        let layers = cachedLayers(width: width,height: height)
        let shutter = motionBlurSamples(time: time,rect: rect,state: state,canvas: canvasSize)
        if let shutter {
            // Motion blur: average the moving card over the shutter interval on the GPU; background stays sharp.
            if !precomposed, let composite = blurredComposite(screen: image,time: time,width: width,height: height),
               let frame = ci.createCGImage(composite,from: canvas,format: .RGBA8,colorSpace: colorSpace) {
                ctx.draw(frame,in: canvas)
            }
            ctx.translateBy(x: 0, y: Double(height)); ctx.scaleBy(x: 1, y: -1)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: drawn,cornerWidth: unit*style.cornerRadius*factor,cornerHeight: unit*style.cornerRadius*factor,transform: nil)); ctx.clip()
            drawPointer(in: ctx,time: time,rect: rect,drawn: drawn,state: state,unit: unit,shutter: shutter,canvas: canvasSize)
            ctx.restoreGState()
        } else {
            // At rest, background, shadow and frame fill are one cached image. While zoomed, the whole card
            // (frame, rounded corners, shadow) scales and moves over the static background like a camera move.
            let zoomed = !Self.same(drawn,rect)
            if let base = zoomed ? layers?.background : layers?.base { ctx.draw(base,in: canvas) }
            ctx.translateBy(x: 0, y: Double(height)); ctx.scaleBy(x: 1, y: -1)
            drawCard(in: ctx,image: image,layers: layers,rect: rect,drawn: drawn,state: state,unit: unit,forceZoomed: false)
            ctx.saveGState()
            ctx.addPath(CGPath(roundedRect: zoomed ? drawn : rect,cornerWidth: unit*style.cornerRadius*(zoomed ? factor : 1),cornerHeight: unit*style.cornerRadius*(zoomed ? factor : 1),transform: nil)); ctx.clip()
            drawPointer(in: ctx,time: time,rect: rect,drawn: drawn,state: state,unit: unit,shutter: nil,canvas: canvasSize)
            ctx.restoreGState()
        }
        if style.showCamera, let camera {
            let shapeKind = style.cameraShape ?? (view.recordingMode == .loom ? .circle : .rounded)
            // Proportions: circles stay round; other shapes follow the chosen aspect at the same area.
            let ratio = shapeKind == .circle ? 1 : (style.cameraAspect ?? .square).ratio
            let full = unit*style.cameraSize, baseW = full*sqrt(ratio), baseH = full/sqrt(ratio)
            // While zoomed the camera resizes (default: shrinks to 70 % at 2× and above), following the zoom spring
            // and staying anchored to its corner.
            let zoomState = Motion.camera(at: time, zooms: view.zooms, pointer: motion)
            let resize = 1+((style.cameraZoomScale ?? Style.defaultCameraZoomScale)-1)*min(1,max(0,zoomState.scale-1))
            let w = baseW*resize, h = baseH*resize, margin = unit*0.025
            let cx = min(Double(width)-baseW/2-margin,max(baseW/2+margin,style.cameraPosition.x*Double(width)))
            let cy = min(Double(height)-baseH/2-margin,max(baseH/2+margin,style.cameraPosition.y*Double(height)))
            let anchorX = min(Double(width)-w-margin,max(margin,style.cameraPosition.x >= 0.5 ? cx+baseW/2-w : cx-baseW/2))
            let anchorY = min(Double(height)-h-margin,max(margin,style.cameraPosition.y >= 0.5 ? cy+baseH/2-h : cy-baseH/2))
            var box = CGRect(x: anchorX,y: anchorY,width: w,height: h)
            var shape = shapeKind.path(in: box)
            var alpha = 1.0, shadow = 0.38
            // Camera layouts: spring between the floating overlay and full screen / split panel / hidden.
            if let layout = Motion.cameraLayout(at: time,segments: view.cameraLayouts ?? []) {
                let a = layout.amount
                let target: CGRect
                switch layout.layout {
                case .fullscreen: target = canvas; shadow *= 1-a
                case .split: target = splitTargets(canvas: canvasSize,rect: rect).camera
                case .hidden: target = box.insetBy(dx: box.width*0.08,dy: box.height*0.08); alpha = 1-a
                }
                box = CGRect(x: box.minX+(target.minX-box.minX)*a,y: box.minY+(target.minY-box.minY)*a,width: box.width+(target.width-box.width)*a,height: box.height+(target.height-box.height)*a)
                let short = min(box.width,box.height)
                let startRadius = shapeKind == .circle ? short/2 : short*(shapeKind == .rounded ? 0.3 : 0.09)
                let endRadius = layout.layout == .fullscreen ? 0 : (layout.layout == .split ? unit*max(0.02,style.cornerRadius) : startRadius)
                let radius = min(short/2,startRadius+(endRadius-startRadius)*a)
                if a > 0.002 { shape = CGPath(roundedRect: box,cornerWidth: radius,cornerHeight: radius,transform: nil) }
            }
            if alpha > 0.01 {
                // A transparency layer (whole-canvas buffer) only while fading; opaque frames draw directly.
                let fading = alpha < 0.999
                ctx.saveGState(); if fading { ctx.setAlpha(alpha); ctx.beginTransparencyLayer(auxiliaryInfo: nil) }
                // Soft, wide shadow; no frame unless chosen.
                if shadow > 0.01 { ctx.saveGState(); ctx.setShadow(offset: CGSize(width: 0,height: unit*0.012), blur: unit*0.05, color: color(0,0,0,shadow)); ctx.addPath(shape); ctx.setFillColor(color(0.08,0.08,0.09)); ctx.fillPath(); ctx.restoreGState() }
                ctx.saveGState(); ctx.addPath(shape); ctx.clip()
                let fit = max(box.width/Double(camera.width),box.height/Double(camera.height))
                let cr = CGRect(x: box.midX-Double(camera.width)*fit/2,y: box.midY-Double(camera.height)*fit/2,width: Double(camera.width)*fit,height: Double(camera.height)*fit)
                if style.mirrorCamera { ctx.translateBy(x: box.midX*2,y: 0); ctx.scaleBy(x: -1,y: 1) }
                drawImage(camera, rect: cr, in: ctx); ctx.restoreGState()
                if style.cameraBorder == true { ctx.addPath(shape); ctx.setStrokeColor(color(1,1,1,0.9)); ctx.setLineWidth(unit*0.003); ctx.strokePath() }
                if fading { ctx.endTransparencyLayer() }; ctx.restoreGState()
            }
        }
        _ = canvas
    }
    static func same(_ a: CGRect,_ b: CGRect) -> Bool { abs(a.minX-b.minX) < 0.01 && abs(a.minY-b.minY) < 0.01 && abs(a.width-b.width) < 0.01 && abs(a.height-b.height) < 0.01 }
    /// Where the window card is drawn at `time`: zoomed around the camera centre, then — in a split camera layout —
    /// scaled and moved beside the camera panel (springing in and out).
    private func cardRect(_ rect: CGRect,_ state: CameraState,time: Double,canvas: CGSize) -> CGRect {
        let zoomed = CGRect(x: rect.midX-state.center.x*rect.width*state.scale, y: rect.midY-state.center.y*rect.height*state.scale, width: rect.width*state.scale, height: rect.height*state.scale)
        guard view.hasCamera, view.style.showCamera, let layout = Motion.cameraLayout(at: time,segments: view.cameraLayouts ?? []), layout.layout == .split else { return zoomed }
        let target = splitTargets(canvas: canvas,rect: rect).card, a = layout.amount
        let k = 1+(target.width/rect.width-1)*a
        let cx = rect.midX+(target.midX-rect.midX)*a, cy = rect.midY+(target.midY-rect.midY)*a
        return CGRect(x: cx+(zoomed.minX-rect.midX)*k,y: cy+(zoomed.minY-rect.midY)*k,width: zoomed.width*k,height: zoomed.height*k)
    }
    /// Split layout: camera panel on the right (landscape canvas) or at the bottom (portrait), screen fitted beside it.
    private func splitTargets(canvas: CGSize,rect: CGRect) -> (card: CGRect,camera: CGRect) {
        let unit = Double(min(canvas.width,canvas.height)), margin = unit*max(0.045,view.style.padding)
        let area: CGRect, camera: CGRect
        if canvas.width >= canvas.height {
            let panel = canvas.width*0.36
            camera = CGRect(x: canvas.width-panel,y: margin,width: panel-margin,height: canvas.height-margin*2)
            area = CGRect(x: margin,y: margin,width: canvas.width-panel-margin*2,height: canvas.height-margin*2)
        } else {
            let panel = canvas.height*0.42
            camera = CGRect(x: margin,y: canvas.height-panel,width: canvas.width-margin*2,height: panel-margin)
            area = CGRect(x: margin,y: margin,width: canvas.width-margin*2,height: canvas.height-panel-margin*2)
        }
        let fit = min(area.width/rect.width,area.height/rect.height)
        let size = CGSize(width: rect.width*fit,height: rect.height*fit)
        return (CGRect(x: area.midX-size.width/2,y: area.midY-size.height/2,width: size.width,height: size.height),camera)
    }
    /// Card sprite (when zoomed) and the clipped screen content. Pointer and camera are drawn separately.
    private func drawCard(in ctx: CGContext,image: CGImage,layers: Layers?,rect: CGRect,drawn: CGRect,state: CameraState,unit: Double,forceZoomed: Bool) {
        let s = drawn.width/rect.width
        let zoomed = forceZoomed || !Self.same(drawn,rect)
        if zoomed, let card = layers?.card, let crop = layers?.cardRect {
            drawImage(card,rect: CGRect(x: drawn.minX+(crop.minX-rect.minX)*s,y: drawn.minY+(crop.minY-rect.minY)*s,width: crop.width*s,height: crop.height*s),in: ctx)
        }
        let radius = unit*view.style.cornerRadius*(zoomed ? s : 1)
        ctx.saveGState(); ctx.addPath(CGPath(roundedRect: zoomed ? drawn : rect, cornerWidth: radius, cornerHeight: radius, transform: nil)); ctx.clip()
        drawImage(image, rect: drawn, in: ctx)
        ctx.restoreGState()
    }
    private func drawPointer(in ctx: CGContext,time: Double,rect: CGRect,drawn: CGRect,state: CameraState,unit: Double,shutter: Shutter?,canvas: CGSize) {
        let style = view.style
        guard style.showCursor, let sample = motion.sample(at: time), sample.visible else { return }
        let factor = drawn.width/rect.width
        drawClickEffect(in: ctx,time: time,drawn: drawn,factor: factor,unit: unit)
        func position(_ t: Double,_ s: CameraState) -> (CGPoint,Double)? {
            guard let sample = motion.sample(at: t) else { return nil }
            let d = cardRect(rect,s,time: t,canvas: canvas)
            return (CGPoint(x: d.minX+sample.position.x*d.width, y: d.minY+sample.position.y*d.height),unit*0.028*style.cursorSize*d.width/rect.width)
        }
        let p = CGPoint(x: drawn.minX+sample.position.x*drawn.width, y: drawn.minY+sample.position.y*drawn.height)
        let samples = (shutter ?? cursorShutter(time: time)).compactMap { sample in position(sample.time,sample.state ?? state).map { ($0.0,$0.1,cursorAngle(at: sample.time)) } }
        guard samples.count > 1, let first = samples.first, let last = samples.last, hypot(first.0.x-last.0.x,first.0.y-last.0.y) > unit*0.002 else {
            drawCursor(at: p, size: unit*0.028*style.cursorSize*factor, angle: cursorAngle(at: time), in: ctx); return
        }
        // Average the cursor over the shutter: additive copies at 1/n in a transparency layer.
        ctx.saveGState(); ctx.beginTransparencyLayer(auxiliaryInfo: nil)
        ctx.setBlendMode(.plusLighter); ctx.setAlpha(1/Double(samples.count))
        for (point,size,angle) in samples { drawCursor(at: point,size: size,angle: angle,in: ctx) }
        ctx.endTransparencyLayer(); ctx.restoreGState()
    }
    typealias Shutter = [(time: Double,state: CameraState?)]
    /// Shutter of the virtual camera: `motionBlur` 1.0 equals a 360° shutter at 60 fps (1/60 s).
    private var shutterDuration: Double { (view.style.motionBlur ?? Style.defaultMotionBlur)/60 }
    private func shutterTimes(_ time: Double,count: Int) -> [Double] {
        (0..<count).map { time+shutterDuration*(Double($0)/Double(count-1)-0.5) }
    }
    /// Camera states across the shutter when the card moves visibly within it, otherwise nil (sharp frame).
    private func motionBlurSamples(time: Double,rect: CGRect,state: CameraState,canvas: CGSize) -> Shutter? {
        guard shutterDuration > 0, !(view.zooms.isEmpty && (view.cameraLayouts ?? []).isEmpty) else { return nil }
        let half = shutterDuration/2
        let a = cardRect(rect,Motion.camera(at: time-half,zooms: view.zooms,pointer: motion),time: time-half,canvas: canvas)
        let b = cardRect(rect,Motion.camera(at: time+half,zooms: view.zooms,pointer: motion),time: time+half,canvas: canvas)
        let travel = max(hypot(a.minX-b.minX,a.minY-b.minY),hypot(a.maxX-b.maxX,a.maxY-b.maxY))
        guard travel > 0.75 else { return nil }
        let count = min(16,max(3,Int((travel/1.5).rounded(.up))))
        return shutterTimes(time,count: count).map { ($0,Motion.camera(at: $0,zooms: view.zooms,pointer: motion)) }
    }
    /// Cursor-only motion blur on frames where the card is still.
    private func cursorShutter(time: Double) -> Shutter {
        guard shutterDuration > 0, let a = motion.sample(at: time-shutterDuration/2), let b = motion.sample(at: time+shutterDuration/2) else { return [] }
        let travel = hypot(a.position.x-b.position.x,a.position.y-b.position.y)*Double(max(view.width,view.height))
        guard travel > 2 else { return [] }
        return shutterTimes(time,count: min(12,max(3,Int((travel/3).rounded(.up))))).map { ($0,nil) }
    }
    /// Averages the card layer over the shutter in linear light on the GPU. Each sample is the same rendered card
    /// moved by the similarity transform between its camera state and the frame's; content is static within 1/60 s.
    private func averagedCard(_ source: CIImage,from drawn: CGRect,to targets: [CGRect],height: Double) -> CIImage? {
        guard !targets.isEmpty else { return nil }
        let weight = 1/Double(targets.count)
        var accumulated: CIImage?
        for target in targets {
            let s = target.width/drawn.width
            // Flipped (top-left) mapping q -> target.origin + (q - drawn.origin)*s, expressed in Core Image's y-up space.
            let bx = target.minX-drawn.minX*s, by = target.minY-drawn.minY*s
            let transform = CGAffineTransform(a: s,b: 0,c: 0,d: s,tx: bx,ty: height*(1-s)-by)
            // CIColorMatrix works on unpremultiplied colour: scaling alpha alone weights the premultiplied sample by 1/n.
            let sample = source.transformed(by: transform).applyingFilter("CIColorMatrix",parameters: [
                "inputAVector": CIVector(x: 0,y: 0,z: 0,w: weight)])
            accumulated = accumulated.map { sample.applyingFilter("CIAdditionCompositing",parameters: [kCIInputBackgroundImageKey: $0]) } ?? sample
        }
        return accumulated?.cropped(to: source.extent)
    }
    struct Layers { let base: CGImage; let background: CGImage; let card: CGImage?; let cardRect: CGRect }
    /// Static per output size: background alone, background with the card at rest, and the card (fill + shadow)
    /// as a sprite cropped around its resting rectangle for zoomed frames.
    private func cachedLayers(width: Int,height: Int) -> Layers? {
        baseLock.lock(); defer { baseLock.unlock() }
        if let cached = baseCache, cached.width == width, cached.height == height { return cached.layers }
        let style = view.style
        let layout = FrameLayout(width: width, height: height, sourceWidth: view.width, sourceHeight: view.height, padding: style.padding)
        let unit = Double(min(width,height))
        func context() -> CGContext? {
            let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: width*4, space: colorSpace, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
            ctx?.translateBy(x: 0, y: Double(height)); ctx?.scaleBy(x: 1, y: -1)
            return ctx
        }
        func drawCard(_ ctx: CGContext) {
            let path = CGPath(roundedRect: layout.screen, cornerWidth: unit*style.cornerRadius, cornerHeight: unit*style.cornerRadius, transform: nil)
            ctx.setShadow(offset: CGSize(width: 0,height: unit*0.018), blur: unit*0.045, color: color(0,0,0,style.shadow))
            ctx.addPath(path); ctx.setFillColor(color(0.05,0.05,0.07)); ctx.fillPath()
        }
        guard let background = context(), let base = context(), let card = context() else { return nil }
        drawBackground(in: background,canvas: layout.canvas)
        drawBackground(in: base,canvas: layout.canvas); drawCard(base)
        drawCard(card)
        let margin = (unit*0.12).rounded(.up)
        let cardRect = layout.screen.insetBy(dx: -margin,dy: -margin).integral.intersection(layout.canvas)
        guard let backgroundImage = background.makeImage(), let baseImage = base.makeImage() else { return nil }
        let layers = Layers(base: baseImage,background: backgroundImage,card: card.makeImage()?.cropping(to: cardRect),cardRect: cardRect)
        baseCache = (width,height,layers)
        return layers
    }
    private func drawBackground(in ctx: CGContext,canvas: CGRect) {
        if let backdrop = view.style.backdrop {
            if backdrop.kind == .solid {
                ctx.setFillColor(backdrop.start.cgColor); ctx.fill(canvas); return
            }
            if backdrop.kind == .image,let image = backgroundImage {
                let scale = max(canvas.width/Double(image.width),canvas.height/Double(image.height))
                drawImage(image,rect: CGRect(x: canvas.midX-Double(image.width)*scale/2,y: canvas.midY-Double(image.height)*scale/2,width: Double(image.width)*scale,height: Double(image.height)*scale),in: ctx)
                return
            }
        }
        if view.style.backdrop == nil, let art = BackgroundArtCache.image(view.style.background,width: Int(canvas.width.rounded()),height: Int(canvas.height.rounded())) {
            drawImage(art,rect: canvas,in: ctx); return
        }
        let backdrop = view.style.backdrop
        let colors = backdrop?.kind == .gradient ? [backdrop!.start.cgColor,backdrop!.end.cgColor] : view.style.background.palette.map { $0.cgColor }
        let gradient = CGGradient(colorsSpace: colorSpace,colors: colors as CFArray,locations: nil)!
        var start = CGPoint.zero,end = CGPoint(x: canvas.width,y: canvas.height)
        if let backdrop,backdrop.kind == .gradient {
            let angle = backdrop.angle * .pi / 180,dx = cos(angle),dy = sin(angle)
            let extent = (abs(canvas.width*dx)+abs(canvas.height*dy))/2
            start = CGPoint(x: canvas.midX-dx*extent,y: canvas.midY-dy*extent)
            end = CGPoint(x: canvas.midX+dx*extent,y: canvas.midY+dy*extent)
        }
        ctx.drawLinearGradient(gradient,start: start,end: end,options: [.drawsBeforeStartLocation,.drawsAfterEndLocation])
    }
    private func drawImage(_ image: CGImage, rect: CGRect, in ctx: CGContext) {
        ctx.saveGState(); ctx.translateBy(x: rect.minX,y: rect.maxY); ctx.scaleBy(x: 1,y: -1)
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(origin: .zero,size: rect.size)); ctx.restoreGState()
    }
    /// Lean of the cursor into horizontal movement: like an object hanging from its tip, the body trails behind.
    /// Bounded with tanh so fast swipes saturate smoothly (max 0.5 rad × tilt).
    private func cursorAngle(at time: Double) -> Double {
        let tilt = view.style.cursorTilt ?? Style.defaultCursorTilt
        guard tilt > 0, let a = motion.sample(at: time-1.0/60), let b = motion.sample(at: time+1.0/60) else { return 0 }
        let widthsPerSecond = (b.position.x-a.position.x)*30*Double(view.width)/Double(max(view.width,view.height))
        return 0.5*tilt*tanh(widthsPerSecond/1.2)
    }
    private func drawClickEffect(in ctx: CGContext,time: Double,drawn: CGRect,factor: Double,unit: Double) {
        let effect = view.style.clickEffect ?? .ring
        let lifetime = effect == .pulse ? 0.3 : 0.4
        guard effect != .none, view.recordingMode == .studio,
              let click = view.pointer.last(where: { $0.clicked && $0.visible && $0.time <= time && time-$0.time < lifetime }) else { return }
        let age = time-click.time, progress = age/lifetime
        let cp = CGPoint(x: drawn.minX+click.position.x*drawn.width, y: drawn.minY+click.position.y*drawn.height)
        switch effect {
        case .ring:
            let r = unit*(0.012+progress*0.022)*factor
            ctx.setStrokeColor(color(1,1,1,(1-progress)*0.8)); ctx.setLineWidth(unit*0.003)
            ctx.strokeEllipse(in: CGRect(x: cp.x-r,y: cp.y-r,width: r*2,height: r*2))
        case .pulse:
            // A soft disc that springs open and fades: fast in, gone by 80 % of its life.
            let grow = 0.2+2.8*Motion.spring(age,40)
            let alpha = 0.55*(progress < 0.05 ? progress/0.05 : max(0,(0.8-progress)/0.75))
            let r = unit*0.0085*view.style.cursorSize*factor*grow
            let disc = CGRect(x: cp.x-r,y: cp.y-r,width: r*2,height: r*2)
            ctx.setFillColor(color(1,1,1,alpha)); ctx.fillEllipse(in: disc)
            ctx.setStrokeColor(color(0,0,0,alpha*0.45)); ctx.setLineWidth(unit*0.0012*factor); ctx.strokeEllipse(in: disc)
        case .none: break
        }
    }
    private func drawCursor(at p: CGPoint, size: Double, angle: Double = 0, in ctx: CGContext) {
        ctx.saveGState(); ctx.translateBy(x: p.x,y: p.y); ctx.rotate(by: angle); ctx.scaleBy(x: size,y: size)
        let path = CGMutablePath(); path.move(to: .zero)
        // Original arrow polygon; no system or third-party cursor artwork.
        for point in [CGPoint(x: 0.08,y: 1), CGPoint(x: 0.32,y: 0.74), CGPoint(x: 0.53,y: 1.14), CGPoint(x: 0.72,y: 1.04), CGPoint(x: 0.51,y: 0.64), CGPoint(x: 0.87,y: 0.59)] { path.addLine(to: point) }
        path.closeSubpath(); ctx.setShadow(offset: CGSize(width: 0.04,height: 0.06), blur: 0.12, color: color(0,0,0,0.5))
        ctx.addPath(path); ctx.setFillColor(color(1,1,1)); ctx.setStrokeColor(color(0.08,0.09,0.12)); ctx.setLineWidth(0.06); ctx.drawPath(using: .fillStroke)
        ctx.restoreGState()
    }
    private func color(_ r: Double,_ g: Double,_ b: Double,_ a: Double = 1) -> CGColor { CGColor(colorSpace: colorSpace, components: [r,g,b,a])! }
}
