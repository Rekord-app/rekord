import Foundation
import RecorderCore

func testVideoOffers() throws {
    let old = Data(#"{"service":"focus-recorder-share","version":1,"maxUploadBytes":1000,"availableBytes":2000}"#.utf8)
    let status = try JSONDecoder().decode(ShareServiceStatus.self,from: old)
    XCTAssertEqual(status.features,[]); XCTAssertEqual(status.supportsOffers,false)
    let new = Data(#"{"service":"focus-recorder-share","version":1,"maxUploadBytes":1000,"availableBytes":2000,"features":["expiry","video-offers-v1","future-feature"]}"#.utf8)
    XCTAssertEqual(try JSONDecoder().decode(ShareServiceStatus.self,from: new).supportsOffers,true)
    var draft = OfferDraft(videoId: String(repeating: "a",count: 32),title: "Angebot",bookingURL: "https://example.test/termin")
    try draft.validate()
    let retry = try JSONDecoder().decode(OfferDraft.self,from: JSONEncoder().encode(draft))
    XCTAssertEqual(retry,draft)
    for invalid in ["javascript:alert(1)","data:text/html,test","//example.test","http://example.test","https://user:password@example.test"] {
        draft.bookingURL = invalid; XCTAssertThrowsError(try draft.validate())
    }
    draft.bookingURL = "https://example.test"; draft.title = " "; XCTAssertThrowsError(try draft.validate())
    draft.title = "Angebot"; draft.message = String(repeating: "ä",count: 1001); XCTAssertThrowsError(try draft.validate())
    let events = try JSONDecoder().decode([OfferActivity].self,from: Data(#"[{"id":"a","offerId":"one","openedAt":"2026-10-15T10:00:00Z","title":"A","recipientLabel":"Test","notifyEligible":true,"cursor":"01|a"},{"id":"b","offerId":"two","openedAt":"2026-10-15T11:00:00Z","title":"B","recipientLabel":"","notifyEligible":false,"cursor":"02|b"},{"id":"c","offerId":"three","openedAt":"2026-10-15T12:00:00Z","title":"C","recipientLabel":"","notifyEligible":true,"cursor":"03|c"}]"#.utf8))
    let initial = OfferNotificationBatch(previousCursor: nil,activities: events)
    XCTAssertEqual(initial.notifications.count,0); XCTAssertEqual(initial.cursor,"03|c")
    let catchup = OfferNotificationBatch(previousCursor: "",activities: events)
    XCTAssertEqual(catchup.notifications.count,2); XCTAssertEqual(catchup.cursor,"03|c")
    XCTAssertEqual(OfferNotificationBatch(previousCursor: catchup.cursor,activities: events).notifications.count,0)
    XCTAssertEqual(OfferNotificationBatch(previousCursor: catchup.cursor,activities: [events[0]]).cursor,catchup.cursor)
    XCTAssertEqual(OfferNotificationBatch(previousCursor: catchup.cursor,activities: []).cursor,catchup.cursor)
    print("PASS: offer capability compatibility, draft validation/idempotency, initial/catch-up notifications and non-rewinding cursor")
}

func testOfferSharing(client: ShareClient,video: SharedVideo) async throws {
    guard try await client.status().supportsOffers else { return } // New app still shares with old servers.
    var draft = OfferDraft(videoId: video.id,title: "Synthetisches Angebot",bookingURL: "https://example.test/booking")
    draft.recipientLabel = "INTERNER TESTEMPFÄNGER"
    let a = try await client.createOffer(draft),retry = try await client.createOffer(draft)
    XCTAssertEqual(a.id,retry.id)
    draft.creationRequestId = UUID().uuidString
    let b = try await client.createOffer(draft)
    precondition(a.id != b.id); XCTAssertEqual(a.videoId,b.videoId)
    let (data,response) = try await URLSession.shared.data(from: a.url)
    XCTAssertEqual((response as! HTTPURLResponse).statusCode,200)
    let page = String(decoding: data,as: UTF8.self)
    precondition(page.contains("Termin buchen") && !page.contains(draft.recipientLabel) && !page.contains(video.id))
    let preview = try await client.offerPreview(a.id)
    let (previewData,_) = try await URLSession.shared.data(from: preview)
    precondition(String(decoding: previewData,as: UTF8.self).contains("VORSCHAU · OHNE STATISTIK"))
    XCTAssertEqual(try await client.offerAnalytics(a.id).summary.openings,0)
    let publicURL = client.baseURL.appendingPathComponent("api/offers/\(a.id)/sessions")
    var req = URLRequest(url: publicURL); req.httpMethod = "POST"
    req.httpBody = Data(#"{"consent":"playback-v1"}"#.utf8); req.setValue("application/json",forHTTPHeaderField: "Content-Type")
    var origin = URLComponents(url: client.baseURL,resolvingAgainstBaseURL: false)!; origin.path = ""
    req.setValue(origin.url!.absoluteString,forHTTPHeaderField: "Origin")
    let (_,opened) = try await URLSession.shared.data(for: req)
    XCTAssertEqual((opened as! HTTPURLResponse).statusCode,201)
    XCTAssertEqual(try await client.offerAnalytics(a.id).summary.openings,1)
    XCTAssertEqual(try await client.offerAnalytics(b.id).summary.openings,0)
    let activity = try await client.offerActivity(); precondition(activity.entries.contains { $0.offerId == a.id })
    draft.title = "Angebot geändert"; let edited = try await client.updateOffer(a.id,draft: draft); XCTAssertEqual(edited.title,draft.title)
    _ = try await client.setOfferExpiry(a.id,date: Date().addingTimeInterval(86400))
    try await client.clearOfferAnalytics(a.id); XCTAssertEqual(try await client.offerAnalytics(a.id).summary.openings,0)
    try await client.revokeOffer(a.id)
    let (_,revoked) = try await URLSession.shared.data(from: a.url); XCTAssertEqual((revoked as! HTTPURLResponse).statusCode,404)
    let remaining = try await client.offers(); precondition(remaining.offers.contains { $0.id == b.id })
    print("PASS: native offers create/retry, privacy, preview, consent, separate analytics/activity, edit/expiry/reset/revoke")
}

func testInvalidOfferReceipts(base: URL,token: String) async throws {
    for kind in ["port","credentials","query","fragment","path","scheme"] {
        let client = try ShareClient(baseURL: base.appendingPathComponent(kind),token: token)
        do { _ = try await client.offers(); preconditionFailure("Forged offer URL accepted: \(kind)") } catch is ShareError {}
    }
    let old = try ShareClient(baseURL: base.appendingPathComponent("legacy"),token: token)
    XCTAssertEqual(try await old.status().supportsOffers,false)
    print("PASS: native offer URL rejects wrong port, credentials, query, fragment, path and scheme; old server detected")
}
