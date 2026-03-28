import Foundation

struct SupportMessage: Codable, Identifiable {
    let id: Int
    let direction: String  // "user" or "admin"
    let content: String?
    let attachments: [String]  // URLs
    let isRead: Bool
    let createdAt: Date

    var isFromUser: Bool { direction == "user" }

    enum CodingKeys: String, CodingKey {
        case id
        case direction
        case content
        case attachments
        case isRead = "is_read"
        case createdAt = "created_at"
    }
}

struct SupportMessagesResponse: Codable {
    let messages: [SupportMessage]
    let unreadAdminCount: Int

    enum CodingKeys: String, CodingKey {
        case messages
        case unreadAdminCount = "unread_admin_count"
    }
}
