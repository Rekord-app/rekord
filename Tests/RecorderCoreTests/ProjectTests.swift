import Foundation
import RecorderCore
struct ProjectTests {
    func testCutsMapSourceTimeAndSplit() throws {
        var p = Project(name: "Test", duration: 10, width: 1920, height: 1080)
        p.split(at: 3); p.split(at: 7); p.cuts.remove(at: 1)
        XCTAssertEqual(p.editedDuration, 6)
        XCTAssertEqual(p.sourceTime(at: 2), 2)
        XCTAssertEqual(p.sourceTime(at: 3), 7)
        XCTAssertEqual(p.sourceTime(at: 5), 9)
        XCTAssertEqual(p.sourceTime(at: 100), 10)
        try p.validate()
    }
    func testRejectsOverlappingCutsAndInvalidStyle() {
        var p = Project(name: "Test", duration: 10, width: 1920, height: 1080)
        p.cuts = [Cut(start: 0, end: 5), Cut(start: 4, end: 8)]
        XCTAssertThrowsError(try p.validate())
        p.cuts = [Cut(start: 0, end: 10)]; p.style.padding = .nan
        XCTAssertThrowsError(try p.validate())
    }
    func testClickClustersAndZoomEnvelope() {
        let samples = [PointerSample(time: 1, position: Point(0.95,0.1), clicked: true), PointerSample(time: 2, position: Point(0.8,0.2), clicked: true), PointerSample(time: 6, position: .center, clicked: true)]
        let zooms = Motion.automaticZooms(pointer: samples, duration: 8)
        XCTAssertEqual(zooms.count, 2)
        let track = MotionTrack(samples: samples, smoothing: 0.08)
        XCTAssertEqual(Motion.camera(at: 0, zooms: zooms, pointer: track).scale, 1)
        let camera = Motion.camera(at: 1.5, zooms: zooms, pointer: track)
        XCTAssertEqual(camera.scale, 2.0, accuracy: 0.01)
        XCTAssertLessThanOrEqual(camera.center.x, 1-0.5/camera.scale)
        // The spring has landed back at 1× well before the next zoom (5.6 s) begins.
        XCTAssertEqual(Motion.camera(at: 5.5, zooms: zooms, pointer: track).scale, 1, accuracy: 0.002)
        XCTAssertEqual(Motion.camera(at: 9.4, zooms: zooms, pointer: track).scale, 1)
    }
    func testSmoothingAndInterpolation() {
        let s = [PointerSample(time: 0, position: Point(0,0)), PointerSample(time: 0.1, position: Point(1,1))]
        let raw = MotionTrack(samples: s, smoothing: 0)
        let smooth = MotionTrack(samples: s, smoothing: 0.2)
        XCTAssertEqual(raw.sample(at: 0.05)!.position.x, 0.5, accuracy: 0.001)
        XCTAssertLessThan(smooth.sample(at: 0.1)!.position.x, 0.5)
        XCTAssertNil(MotionTrack(samples: [], smoothing: 0.1).sample(at: 0))
        let overlaps = [ZoomSegment(start: 0.2,end: 3,scale: 1.8,focus: Point(0.15,0.5),followsCursor: false),ZoomSegment(start: 1,end: 4,scale: 2.4,focus: Point(0.85,0.5),followsCursor: false)]
        let empty = MotionTrack(samples: [],smoothing: 0)
        var previous = Motion.camera(at: 0,zooms: overlaps,pointer: empty)
        for frame in 1...300 {
            let next = Motion.camera(at: Double(frame)/60,zooms: overlaps,pointer: empty)
            precondition(abs(next.center.x-previous.center.x) < 0.04,"Overlapping zooms must not jump when their strength crosses")
            precondition(abs(next.scale-previous.scale) < 0.09,"Zoom scale must ease continuously at 60fps")
            previous = next
        }
    }
    func testPersistence() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Project(name: "Roundtrip", duration: 1, width: 1280, height: 720)
        XCTAssertEqual(p.defaultExportFPS,60)
        try p.save(to: dir)
        try Data().write(to: dir.appendingPathComponent("screen.mov"))
        let loaded = try Project.load(from: dir)
        XCTAssertEqual(loaded.name, p.name); XCTAssertEqual(loaded.cuts, p.cuts)
        XCTAssertNil(loaded.style.backdrop)
        var custom = p; var backdrop = BackdropSettings(kind: .solid)
        custom.mode = .loom; XCTAssertEqual(custom.defaultExportFPS,30)
        backdrop.start = RGB(0.1,0.2,0.3); custom.style.backdrop = backdrop
        try custom.save(to: dir)
        XCTAssertEqual(try Project.load(from: dir).style.backdrop,backdrop)
        backdrop.kind = .image; backdrop.imageFile = "../../outside.png"; custom.style.backdrop = backdrop
        XCTAssertThrowsError(try custom.validate())
        backdrop.kind = .gradient; backdrop.angle = .nan; custom.style.backdrop = backdrop
        XCTAssertThrowsError(try custom.validate())
    }
}

func XCTAssertEqual<T: Equatable>(_ a: T, _ b: T, file: StaticString = #file, line: UInt = #line) { precondition(a == b, "Expected \(a) == \(b)", file: file, line: line) }
func XCTAssertEqual(_ a: Double, _ b: Double, accuracy: Double) { precondition(abs(a-b) <= accuracy, "Expected \(a) ≈ \(b)") }
func XCTAssertLessThan(_ a: Double, _ b: Double) { precondition(a < b) }
func XCTAssertLessThanOrEqual(_ a: Double, _ b: Double) { precondition(a <= b) }
func XCTAssertNil<T>(_ a: T?) { precondition(a == nil) }
func XCTAssertThrowsError(_ operation: @autoclosure () throws -> Void) { do { try operation(); preconditionFailure("Expected error") } catch {} }
@main struct CoreTestRunner {
    static func main() async throws {
        let tests = ProjectTests()
        try tests.testCutsMapSourceTimeAndSplit()
        tests.testRejectsOverlappingCutsAndInvalidStyle()
        tests.testClickClustersAndZoomEnvelope()
        tests.testSmoothingAndInterpolation()
        try tests.testPersistence()
        try testRenderer()
        try testLoomRenderer()
        testMotionBlurPreservesBrightness()
        testCrop()
        testCursorStyling()
        try testAutoZoomSettings()
        testPauseCuts()
        testCameraLayouts()
        testBackgroundArt()
        testRenameMigration()
        try testHardening()
        try testStorageCleanup()
        try testMeetings()
        try testGuides()
        testGuideSpeechAnchors()
        if let i = CommandLine.arguments.firstIndex(of: "--background-sheet"), CommandLine.arguments.count > i+2 {
            try dumpBackgroundSheet(to: URL(fileURLWithPath: CommandLine.arguments[i+1]),screen: URL(fileURLWithPath: CommandLine.arguments[i+2]))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--render-dump"), CommandLine.arguments.count > i+1 {
            try dumpRenderMatrix(to: URL(fileURLWithPath: CommandLine.arguments[i+1]))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--guide-pdf"), CommandLine.arguments.count > i+1 {
            let directory = URL(fileURLWithPath: CommandLine.arguments[i+1])
            try GuidePDF.write(try Guide.load(from: directory),directory: directory,to: directory.appendingPathComponent(GuideFile.pdf))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--guide-share"), CommandLine.arguments.count > i+1,
           let base = ProcessInfo.processInfo.environment["REKORD_SHARE_URL"].flatMap(URL.init(string:)), let token = ProcessInfo.processInfo.environment["REKORD_SHARE_TOKEN"] {
            let directory = URL(fileURLWithPath: CommandLine.arguments[i+1])
            let shared = try await GuideSharing.upload(guide: try Guide.load(from: directory),directory: directory,client: try ShareClient(baseURL: base,token: token))
            print("SHARED \(shared.url.absoluteString) · \(shared.bytes) bytes images")
        }
        if CommandLine.arguments.contains("--benchmark") { benchmarkRenderer() }
        if let i = CommandLine.arguments.firstIndex(of: "--motion-report"), CommandLine.arguments.count > i+1 {
            try motionReport(project: URL(fileURLWithPath: CommandLine.arguments[i+1]))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--export-benchmark"), CommandLine.arguments.count > i+1 {
            try await benchmarkExport(project: URL(fileURLWithPath: CommandLine.arguments[i+1]))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--playback-benchmark"), CommandLine.arguments.count > i+1 {
            try await benchmarkPlayback(project: URL(fileURLWithPath: CommandLine.arguments[i+1]))
        }
        if let i = CommandLine.arguments.firstIndex(of: "--make-demo"), CommandLine.arguments.count > i+1 {
            _ = try await makeFixture(at: URL(fileURLWithPath: CommandLine.arguments[i+1]))
        }
        if CommandLine.arguments.contains("--integration") {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REKORD_TEST_ARTIFACTS"] ?? FileManager.default.temporaryDirectory.appendingPathComponent("rekord-tests").path)
            try FileManager.default.createDirectory(at: root,withIntermediateDirectories: true)
            try await testExports(in: root)
            try await testHardeningWithMedia(in: root)
            try await testExportCancellationStress(in: root)
            try await testLoomBitRateCap(in: root)
            try await testPlaybackComposition(in: root)
        }
        if let i = CommandLine.arguments.firstIndex(of: "--share-integration"),CommandLine.arguments.count > i+1 {
            let root = URL(fileURLWithPath: ProcessInfo.processInfo.environment["REKORD_TEST_ARTIFACTS"] ?? "build/qa")
            try await testSharing(configuration: URL(fileURLWithPath: CommandLine.arguments[i+1]),artifacts: root)
        }
        print("PASS: 5 core test groups (cuts, validation, zoom, smoothing, persistence)")
    }
}
