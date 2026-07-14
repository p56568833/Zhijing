import Foundation

struct DocumentStateMigrationResult: Sendable {
    let favorites: Set<String>
    let chats: [String: [ChatMessage]]
    let didChange: Bool
}

enum DocumentStateStore {
    static func migrateLegacyKeys(
        favorites: Set<String>,
        chats: [String: [ChatMessage]],
        documents: [NoteDocument]
    ) -> DocumentStateMigrationResult {
        var migratedFavorites = favorites
        var migratedChats = chats
        var didChange = false

        for document in documents {
            let legacyKey = document.relativePath
            let key = document.persistenceKey
            guard legacyKey != key else { continue }

            if migratedFavorites.remove(legacyKey) != nil {
                migratedFavorites.insert(key)
                didChange = true
            }

            if let legacyMessages = migratedChats.removeValue(forKey: legacyKey) {
                migratedChats[key] = mergedMessages(
                    migratedChats[key] ?? [],
                    legacyMessages
                )
                didChange = true
            }
        }

        return DocumentStateMigrationResult(
            favorites: migratedFavorites,
            chats: migratedChats,
            didChange: didChange
        )
    }

    private static func mergedMessages(
        _ current: [ChatMessage],
        _ legacy: [ChatMessage]
    ) -> [ChatMessage] {
        var seen: Set<UUID> = []
        return (current + legacy)
            .sorted { $0.createdAt < $1.createdAt }
            .filter { seen.insert($0.id).inserted }
    }
}
