import Foundation
import RecorderCore

func testProcessPlanning() throws {
    var count = 0
    func check(_ pass: Bool,_ text: String) { precondition(pass,text); count += 1 }
    func near(_ value: Double?,_ expected: Double,_ label: String) { check(value.map { abs($0-expected) < 0.00001 } ?? false,label) }
    var i = ProcessROIInputs()
    check(ProcessROI(inputs: i,observedMinutes: 10,observedRuns: nil,hourlyRate: 60) == nil,"missing frequency is unknown, not a made-up default")
    let base = ProcessROI(inputs: i,observedMinutes: 10,observedRuns: 5,hourlyRate: 60)!
    check(base.monthlyNetValue == nil && base.paybackMonths == nil && base.firstYearROI == nil,"unknown costs must stay unknown")
    near(base.capacityValuePerMonth,108.333333333,"50 percent scenario")
    i.reviewMinutesPerRun = 1; i.monthlyCost = 20; i.setupCost = 200
    let r = ProcessROI(inputs: i,observedMinutes: 10,observedRuns: 5,hourlyRate: 60)!
    near(r.savedHoursPerMonth,1.444444444,"review time deducted")
    near(r.monthlyNetValue,66.666666667,"running costs deducted")
    near(r.paybackMonths,3,"setup break-even")
    near(r.firstYearROI,300,"year ROI after setup")
    i.minutesPerRun = 20; i.runsPerWeek = 10
    let manual = ProcessROI(inputs: i,observedMinutes: 1,observedRuns: 1,hourlyRate: 60)!
    check(manual.minutesPerRun == 20 && manual.runsPerWeek == 10,"human overrides observation")
    i.reviewMinutesPerRun = 25
    let loss = ProcessROI(inputs: i,observedMinutes: nil,observedRuns: nil,hourlyRate: 60)!
    check(loss.savedHoursPerMonth < 0 && loss.monthlyNetValue! < 0 && loss.paybackMonths == nil,"negative scenario never claims payback")
    i.setupCost = 0; i.reviewMinutesPerRun = 0
    check(ProcessROI(inputs: i,observedMinutes: nil,observedRuns: nil,hourlyRate: 60)?.firstYearROI == nil,"no divide by zero")
    for bad in [-1.0,Double.nan,Double.infinity,1e30] {
        i.minutesPerRun = bad
        check(ProcessROI(inputs: i,observedMinutes: 10,observedRuns: 5,hourlyRate: 60) == nil,"invalid input")
    }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("process-planning-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    var p = ProcessProfile(); p.goal = "Kontakt fixture@example.test"; p.exceptions = "Keine Quelle: Rückfrage"; p.roi.monthlyCost = 10
    try ProcessProfiles.save(["p-test":p],root: root)
    let restored = try ProcessProfiles.load(root: root)["p-test"]!
    check(restored.exceptions == p.exceptions && restored.roi.monthlyCost == 10,"human context and scenario persist")
    check(!restored.goal.contains("fixture@example"),"human context masked")
    let step = GuideStep(action: .click,text: "Aufgaben lesen",element: nil,appName: "Mail",bundleID: "test",windowTitle: nil,url: nil,time: 0,position: Point(0.5,0.5))
    var guide = Guide(title: "Kunden-Update",duration: 30,steps: [step]); guide.steps[0].note = "Keine Quelle: abbrechen"; guide.steps[0].speech = "fixture@example.test"
    let directory = root.appendingPathComponent("Anleitung"); try FileManager.default.createDirectory(at: directory,withIntermediateDirectories: true); try guide.save(to: directory)
    check(ProcessProfiles.guides(for: p,available: [directory]).isEmpty,"same app never auto-links a guide")
    p.guidePaths = [directory.path,root.appendingPathComponent("other").path]
    check(ProcessProfiles.guides(for: p,available: [directory])  .map(\.path) == [directory.standardizedFileURL.path],"only explicit valid library entries")
    check(ProcessProfiles.guides(for: p,available: []).isEmpty,"deleted guide excluded")
    let evidence = InventoryAI.guideEvidence(paths: [directory.path])
    let json = String(decoding: try JSONSerialization.data(withJSONObject: evidence),as: UTF8.self)
    check(json.contains("Aufgaben lesen") && json.contains("Keine Quelle") && !json.contains("fixture@example") && !json.contains("image") && !json.contains("screen.mov"),"handover includes actual guide texts without images")
    let request = String(decoding: try GuideAI.briefRequestBody(guide,context: "Ausnahme fehlt: fixture@example.test"),as: UTF8.self)
    check(request.contains("Ausnahme fehlt") && !request.contains("fixture@example"),"guide AI consumes human context")
    let groupJSON = #"{"title":"Lesen","steps":[1],"automatable":"ja","method":"api","tools":"prüfen","apiStatus":"prüfen","reason":"Fixture","effort":"S","effortHours":2}"#
    let group = try JSONDecoder().decode(AutomationBrief.Group.self,from: Data(groupJSON.utf8))
    try AutomationBrief.validate(groups: [group],stepCount: 1); count += 1
    for (groups,n) in [([group,group],1),([group],2),([],1)] {
        do { try AutomationBrief.validate(groups: groups,stepCount: n); preconditionFailure("invalid partition") } catch { count += 1 }
    }
    var old = ProcessCatalog(); old.processes = [InventoryProcess(id: "p-old",name: "Berichte",occurrences: ["a","b"])]
    var update = ProcessCatalog(); update.processes = [InventoryProcess(name: "Kundenbericht",occurrences: ["a"]),InventoryProcess(name: "Wochenbericht",occurrences: ["b"])]
    let split = ProcessCatalog.merge(existing: old,update: update)
    check(Set(split.processes.map(\.id)).count == 2,"splitting a process keeps unique IDs")
    check(split.processes.flatMap(\.occurrences).count == 2,"split does not re-add old occurrences")
    let source = try InventoryAI.handoverSource(process: old.processes[0],profile: p,guides: [directory.path],hourlyRate: 50)
    let same = try InventoryAI.handoverSource(process: old.processes[0],profile: p,guides: [directory.path],hourlyRate: 50)
    check(source == same,"same inputs have stable handover provenance")
    let newRate = try InventoryAI.handoverSource(process: old.processes[0],profile: p,guides: [directory.path],hourlyRate: 80)
    check(source != newRate,"hourly rate change makes handover stale")
    guide.steps[0].note = "Neue Ausnahme"; try guide.save(to: directory)
    let newGuide = try InventoryAI.handoverSource(process: old.processes[0],profile: p,guides: [directory.path],hourlyRate: 50)
    check(source != newGuide,"guide edits make handover stale even outside the app")
    let readiness = ProcessReadiness(process: old.processes[0],profile: p,blocks: [],guideCount: 0)
    check(!readiness.missing.isEmpty && readiness.observedRuns == 0,"readiness states evidence gaps")
    print("PASS: process planning (\(count) assertions: ROI, unknown costs, negative scenarios, persistence, explicit guide links, text-only evidence, step partition, split IDs)")
}
