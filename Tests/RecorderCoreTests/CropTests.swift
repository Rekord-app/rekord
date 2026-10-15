import Foundation
import CoreGraphics
import CoreVideo
import RecorderCore

/// 16:9 crop of a taller Mac display: menu bar and Dock leave the frame, the screen fills a borderless 16:9 video.
func testCrop() {
    let preset = CropRect.preset(.widescreenWithoutMenuBar,sourceWidth: 2940,sourceHeight: 1912)!
    XCTAssertEqual(preset.y,CropRect.menuBarShare,accuracy: 0.0001)
    XCTAssertEqual(preset.height*1912/9*16,2940,accuracy: 1)
    let centred = CropRect.preset(.widescreenCentered,sourceWidth: 2940,sourceHeight: 1912)!
    XCTAssertEqual(centred.y,(1-centred.height)/2,accuracy: 0.0001)
    XCTAssertNil(CropRect.preset(.widescreenCentered,sourceWidth: 1920,sourceHeight: 1080))
    let wide = CropRect.preset(.widescreenCentered,sourceWidth: 3440,sourceHeight: 1440)!
    XCTAssertEqual(wide.width*3440/16*9,1440,accuracy: 1)

    // Automatic 16:9 only for displays a bit taller than 16:9 (MacBooks), never for 16:9, ultrawide or portrait.
    let air = CropRect.automaticWidescreen(sourceWidth: 2940,sourceHeight: 1912,menuBar: 37.0/956)!
    XCTAssertEqual(air.y,37.0/956,accuracy: 0.0001); XCTAssertEqual(air.height*1912/9*16,2940,accuracy: 1)
    precondition(air.matchingPreset(sourceWidth: 2940,sourceHeight: 1912) == .widescreenWithoutMenuBar)
    precondition(centred.matchingPreset(sourceWidth: 2940,sourceHeight: 1912) == .widescreenCentered)
    precondition(CropRect.automaticWidescreen(sourceWidth: 2880,sourceHeight: 1800) != nil)   // 16:10
    for (w,h) in [(1920,1080),(3440,1440),(1080,1920),(1600,1200)] { XCTAssertNil(CropRect.automaticWidescreen(sourceWidth: w,sourceHeight: h)) }

    // Source: red menu bar (top 3 %), green content, blue Dock (bottom 9 %).
    let w = 1470, h = 956
    let ctx = CGContext(data: nil,width: w,height: h,bitsPerComponent: 8,bytesPerRow: w*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 0.1,green: 0.8,blue: 0.2,alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: w,height: h))
    ctx.setFillColor(CGColor(red: 0.9,green: 0.1,blue: 0.1,alpha: 1)); ctx.fill(CGRect(x: 0,y: Double(h)*0.97,width: Double(w),height: Double(h)*0.03))
    ctx.setFillColor(CGColor(red: 0.1,green: 0.1,blue: 0.9,alpha: 1)); ctx.fill(CGRect(x: 0,y: 0,width: Double(w),height: Double(h)*0.09))
    let source = ctx.makeImage()!
    var project = Project(name: "Crop",duration: 2,width: w,height: h)
    project.style.showCamera = false; project.style.padding = 0; project.style.cornerRadius = 0; project.style.shadow = 0
    project.style.crop = CropRect.preset(.widescreenWithoutMenuBar,sourceWidth: w,sourceHeight: h)
    project.pointer = [PointerSample(time: 0,position: Point(0.5,0.02)),PointerSample(time: 1,position: Point(0.5,0.5))]
    project.style.showCursor = false
    let image = FrameRenderer(project: project).image(screen: source,camera: nil,time: 0.5,width: 1920,height: 1080)!
    for (x,y) in [(2,2),(1917,2),(2,1077),(1917,1077),(960,540)] {
        let p = pixel(image,x,y)
        precondition(p[1] > 180 && p[0] < 60 && p[2] < 80,"Crop must show only content edge to edge, got \(p) at \(x),\(y)")
    }
    let view = project.applyingCrop()
    precondition(view.pointer[0].visible == false && view.pointer[1].visible,"Pointer in the cropped menu bar must be hidden")
    XCTAssertEqual(Double(view.width)/Double(view.height),16.0/9.0,accuracy: 0.01)
    var old = project; old.style.crop = nil
    precondition((try? JSONDecoder().decode(Project.self,from: JSONEncoder().encode(old))) != nil)
    print("PASS: crop presets (menu bar/Dock, centred, ultrawide), borderless 16:9 output, pointer remap")
}

/// Rename to Rekord: old project folders still count as projects, paths in the old recordings folder map to the new one.
func testRenameMigration() {
    precondition(ProjectFolder.isProject(URL(fileURLWithPath: "/x/Aufnahme.rekord")) && ProjectFolder.isProject(URL(fileURLWithPath: "/x/Alt.focusrec")))
    precondition(!ProjectFolder.isProject(URL(fileURLWithPath: "/x/clip.mov")))
    let old = RecordingsFolder.legacy.path+"/Aufnahme 1.focusrec"
    precondition(RecordingsFolder.migratedPath(old) == RecordingsFolder.current.path+"/Aufnahme 1.focusrec")
    precondition(RecordingsFolder.migratedPath("/tmp/a.focusrec") == "/tmp/a.focusrec")
    precondition(RecordingsFolder.migratedPath(RecordingsFolder.legacy.path+" Backup/x.focusrec").hasPrefix(RecordingsFolder.legacy.path),"Only paths inside the old folder move")
    print("PASS: rename migration (.rekord/.focusrec projects, recordings folder paths)")
}
