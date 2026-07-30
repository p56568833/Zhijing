import Foundation

enum LocalSecretStore {
    private struct Payload: Codable {
        var values: [String: String] = [:]
    }

    private static let filename = "AISecrets.json"

    static func save(
        _ value: String,
        account: String,
        directoryOverride: URL? = nil
    ) throws {
        let directory = try storageDirectory(override: directoryOverride)
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o700],
            ofItemAtPath: directory.path
        )

        let url = directory.appending(path: filename)
        var payload = try loadPayloadForUpdate(at: url)
        if value.isEmpty {
            payload.values.removeValue(forKey: account)
        } else {
            payload.values[account] = value
        }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(payload).write(to: url, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: url.path
        )
    }

    static func read(
        account: String,
        directoryOverride: URL? = nil
    ) -> String {
        guard let directory = try? storageDirectory(override: directoryOverride) else {
            return ""
        }
        let url = directory.appending(path: filename)
        return loadPayload(at: url).values[account] ?? ""
    }

    static func storageURL(directoryOverride: URL? = nil) throws -> URL {
        try storageDirectory(override: directoryOverride)
            .appending(path: filename)
    }

    private static func loadPayload(at url: URL) -> Payload {
        guard let data = try? Data(contentsOf: url),
              let payload = try? JSONDecoder().decode(Payload.self, from: data)
        else { return Payload() }
        return payload
    }

    private static func loadPayloadForUpdate(at url: URL) throws -> Payload {
        guard FileManager.default.fileExists(atPath: url.path) else {
            return Payload()
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Payload.self, from: data)
    }

    private static func storageDirectory(override: URL?) throws -> URL {
        if let override { return override }
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        return base.appending(path: "知境", directoryHint: .isDirectory)
    }
}
