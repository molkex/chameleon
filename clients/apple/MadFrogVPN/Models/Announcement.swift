import Foundation

/// INAPP-ANNOUNCEMENTS — one admin-authored in-app message, fetched from
/// GET /api/v1/mobile/announcements/active and shown as a dismissible card when
/// the app opens. `kind` drives the badge colour/label; the optional CTA renders
/// a button that opens `ctaUrl`.
struct Announcement: Decodable, Identifiable, Equatable {
    let id: Int
    let title: String
    let body: String
    let kind: String        // "info" | "promo" | "update"
    let ctaLabel: String?
    let ctaUrl: String?

    enum CodingKeys: String, CodingKey {
        case id, title, body, kind
        case ctaLabel = "cta_label"
        case ctaUrl = "cta_url"
    }

    /// A valid CTA needs both a label and a parseable URL.
    var ctaURL: URL? {
        guard let ctaLabel, !ctaLabel.isEmpty, let ctaUrl, let url = URL(string: ctaUrl) else { return nil }
        return url
    }
}
