import Foundation
import CoreGraphics
import RecorderCore
import ImageIO

/// Cursor tilt reacts only to movement; click effects are distinct and “Aus” draws nothing.
func testCursorStyling() {
    let screen = solidImage(red: 40,green: 40,blue: 48,width: 1600,height: 1000)
    var base = Project(name: "Cursor",duration: 3,width: 1600,height: 1000)
    base.style.showCamera = false; base.style.motionBlur = 0; base.style.cursorSize = 2.5
    func frame(_ configure: (inout Project) -> Void,time: Double) -> CGImage {
        var p = base; configure(&p)
        return FrameRenderer(project: p).image(screen: screen,camera: nil,time: time,width: 960,height: 600)!
    }
    func same(_ a: CGImage,_ b: CGImage) -> Bool { (a.dataProvider!.data! as Data) == (b.dataProvider!.data! as Data) }
    let resting: (inout Project) -> Void = { $0.pointer = [PointerSample(time: 0,position: .center),PointerSample(time: 3,position: .center)] }
    let swiping: (inout Project) -> Void = { $0.pointer = (0...180).map { PointerSample(time: Double($0)/60,position: Point(0.1+Double($0)/180*0.8,0.5)) } }
    precondition(same(frame({ resting(&$0); $0.style.cursorTilt = 0 },time: 1),frame({ resting(&$0); $0.style.cursorTilt = 1 },time: 1)),"A resting cursor must not tilt")
    precondition(!same(frame({ swiping(&$0); $0.style.cursorTilt = 0 },time: 1.5),frame({ swiping(&$0); $0.style.cursorTilt = 1 },time: 1.5)),"A fast cursor must tilt")
    let click: (inout Project) -> Void = { $0.pointer = [PointerSample(time: 0,position: .center),PointerSample(time: 1,position: .center,clicked: true),PointerSample(time: 3,position: .center)] }
    let ring = frame({ click(&$0); $0.style.clickEffect = .ring },time: 1.1)
    let pulse = frame({ click(&$0); $0.style.clickEffect = .pulse },time: 1.1)
    let none = frame({ click(&$0); $0.style.clickEffect = ClickEffect.none },time: 1.1)
    let noClick = frame(resting,time: 1.1)
    precondition(!same(ring,pulse) && !same(ring,none) && !same(pulse,none),"Click effects must look different")
    precondition(same(none,noClick),"“Aus” must draw no click feedback")
    precondition(same(frame({ click(&$0); $0.style.clickEffect = .pulse },time: 1.35),noClick),"Pulse must be gone after its lifetime")
    if let path = ProcessInfo.processInfo.environment["REKORD_CURSOR_SHEET"] {
        let fast: (inout Project) -> Void = { $0.pointer = (0...30).map { PointerSample(time: 1.25+Double($0)/60,position: Point(0.1+Double($0)/30*0.8,0.5)) } }
        let frames = [frame({ fast(&$0); $0.style.cursorTilt = 0 },time: 1.5),frame({ fast(&$0) },time: 1.5),frame({ fast(&$0); $0.style.cursorTilt = 1 },time: 1.5)]
            + [1.02,1.06,1.12,1.2].map { t in frame({ click(&$0); $0.style.clickEffect = .pulse },time: t) }
        let sheet = CGContext(data: nil,width: 240*frames.count,height: 150,bitsPerComponent: 8,bytesPerRow: 240*frames.count*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        for (i,f) in frames.enumerated() {
            let crop = f.cropping(to: i < 3 ? CGRect(x: 150,y: 270,width: 400,height: 90) : CGRect(x: 400,y: 240,width: 160,height: 100))!
            sheet.draw(crop,in: CGRect(x: i*240,y: 0,width: 240,height: 150))
        }
        let destination = CGImageDestinationCreateWithURL(URL(fileURLWithPath: path) as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,sheet.makeImage()!,nil); _ = CGImageDestinationFinalize(destination)
    }
    print("PASS: cursor tilt only while moving, ring/pulse/off click effects")
}
