import Foundation

struct DocumentStateMigrationResult: Sendable {
    let favorites: Set<String>
    let didChange: Bool
}

enum DocumentStateStore {
    static func migrateLegacyKeys(
        favorites: Set<String>,
        documents: [NoteDocument]
    ) -> DocumentStateMigrationResult {
        var migratedFavorites = favorites
        var didChange = false

        for document in documents {
            let legacyKey = document.relativePath
            let key = document.persistenceKey
            guard legacyKey != key else { continue }

            if migratedFavorites.remove(legacyKey) != nil {
                migratedFavorites.insert(key)
                didChange = true
            }
        }

        return DocumentStateMigrationResult(
            favorites: migratedFavorites,
            didChange: didChange
        )
    }
}
