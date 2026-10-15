import Foundation
import CoreImage
import CoreGraphics
import CoreVideo
import RecorderCore

func testLoomRenderer() throws {
    let space = CGColorSpace(name: CGColorSpace.sRGB)!, ci = CIContext()
    func buffer(_ width: Int,_ height: Int) -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        precondition(CVPixelBufferCreate(nil,width,height,kCVPixelFormatType_32BGRA,[kCVPixelBufferIOSurfacePropertiesKey as String:[:]] as CFDictionary,&buffer) == kCVReturnSuccess)
        return buffer!
    }
    func image(_ buffer: CVPixelBuffer) -> CGImage {
        let input = CIImage(cvPixelBuffer: buffer)
        return ci.createCGImage(input,from: input.extent,format: .RGBA8,colorSpace: space)!
    }
    let source = buffer(640,360), camera = buffer(320,180), output = buffer(640,360)
    let top = CIImage(color: CIColor(red: 0.9,green: 0.1,blue: 0.05)).cropped(to: CGRect(x: 0,y: 180,width: 640,height: 180))
    let bottom = CIImage(color: CIColor(red: 0.05,green: 0.1,blue: 0.9)).cropped(to: CGRect(x: 0,y: 0,width: 640,height: 180))
    ci.render(top.composited(over: bottom),to: source,bounds: CGRect(x: 0,y: 0,width: 640,height: 360),colorSpace: space)
    ci.render(CIImage(color: CIColor(red: 0.05,green: 0.85,blue: 0.12)),to: camera,bounds: CGRect(x: 0,y: 0,width: 320,height: 180),colorSpace: space)
    var style = Style(); style.showCursor = false; style.showCamera = false
    let renderer = LoomFrameRenderer(width: 640,height: 360)
    renderer.render(to: output,screen: source,camera: nil,pointer: nil,style: style)
    let baseline = image(output), original = image(source)
    for y in [20,300] {
        let a = pixel(baseline,100,y), b = pixel(original,100,y)
        precondition(zip(a,b).allSatisfy { abs(Int($0)-Int($1)) < 4 },"Loom must preserve orientation and colors")
    }
    style.showCamera = true
    renderer.render(to: output,screen: source,camera: camera,pointer: nil,style: style)
    let overlay = image(output)
    precondition(pixel(overlay,537,291)[1] > 190,"Camera must appear at top-left-normalized position")
    precondition(pixel(overlay,497,251)[1] < 100,"Circular camera corners must remain transparent")
    style.showCamera = false; style.showCursor = true
    renderer.render(to: output,screen: source,camera: nil,pointer: .center,style: style)
    precondition(pixel(image(output),322,183) != pixel(baseline,322,183),"GPU cursor must be visible")
    // MacBook display (1.54:1) with menu bar (red) and Dock (blue): the auto crop fills 16:9 with no gradient bars.
    let mac = buffer(1470,956)
    let content = CIImage(color: CIColor(red: 0.1,green: 0.8,blue: 0.2)).cropped(to: CGRect(x: 0,y: 0,width: 1470,height: 956))
    let menu = CIImage(color: CIColor(red: 0.9,green: 0.1,blue: 0.1)).cropped(to: CGRect(x: 0,y: 956-37,width: 1470,height: 37))
    let dock = CIImage(color: CIColor(red: 0.1,green: 0.1,blue: 0.9)).cropped(to: CGRect(x: 0,y: 0,width: 1470,height: 80))
    ci.render(menu.composited(over: dock.composited(over: content)),to: mac,bounds: CGRect(x: 0,y: 0,width: 1470,height: 956),colorSpace: space)
    var macStyle = Style(); macStyle.showCursor = false; macStyle.showCamera = false
    macStyle.crop = CropRect.automaticWidescreen(sourceWidth: 1470,sourceHeight: 956,menuBar: 37.0/956)
    renderer.render(to: output,screen: mac,camera: nil,pointer: nil,style: macStyle)
    let cropped = image(output)
    for (x,y) in [(0,0),(639,0),(0,359),(639,359),(320,180)] {
        let p = pixel(cropped,x,y)
        precondition(p[1] > 180 && p[0] < 60 && p[2] < 80,"Loom auto 16:9 must be full-bleed content, got \(p) at \(x),\(y)")
    }
    style.showCamera = true
    let full = buffer(1920,1080), fullRenderer = LoomFrameRenderer()
    for _ in 0..<3 { fullRenderer.render(to: full,screen: source,camera: camera,pointer: .center,style: style) }
    let started = Date()
    for _ in 0..<60 { fullRenderer.render(to: full,screen: source,camera: camera,pointer: .center,style: style) }
    let duration = Date().timeIntervalSince(started)
    precondition(duration < 2,"Loom 1080p renderer must sustain at least 30 fps on the acceptance machine")
    print(String(format:"PASS: GPU Loom orientation/camera/cursor; 1080p composition %.0f fps",60/duration))
}
