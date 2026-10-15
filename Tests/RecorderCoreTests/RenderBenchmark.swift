import Foundation
import CoreGraphics
import CoreVideo
import RecorderCore

// Renderer regression and speed checks on realistic Retina-sized sources.
// `--render-dump <dir>` writes raw frames for a matrix of looks, so renderer
// optimisations can be compared byte-for-byte against the previous build.
// `--benchmark` prints per-frame cost of the export path (decode buffer → CGImage → render).

func makeSourceBuffer(width: Int,height: Int,seed: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String: [:],kCVPixelBufferCGImageCompatibilityKey as String: true,kCVPixelBufferCGBitmapContextCompatibilityKey as String: true] as CFDictionary,&buffer)
    let pixelBuffer = buffer!
    CVPixelBufferLockBaseAddress(pixelBuffer,[])
    let ctx = CGContext(data: CVPixelBufferGetBaseAddress(pixelBuffer),width: width,height: height,bitsPerComponent: 8,bytesPerRow: CVPixelBufferGetBytesPerRow(pixelBuffer),space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue|CGImageAlphaInfo.premultipliedFirst.rawValue)!
    ctx.setFillColor(CGColor(red: 0.96,green: 0.96,blue: 0.97,alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: width,height: height))
    for i in 0..<40 {
        let hue = Double((i*37+seed*11)%100)/100
        ctx.setFillColor(CGColor(red: hue,green: 1-hue,blue: 0.4+hue*0.5,alpha: 1))
        ctx.fill(CGRect(x: (i*97)%width,y: (i*61)%height,width: width/9,height: height/14))
    }
    CVPixelBufferUnlockBaseAddress(pixelBuffer,[])
    return pixelBuffer
}

func makeOutputBuffer(width: Int,height: Int) -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String: [:],kCVPixelBufferCGBitmapContextCompatibilityKey as String: true] as CFDictionary,&buffer)
    return buffer!
}

private func renderMatrix() -> [(String,Project,Double,CanvasFormat)] {
    var base = Project(name: "Matrix",duration: 4,width: 2940,height: 1912,fps: 60)
    base.pointer = (0..<240).map { (i: Int) -> PointerSample in
        let t = Double(i)
        let position = Point(0.2+t/400,0.3+0.2*sin(t/30))
        return PointerSample(time: t/60,position: position,clicked: i == 60)
    }
    base.zooms = Motion.automaticZooms(pointer: base.pointer,duration: base.duration)
    var cases: [(String,Project,Double,CanvasFormat)] = []
    for format in [CanvasFormat.landscape,.portrait] {
        for (name,configure) in [
            ("default",{ (_: inout Project) in }),
            ("solid",{ (p: inout Project) in var b = BackdropSettings(kind: .solid); b.start = RGB(0.12,0.5,0.8); p.style.backdrop = b }),
            ("gradient",{ (p: inout Project) in var b = BackdropSettings(kind: .gradient); b.angle = 35; p.style.backdrop = b; p.style.padding = 0.08; p.style.cornerRadius = 0.04; p.style.shadow = 0.9 }),
            ("flat",{ (p: inout Project) in p.style.padding = 0; p.style.cornerRadius = 0; p.style.shadow = 0 }),
            ("loom",{ (p: inout Project) in p.mode = .loom; p.style.padding = 0; p.style.cornerRadius = 0; p.style.shadow = 0; p.zooms = [] }),
        ] as [(String,(inout Project) -> Void)] {
            var project = base; project.style.format = format; project.style.showCamera = true; configure(&project)
            for time in [0.2,1.15,2.4] { cases.append(("\(format == .landscape ? "landscape" : "portrait")-\(name)-\(time)",project,time,format)) }
        }
    }
    return cases
}

func dumpRenderMatrix(to directory: URL) throws {
    try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
    let screen = makeSourceBuffer(width: 2940,height: 1912,seed: 1), camera = makeSourceBuffer(width: 1280,height: 720,seed: 2)
    for (name,project,time,format) in renderMatrix() {
        let renderer = FrameRenderer(project: project)
        let (w,h) = format.dimensions(height: 1080)
        let output = makeOutputBuffer(width: w,height: h)
        precondition(renderer.render(to: output,screen: renderer.cgImage(from: screen)!,camera: renderer.cgImage(from: camera),time: time))
        CVPixelBufferLockBaseAddress(output,.readOnly)
        let rowBytes = w*4, stride = CVPixelBufferGetBytesPerRow(output), base = CVPixelBufferGetBaseAddress(output)!
        var data = Data(capacity: rowBytes*h)
        for row in 0..<h { data.append(base.advanced(by: row*stride).assumingMemoryBound(to: UInt8.self),count: rowBytes) }
        CVPixelBufferUnlockBaseAddress(output,.readOnly)
        try data.write(to: directory.appendingPathComponent("\(name).raw"))
        let preview = renderer.image(screen: renderer.cgImage(from: screen)!,camera: renderer.cgImage(from: camera),time: time,width: w/2,height: h/2)!
        try (preview.dataProvider!.data! as Data).write(to: directory.appendingPathComponent("\(name)-image.raw"))
    }
    print("PASS: render matrix dumped to \(directory.path)")
}

func benchmarkRenderer() {
    let screens = (0..<4).map { makeSourceBuffer(width: 2940,height: 1912,seed: $0) }
    let camera = makeSourceBuffer(width: 1280,height: 720,seed: 9)
    var project = Project(name: "Bench",duration: 10,width: 2940,height: 1912,fps: 60)
    project.style.showCamera = true
    project.pointer = (0..<600).map { (i: Int) -> PointerSample in
        PointerSample(time: Double(i)/60,position: Point(0.3+Double(i)/2000,0.5),clicked: i % 120 == 10)
    }
    project.zooms = Motion.automaticZooms(pointer: project.pointer,duration: project.duration)
    let renderer = FrameRenderer(project: project)
    for (label,height) in [("1080p",1080),("4K",2160)] {
        let (w,h) = project.style.format.dimensions(height: height)
        let output = makeOutputBuffer(width: w,height: h)
        var frames = 0, convert = 0.0, draw = 0.0
        let clock = Date()
        while Date().timeIntervalSince(clock) < 2.5 {
            let t0 = Date()
            let screen = renderer.cgImage(from: screens[frames%screens.count])!, cam = renderer.cgImage(from: camera)
            let t1 = Date()
            _ = renderer.render(to: output,screen: screen,camera: cam,time: Double(frames%600)/60)
            draw += Date().timeIntervalSince(t1); convert += t1.timeIntervalSince(t0); frames += 1
        }
        print(String(format: "BENCH renderer %@: %.1f fps · convert %.2f ms · draw %.2f ms per frame (%d frames)",label,Double(frames)/(convert+draw),convert/Double(frames)*1000,draw/Double(frames)*1000,frames))
    }
}


/// Motion blur must only smear, never darken or brighten: compare a mid-zoom frame with and without blur.
func testMotionBlurPreservesBrightness() {
    var project = Project(name: "Blur",duration: 4,width: 1600,height: 1000,fps: 60)
    project.style.background = .lavender   // grain-free background: the edge metric measures only the card
    project.style.showCursor = false; project.style.showCamera = false
    project.zooms = [ZoomSegment(start: 0.5,end: 3,scale: 2,focus: Point(0.3,0.4),followsCursor: false)]
    let screen = makeSourceBuffer(width: 1600,height: 1000,seed: 3)
    func mean(_ blur: Double) -> (Double,Double) {
        var p = project; p.style.motionBlur = blur
        let renderer = FrameRenderer(project: p), output = makeOutputBuffer(width: 960,height: 540)
        precondition(renderer.render(to: output,screen: renderer.cgImage(from: screen)!,camera: nil,time: 0.62))
        CVPixelBufferLockBaseAddress(output,.readOnly); defer { CVPixelBufferUnlockBaseAddress(output,.readOnly) }
        let base = CVPixelBufferGetBaseAddress(output)!.assumingMemoryBound(to: UInt8.self), stride = CVPixelBufferGetBytesPerRow(output)
        var sum = 0.0, edges = 0.0
        for y in 0..<540 { for x in 0..<960 {
            let i = y*stride+x*4; sum += Double(base[i])+Double(base[i+1])+Double(base[i+2])
            if x > 0 { edges += abs(Double(base[i+1])-Double(base[i-3])) }
        } }
        return (sum/Double(960*540*3),edges/Double(960*540))
    }
    let sharp = mean(0), blurred = mean(0.5)
    precondition(abs(sharp.0-blurred.0) < 2.5,"Motion blur changed brightness: \(sharp.0) vs \(blurred.0)")
    precondition(blurred.1 < sharp.1*0.95,"Motion blur must soften edges during a zoom (\(sharp.1) vs \(blurred.1))")
    print(String(format: "PASS: motion blur keeps brightness (mean %.1f vs %.1f) and softens edges (%.2f vs %.2f)",sharp.0,blurred.0,sharp.1,blurred.1))
}
