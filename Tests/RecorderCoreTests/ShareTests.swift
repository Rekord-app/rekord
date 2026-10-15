import Foundation
import RecorderCore

func testSharing(configuration: URL,artifacts: URL) async throws {
    struct Configuration: Decodable { let baseURL: URL; let token: String; let invalidReceiptBaseURL: URL? }
    let config = try JSONDecoder().decode(Configuration.self,from: Data(contentsOf: configuration))
    let client = try ShareClient(baseURL: config.baseURL,token: config.token)
    XCTAssertEqual(try await client.status().service,"focus-recorder-share")
    let file = artifacts.appendingPathComponent("motion-1080p60.mp4")
    precondition(FileManager.default.fileExists(atPath: file.path),"Run --integration first")
    let receipt = try await client.upload(file: file,title: "Native Studio/Loom · Umlaut äöü")
    XCTAssertEqual(receipt.sha256,try fileHash(file))
    let active = try await client.videos()
    precondition(active.contains { $0.id == receipt.id },"Uploaded video missing from share library")
    let (page,pageResponse) = try await URLSession.shared.data(from: receipt.url)
    XCTAssertEqual((pageResponse as! HTTPURLResponse).statusCode,200)
    precondition(String(decoding: page,as: UTF8.self).contains("Native Studio/Loom"))
    let media = config.baseURL.appendingPathComponent("media/\(receipt.id)")
    var req = URLRequest(url: media); req.setValue("bytes=0-255",forHTTPHeaderField: "Range")
    let (range,response) = try await URLSession.shared.data(for: req)
    XCTAssertEqual((response as! HTTPURLResponse).statusCode,206); XCTAssertEqual(range.count,256)
    XCTAssertEqual(range,Data(try Data(contentsOf: file).prefix(256)))
    let bad = try ShareClient(baseURL: config.baseURL,token: String(repeating: "x",count: 64))
    do { _ = try await bad.status(); preconditionFailure("Bad credentials accepted") } catch is ShareError {}
    do { _ = try ShareClient(baseURL: URL(string: "http://example.com")!,token: config.token); preconditionFailure("Non-TLS remote service accepted") } catch is ShareError {}
    try await testOfferSharing(client: client,video: receipt)
    try await client.revoke(receipt.id)
    let remaining = try await client.videos()
    precondition(!remaining.contains { $0.id == receipt.id },"Revoked video remains in share library")
    let (_,revoked) = try await URLSession.shared.data(from: receipt.url)
    XCTAssertEqual((revoked as! HTTPURLResponse).statusCode,404)
    try await client.requireGuideLifecycle()
    let guideDirectory = artifacts.appendingPathComponent("native-share-guide-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: guideDirectory,withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: guideDirectory) }
    try FileManager.default.copyItem(at: file,to: guideDirectory.appendingPathComponent("screen.mov"))
    let step = GuideStep(action: .click,text: "Only this reviewed step",element: nil,appName: nil,bundleID: nil,windowTitle: nil,url: nil,time: 0.5,position: .center)
    var guide = Guide(title: "Synthetic native guide",duration: 1,steps: [step])
    try guide.save(to: guideDirectory)
    let first = try await GuideSharing.upload(guide: guide,directory: guideDirectory,client: client)
    let saved = GuideSharing.record(in: guideDirectory)
    precondition(saved?.videoID == nil && saved?.guideID == first.id)
    let afterGuide = try await client.videos()
    precondition(!afterGuide.contains { $0.title == guide.title },"Guide uploaded raw video")
    let retry = try await GuideSharing.upload(guide: guide,directory: guideDirectory,client: client)
    XCTAssertEqual(first.id,retry.id)
    guide.title = "Edited synthetic guide"
    let edited = try await GuideSharing.upload(guide: guide,directory: guideDirectory,client: client)
    let listed = try await client.guides()
    let impact = ShareRevocation(guideID: first.id,guides: listed)
    precondition(impact.guideIDs == Set([first.id,edited.id]) && impact.videoIDs.isEmpty)
    try await client.revokeGuide(first.id)
    for id in [first.id,edited.id] {
        for route in ["g/\(id)","gi/\(id)/1.jpg"] {
            let (_,response) = try await URLSession.shared.data(from: config.baseURL.appendingPathComponent(route))
            XCTAssertEqual((response as! HTTPURLResponse).statusCode,404)
        }
    }
    try await client.revokeGuide(first.id)
    if let invalid = config.invalidReceiptBaseURL {
        try await testInvalidOfferReceipts(base: invalid,token: config.token)
        for kind in ["port","credentials","query","fragment","path","scheme"] {
            let malicious = try ShareClient(baseURL: invalid.appendingPathComponent(kind),token: config.token)
            do { _ = try await malicious.guides(); preconditionFailure("Forged guide URL accepted: \(kind)") } catch is ShareError {}
        }
        let legacy = try ShareClient(baseURL: invalid.appendingPathComponent("legacy"),token: config.token)
        do { try await legacy.requireGuideLifecycle(); preconditionFailure("Legacy server accepted") } catch is ShareError {}
        print("PASS: forged guide URL origin/port/credentials/query/fragment/path rejected; old server blocked")
    }
    print("PASS: native safe GuideSharing upload → retry → edited revision → grouped revoke → pages/images unavailable")
    print("PASS: native URLSession upload → SHA-256 receipt → browser page/range playback → revoke; invalid credentials and insecure origin rejected")
}
