import Foundation
import RecorderCore

func testAutoZoomSettings() throws {
    let clicks = [PointerSample(time: 2,position: Point(0.3,0.4),clicked: true),PointerSample(time: 3,position: Point(0.6,0.4),clicked: true),PointerSample(time: 9,position: Point(0.8,0.2),clicked: true)]
    let standard = Motion.automaticZooms(pointer: clicks,duration: 12)
    XCTAssertEqual(standard.count,2)
    XCTAssertEqual(standard[0].start,1.6,accuracy: 0.0001); XCTAssertEqual(standard[0].end,4.8,accuracy: 0.0001); XCTAssertEqual(standard[0].scale,2,accuracy: 0)
    let custom = Motion.automaticZooms(pointer: clicks,duration: 12,settings: AutoZoomSettings(scale: 3,lead: 0.1,hold: 0.5))
    XCTAssertEqual(custom.count,3)   // short hold: the 2 s and 3 s clicks no longer merge
    XCTAssertEqual(custom[0].start,1.9,accuracy: 0.0001); XCTAssertEqual(custom[0].end,2.5,accuracy: 0.0001); XCTAssertEqual(custom[2].scale,3,accuracy: 0)
    let clipped = Motion.automaticZooms(pointer: [PointerSample(time: 11.9,position: .center,clicked: true)],duration: 12,settings: AutoZoomSettings(lead: 0,hold: 2))
    XCTAssertEqual(clipped[0].end,12,accuracy: 0.0001)
    var project = Project(name: "Zoom settings",duration: 12,width: 100,height: 100)
    project.autoZoom = AutoZoomSettings(scale: 9,lead: 0,hold: 1)
    do { try project.validate(); preconditionFailure("Invalid zoom settings must be rejected") } catch ProjectError.invalid {}
    project.autoZoom = AutoZoomSettings(scale: 2.5,lead: 0.2,hold: 2)
    let decoded = try JSONDecoder().decode(Project.self,from: JSONEncoder().encode(project))
    precondition(decoded.autoZoom == project.autoZoom)
    project.autoZoom = nil
    let legacy = try JSONDecoder().decode(Project.self,from: JSONEncoder().encode(project))
    precondition(legacy.autoZoom == nil,"Projects without settings must still load")
    print("PASS: auto-zoom strength, lead, hold, merging, clipping, validation and persistence")
}

func testPauseCuts() {
    let cuts = Project.retainedCuts(duration: 10,pauses: [(start: 6,end: 7.5),(start: 2,end: 3)])
    precondition(cuts.map(\.start) == [0,3,7.5] && cuts.map(\.end) == [2,6,10],"Pauses must become gaps between retained ranges: \(cuts)")
    let open = Project.retainedCuts(duration: 10,pauses: [(start: 8,end: 12)])
    precondition(open.count == 1 && open[0].end == 8,"A pause running into Stop ends the recording")
    let early = Project.retainedCuts(duration: 10,pauses: [(start: -1,end: 0.02),(start: 9.99,end: 10)])
    precondition(early.count == 1 && abs(early[0].start-0.02) < 0.0001 && abs(early[0].end-9.99) < 0.0001,"Tiny fragments are dropped")
    precondition(Project.retainedCuts(duration: 5,pauses: [(start: 0,end: 5)]).count == 1,"A fully paused take keeps one range")
    print("PASS: pauses become cuts (ordering, open pause at Stop, tiny fragments)")
}
