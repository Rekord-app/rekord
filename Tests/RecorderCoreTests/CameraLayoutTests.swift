import Foundation
import CoreGraphics
import RecorderCore

/// Camera layouts: spring in and out, segments starting at 0 apply instantly, and the renderer places
/// fullscreen camera, split panel (screen left, camera right) and hidden camera as specified.
func testCameraLayouts() {
    let segments = [CameraLayoutSegment(start: 0,end: 2,layout: .fullscreen),CameraLayoutSegment(start: 4,end: 6,layout: .split)]
    precondition(Motion.cameraLayout(at: 0,segments: segments)?.layout == .fullscreen && Motion.cameraLayout(at: 0,segments: segments)!.amount > 0.99,"A layout from 0 s applies instantly")
    precondition(Motion.cameraLayout(at: 3.9,segments: segments) == nil,"Between segments the camera floats")
    let entering = Motion.cameraLayout(at: 4.1,segments: segments)!
    precondition(entering.layout == .split && entering.amount > 0.05 && entering.amount < 0.9,"Layouts spring in")
    precondition(Motion.cameraLayout(at: 5.5,segments: segments)!.amount > 0.99)
    precondition((Motion.cameraLayout(at: 6.2,segments: segments)?.amount ?? 0) < 0.9,"Layouts spring out after the end")

    func solid(_ w: Int,_ h: Int,_ r: CGFloat,_ g: CGFloat,_ b: CGFloat) -> CGImage {
        let ctx = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: r,green: g,blue: b,alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: w,height: h)); return ctx.makeImage()!
    }
    let screen = solid(1920,1080,0.1,0.8,0.2), camera = solid(640,480,0.9,0.1,0.1)
    var project = Project(name: "Layouts",duration: 9,width: 1920,height: 1080)
    project.hasCamera = true; project.style.showCursor = false
    func frame(_ layouts: [CameraLayoutSegment],at t: Double) -> CGImage {
        var p = project; p.cameraLayouts = layouts
        return FrameRenderer(project: p).image(screen: screen,camera: camera,time: t,width: 1920,height: 1080)!
    }
    let isRed = { (p: [UInt8]) in p[0] > 180 && p[1] < 60 }, isGreen = { (p: [UInt8]) in p[1] > 160 && p[0] < 60 }
    let full = frame([CameraLayoutSegment(start: 0,end: 5,layout: .fullscreen)],at: 1)
    precondition([(20,20),(960,540),(1900,1060)].allSatisfy { isRed(pixel(full,$0.0,$0.1)) },"Fullscreen camera covers the canvas")
    let split = frame([CameraLayoutSegment(start: 0,end: 5,layout: .split)],at: 1)
    precondition(isGreen(pixel(split,560,540)) && isRed(pixel(split,1600,540)),"Split: screen left, camera right")
    precondition(!isRed(pixel(split,560,540)) && !isGreen(pixel(split,1600,540)))
    let floating = frame([],at: 1), hidden = frame([CameraLayoutSegment(start: 0,end: 5,layout: .hidden)],at: 1)
    let bubble = (Int(1920*project.style.cameraPosition.x),Int(1080*project.style.cameraPosition.y))
    precondition(isRed(pixel(floating,bubble.0,bubble.1)) && !isRed(pixel(hidden,bubble.0,bubble.1)),"Hidden layout removes the floating camera")
    var portrait = project; portrait.style.format = .portrait; portrait.cameraLayouts = [CameraLayoutSegment(start: 0,end: 5,layout: .split)]
    let stacked = FrameRenderer(project: portrait).image(screen: screen,camera: camera,time: 1,width: 1080,height: 1920)!
    precondition(isRed(pixel(stacked,540,1550)) && isGreen(pixel(stacked,540,600)),"Portrait split stacks screen over camera")
    print("PASS: camera layouts spring in/out; fullscreen, split (landscape + portrait) and hidden placement")
}
