import Foundation
import CoreGraphics
import ImageIO
import RecorderCore

/// Studio wallpapers: deterministic, no banding (grain dithers every smooth area), centre kept clear by the vignette,
/// and the renderer uses them for presets while custom backdrops still win.
func testBackgroundArt() {
    for background in Background.allCases where background.isStudio {
        let art = background.art!
        let a = art.image(width: 640,height: 360)!, b = art.image(width: 640,height: 360)!
        if let dir = ProcessInfo.processInfo.environment["ART_DUMP"] {
            let d = CGImageDestinationCreateWithURL(URL(fileURLWithPath: "\(dir)/\(background.rawValue).png") as CFURL,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(d,a,nil); _ = CGImageDestinationFinalize(d)
        }
        precondition(pixel(a,100,100) == pixel(b,100,100) && pixel(a,500,300) == pixel(b,500,300),"\(background) must render deterministically")
        // Grain: neighbouring pixels in a smooth area differ slightly, never strongly.
        let row = (200..<260).map { Int(pixel(a,$0,180)[1]) }
        let steps = zip(row,row.dropFirst()).map { abs($0-$1) }
        precondition(steps.contains { $0 > 0 } && steps.max()! < 24,"\(background) grain must dither without noise blotches: \(steps)")
        precondition(background.palette.count >= 2 && !background.title.isEmpty)
    }
    var project = Project(name: "Art",duration: 1,width: 1920,height: 1080)
    project.style.background = .nightStudio; project.style.showCursor = false; project.style.showCamera = false
    let screen = CGContext(data: nil,width: 64,height: 36,bitsPerComponent: 8,bytesPerRow: 256,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!.makeImage()!
    let studio = FrameRenderer(project: project).image(screen: screen,camera: nil,time: 0,width: 1920,height: 1080)!
    let expected = BackgroundArtCache.image(.nightStudio,width: 1920,height: 1080)!
    precondition(zip(pixel(studio,6,6),pixel(expected,6,6)).allSatisfy { abs(Int($0)-Int($1)) <= 2 },"Renderer must draw the studio wallpaper")
    var solid = BackdropSettings(kind: .solid); solid.start = RGB(1,0,0); project.style.backdrop = solid
    precondition(pixel(FrameRenderer(project: project).image(screen: screen,camera: nil,time: 0,width: 1920,height: 1080)!,6,6)[0] > 240,"Custom backdrop overrides the preset")
    print("PASS: studio wallpapers deterministic, grain-dithered, drawn by the renderer; custom backdrops still win")
}

/// `--background-sheet <dir> <screen.png>`: every studio wallpaper with a real screen frame at 1080p.
func dumpBackgroundSheet(to directory: URL,screen: URL) throws {
    try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true)
    let source = CGImageSourceCreateWithURL(screen as CFURL,nil).flatMap { CGImageSourceCreateImageAtIndex($0,0,nil) }!
    for background in Background.allCases where background.isStudio {
        var project = Project(name: "Sheet",duration: 1,width: source.width,height: source.height)
        project.style.background = background; project.style.showCursor = false; project.style.showCamera = false
        project.style.crop = CropRect.automaticWidescreen(sourceWidth: source.width,sourceHeight: source.height)
        let frame = FrameRenderer(project: project).image(screen: source,camera: nil,time: 0,width: 1920,height: 1080)!
        let url = directory.appendingPathComponent("\(Background.allCases.firstIndex(of: background)!)-\(background.rawValue).png")
        let destination = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
        CGImageDestinationAddImage(destination,frame,nil); precondition(CGImageDestinationFinalize(destination))
    }
}
