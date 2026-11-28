import ChatModel
import ChatSync
import ChatText

extension MentionEditor {
    static let allContact = Contact(
        user: .all, displayName: "all", email: nil, directMessage: nil, source: .chats)

    static func filter(_ candidates: [Contact], prefix: String) -> [Contact] {
        let needle = prefix.lowercased()
        guard !needle.isEmpty else { return candidates }
        return candidates.filter { contact in
            let name = contact.displayName.lowercased()
            return name.hasPrefix(needle) || name.contains(" " + needle)
        }
    }

    static func token(for contact: Contact) -> String? {
        guard let user = contact.user else { return nil }
        return "@" + (user == .all ? "all" : contact.displayName)
    }

    /// Replaces the typed `@prefix` with `@Name ` and records the mention. Returns the new text and caret offset.
    mutating func insert(_ contact: Contact, into text: String, trigger: Trigger) -> (text: String, caret: Int) {
        guard let user = contact.user, let token = Self.token(for: contact) else { return (text, trigger.at) }
        return insert(user, token: token, into: text, trigger: trigger)
    }
}
