import Foundation
import CoreGraphics
import ImageIO
import RecorderCore

func solidImage(red: UInt8, green: UInt8, blue: UInt8, width: Int = 160, height: Int = 90) -> CGImage {
    var bytes = [UInt8](repeating: 255,count: width*height*4)
    for i in stride(from: 0,to: bytes.count,by: 4) { bytes[i] = red; bytes[i+1] = green; bytes[i+2] = blue }
    return CGImage(width: width,height: height,bitsPerComponent: 8,bitsPerPixel: 32,bytesPerRow: width*4,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),provider: CGDataProvider(data: Data(bytes) as CFData)!,decode: nil,shouldInterpolate: false,intent: .defaultIntent)!
}
func pixel(_ image: CGImage, _ x: Int, _ y: Int) -> [UInt8] {
    let data = image.dataProvider!.data! as Data
    let i = y*image.bytesPerRow+x*4
    return Array(data[i..<i+4])
}
func testRenderer() throws {
    var p = Project(name: "Render",duration: 3,width: 160,height: 90)
    p.style.showCursor = false; p.style.showCamera = false
    let screen = solidImage(red: 230,green: 30,blue: 10)
    let renderer = FrameRenderer(project: p)
    let image = renderer.image(screen: screen,camera: nil,time: 0,width: 640,height: 360)!
    XCTAssertEqual(image.width,640); XCTAssertEqual(image.height,360)
    XCTAssertEqual(pixel(image,320,180)[0],230)
    precondition(pixel(image,0,0)[0] != 230, "Background must be visible")
    let layout = FrameLayout(width: 640,height: 360,sourceWidth: 160,sourceHeight: 90,padding: p.style.padding)
    precondition(pixel(image,Int(layout.screen.minX)+1,Int(layout.screen.minY)+1)[0] != 230,"Rounded corner must clip screen")
    p.style.showCamera = true
    let camera = solidImage(red: 10,green: 220,blue: 30)
    let overlay = FrameRenderer(project: p).image(screen: screen,camera: camera,time: 1,width: 640,height: 360)!
    XCTAssertEqual(pixel(overlay,Int(p.style.cameraPosition.x*640),Int(p.style.cameraPosition.y*360))[1],220)
    p.style.showCamera = false; p.style.showCursor = true
    p.pointer = [PointerSample(time: 0,position: .center)]
    let cursor = FrameRenderer(project: p).image(screen: screen,camera: nil,time: 1,width: 640,height: 360)!
    precondition(pixel(cursor,323,185) != pixel(image,323,185),"Cursor must be drawn")
    // Camera zoom must move the visible center towards the cursor, including edge clamping.
    p.style.showCursor = false
    p.pointer = [PointerSample(time: 0,position: Point(0.95,0.5))]
    p.zooms = [ZoomSegment(start: 0.25,end: 2.5)]
    let stripes = CGContext(data: nil,width: 300,height: 90,bitsPerComponent: 8,bytesPerRow: 1200,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    for (i,color) in [CGColor(red: 1,green: 0,blue: 0,alpha: 1),CGColor(red: 0,green: 1,blue: 0,alpha: 1),CGColor(red: 0,green: 0,blue: 1,alpha: 1)].enumerated() {
        stripes.setFillColor(color); stripes.fill(CGRect(x: i*100,y: 0,width: 100,height: 90))
    }
    let zoomRenderer = FrameRenderer(project: p), pattern = stripes.makeImage()!
    let neutral = zoomRenderer.image(screen: pattern,camera: nil,time: 0,width: 640,height: 360)!
    let zoomed = zoomRenderer.image(screen: pattern,camera: nil,time: 1,width: 640,height: 360)!
    precondition(pixel(neutral,320,180)[1] > 240,"Neutral center should be green")
    precondition(pixel(zoomed,320,180)[2] > 240,"Zoom must follow cursor into blue stripe")
    p.style.format = .portrait
    let portrait = FrameRenderer(project: p).image(screen: screen,camera: camera,time: 1,width: 360,height: 640)!
    XCTAssertEqual(portrait.width,360); XCTAssertEqual(portrait.height,640)
    var styled = Project(name: "Custom look",duration: 1,width: 160,height: 90)
    styled.style.showCursor = false; styled.style.padding = 0.15; styled.style.shadow = 0
    var backdrop = BackdropSettings(kind: .solid); backdrop.start = RGB(0.1,0.7,0.8); styled.style.backdrop = backdrop
    let solid = FrameRenderer(project: styled).image(screen: screen,camera: nil,time: 0,width: 640,height: 360)!
    precondition(abs(Int(pixel(solid,1,1)[1])-179) <= 1,"Custom solid color must reach renderer")
    backdrop.kind = .gradient; backdrop.start = RGB(1,0,0); backdrop.end = RGB(0,0,1); backdrop.angle = 0; styled.style.backdrop = backdrop
    let gradient = FrameRenderer(project: styled).image(screen: screen,camera: nil,time: 0,width: 640,height: 360)!
    precondition(pixel(gradient,1,1)[0] > 250 && pixel(gradient,638,1)[2] > 250,"Custom gradient direction/colors must reach renderer")
    let photoContext = CGContext(data: nil,width: 100,height: 100,bitsPerComponent: 8,bytesPerRow: 400,space: CGColorSpace(name: CGColorSpace.sRGB)!,bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    photoContext.setFillColor(CGColor(gray: 0,alpha: 1)); photoContext.fill(CGRect(x: 0,y: 0,width: 100,height: 100))
    photoContext.setFillColor(CGColor(gray: 1,alpha: 1)); photoContext.fill(CGRect(x: 0,y: 0,width: 50,height: 100))
    let photo = photoContext.makeImage()!
    backdrop.kind = .image; backdrop.imageFile = "background-test.png"; styled.style.backdrop = backdrop
    let photoFrame = FrameRenderer(project: styled,backgroundImage: photo).image(screen: screen,camera: nil,time: 0,width: 640,height: 360)!
    backdrop.blur = 0.04; styled.style.backdrop = backdrop
    let blurred = FrameRenderer(project: styled,backgroundImage: photo).image(screen: screen,camera: nil,time: 0,width: 640,height: 360)!
    precondition(abs(Int(pixel(photoFrame,316,1)[0])-Int(pixel(blurred,316,1)[0])) > 30,"Background blur must soften image edge")
    for preset in Background.allCases {
        styled.style.backdrop = nil; styled.style.background = preset
        precondition(FrameRenderer(project: styled).image(screen: screen,camera: nil,time: 0,width: 640,height: 360) != nil)
    }
    let assetDir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: assetDir,withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: assetDir) }
    let photoFile = assetDir.appendingPathComponent("background-test.png")
    let destination = CGImageDestinationCreateWithURL(photoFile as CFURL,"public.png" as CFString,1,nil)!
    CGImageDestinationAddImage(destination,photo,nil); precondition(CGImageDestinationFinalize(destination))
    styled.style.backdrop = backdrop
    let loadedPhoto = try BackgroundAsset.load(project: styled,directory: assetDir)
    precondition(loadedPhoto?.width == 100)
    try FileManager.default.removeItem(at: photoFile)
    do { _ = try BackgroundAsset.load(project: styled,directory: assetDir); preconditionFailure("Missing photo must not silently change export") } catch ProjectError.missingBackground { }
    if let path = ProcessInfo.processInfo.environment["REKORD_TEST_ARTIFACTS"] {
        try FileManager.default.createDirectory(atPath: path,withIntermediateDirectories: true)
        for (name, frame) in [("landscape.png",overlay),("portrait.png",portrait)] {
            let url = URL(fileURLWithPath: path).appendingPathComponent(name)
            let dst = CGImageDestinationCreateWithURL(url as CFURL,"public.png" as CFString,1,nil)!
            CGImageDestinationAddImage(dst,frame,nil); precondition(CGImageDestinationFinalize(dst))
        }
    }
    print("PASS: renderer pixels (12 palettes, custom color/gradient/photo/blur, asset loading, padding, corners, cursor, webcam, zoom follow, portrait)")
}
