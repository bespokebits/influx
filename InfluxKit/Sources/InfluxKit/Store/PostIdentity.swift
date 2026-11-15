import Foundation
import GRDB

/// Shows a rich feed's post and the other copies of the same post in one
/// row, by the identities the rich feed gives it (ADR 0014, 0031).
///
/// A rich post names itself by `{canonicalId} ∪ aliases`, and an alias can
/// name a native post the reader holds from another connector: its legacy
/// identity (`LegacyPostIdentity`). Each stored item keeps its identities in
/// `itemIdentity`: a rich post its set, a native post its legacy identity.
/// Two copies are the same post when their sets meet, directly or through a
/// chain of copies. A new copy joins the row of the earliest stored copy it
/// is the same post as, taking its merge key and keeping its own in
/// `postKey`. The copy stored first keeps its key, and nothing stored is
/// re-keyed, as for bridged copies.
///
/// Only a rich feed's aliases count, from a `.sammyFeed` source whose key
/// the store accepted as its server's (`reservingSammyPostKeys`): no other
/// connector says what another copy is. A native post counts only by the
/// URI its service gives it as the post's own ID; articles, RSS items,
/// links, text and dates never join anything, since a wrong join hides a
/// post.
enum PostIdentity {
    static let tableName = "itemIdentity"

    private static let blueskyKinds: Set<Source.Kind> = [.blueskyFollowing, .blueskyFeed]
    private static let mastodonKinds: Set<Source.Kind> = [.mastodonHome, .mastodonList]

    /// The native post identity of an item, when it has one a rich feed may
    /// name: a post from Mastodon or Bluesky, by its own ID (`postKey` when
    /// it is filed under another copy's key, else its merge key), which
    /// must be the URI its service gave it. Mastodon's is its ActivityPub
    /// URI, or the `at://` URI of a Bluesky post it carries; Bluesky's its
    /// `at://` URI. Anything else, including a key only its source uses,
    /// is nil.
    static func nativeIdentity(kind: Item.Kind, mergeKey: String, postKey: String?, sourceKind: Source.Kind) -> String? {
        guard kind == .post else { return nil }
        let own = postKey ?? mergeKey
        let schemes: [String]
        if blueskyKinds.contains(sourceKind) {
            schemes = ["at://"]
        } else if mastodonKinds.contains(sourceKind) {
            schemes = ["https://", "http://", "at://"]
        } else {
            return nil
        }
        let bytes = Array(own.utf8)
        return schemes.contains { scheme in bytes.count > scheme.utf8.count && bytes.starts(with: scheme.utf8) } ? own : nil
    }

    /// A rich post's own key (`sammy-post:<server>:<canonicalId>`), for a
    /// post of a rich feed; nil for anything else.
    static func richKey(kind: Item.Kind, mergeKey: String, postKey: String?, sourceKind: Source.Kind) -> String? {
        guard kind == .post, sourceKind == .sammyFeed else { return nil }
        let own = postKey ?? mergeKey
        return SammyPostKey.canonicalID(of: own) == nil ? nil : own
    }

    /// Which service a native post is from, so a copy is only ever found by
    /// its own ID among copies from its own service.
    private static func service(_ kind: Source.Kind) -> Int? {
        blueskyKinds.contains(kind) ? 1 : mastodonKinds.contains(kind) ? 2 : nil
    }

    /// `items`, with each new copy of a post that another copy is the same
    /// post as, by identity, given the merge key of that copy's row, and its
    /// own key as `postKey`. `isStored` says which items are stored, which
    /// keep their keys. `identities` are the rich posts' sets, by key, as
    /// their feed sent them; a set already stored for a key stands instead.
    static func joining(_ items: [Item], isStored: [Bool], identities: [String: [String]], _ db: Database) throws -> [Item] {
        let sourceIDs = Array(Set(items.map(\.sourceID)))
        let kinds = Dictionary(try Source.fetchAll(db, keys: sourceIDs).map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })

        // The new copies that can join: rich posts by their identities,
        // native posts by their legacy identity. A copy already filed
        // under another's key (a bridged copy) keeps it.
        var nodes: [Node] = []
        for index in items.indices where !(isStored.indices.contains(index) && isStored[index]) && items[index].postKey == nil {
            let item = items[index]
            guard let kind = kinds[item.sourceID] else { continue }
            if let key = richKey(kind: item.kind, mergeKey: item.mergeKey, postKey: nil, sourceKind: kind),
               let authority = SammyPostKey.authority(ofKey: key) {
                nodes.append(Node(index: index, own: key, sourceKind: kind, authority: authority))
            } else if let own = nativeIdentity(kind: item.kind, mergeKey: item.mergeKey, postKey: nil, sourceKind: kind),
                      let legacy = LegacyPostIdentity.alias(of: own) {
                nodes.append(Node(index: index, own: own, sourceKind: kind, legacy: legacy))
            }
        }
        guard !nodes.isEmpty else { return items }

        // A rich post's set: the one stored for its key, else the one sent.
        let richKeys = Array(Set(nodes.filter(\.isRich).map(\.own)))
        let storedSets = try storedSets(for: richKeys, db)
        for n in nodes.indices where nodes[n].isRich {
            let key = nodes[n].own
            nodes[n].identities = storedSets[Exact(key)] ?? sent(identities[key], for: key)
        }

        // Stored copies each node is the same post as: by its own key (the
        // post already has a row), and by identity.
        var ownRows: [Int: [Stored]] = [:]
        var identityRows: [Int: [Stored]] = [:]
        // Keys compare as bytes, as SQLite compares them: two IDs that are
        // the same text to Swift but differ in their bytes are two posts.
        let byOwn = Dictionary(grouping: nodes.indices, by: { Exact(nodes[$0].own) })
        let owns = byOwn.values.map { nodes[$0[0]].own }
        for row in try Row.fetchAll(db, SQLRequest<Row>(literal: """
            SELECT item.id, item.mergeKey, item.postKey, source.kind AS sourceKind
            FROM item JOIN source ON source.id = item.sourceID
            WHERE item.mergeKey IN \(owns) OR item.postKey IN \(owns)
            """)) {
            let stored = Stored(id: row["id"], mergeKey: row["mergeKey"])
            for n in byOwn[Exact(stored.mergeKey)] ?? [] {
                ownRows[n, default: []].append(stored)
            }
            // A copy of the post filed under another row: a rich post's
            // other copy, or a native post's copy from the same service
            // that joined a row by identity.
            guard let postKey = row["postKey"] as String?, Exact(postKey) != Exact(stored.mergeKey),
                  let sourceKind = Source.Kind(rawValue: row["sourceKind"]) else { continue }
            for n in byOwn[Exact(postKey)] ?? [] {
                let node = nodes[n]
                if node.isRich ? sourceKind == .sammyFeed : service(sourceKind) == service(node.sourceKind) {
                    ownRows[n, default: []].append(stored)
                }
            }
        }
        var byIdentity: [String: [Int]] = [:], byLegacy: [String: [Int]] = [:]
        for n in nodes.indices {
            if let legacy = nodes[n].legacy { byLegacy[legacy, default: []].append(n) }
            for identity in nodes[n].identities { byIdentity[identity, default: []].append(n) }
        }
        let tokens = Array(Set(byIdentity.keys).union(byLegacy.keys))
        for row in try Row.fetchAll(db, SQLRequest<Row>(literal: """
            SELECT identity.identity, item.id, item.mergeKey, item.postKey, source.kind AS sourceKind
            FROM \(sql: tableName) AS identity JOIN item ON item.id = identity.itemID JOIN source ON source.id = item.sourceID
            WHERE identity.identity IN \(tokens)
            """)) {
            let token: String = row["identity"]
            let stored = Stored(id: row["id"], mergeKey: row["mergeKey"])
            guard let sourceKind = Source.Kind(rawValue: row["sourceKind"]) else { continue }
            if sourceKind == .sammyFeed {
                // A stored rich post: the same post as a new rich post of
                // its own server that shares an identity with it, and as a
                // new native post it names.
                let authority = SammyPostKey.authority(ofKey: (row["postKey"] as String?) ?? stored.mergeKey).map(Exact.init)
                for n in byIdentity[token] ?? [] where authority != nil && nodes[n].authority.map(Exact.init) == authority {
                    identityRows[n, default: []].append(stored)
                }
                for n in byLegacy[token] ?? [] {
                    identityRows[n, default: []].append(stored)
                }
            } else {
                // A stored native post, named by a new rich post.
                for n in byIdentity[token] ?? [] {
                    identityRows[n, default: []].append(stored)
                }
            }
        }

        // New copies are the same post as each other in the same ways, so
        // a batch joins whole, chains included.
        var parent = Array(nodes.indices)
        func root(_ n: Int) -> Int {
            var n = n
            while parent[n] != n { parent[n] = parent[parent[n]]; n = parent[n] }
            return n
        }
        func union(_ a: Int, _ b: Int) { parent[root(a)] = root(b) }
        for same in byOwn.values { for n in same.dropFirst() { union(n, same[0]) } }
        for n in nodes.indices where nodes[n].isRich {
            for identity in nodes[n].identities {
                // Rich posts of one server that share an identity, and the
                // native posts a rich post names.
                for other in byIdentity[identity] ?? [] where nodes[other].authority.map(Exact.init) == nodes[n].authority.map(Exact.init) {
                    union(n, other)
                }
                for native in byLegacy[identity] ?? [] { union(n, native) }
            }
        }

        // Each node's row: the one its post already has; otherwise the
        // group's, which is the earliest stored row any of it already has,
        // else the earliest stored copy it is the same post as, else the
        // copy `insert` stores first.
        var groups: [Int: [Int]] = [:]
        for n in nodes.indices { groups[root(n), default: []].append(n) }
        var result = items
        for members in groups.values {
            let earliest = { (rows: [Int: [Stored]]) in members.compactMap { rows[$0]?.min { $0.id < $1.id } }.min { $0.id < $1.id } }
            let first = members.min { a, b in
                let x = items[nodes[a].index], y = items[nodes[b].index]
                return (x.placement, x.sourceID, x.remoteID) < (y.placement, y.sourceID, y.remoteID)
            }!
            let groupKey = earliest(ownRows)?.mergeKey ?? earliest(identityRows)?.mergeKey ?? nodes[first].own
            for n in members {
                let key = ownRows[n]?.min { $0.id < $1.id }?.mergeKey ?? groupKey
                let index = nodes[n].index
                guard Exact(key) != Exact(items[index].mergeKey) else { continue }
                result[index].postKey = nodes[n].own
                result[index].mergeKey = key
            }
        }
        return result
    }

    /// Records a newly stored item's identities: a rich post's set (the one
    /// already stored for its key, which never changes, else the one its
    /// feed sent), or a native post's legacy identity.
    static func record(_ item: Item, id: Int64, sourceKind: Source.Kind, identities: [String: [String]], _ db: Database) throws {
        let values: [String]
        if let key = richKey(kind: item.kind, mergeKey: item.mergeKey, postKey: item.postKey, sourceKind: sourceKind) {
            values = try storedSets(for: [key], excluding: id, db)[Exact(key)].map(Array.init) ?? Array(sent(identities[key], for: key))
        } else if let own = nativeIdentity(kind: item.kind, mergeKey: item.mergeKey, postKey: item.postKey, sourceKind: sourceKind),
                  let legacy = LegacyPostIdentity.alias(of: own) {
            values = [legacy]
        } else {
            return
        }
        for value in values {
            try db.execute(literal: "INSERT OR IGNORE INTO \(sql: tableName) (itemID, identity) VALUES (\(id), \(value))")
        }
    }

    /// Records the identities of a stored rich post that has none, as
    /// `record` would: one stored before they were kept (migration v24).
    static func recordMissing(_ item: Item, sourceKind: Source.Kind, identities: [String: [String]], _ db: Database) throws {
        guard richKey(kind: item.kind, mergeKey: item.mergeKey, postKey: item.postKey, sourceKind: sourceKind) != nil,
              let id = try Int64.fetchOne(db, SQLRequest<Int64>(literal: """
                  SELECT id FROM item WHERE sourceID = \(item.sourceID) AND remoteID = \(item.remoteID)
                      AND NOT EXISTS (SELECT 1 FROM \(sql: tableName) WHERE itemID = item.id)
                  """)) else { return }
        try record(item, id: id, sourceKind: sourceKind, identities: identities, db)
    }

    /// The set a rich feed sent for `key`, as far as it is valid, with the
    /// canonical ID the key names.
    private static func sent(_ identities: [String]?, for key: String) -> Set<String> {
        var set = Set((identities ?? []).filter(RichFeedPage.isCanonicalURN))
        if let canonical = SammyPostKey.canonicalID(of: key) { set.insert(canonical) }
        return set
    }

    /// The set stored for each of `keys`: the earliest stored copy's.
    private static func storedSets(for keys: [String], excluding id: Int64? = nil, _ db: Database) throws -> [Exact: Set<String>] {
        guard !keys.isEmpty else { return [:] }
        let wanted = Set(keys.map(Exact.init))
        var sets: [Exact: (id: Int64, set: Set<String>)] = [:]
        for row in try Row.fetchAll(db, SQLRequest<Row>(literal: """
            SELECT item.id, COALESCE(item.postKey, item.mergeKey) AS own, identity.identity
            FROM \(sql: tableName) AS identity JOIN item ON item.id = identity.itemID JOIN source ON source.id = item.sourceID
            WHERE source.kind = \(Source.Kind.sammyFeed.rawValue) AND (item.postKey IN \(keys) OR item.mergeKey IN \(keys))
                AND item.id IS NOT \(id)
            """)) {
            let own = Exact(row["own"] as String), itemID: Int64 = row["id"], identity: String = row["identity"]
            guard wanted.contains(own) else { continue }
            if let current = sets[own], current.id < itemID { continue }
            if sets[own]?.id == itemID {
                sets[own]?.set.insert(identity)
            } else {
                sets[own] = (itemID, [identity])
            }
        }
        return sets.mapValues(\.set)
    }

    private struct Node {
        var index: Int
        /// The copy's own key: a rich post's key, or a native post's ID.
        var own: String
        var sourceKind: Source.Kind
        /// For a rich post, the server its key names, and its set.
        var authority: String?
        var identities: Set<String> = []
        /// For a native post, its legacy identity.
        var legacy: String?

        var isRich: Bool { authority != nil }
    }

    /// A key as its exact UTF-8 bytes. Swift's `String ==` treats
    /// canonically equivalent text as equal; a key is equal only to the
    /// same bytes.
    private struct Exact: Hashable {
        let bytes: [UInt8]
        init(_ key: String) { bytes = Array(key.utf8) }
    }

    private struct Stored {
        var id: Int64
        var mergeKey: String
    }
}
