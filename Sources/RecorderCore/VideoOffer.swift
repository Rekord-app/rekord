import Foundation

extension SharedVideo: Identifiable {}

public struct VideoOffer: Codable, Sendable, Identifiable {
    public let id: String
    public let videoId: String
    public let url: URL
    public let title: String
    public let recipientLabel: String
    public let message: String
    public let bookingURL: URL
    public let trackingEnabled: Bool
    public let notifyOnFirstOpen: Bool
    public let createdAt: String
    public let expiresAt: String?
    public let durationSeconds: Double
    public let summary: OfferSummary
    public var label: String { recipientLabel.isEmpty ? title : recipientLabel }
}
public struct OfferDraft: Codable, Sendable, Equatable {
    public var videoId: String
    public var creationRequestId: String
    public var title: String
    public var recipientLabel: String
    public var message: String
    public var bookingURL: String
    public var trackingEnabled: Bool
    public var notifyOnFirstOpen: Bool
    public init(videoId: String,title: String,bookingURL: String = "") {
        self.videoId = videoId; self.creationRequestId = UUID().uuidString
        self.title = title; self.recipientLabel = ""; self.message = ""; self.bookingURL = bookingURL
        self.trackingEnabled = true; self.notifyOnFirstOpen = true
    }
    public func validate() throws {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,title.utf16.count <= 180,recipientLabel.utf16.count <= 120,message.utf16.count <= 1000,
              bookingURL.utf16.count <= 2048,let url = URL(string: bookingURL),url.scheme == "https",url.host != nil,url.user == nil,url.password == nil else {
            throw ShareError.message("Bitte Titel und einen vollständigen HTTPS-Buchungslink ohne Zugangsdaten eingeben. Titel: höchstens 180 Zeichen, Nachricht: 1.000 Zeichen.")
        }
    }
}
public struct OfferSummary: Codable, Sendable {
    public let openings: Int
    public let started: Int
    public let bestPercent: Double
    public let bestPlayedSeconds: Double
    public let ctaClickCount: Int
    public let lastActivityAt: String?
    public let state: String
    public let retentionDays: Int
}
public struct OfferSession: Codable, Sendable, Identifiable {
    public let id: String
    public let openedAt: String
    public let lastActivityAt: String
    public let playedRanges: [[Double]]
    public let playedSeconds: Double
    public let percent: Double
    public let lastPosition: Double
    public let ctaClickCount: Int
}
public struct OfferAnalytics: Codable, Sendable {
    public let summary: OfferSummary
    public let entries: [OfferSession]
    public let nextCursor: String
    public let hasMore: Bool
    public let durationSeconds: Double
}
public struct OfferActivity: Codable, Sendable, Identifiable {
    public let id: String
    public let offerId: String
    public let openedAt: String
    public let title: String
    public let recipientLabel: String
    public let notifyEligible: Bool
    public let cursor: String
}
public struct OfferActivityPage: Codable, Sendable {
    public let entries: [OfferActivity]
    public let nextCursor: String
    public let hasMore: Bool
}
public struct OfferListing: Codable, Sendable {
    public let offers: [VideoOffer]
    public let nextCursor: String
    public let hasMore: Bool
}
/// Independent of UI/UNUserNotificationCenter so offline/catch-up behaviour is testable.
public struct OfferNotificationBatch: Sendable {
    public let cursor: String
    public let notifications: [OfferActivity]
    public init(previousCursor: String?,activities: [OfferActivity]) {
        cursor = max(activities.map(\.cursor).max() ?? "",previousCursor ?? "")
        notifications = previousCursor == nil ? [] : activities.filter { $0.notifyEligible && $0.cursor > previousCursor! }
    }
}
