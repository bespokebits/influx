import Foundation
import Testing
@testable import InfluxKit

/// CloudKit/schema.ckdb is what goes into the container's Production
/// environment, which refuses a record type or field it doesn't have. These
/// check it names every record type sync writes, with the fields the sync
/// framework writes them with.
@Suite struct CloudKitSchemaTests {
    private static let repo = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()

    private static func text(_ path: String) throws -> String {
        try String(contentsOf: repo.appendingPathComponent(path), encoding: .utf8)
    }

    /// Each record type's declared fields, by type name, from the schema
    /// with its comments removed.
    private static func schema() throws -> [String: [String: String]] {
        let lines = try text("CloudKit/schema.ckdb")
            .split(separator: "\n", omittingEmptySubsequences: false)
            .map { line in line.range(of: "//").map { String(line[..<$0.lowerBound]) } ?? String(line) }
        var types: [String: [String: String]] = [:]
        var current: String?
        for raw in lines {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("RECORD TYPE ") {
                let name = line.dropFirst("RECORD TYPE ".count).split(separator: " ").first.map(String.init) ?? ""
                current = name
                types[name] = [:]
            } else if line.hasPrefix(");") {
                current = nil
            } else if let type = current, !line.isEmpty, !line.hasPrefix("GRANT"), !line.hasPrefix("\"") {
                let parts = line.trimmingCharacters(in: CharacterSet(charactersIn: ",")).split(separator: " ", maxSplits: 1)
                if parts.count == 2 {
                    types[type]?[String(parts[0])] = String(parts[1])
                }
            }
        }
        return types
    }

    /// The names in InfluxSync's `Field`, by their Swift name.
    private static func syncFields() throws -> [String: String] {
        let source = try text("Influx/Sync/InfluxSync.swift")
        guard let start = source.range(of: "private enum Field {"),
              let end = source[start.upperBound...].range(of: "}") else { return [:] }
        var fields: [String: String] = [:]
        for line in source[start.upperBound..<end.lowerBound].split(separator: "\n") {
            let words = line.trimmingCharacters(in: .whitespaces).split(separator: " ")
            if words.count == 5, words[0] == "static", words[1] == "let", words[3] == "=" {
                fields[String(words[2])] = words[4].trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            }
        }
        return fields
    }

    @Test func everySyncRecordTypeIsInTheSchemaAndNothingElse() throws {
        let declared = Set(try Self.schema().keys)
        let synced = Set(SyncRecordType.allCases.map(\.rawValue))
        #expect(declared == synced.union(["Users"]))
    }

    @Test func everyRecordTypeHasTheFieldsSyncWrites() throws {
        let fields = try Self.syncFields()
        let expected = try [
            #require(fields["key"]): "ENCRYPTED STRING",
            #require(fields["payload"]): "ENCRYPTED BYTES",
            #require(fields["plainKey"]): "STRING",
            #require(fields["plainPayload"]): "BYTES",
        ]
        #expect(fields.count == 4)
        let schema = try Self.schema()
        for type in SyncRecordType.allCases {
            #expect(schema[type.rawValue] == expected, "\(type.rawValue)")
        }
    }
}
