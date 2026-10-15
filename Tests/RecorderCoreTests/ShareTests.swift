import Foundation
import RecorderCore

func testSharing(configuration: URL,artifacts: URL) async throws {
    struct Configuration: Decodable { let baseURL: URL; let token: String }
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
    try await client.revoke(receipt.id)
    let remaining = try await client.videos()
    precondition(!remaining.contains { $0.id == receipt.id },"Revoked video remains in share library")
    let (_,revoked) = try await URLSession.shared.data(from: receipt.url)
    XCTAssertEqual((revoked as! HTTPURLResponse).statusCode,404)
    print("PASS: native URLSession upload → SHA-256 receipt → browser page/range playback → revoke; invalid credentials and insecure origin rejected")
}
